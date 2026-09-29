package jobs

import (
	"context"
	"fmt"

	"github.com/aiub1/poiema-gallery/worker/internal/faces"
)

// PhotoStore é a projeção de photos/photo_faces usada pelo job index_faces.
type PhotoStore interface {
	LoadPhoto(ctx context.Context, photoID string) (Photo, error)
	MarkPhotoSkipped(ctx context.Context, photoID string) error
	MarkPhotoIndexed(ctx context.Context, photoID string) error
	MarkPhotoFailed(ctx context.Context, photoID string) error
	SaveFaces(ctx context.Context, photo Photo, detected []faces.Face) error
}

// URLSigner assina a URL de leitura temporária do R2 (docs/ARQUITETURA.md §8).
type URLSigner interface {
	SignedReadURL(ctx context.Context, storageKey string) (string, error)
}

// IndexFacesDeps são as dependências do handler, injetáveis nos testes.
type IndexFacesDeps struct {
	Photos   PhotoStore
	Signer   URLSigner
	Detector faces.Detector
}

// HandleIndexFaces processa um job "index_faces".
//
// A checagem de menores (CLAUDE.md §3, primeira camada) é a primeira coisa
// que acontece — antes de gerar a URL assinada, não só antes de chamar o
// serviço facial. Gerar a URL já produz uma credencial de leitura de curta
// duração para os bytes da foto; uma foto marcada (ou não respondida) nunca
// deve sair da esfera puramente interna do worker, mesmo que a URL nunca
// chegasse a ser usada.
func HandleIndexFaces(ctx context.Context, deps IndexFacesDeps, payload IndexFacesPayload) error {
	photo, err := deps.Photos.LoadPhoto(ctx, payload.PhotoID)
	if err != nil {
		return fmt.Errorf("index_faces: carregar foto %s: %w", payload.PhotoID, err)
	}

	if photo.ContainsMinors == nil || *photo.ContainsMinors {
		if err := deps.Photos.MarkPhotoSkipped(ctx, photo.ID); err != nil {
			return fmt.Errorf("index_faces: marcar foto %s como pulada: %w", photo.ID, err)
		}
		return nil
	}

	url, err := deps.Signer.SignedReadURL(ctx, photo.StorageKey)
	if err != nil {
		return fmt.Errorf("index_faces: assinar URL de leitura: %w", err)
	}

	detected, err := deps.Detector.Detect(ctx, url)
	if err != nil {
		return fmt.Errorf("index_faces: detectar rostos: %w", err)
	}

	if err := deps.Photos.SaveFaces(ctx, photo, detected); err != nil {
		return fmt.Errorf("index_faces: salvar rostos da foto %s: %w", photo.ID, err)
	}

	if err := deps.Photos.MarkPhotoIndexed(ctx, photo.ID); err != nil {
		return fmt.Errorf("index_faces: marcar foto %s como indexada: %w", photo.ID, err)
	}
	return nil
}
