// sds-client verifies that tbot's SDS endpoint correctly serves VTD resources.
// It connects to a tbot Workload API Unix socket, issues FetchSecrets requests
// for various SDS resource names, and validates the responses contain the
// expected VTD trust bundles and SVIDs.
//
// Usage:
//
//	go run ./mwi/sds-client \
//	  -socket /tmp/tpdev-mwi-alpha/workload.sock \
//	  -vtd-trust-domain alpha.teleport-local \
//	  -cluster-trust-domain teleport-local
package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	tlsv3 "github.com/envoyproxy/go-control-plane/envoy/extensions/transport_sockets/tls/v3"
	discoveryv3 "github.com/envoyproxy/go-control-plane/envoy/service/discovery/v3"
	secretv3 "github.com/envoyproxy/go-control-plane/envoy/service/secret/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
)

type config struct {
	socket             string
	vtdTrustDomain     string
	clusterTrustDomain string
	jsonOutput         bool
}

type testResult struct {
	Name    string `json:"name"`
	Pass    bool   `json:"pass"`
	Message string `json:"message,omitempty"`
}

type report struct {
	Results []testResult `json:"results"`
	Pass    bool         `json:"pass"`
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.socket, "socket", "", "path to tbot workload API unix socket")
	flag.StringVar(&cfg.vtdTrustDomain, "vtd-trust-domain", "", "expected VTD trust domain name (e.g., alpha.teleport-local)")
	flag.StringVar(&cfg.clusterTrustDomain, "cluster-trust-domain", "", "expected cluster trust domain name (e.g., teleport-local)")
	flag.BoolVar(&cfg.jsonOutput, "json", false, "output results as JSON")
	flag.Parse()

	if cfg.socket == "" || cfg.vtdTrustDomain == "" || cfg.clusterTrustDomain == "" {
		fmt.Fprintf(os.Stderr, "all flags are required: -socket, -vtd-trust-domain, -cluster-trust-domain\n")
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	conn, err := grpc.NewClient(
		"unix://"+cfg.socket,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	client := secretv3.NewSecretDiscoveryServiceClient(conn)

	r := &report{}

	// Test 1: Request "ALL" — should contain both VTD and cluster trust domains
	r.run("ALL contains VTD and cluster trust domains", func() (bool, string) {
		return testAllBundle(ctx, client, cfg)
	})

	// Test 2: Request specific VTD bundle by spiffe:// ID
	r.run("specific VTD bundle request", func() (bool, string) {
		return testSpecificVTDBundle(ctx, client, cfg)
	})

	// Test 3: Request "ROOTCA" — should contain only cluster trust domain
	r.run("ROOTCA returns only cluster trust domain", func() (bool, string) {
		return testROOTCA(ctx, client, cfg)
	})

	// Test 4: Request "default" SVID — should get a valid SVID
	r.run("default SVID is served", func() (bool, string) {
		return testDefaultSVID(ctx, client, cfg)
	})

	// Test 5: Request all (empty names) — should include VTD SVID and VTD bundle
	r.run("empty resource names returns VTD SVID and bundles", func() (bool, string) {
		return testReturnAll(ctx, client, cfg)
	})

	// Test 6: Request specific VTD SVID by SPIFFE ID prefix match
	r.run("VTD SVID requestable by SPIFFE ID", func() (bool, string) {
		return testVTDSVID(ctx, client, cfg)
	})

	r.Pass = true
	for _, result := range r.Results {
		if !result.Pass {
			r.Pass = false
			break
		}
	}

	if cfg.jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(r)
	} else {
		fmt.Printf("1..%d\n", len(r.Results))
		for i, result := range r.Results {
			if result.Pass {
				fmt.Printf("ok %d %s\n", i+1, result.Name)
			} else {
				fmt.Printf("not ok %d %s\n", i+1, result.Name)
				if result.Message != "" {
					fmt.Printf("  # %s\n", result.Message)
				}
			}
		}
	}

	if !r.Pass {
		os.Exit(1)
	}
}

func (r *report) run(name string, fn func() (bool, string)) {
	pass, msg := fn()
	r.Results = append(r.Results, testResult{Name: name, Pass: pass, Message: msg})
}

