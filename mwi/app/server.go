package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

const (
	defaultListenAddress = "127.0.0.1:8443"
	shutdownTimeout      = 10 * time.Second
)

type serverConfig struct {
	listenAddress         string
	serverCertificateFile string
	serverKeyFile         string
	clientCAFile          string
	expectedClientID      string
}

type identityResponse struct {
	Status         string `json:"status"`
	ServerSPIFFEID string `json:"server_spiffe_id"`
	ClientSPIFFEID string `json:"client_spiffe_id"`
}

type connectionIdentity struct {
	mu             sync.RWMutex
	serverSPIFFEID string
}

func (i *connectionIdentity) setServerSPIFFEID(id string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.serverSPIFFEID = id
}

func (i *connectionIdentity) getServerSPIFFEID() string {
	i.mu.RLock()
	defer i.mu.RUnlock()
	return i.serverSPIFFEID
}

// handshakeConn carries the certificate identity from the TLS callback to the
// HTTP connection context without sharing it across concurrent handshakes.
type handshakeConn struct {
	net.Conn
	identity *connectionIdentity
}

type managedTLSListener struct {
	net.Listener
	tlsConfig *tls.Config

	mu         sync.Mutex
	identities map[net.Conn]*connectionIdentity
}

func newManagedTLSListener(listener net.Listener, tlsConfig *tls.Config) *managedTLSListener {
	return &managedTLSListener{
		Listener:   listener,
		tlsConfig:  tlsConfig,
		identities: make(map[net.Conn]*connectionIdentity),
	}
}

func (l *managedTLSListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}

	identity := &connectionIdentity{}
	tlsConn := tls.Server(&handshakeConn{Conn: conn, identity: identity}, l.tlsConfig)

	l.mu.Lock()
	l.identities[tlsConn] = identity
	l.mu.Unlock()

	return tlsConn, nil
}

type connectionIdentityContextKey struct{}

func (l *managedTLSListener) connContext(ctx context.Context, conn net.Conn) context.Context {
	l.mu.Lock()
	identity := l.identities[conn]
	l.mu.Unlock()
	if identity == nil {
		return ctx
	}
	return context.WithValue(ctx, connectionIdentityContextKey{}, identity)
}

func (l *managedTLSListener) connState(conn net.Conn, state http.ConnState) {
	if state != http.StateClosed && state != http.StateHijacked {
		return
	}
	l.mu.Lock()
	delete(l.identities, conn)
	l.mu.Unlock()
}

func main() {
	config, err := parseFlags(os.Args[1:])
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		log.Printf("configuration error: %v", err)
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, config); err != nil {
		log.Printf("server error: %v", err)
		os.Exit(1)
	}
}

func parseFlags(args []string) (serverConfig, error) {
	flags := flag.NewFlagSet("managed-mtls-server", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)

	var config serverConfig
	flags.StringVar(&config.listenAddress, "listen", defaultListenAddress, "TCP address to listen on")
	flags.StringVar(&config.serverCertificateFile, "server-cert", "", "server certificate PEM file")
	flags.StringVar(&config.serverKeyFile, "server-key", "", "server private key PEM file")
	flags.StringVar(&config.clientCAFile, "client-ca", "", "trusted client CA PEM bundle")
	flags.StringVar(&config.expectedClientID, "expected-client-spiffe-id", "", "exact client SPIFFE ID to accept")

	if err := flags.Parse(args); err != nil {
		return serverConfig{}, err
	}
	if flags.NArg() != 0 {
		return serverConfig{}, errors.New("unexpected positional arguments")
	}

	required := []struct {
		name  string
		value string
	}{
		{name: "server-cert", value: config.serverCertificateFile},
		{name: "server-key", value: config.serverKeyFile},
		{name: "client-ca", value: config.clientCAFile},
		{name: "expected-client-spiffe-id", value: config.expectedClientID},
	}
	for _, field := range required {
		if field.value == "" {
			return serverConfig{}, fmt.Errorf("-%s is required", field.name)
		}
	}
	if err := validateSPIFFEID(config.expectedClientID); err != nil {
		return serverConfig{}, fmt.Errorf("-expected-client-spiffe-id: %w", err)
	}

	return config, nil
}

func validateSPIFFEID(id string) error {
	parsed, err := url.Parse(id)
	if err != nil || parsed.Scheme != "spiffe" || parsed.Host == "" || parsed.Opaque != "" ||
		parsed.User != nil || parsed.Port() != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("must be an absolute SPIFFE URI without user info, port, query, or fragment")
	}
	return nil
}

