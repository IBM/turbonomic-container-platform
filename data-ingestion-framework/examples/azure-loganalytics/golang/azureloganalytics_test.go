package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Dummy credential.
const (
	testClientID      = "client-id"
	testTenantID      = "tenant-id"
	testSecret        = "super-secret"         // pragma: allowlist secret
	testSpecialSecret = "p@ss w/rd+&=%special" // pragma: allowlist secret
)

// testTargetInfoYAML builds target-info YAML for the given secret.
func testTargetInfoYAML(secret string) string {
	return fmt.Sprintf("client: %s\ntenant: %s\nkey: %q\n", testClientID, testTenantID, secret)
}

func resetAzureExampleGlobals() {
	workspaces = nil
	targetInfoPath = ""
	hostMap = nil
	client = nil
}

func TestResolveTargetInfoPath(t *testing.T) {
	baseDir := filepath.Join(string(os.PathSeparator), "tmp", "targets")

	tests := []struct {
		name     string
		targetID string
		wantErr  string
	}{
		{name: "valid target id", targetID: "cluster-a"},
		{name: "reject parent traversal", targetID: "../evil", wantErr: "invalid TARGET_ID"},
		{name: "reject nested path", targetID: "foo/bar", wantErr: "invalid TARGET_ID"},
		{name: "reject current dir", targetID: ".", wantErr: "invalid TARGET_ID"},
		{name: "reject parent dir", targetID: "..", wantErr: "invalid TARGET_ID"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveTargetInfoPath(baseDir, tc.targetID)
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tc.wantErr)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("expected error containing %q, got %q", tc.wantErr, err.Error())
				}
				return
			}

			if err != nil {
				t.Fatalf("resolveTargetInfoPath() unexpected error: %v", err)
			}

			want := filepath.Join(baseDir, tc.targetID)
			if got != want {
				t.Fatalf("resolveTargetInfoPath() = %q, want %q", got, want)
			}
		})
	}
}

func TestLoadTargetInfo(t *testing.T) {
	tempDir := t.TempDir()
	targetFile := filepath.Join(tempDir, "target.yaml")
	content := testTargetInfoYAML(testSecret)
	if err := os.WriteFile(targetFile, []byte(content), 0o600); err != nil {
		t.Fatalf("failed to write temp target file: %v", err)
	}

	targetInfo, err := loadTargetInfo(targetFile)
	if err != nil {
		t.Fatalf("loadTargetInfo() unexpected error: %v", err)
	}

	if targetInfo.ClientID != testClientID {
		t.Fatalf("ClientID = %q, want %q", targetInfo.ClientID, testClientID)
	}
	if targetInfo.TenantID != testTenantID {
		t.Fatalf("TenantID = %q, want %q", targetInfo.TenantID, testTenantID)
	}
	if string(targetInfo.Secret) != testSecret {
		t.Fatalf("Secret = %q, want %q", string(targetInfo.Secret), testSecret)
	}
}

func TestInitializeFromEnv(t *testing.T) {
	resetAzureExampleGlobals()
	t.Cleanup(resetAzureExampleGlobals)

	tempDir := t.TempDir()
	targetID := "target.yaml"
	targetFile := filepath.Join(tempDir, targetID)
	content := testTargetInfoYAML(testSecret)
	if err := os.WriteFile(targetFile, []byte(content), 0o600); err != nil {
		t.Fatalf("failed to write temp target file: %v", err)
	}

	t.Setenv("AZURE_LOG_ANALYTICS_WORKSPACES", "ws-1,ws-2")
	t.Setenv("TARGET_INFO_LOCATION", tempDir)
	t.Setenv("TARGET_ID", targetID)

	if err := initializeFromEnv(); err != nil {
		t.Fatalf("initializeFromEnv() unexpected error: %v", err)
	}

	if len(workspaces) != 2 || workspaces[0] != "ws-1" || workspaces[1] != "ws-2" {
		t.Fatalf("workspaces = %#v, want [ws-1 ws-2]", workspaces)
	}

	wantTargetInfoPath := filepath.Join(tempDir, targetID)
	if targetInfoPath != wantTargetInfoPath {
		t.Fatalf("targetInfoPath = %q, want %q", targetInfoPath, wantTargetInfoPath)
	}

	if client == nil {
		t.Fatalf("client was not initialized")
	}

	if hostMap == nil {
		t.Fatalf("hostMap was not initialized")
	}
}

func TestSensitiveBytesClear(t *testing.T) {
	secret := sensitiveBytes(testSecret)
	secret.Clear()

	for i, b := range secret {
		if b != 0 {
			t.Fatalf("secret byte %d = %d, want 0", i, b)
		}
	}
}

// TestSensitiveBytesStringRedacted checks the secret is masked when formatted.
func TestSensitiveBytesStringRedacted(t *testing.T) {
	secret := sensitiveBytes(testSecret)

	if got := secret.String(); got != "xxxx" {
		t.Fatalf("String() = %q, want %q", got, "xxxx")
	}
	if got := fmt.Sprintf("%v", secret); strings.Contains(got, testSecret) {
		t.Fatalf("formatting sensitiveBytes leaked secret: %q", got)
	}

	info := TargetInfo{ClientID: "c", TenantID: "t", Secret: secret}
	if got := fmt.Sprintf("%v", info); strings.Contains(got, testSecret) {
		t.Fatalf("formatting TargetInfo leaked secret: %q", got)
	}
}

// rewriteTransport sends every request to the test server.
type rewriteTransport struct {
	base *url.URL
	rt   http.RoundTripper
}

func (t rewriteTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req.URL.Scheme = t.base.Scheme
	req.URL.Host = t.base.Host
	req.Host = t.base.Host
	return t.rt.RoundTrip(req)
}

// TestLogin checks login sends the secret correctly and returns the token.
func TestLogin(t *testing.T) {
	resetAzureExampleGlobals()
	t.Cleanup(resetAzureExampleGlobals)

	wantSecret := testSpecialSecret
	var gotSecret, gotClientID, gotGrantType string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Errorf("server failed to parse form: %v", err)
		}
		gotSecret = r.PostFormValue("client_secret")
		gotClientID = r.PostFormValue("client_id")
		gotGrantType = r.PostFormValue("grant_type")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"test-token"}`))
	}))
	defer server.Close()

	serverURL, err := url.Parse(server.URL)
	if err != nil {
		t.Fatalf("failed to parse server URL: %v", err)
	}
	client = &http.Client{Transport: rewriteTransport{base: serverURL, rt: http.DefaultTransport}}

	tempDir := t.TempDir()
	targetID := "target.yaml"
	targetFile := filepath.Join(tempDir, targetID)
	content := testTargetInfoYAML(wantSecret)
	if err := os.WriteFile(targetFile, []byte(content), 0o600); err != nil {
		t.Fatalf("failed to write temp target file: %v", err)
	}
	targetInfoPath = targetFile

	token, err := login()
	if err != nil {
		t.Fatalf("login() unexpected error: %v", err)
	}

	if token != "test-token" {
		t.Fatalf("token = %q, want %q", token, "test-token")
	}
	if gotSecret != wantSecret {
		t.Fatalf("server received client_secret = %q, want %q", gotSecret, wantSecret)
	}
	if gotClientID != "client-id" {
		t.Fatalf("server received client_id = %q, want %q", gotClientID, "client-id")
	}
	if gotGrantType != defaultGrantType {
		t.Fatalf("server received grant_type = %q, want %q", gotGrantType, defaultGrantType)
	}
}
