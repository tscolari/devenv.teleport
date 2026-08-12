package main

import (
	"crypto/x509"
	"net/url"
	"testing"
)

func TestValidateClientSPIFFEID(t *testing.T) {
	const expected = "spiffe://example.test/workload/client"

	tests := []struct {
		name    string
		uris    []string
		wantErr bool
	}{
		{
			name: "exact match",
			uris: []string{expected},
		},
		{
			name:    "wrong URI",
			uris:    []string{"spiffe://example.test/workload/other"},
			wantErr: true,
		},
		{
			name:    "missing URI",
			wantErr: true,
		},
		{
			name:    "multiple URIs",
			uris:    []string{expected, expected},
			wantErr: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			certificate := &x509.Certificate{}
			for _, rawURI := range test.uris {
				certificate.URIs = append(certificate.URIs, parseTestURI(t, rawURI))
			}

			got, err := validateClientSPIFFEID(certificate, expected)
			if test.wantErr {
				if err == nil {
					t.Fatal("validateClientSPIFFEID() returned no error")
				}
				return
			}
			if err != nil {
				t.Fatalf("validateClientSPIFFEID() error = %v", err)
			}
			if got != expected {
				t.Fatalf("validateClientSPIFFEID() = %q, want %q", got, expected)
			}
		})
	}
}

func TestExtractServerSPIFFEID(t *testing.T) {
	const expected = "spiffe://example.test/workload/server"

	tests := []struct {
		name    string
		uris    []string
		want    string
		wantErr bool
	}{
		{
			name: "extracts SPIFFE URI",
			uris: []string{expected},
			want: expected,
		},
		{
			name: "ignores non-SPIFFE URI",
			uris: []string{"https://example.test/server", expected},
			want: expected,
		},
		{
			name:    "missing SPIFFE URI",
			uris:    []string{"https://example.test/server"},
			wantErr: true,
		},
		{
			name:    "multiple SPIFFE URIs",
			uris:    []string{expected, "spiffe://example.test/workload/other"},
			wantErr: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			certificate := &x509.Certificate{}
			for _, rawURI := range test.uris {
				certificate.URIs = append(certificate.URIs, parseTestURI(t, rawURI))
			}

			got, err := extractServerSPIFFEID(certificate)
			if test.wantErr {
				if err == nil {
					t.Fatal("extractServerSPIFFEID() returned no error")
				}
				return
			}
			if err != nil {
				t.Fatalf("extractServerSPIFFEID() error = %v", err)
			}
			if got != test.want {
				t.Fatalf("extractServerSPIFFEID() = %q, want %q", got, test.want)
			}
		})
	}
}

func parseTestURI(t *testing.T, rawURI string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(rawURI)
	if err != nil {
		t.Fatalf("url.Parse(%q) error = %v", rawURI, err)
	}
	return parsed
}
