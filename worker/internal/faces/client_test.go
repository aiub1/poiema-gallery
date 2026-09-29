package faces

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClient_Detect_SendsTokenAndParsesResponse(t *testing.T) {
	var gotToken string
	var gotBody detectRequest

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotToken = r.Header.Get("X-Service-Token")
		if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
			t.Fatalf("decodificar corpo da requisição: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(detectResponse{
			Faces: []Face{{Embedding: []float32{0.1, 0.2}, BBox: BBox{X: 1, Y: 2, W: 3, H: 4}, Quality: 0.9}},
		})
	}))
	defer server.Close()

	client := NewClient(server.URL, "dev-token", time.Second)
	faces, err := client.Detect(context.Background(), "https://example.invalid/signed")
	if err != nil {
		t.Fatalf("Detect retornou erro: %v", err)
	}

	if gotToken != "dev-token" {
		t.Errorf("X-Service-Token = %q, esperado %q", gotToken, "dev-token")
	}
	if gotBody.ImageURL != "https://example.invalid/signed" {
		t.Errorf("image_url enviado = %q", gotBody.ImageURL)
	}
	if len(faces) != 1 || faces[0].Quality != 0.9 {
		t.Fatalf("resposta decodificada incorretamente: %+v", faces)
	}
}

func TestClient_Detect_NonOKStatusIsError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()

	client := NewClient(server.URL, "dev-token", time.Second)
	_, err := client.Detect(context.Background(), "https://example.invalid/signed")
	if err == nil {
		t.Fatal("esperava erro para status 401, recebeu nil")
	}
}

func TestNewClient_DefaultsTimeoutWhenUnset(t *testing.T) {
	client := NewClient("https://example.invalid", "dev-token", 0)
	if client.HTTPClient.Timeout != DefaultTimeout {
		t.Errorf("Timeout = %s, esperado o padrão %s", client.HTTPClient.Timeout, DefaultTimeout)
	}
}

func TestNewClient_UsesGivenTimeout(t *testing.T) {
	client := NewClient("https://example.invalid", "dev-token", 90*time.Second)
	if client.HTTPClient.Timeout != 90*time.Second {
		t.Errorf("Timeout = %s, esperado 90s", client.HTTPClient.Timeout)
	}
}
