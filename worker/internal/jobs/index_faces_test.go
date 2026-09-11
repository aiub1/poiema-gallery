package jobs

import (
	"context"
	"errors"
	"testing"

	"github.com/aiub1/poiema-gallery/worker/internal/faces"
)

// fakePhotoStore é um PhotoStore em memória para testes de unidade — sem
// banco real (CLAUDE.md §8: "teste de unidade nos jobs, com serviço facial
// fake").
type fakePhotoStore struct {
	photos map[string]Photo

	skipped []string
	indexed []string
	failed  []string
	saved   map[string][]faces.Face

	loadErr  error
	saveErr  error
	indexErr error
}

func newFakePhotoStore() *fakePhotoStore {
	return &fakePhotoStore{
		photos: map[string]Photo{},
		saved:  map[string][]faces.Face{},
	}
}

func (f *fakePhotoStore) LoadPhoto(_ context.Context, photoID string) (Photo, error) {
	if f.loadErr != nil {
		return Photo{}, f.loadErr
	}
	photo, ok := f.photos[photoID]
	if !ok {
		return Photo{}, errors.New("foto não encontrada")
	}
	return photo, nil
}

func (f *fakePhotoStore) MarkPhotoSkipped(_ context.Context, photoID string) error {
	f.skipped = append(f.skipped, photoID)
	return nil
}

func (f *fakePhotoStore) MarkPhotoIndexed(_ context.Context, photoID string) error {
	if f.indexErr != nil {
		return f.indexErr
	}
	f.indexed = append(f.indexed, photoID)
	return nil
}

func (f *fakePhotoStore) MarkPhotoFailed(_ context.Context, photoID string) error {
	f.failed = append(f.failed, photoID)
	return nil
}

func (f *fakePhotoStore) SaveFaces(_ context.Context, photo Photo, detected []faces.Face) error {
	if f.saveErr != nil {
		return f.saveErr
	}
	f.saved[photo.ID] = detected
	return nil
}

// fakeSigner nunca falha por padrão — testes de skip de menores usam a
// contagem de chamadas para provar que a URL nem chega a ser assinada.
type fakeSigner struct {
	calls int
	url   string
	err   error
}

func (f *fakeSigner) SignedReadURL(_ context.Context, _ string) (string, error) {
	f.calls++
	if f.err != nil {
		return "", f.err
	}
	if f.url == "" {
		return "https://example.invalid/signed", nil
	}
	return f.url, nil
}

// fakeDetector conta chamadas — usado para provar que o serviço facial
// nunca é chamado para fotos marcadas com menores (CLAUDE.md §3).
type fakeDetector struct {
	calls  int
	result []faces.Face
	err    error
}

func (f *fakeDetector) Detect(_ context.Context, _ string) ([]faces.Face, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return f.result, nil
}

func boolPtr(b bool) *bool { return &b }

func TestHandleIndexFaces_SkipsPhotoWithMinorsTrue(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p1"] = Photo{ID: "p1", ContainsMinors: boolPtr(true)}
	signer := &fakeSigner{}
	detector := &fakeDetector{}

	err := HandleIndexFaces(context.Background(), IndexFacesDeps{Photos: photos, Signer: signer, Detector: detector}, IndexFacesPayload{PhotoID: "p1"})
	if err != nil {
		t.Fatalf("HandleIndexFaces retornou erro inesperado: %v", err)
	}

	if detector.calls != 0 {
		t.Fatalf("serviço facial foi chamado %d vezes para foto com contains_minors=true; esperado 0", detector.calls)
	}
	if signer.calls != 0 {
		t.Fatalf("URL assinada foi gerada %d vezes para foto com contains_minors=true; esperado 0", signer.calls)
	}
	if len(photos.skipped) != 1 || photos.skipped[0] != "p1" {
		t.Fatalf("foto não foi marcada como skipped: %+v", photos.skipped)
	}
	if len(photos.indexed) != 0 {
		t.Fatalf("foto não deveria ter sido marcada como indexed: %+v", photos.indexed)
	}
}

func TestHandleIndexFaces_SkipsPhotoWithMinorsNil(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p2"] = Photo{ID: "p2", ContainsMinors: nil}
	signer := &fakeSigner{}
	detector := &fakeDetector{}

	err := HandleIndexFaces(context.Background(), IndexFacesDeps{Photos: photos, Signer: signer, Detector: detector}, IndexFacesPayload{PhotoID: "p2"})
	if err != nil {
		t.Fatalf("HandleIndexFaces retornou erro inesperado: %v", err)
	}

	if detector.calls != 0 {
		t.Fatalf("serviço facial foi chamado %d vezes para foto com contains_minors=null; esperado 0", detector.calls)
	}
	if signer.calls != 0 {
		t.Fatalf("URL assinada foi gerada %d vezes para foto com contains_minors=null; esperado 0", signer.calls)
	}
	if len(photos.skipped) != 1 || photos.skipped[0] != "p2" {
		t.Fatalf("foto não foi marcada como skipped: %+v", photos.skipped)
	}
}

func TestHandleIndexFaces_IndexesPhotoWithMinorsFalse(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p3"] = Photo{ID: "p3", EventID: "e1", StorageKey: "events/e1/photos/p3/original.webp", ContainsMinors: boolPtr(false)}
	signer := &fakeSigner{}
	detected := []faces.Face{{Embedding: []float32{0.1, 0.2}, Quality: 0.9}}
	detector := &fakeDetector{result: detected}

	err := HandleIndexFaces(context.Background(), IndexFacesDeps{Photos: photos, Signer: signer, Detector: detector}, IndexFacesPayload{PhotoID: "p3"})
	if err != nil {
		t.Fatalf("HandleIndexFaces retornou erro inesperado: %v", err)
	}

	if detector.calls != 1 {
		t.Fatalf("serviço facial foi chamado %d vezes; esperado 1", detector.calls)
	}
	if signer.calls != 1 {
		t.Fatalf("URL assinada foi gerada %d vezes; esperado 1", signer.calls)
	}
	if len(photos.indexed) != 1 || photos.indexed[0] != "p3" {
		t.Fatalf("foto não foi marcada como indexed: %+v", photos.indexed)
	}
	if len(photos.saved["p3"]) != 1 {
		t.Fatalf("rostos não foram salvos: %+v", photos.saved)
	}
}

func TestHandleIndexFaces_DetectorFailureIsPropagated(t *testing.T) {
	photos := newFakePhotoStore()
	photos.photos["p4"] = Photo{ID: "p4", ContainsMinors: boolPtr(false)}
	signer := &fakeSigner{}
	detector := &fakeDetector{err: errors.New("serviço facial fora do ar")}

	err := HandleIndexFaces(context.Background(), IndexFacesDeps{Photos: photos, Signer: signer, Detector: detector}, IndexFacesPayload{PhotoID: "p4"})
	if err == nil {
		t.Fatal("esperava erro quando o serviço facial falha, recebeu nil")
	}
	if len(photos.indexed) != 0 {
		t.Fatalf("foto não deveria ter sido marcada como indexed após falha: %+v", photos.indexed)
	}
}
