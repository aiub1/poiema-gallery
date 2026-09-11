package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"testing"
)

// fakeStore é um Store em memória — permite orquestrar cenários de
// claim/retry/failed sem um Postgres real.
type fakeStore struct {
	jobs []*Job // fila, na ordem de reivindicação

	done      []int64
	skipped   []int64
	retried   []int64
	failedIDs []int64

	// terminal força MarkRetryOrFailed a devolver terminal=true, simulando
	// attempts >= MaxAttempts.
	terminal bool
}

func (s *fakeStore) Claim(_ context.Context, _ string) (*Job, error) {
	if len(s.jobs) == 0 {
		return nil, nil
	}
	job := s.jobs[0]
	s.jobs = s.jobs[1:]
	return job, nil
}

func (s *fakeStore) MarkDone(_ context.Context, jobID int64) error {
	s.done = append(s.done, jobID)
	return nil
}

func (s *fakeStore) MarkSkipped(_ context.Context, jobID int64) error {
	s.skipped = append(s.skipped, jobID)
	return nil
}

func (s *fakeStore) MarkRetryOrFailed(_ context.Context, jobID int64, attempts int, _ error) (bool, error) {
	if s.terminal || attempts >= MaxAttempts {
		s.failedIDs = append(s.failedIDs, jobID)
		return true, nil
	}
	s.retried = append(s.retried, jobID)
	return false, nil
}

func silentLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

func TestRunner_RunOnce_NoJobAvailable(t *testing.T) {
	store := &fakeStore{}
	runner := &Runner{Store: store, Logger: silentLogger(), WorkerID: "test"}

	claimed, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}
	if claimed {
		t.Fatal("RunOnce reportou job reivindicado quando a fila estava vazia")
	}
}

func TestRunner_RunOnce_IndexFacesSuccessMarksDone(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p1"] = Photo{ID: "p1", ContainsMinors: boolPtr(true)} // pulada, mas o job em si é "done"
	store := &fakeStore{jobs: []*Job{{ID: 1, Type: TypeIndexFaces, Payload: mustJSON(t, IndexFacesPayload{PhotoID: "p1"}), Attempts: 1}}}

	runner := &Runner{
		Store:    store,
		Deps:     Deps{Photos: photos, Signer: &fakeSigner{}, Detector: &fakeDetector{}},
		Logger:   silentLogger(),
		WorkerID: "test",
	}

	claimed, err := runner.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}
	if !claimed {
		t.Fatal("esperava claimed=true")
	}
	if len(store.done) != 1 || store.done[0] != 1 {
		t.Fatalf("job não foi marcado como done: %+v", store.done)
	}
}

func TestRunner_RunOnce_FailureSchedulesRetry(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p1"] = Photo{ID: "p1", ContainsMinors: boolPtr(false)}
	detector := &fakeDetector{err: errors.New("indisponível")}
	store := &fakeStore{jobs: []*Job{{ID: 2, Type: TypeIndexFaces, Payload: mustJSON(t, IndexFacesPayload{PhotoID: "p1"}), Attempts: 1}}}

	runner := &Runner{
		Store:    store,
		Deps:     Deps{Photos: photos, Signer: &fakeSigner{}, Detector: detector},
		Logger:   silentLogger(),
		WorkerID: "test",
	}

	if _, err := runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}

	if len(store.retried) != 1 {
		t.Fatalf("job não foi reagendado para retry: %+v", store.retried)
	}
	if len(store.failedIDs) != 0 {
		t.Fatalf("job não deveria ter ido para failed ainda: %+v", store.failedIDs)
	}
	if len(photos.failed) != 0 {
		t.Fatalf("foto não deveria ter sido marcada como failed antes de esgotar tentativas: %+v", photos.failed)
	}
}

func TestRunner_RunOnce_TerminalFailureMarksPhotoFailed(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p1"] = Photo{ID: "p1", ContainsMinors: boolPtr(false)}
	detector := &fakeDetector{err: errors.New("indisponível")}
	store := &fakeStore{
		jobs:     []*Job{{ID: 3, Type: TypeIndexFaces, Payload: mustJSON(t, IndexFacesPayload{PhotoID: "p1"}), Attempts: MaxAttempts}},
		terminal: true,
	}

	runner := &Runner{
		Store:    store,
		Deps:     Deps{Photos: photos, Signer: &fakeSigner{}, Detector: detector},
		Logger:   silentLogger(),
		WorkerID: "test",
	}

	if _, err := runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}

	if len(store.failedIDs) != 1 || store.failedIDs[0] != 3 {
		t.Fatalf("job não foi marcado como failed: %+v", store.failedIDs)
	}
	if len(photos.failed) != 1 || photos.failed[0] != "p1" {
		t.Fatalf("foto não foi marcada como failed após esgotar tentativas: %+v", photos.failed)
	}
}

func TestRunner_RunOnce_DeleteObjectsSuccess(t *testing.T) {
	objects := &fakeObjectDeleter{}
	store := &fakeStore{jobs: []*Job{{ID: 4, Type: TypeDeleteObjects, Payload: mustJSON(t, DeleteObjectsPayload{Keys: []string{"a", "b"}}), Attempts: 1}}}

	runner := &Runner{
		Store:    store,
		Deps:     Deps{Objects: objects},
		Logger:   silentLogger(),
		WorkerID: "test",
	}

	if _, err := runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}
	if len(store.done) != 1 {
		t.Fatalf("job delete_objects não foi marcado como done: %+v", store.done)
	}
	if len(objects.deleted) != 2 {
		t.Fatalf("chaves não foram passadas para o deleter: %+v", objects.deleted)
	}
}

func TestRunner_RunOnce_PurgeExpiredEmbeddingsIsSkippedNotFailed(t *testing.T) {
	store := &fakeStore{jobs: []*Job{{ID: 5, Type: TypePurgeExpiredEmbeddings, Payload: json.RawMessage(`{}`), Attempts: 1}}}
	runner := &Runner{Store: store, Logger: silentLogger(), WorkerID: "test"}

	if _, err := runner.RunOnce(context.Background()); err != nil {
		t.Fatalf("erro inesperado: %v", err)
	}
	if len(store.skipped) != 1 || store.skipped[0] != 5 {
		t.Fatalf("job purge_expired_embeddings deveria ter sido marcado como skipped: %+v", store.skipped)
	}
	if len(store.failedIDs) != 0 || len(store.retried) != 0 {
		t.Fatalf("job sem implementação não deveria consumir retry nem ir para failed: retried=%v failed=%v", store.retried, store.failedIDs)
	}
}

type fakeObjectDeleter struct {
	deleted []string
	err     error
}

func (f *fakeObjectDeleter) DeleteObjects(_ context.Context, keys []string) error {
	if f.err != nil {
		return f.err
	}
	f.deleted = append(f.deleted, keys...)
	return nil
}
