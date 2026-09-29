package jobs

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/aiub1/poiema-gallery/worker/internal/faces"
)

// leaseTimeout é quanto tempo um job "processing" fica travado antes de ser
// elegível de novo — cobre o worker morrer no meio de um job (claim é um
// único UPDATE, sem transação de longa duração segurando o lock do
// FOR UPDATE SKIP LOCKED durante o processamento). Valor acordado: 10 min,
// folga confortável acima do tempo esperado de indexação
// (~0,3-1s por foto no serviço facial, ARQUITETURA.md §7) mais rede.
const leaseTimeout = 10 * time.Minute

// retryBaseDelay/retryMaxDelay definem o backoff exponencial entre
// tentativas (docs/ARQUITETURA.md §6: "retry exponencial, máximo 5
// tentativas").
const (
	retryBaseDelay = 30 * time.Second
	retryMaxDelay  = 30 * time.Minute
)

// PostgresStore implementa jobs.Store e jobs.PhotoStore contra o role
// worker_service — grants restritos a photos/photo_faces/jobs, sem acesso a
// profiles/guardians/minor_consents/etc. (ADR 0011). Esse role ainda não
// existe no banco — ver worker/README.md.
type PostgresStore struct {
	pool *pgxpool.Pool
}

func NewPostgresStore(pool *pgxpool.Pool) *PostgresStore {
	return &PostgresStore{pool: pool}
}

const claimQuery = `
update jobs
set status = 'processing',
    locked_by = $1,
    locked_at = now(),
    attempts = attempts + 1
where id = (
  select id from jobs
  where run_after <= now()
    and (
      status = 'queued'
      or (status = 'processing' and locked_at < now() - $2::interval)
    )
  order by run_after
  for update skip locked
  limit 1
)
returning id, type, payload, attempts
`

func (s *PostgresStore) Claim(ctx context.Context, workerID string) (*Job, error) {
	row := s.pool.QueryRow(ctx, claimQuery, workerID, intervalLiteral(leaseTimeout))

	var job Job
	var jobType string
	if err := row.Scan(&job.ID, &jobType, &job.Payload, &job.Attempts); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("postgres: reivindicar job: %w", err)
	}
	job.Type = Type(jobType)
	return &job, nil
}

func (s *PostgresStore) MarkDone(ctx context.Context, jobID int64) error {
	_, err := s.pool.Exec(ctx, `update jobs set status = 'done' where id = $1`, jobID)
	if err != nil {
		return fmt.Errorf("postgres: marcar job %d concluído: %w", jobID, err)
	}
	return nil
}

func (s *PostgresStore) MarkSkipped(ctx context.Context, jobID int64) error {
	_, err := s.pool.Exec(ctx, `update jobs set status = 'skipped' where id = $1`, jobID)
	if err != nil {
		return fmt.Errorf("postgres: marcar job %d pulado: %w", jobID, err)
	}
	return nil
}

func (s *PostgresStore) MarkRetryOrFailed(ctx context.Context, jobID int64, attempts int, cause error) (bool, error) {
	// Só a mensagem de erro (já embrulhada com %w em código nosso, nunca com
	// corpo de resposta HTTP — ver internal/faces) vai para last_error.
	lastError := cause.Error()

	if attempts >= MaxAttempts {
		_, err := s.pool.Exec(ctx,
			`update jobs set status = 'failed', last_error = $2 where id = $1`,
			jobID, lastError,
		)
		if err != nil {
			return false, fmt.Errorf("postgres: marcar job %d como failed: %w", jobID, err)
		}
		return true, nil
	}

	delay := backoff(attempts)
	_, err := s.pool.Exec(ctx,
		`update jobs set status = 'queued', run_after = now() + $2::interval, last_error = $3 where id = $1`,
		jobID, intervalLiteral(delay), lastError,
	)
	if err != nil {
		return false, fmt.Errorf("postgres: reagendar job %d: %w", jobID, err)
	}
	return false, nil
}