func run(ctx context.Context, config serverConfig) error {
	listener, err := net.Listen("tcp", config.listenAddress)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()

	tlsListener := newManagedTLSListener(listener, newReloadingTLSConfig(config))
	server := &http.Server{
		Handler:           identityHandler(config.expectedClientID),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
		ConnContext:       tlsListener.connContext,
		ConnState:         tlsListener.connState,
		BaseContext: func(net.Listener) context.Context {
			return ctx
		},
	}

	log.Printf("listening on https://%s", listener.Addr())
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- server.Serve(tlsListener)
	}()

	select {
	case err := <-serveErr:
		if err == nil || errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		_ = server.Close()
		<-serveErr
		return fmt.Errorf("graceful shutdown: %w", err)
	}

	err = <-serveErr
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve during shutdown: %w", err)
	}
	return nil
}

func newReloadingTLSConfig(config serverConfig) *tls.Config {
	return &tls.Config{
		MinVersion:             tls.VersionTLS12,
		NextProtos:             []string{"http/1.1"},
		SessionTicketsDisabled: true,
		GetConfigForClient: func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			conn, ok := hello.Conn.(*handshakeConn)
			if !ok {
				return nil, errors.New("TLS connection identity is unavailable")
			}

			certificate, serverID, err := loadServerCertificate(
				config.serverCertificateFile,
				config.serverKeyFile,
			)
			if err != nil {
				return nil, err
			}
			clientCAs, err := loadClientCAs(config.clientCAFile)
			if err != nil {
				return nil, err
			}

			return &tls.Config{
				MinVersion:             tls.VersionTLS12,
				NextProtos:             []string{"http/1.1"},
				SessionTicketsDisabled: true,
				Certificates:           []tls.Certificate{certificate},
				ClientAuth:             tls.RequireAndVerifyClientCert,
				ClientCAs:              clientCAs,
				VerifyConnection: func(state tls.ConnectionState) error {
					if len(state.PeerCertificates) == 0 {
						return errors.New("client certificate is required")
					}
					if _, err := validateClientSPIFFEID(state.PeerCertificates[0], config.expectedClientID); err != nil {
						return err
					}
					conn.identity.setServerSPIFFEID(serverID)
					return nil
				},
			}, nil
		},
	}
}

func loadServerCertificate(certificateFile, keyFile string) (tls.Certificate, string, error) {
	certificate, err := tls.LoadX509KeyPair(certificateFile, keyFile)
	if err != nil {
		return tls.Certificate{}, "", fmt.Errorf("load server certificate and key: %w", err)
	}
	if len(certificate.Certificate) == 0 {
		return tls.Certificate{}, "", errors.New("server certificate chain is empty")
	}

	leaf, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		return tls.Certificate{}, "", fmt.Errorf("parse server certificate: %w", err)
	}
	serverID, err := extractServerSPIFFEID(leaf)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	certificate.Leaf = leaf
	return certificate, serverID, nil
}

func loadClientCAs(path string) (*x509.CertPool, error) {
	bundle, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read client CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(bundle) {
		return nil, errors.New("client CA bundle contains no certificates")
	}
	return pool, nil
}

func validateClientSPIFFEID(certificate *x509.Certificate, expected string) (string, error) {
	if certificate == nil || len(certificate.URIs) != 1 || certificate.URIs[0] == nil {
		return "", errors.New("client certificate must contain exactly one URI SAN")
	}
	observed := certificate.URIs[0].String()
	if observed != expected {
		return "", errors.New("client certificate URI SAN does not match the expected SPIFFE ID")
	}
	return observed, nil
}

func extractServerSPIFFEID(certificate *x509.Certificate) (string, error) {
	if certificate == nil {
		return "", errors.New("server certificate is missing")
	}

	var identity string
	for _, uri := range certificate.URIs {
		if uri == nil || uri.Scheme != "spiffe" {
			continue
		}
		if identity != "" {
			return "", errors.New("server certificate contains multiple SPIFFE URI SANs")
		}
		identity = uri.String()
	}
	if identity == "" {
		return "", errors.New("server certificate does not contain a SPIFFE URI SAN")
	}
	return identity, nil
}

func identityHandler(expectedClientID string) http.Handler {
	return http.HandlerFunc(func(responseWriter http.ResponseWriter, request *http.Request) {
		if request.TLS == nil || len(request.TLS.PeerCertificates) == 0 {
			http.Error(responseWriter, "client certificate is required", http.StatusUnauthorized)
			return
		}

		clientID, err := validateClientSPIFFEID(request.TLS.PeerCertificates[0], expectedClientID)
		if err != nil {
			http.Error(responseWriter, "client identity is not authorized", http.StatusUnauthorized)
			return
		}
		identity, ok := request.Context().Value(connectionIdentityContextKey{}).(*connectionIdentity)
		if !ok {
			http.Error(responseWriter, "server identity is unavailable", http.StatusInternalServerError)
			return
		}
		serverID := identity.getServerSPIFFEID()
		if serverID == "" {
			http.Error(responseWriter, "server identity is unavailable", http.StatusInternalServerError)
			return
		}

		responseWriter.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(responseWriter).Encode(identityResponse{
			Status:         "ok",
			ServerSPIFFEID: serverID,
			ClientSPIFFEID: clientID,
		})
	})
}