func fetchSecrets(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, resourceNames []string) (*discoveryv3.DiscoveryResponse, error) {
	req := &discoveryv3.DiscoveryRequest{
		TypeUrl:       "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret",
		ResourceNames: resourceNames,
		Node: &corev3.Node{
			Id:            "sds-client-test",
			UserAgentName: "envoy",
			UserAgentVersionType: &corev3.Node_UserAgentBuildVersion{
				UserAgentBuildVersion: &corev3.BuildVersion{
					Version: &typev3.SemanticVersion{
						MajorNumber: 1,
						MinorNumber: 31,
						Patch:       0,
					},
				},
			},
		},
	}
	return client.FetchSecrets(ctx, req)
}

func parseSecrets(resp *discoveryv3.DiscoveryResponse) ([]*tlsv3.Secret, error) {
	var secrets []*tlsv3.Secret
	for _, any := range resp.Resources {
		secret := &tlsv3.Secret{}
		if err := anypb.UnmarshalTo(any, secret, proto.UnmarshalOptions{}); err != nil {
			return nil, fmt.Errorf("unmarshal secret: %w", err)
		}
		secrets = append(secrets, secret)
	}
	return secrets, nil
}

func extractValidationTrustDomains(secret *tlsv3.Secret) ([]string, error) {
	vc := secret.GetValidationContext()
	if vc == nil {
		return nil, fmt.Errorf("secret %q is not a validation context", secret.Name)
	}
	custom := vc.GetCustomValidatorConfig()
	if custom == nil {
		return nil, fmt.Errorf("secret %q has no custom validator config", secret.Name)
	}
	spiffeConfig := &tlsv3.SPIFFECertValidatorConfig{}
	if err := anypb.UnmarshalTo(custom.TypedConfig, spiffeConfig, proto.UnmarshalOptions{}); err != nil {
		return nil, fmt.Errorf("unmarshal SPIFFE config: %w", err)
	}
	var names []string
	for _, td := range spiffeConfig.TrustDomains {
		names = append(names, td.Name)
	}
	return names, nil
}

func testAllBundle(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, cfg config) (bool, string) {
	resp, err := fetchSecrets(ctx, client, []string{"ALL"})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets failed: %v", err)
	}
	secrets, err := parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}

	for _, secret := range secrets {
		if secret.Name != "ALL" {
			continue
		}
		tds, err := extractValidationTrustDomains(secret)
		if err != nil {
			return false, err.Error()
		}
		hasVTD := false
		hasCluster := false
		for _, td := range tds {
			if td == cfg.vtdTrustDomain {
				hasVTD = true
			}
			if td == cfg.clusterTrustDomain {
				hasCluster = true
			}
		}
		if !hasVTD {
			return false, fmt.Sprintf("ALL bundle missing VTD trust domain %q, got: %v", cfg.vtdTrustDomain, tds)
		}
		if !hasCluster {
			return false, fmt.Sprintf("ALL bundle missing cluster trust domain %q, got: %v", cfg.clusterTrustDomain, tds)
		}
		return true, fmt.Sprintf("trust domains: %v", tds)
	}
	return false, "no secret named ALL in response"
}

func testSpecificVTDBundle(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, cfg config) (bool, string) {
	vtdID := "spiffe://" + cfg.vtdTrustDomain
	resp, err := fetchSecrets(ctx, client, []string{vtdID})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets failed: %v", err)
	}
	secrets, err := parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}
	if len(secrets) == 0 {
		return false, "no secrets returned"
	}

	for _, secret := range secrets {
		if secret.Name != vtdID {
			continue
		}
		tds, err := extractValidationTrustDomains(secret)
		if err != nil {
			return false, err.Error()
		}
		if len(tds) != 1 || tds[0] != cfg.vtdTrustDomain {
			return false, fmt.Sprintf("expected only %q, got: %v", cfg.vtdTrustDomain, tds)
		}
		return true, fmt.Sprintf("contains exactly: %v", tds)
	}
	return false, fmt.Sprintf("no secret named %q in response", vtdID)
}

func testROOTCA(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, cfg config) (bool, string) {
	resp, err := fetchSecrets(ctx, client, []string{"ROOTCA"})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets failed: %v", err)
	}
	secrets, err := parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}

	for _, secret := range secrets {
		if secret.Name != "ROOTCA" {
			continue
		}
		tds, err := extractValidationTrustDomains(secret)
		if err != nil {
			return false, err.Error()
		}
		for _, td := range tds {
			if td == cfg.vtdTrustDomain {
				return false, fmt.Sprintf("ROOTCA should not contain VTD %q, got: %v", cfg.vtdTrustDomain, tds)
			}
		}
		hasCluster := false
		for _, td := range tds {
			if td == cfg.clusterTrustDomain {
				hasCluster = true
			}
		}
		if !hasCluster {
			return false, fmt.Sprintf("ROOTCA missing cluster trust domain %q, got: %v", cfg.clusterTrustDomain, tds)
		}
		return true, fmt.Sprintf("contains only: %v", tds)
	}
	return false, "no secret named ROOTCA in response"
}