// backoff é exponencial a partir de retryBaseDelay, dobrando por tentativa e
// limitado a retryMaxDelay.
func backoff(attempts int) time.Duration {
	if attempts < 1 {
		attempts = 1
	}
	d := retryBaseDelay * time.Duration(1<<uint(attempts-1))
	if d > retryMaxDelay {
		return retryMaxDelay
	}
	return d
}

// intervalLiteral formata uma duração como literal ::interval do Postgres.
func intervalLiteral(d time.Duration) string {
	return strconv.FormatFloat(d.Seconds(), 'f', -1, 64) + " seconds"
}

// --- PhotoStore ---

func (s *PostgresStore) LoadPhoto(ctx context.Context, photoID string) (Photo, error) {
	row := s.pool.QueryRow(ctx,
		`select id, event_id, storage_key, contains_minors from photos where id = $1`,
		photoID,
	)

	var photo Photo
	if err := row.Scan(&photo.ID, &photo.EventID, &photo.StorageKey, &photo.ContainsMinors); err != nil {
		return Photo{}, fmt.Errorf("postgres: carregar foto %s: %w", photoID, err)
	}
	return photo, nil
}

func (s *PostgresStore) MarkPhotoSkipped(ctx context.Context, photoID string) error {
	return s.setPhotoStatus(ctx, photoID, "skipped")
}

func (s *PostgresStore) MarkPhotoIndexed(ctx context.Context, photoID string) error {
	return s.setPhotoStatus(ctx, photoID, "indexed")
}

func (s *PostgresStore) MarkPhotoFailed(ctx context.Context, photoID string) error {
	return s.setPhotoStatus(ctx, photoID, "failed")
}

func (s *PostgresStore) setPhotoStatus(ctx context.Context, photoID, status string) error {
	_, err := s.pool.Exec(ctx, `update photos set status = $2 where id = $1`, photoID, status)
	if err != nil {
		return fmt.Errorf("postgres: marcar foto %s como %s: %w", photoID, status, err)
	}
	return nil
}

// SaveFaces insere os rostos detectados em photo_faces. A segunda camada de
// proteção de menores (trigger trg_forbid_minor_faces, CLAUDE.md §3) roda
// aqui independentemente deste código estar certo — ela dispara para
// qualquer role, inclusive worker_service, porque é BEFORE INSERT, não uma
// policy de RLS.
func (s *PostgresStore) SaveFaces(ctx context.Context, photo Photo, detected []faces.Face) error {
	if len(detected) == 0 {
		return nil
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("postgres: iniciar transação: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // rollback é no-op após commit

	for _, face := range detected {
		bboxJSON := fmt.Sprintf(`{"x":%g,"y":%g,"w":%g,"h":%g}`, face.BBox.X, face.BBox.Y, face.BBox.W, face.BBox.H)
		_, err := tx.Exec(ctx,
			`insert into photo_faces (photo_id, event_id, embedding, bbox, quality)
			 values ($1, $2, $3::vector, $4::jsonb, $5)`,
			photo.ID, photo.EventID, embeddingLiteral(face.Embedding), bboxJSON, face.Quality,
		)
		if err != nil {
			return fmt.Errorf("postgres: inserir rosto da foto %s: %w", photo.ID, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("postgres: confirmar rostos da foto %s: %w", photo.ID, err)
	}
	return nil
}

// embeddingLiteral formata um vetor como literal ::vector do pgvector, ex.
// "[0.1,0.2,...]". Nunca aparece em log: só é usado dentro do parâmetro da
// query, e internal/jobs/runner.go só loga job_id/job_type/attempt/err.
func embeddingLiteral(v []float32) string {
	parts := make([]string, len(v))
	for i, f := range v {
		parts[i] = strconv.FormatFloat(float64(f), 'g', -1, 32)
	}
	return "[" + strings.Join(parts, ",") + "]"
}
