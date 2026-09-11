// Package faces é o cliente HTTP do serviço de reconhecimento facial
// (services/face/, docs/CONTRATO.md §3). Nunca loga corpo de request ou
// response: pode conter a URL assinada de leitura ou, em tese, o embedding.
package faces

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// BBox espelha o bbox retornado por /detect (services/face/main.py).
type BBox struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	W float64 `json:"w"`
	H float64 `json:"h"`
}

// Face é um rosto detectado, com embedding de 512 dimensões L2-normalizado
// (InsightFace buffalo_l — ARQUITETURA.md §7).
type Face struct {
	Embedding []float32 `json:"embedding"`
	BBox      BBox      `json:"bbox"`
	Quality   float32   `json:"quality"`
}

// Detector é a interface consumida por internal/jobs — permite um fake nos
// testes de unidade sem chamar o serviço facial de verdade (CLAUDE.md §8).
type Detector interface {
	Detect(ctx context.Context, imageURL string) ([]Face, error)
}

// Client implementa Detector chamando POST /detect com autenticação por
// X-Service-Token (docs/CONTRATO.md §3).
type Client struct {
	BaseURL      string
	ServiceToken string
	MinQuality   float64
	HTTPClient   *http.Client
}

func NewClient(baseURL, serviceToken string) *Client {
	return &Client{
		BaseURL:      baseURL,
		ServiceToken: serviceToken,
		MinQuality:   0.5,
		HTTPClient:   &http.Client{Timeout: 30 * time.Second},
	}
}

type detectRequest struct {
	ImageURL   string  `json:"image_url"`
	MinQuality float64 `json:"min_quality"`
}

type detectResponse struct {
	Faces []Face `json:"faces"`
}

func (c *Client) Detect(ctx context.Context, imageURL string) ([]Face, error) {
	body, err := json.Marshal(detectRequest{ImageURL: imageURL, MinQuality: c.MinQuality})
	if err != nil {
		return nil, fmt.Errorf("faces: codificar requisição: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/detect", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("faces: montar requisição: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Service-Token", c.ServiceToken)

	resp, err := c.httpClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("faces: chamar /detect: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Só o status entra no erro — o corpo pode ecoar a URL assinada.
		return nil, fmt.Errorf("faces: /detect respondeu status %d", resp.StatusCode)
	}

	var out detectResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("faces: decodificar resposta: %w", err)
	}
	return out.Faces, nil
}

func (c *Client) httpClient() *http.Client {
	if c.HTTPClient != nil {
		return c.HTTPClient
	}
	return http.DefaultClient
}