func testDefaultSVID(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, cfg config) (bool, string) {
	resp, err := fetchSecrets(ctx, client, []string{"default"})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets failed: %v", err)
	}
	secrets, err := parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}

	for _, secret := range secrets {
		if secret.Name != "default" {
			continue
		}
		tlsCert := secret.GetTlsCertificate()
		if tlsCert == nil {
			return false, "default secret is not a TLS certificate"
		}
		certPEM := tlsCert.GetCertificateChain().GetInlineBytes()
		if len(certPEM) == 0 {
			return false, "default certificate chain is empty"
		}
		// Parse the first cert to extract the SPIFFE ID
		block, _ := pem.Decode(certPEM)
		if block == nil {
			return false, "failed to decode PEM certificate"
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return false, fmt.Sprintf("parse certificate: %v", err)
		}
		if len(cert.URIs) == 0 {
			return false, "certificate has no URI SANs (expected SPIFFE ID)"
		}
		spiffeID := cert.URIs[0].String()
		return true, fmt.Sprintf("SPIFFE ID: %s", spiffeID)
	}
	return false, "no secret named default in response"
}

func testReturnAll(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, cfg config) (bool, string) {
	resp, err := fetchSecrets(ctx, client, []string{})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets failed: %v", err)
	}
	secrets, err := parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}

	vtdBundleID := "spiffe://" + cfg.vtdTrustDomain
	hasVTDBundle := false
	hasVTDSVID := false
	var svidIDs []string

	for _, secret := range secrets {
		if secret.Name == vtdBundleID {
			hasVTDBundle = true
		}
		if tlsCert := secret.GetTlsCertificate(); tlsCert != nil {
			certPEM := tlsCert.GetCertificateChain().GetInlineBytes()
			block, _ := pem.Decode(certPEM)
			if block != nil {
				cert, err := x509.ParseCertificate(block.Bytes)
				if err == nil && len(cert.URIs) > 0 {
					id := cert.URIs[0].String()
					svidIDs = append(svidIDs, id)
					if strings.HasPrefix(id, "spiffe://"+cfg.vtdTrustDomain+"/") {
						hasVTDSVID = true
					}
				}
			}
		}
	}

	if !hasVTDBundle {
		return false, fmt.Sprintf("VTD bundle %q not found in response", vtdBundleID)
	}
	if !hasVTDSVID {
		return false, fmt.Sprintf("no SVID with VTD trust domain prefix found, SVIDs: %v", svidIDs)
	}
	return true, fmt.Sprintf("VTD bundle present, VTD SVIDs: %v", svidIDs)
}

func testVTDSVID(ctx context.Context, client secretv3.SecretDiscoveryServiceClient, cfg config) (bool, string) {
	// First, discover what VTD SVIDs are available by requesting all
	resp, err := fetchSecrets(ctx, client, []string{})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets (discover) failed: %v", err)
	}
	secrets, err := parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}

	// Find a VTD SVID's SPIFFE ID
	var vtdSVIDName string
	for _, secret := range secrets {
		if tlsCert := secret.GetTlsCertificate(); tlsCert != nil {
			if strings.HasPrefix(secret.Name, "spiffe://"+cfg.vtdTrustDomain+"/") {
				vtdSVIDName = secret.Name
				break
			}
		}
	}
	if vtdSVIDName == "" {
		return false, "no VTD SVID found in full listing"
	}

	// Now request it specifically
	resp, err = fetchSecrets(ctx, client, []string{vtdSVIDName})
	if err != nil {
		return false, fmt.Sprintf("FetchSecrets(%q) failed: %v", vtdSVIDName, err)
	}
	secrets, err = parseSecrets(resp)
	if err != nil {
		return false, fmt.Sprintf("parse secrets: %v", err)
	}
	if len(secrets) != 1 {
		return false, fmt.Sprintf("expected 1 secret, got %d", len(secrets))
	}
	if secrets[0].Name != vtdSVIDName {
		return false, fmt.Sprintf("expected name %q, got %q", vtdSVIDName, secrets[0].Name)
	}
	return true, fmt.Sprintf("fetched: %s", vtdSVIDName)
}
