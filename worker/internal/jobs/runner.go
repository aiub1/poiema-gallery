package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/aiub1/poiema-gallery/worker/internal/faces"
)

// Store é a fila jobs: reivindicar, concluir, pular ou agendar retry.
// Implementada por PostgresStore contra o role worker_service — ver
// worker/README.md sobre o pré-requisito ainda não aplicado.
type Store interface {
	// Claim reivindica o próximo job elegível (fila ou lease expirado) e
	// incrementa attempts. Retorna (nil, nil) se não há job disponível.
	Claim(ctx context.Context, workerID string) (*Job, error)
	MarkDone(ctx context.Context, jobID int64) error
	MarkSkipped(ctx context.Context, jobID int64) error
	// MarkRetryOrFailed decide, a partir de attempts, se o job volta para a
	// fila (com backoff) ou vai para "failed" — retorna true quando for
	// terminal (failed).
	MarkRetryOrFailed(ctx context.Context, jobID int64, attempts int, cause error) (terminal bool, err error)
}

// Deps agrega as dependências reais dos handlers de job.
type Deps struct {
	Photos   PhotoStore
	Signer   URLSigner
	Detector faces.Detector
	Objects  ObjectDeleter
}

type Runner struct {
	Store    Store
	Deps     Deps
	Logger   *slog.Logger
	WorkerID string
}

// RunOnce reivindica e processa no máximo um job. Retorna claimed=false
// quando a fila estava vazia — o chamador decide quanto esperar até tentar
// de novo (docs/ARQUITETURA.md §6: polling a cada 5s).
func (r *Runner) RunOnce(ctx context.Context) (claimed bool, err error) {
	job, err := r.Store.Claim(ctx, r.WorkerID)
	if err != nil {
		return false, fmt.Errorf("runner: reivindicar job: %w", err)
	}
	if job == nil {
		return false, nil
	}

	runErr := r.dispatch(ctx, *job)

	switch {
	case runErr == nil:
		if err := r.Store.MarkDone(ctx, job.ID); err != nil {
			return true, fmt.Errorf("runner: marcar job %d concluído: %w", job.ID, err)
		}

	case errors.Is(runErr, ErrNotImplemented):
		if err := r.Store.MarkSkipped(ctx, job.ID); err != nil {
			return true, fmt.Errorf("runner: marcar job %d pulado: %w", job.ID, err)
		}

	default:
		r.Logger.Error("job falhou",
			"job_id", job.ID,
			"job_type", string(job.Type),
			"attempt", job.Attempts,
			"err", runErr,
		)
		terminal, err := r.Store.MarkRetryOrFailed(ctx, job.ID, job.Attempts, runErr)
		if err != nil {
			return true, fmt.Errorf("runner: marcar job %d para retry: %w", job.ID, err)
		}
		if terminal {
			r.markPhotoFailedIfIndexFaces(ctx, *job)
		}
	}

	return true, nil
}

// markPhotoFailedIfIndexFaces reflete a falha terminal do job na foto,
// quando o payload é decodificável — melhor esforço, não afeta o resultado
// do job em si (o estado autoritativo de retry é a linha em `jobs`).
func (r *Runner) markPhotoFailedIfIndexFaces(ctx context.Context, job Job) {
	if job.Type != TypeIndexFaces {
		return
	}
	var payload IndexFacesPayload
	if err := json.Unmarshal(job.Payload, &payload); err != nil {
		return
	}
	if err := r.Deps.Photos.MarkPhotoFailed(ctx, payload.PhotoID); err != nil {
		r.Logger.Error("não foi possível marcar foto como failed após job esgotar tentativas",
			"job_id", job.ID, "photo_id", payload.PhotoID, "err", err)
	}
}

func (r *Runner) dispatch(ctx context.Context, job Job) error {
	switch job.Type {
	case TypeIndexFaces:
		var payload IndexFacesPayload
		if err := json.Unmarshal(job.Payload, &payload); err != nil {
			return fmt.Errorf("dispatch: payload de index_faces: %w", err)
		}
		deps := IndexFacesDeps{Photos: r.Deps.Photos, Signer: r.Deps.Signer, Detector: r.Deps.Detector}
		return HandleIndexFaces(ctx, deps, payload)

	case TypeDeleteObjects:
		var payload DeleteObjectsPayload
		if err := json.Unmarshal(job.Payload, &payload); err != nil {
			return fmt.Errorf("dispatch: payload de delete_objects: %w", err)
		}
		return HandleDeleteObjects(ctx, r.Deps.Objects, payload)

	case TypePurgeExpiredEmbeddings:
		return HandlePurgeExpiredEmbeddings()

	default:
		return fmt.Errorf("dispatch: tipo de job desconhecido: %q", job.Type)
	}
}
