package jobs

import "encoding/json"

// Type é o tipo do job, conforme docs/CONTRATO.md §4.
type Type string

const (
	TypeIndexFaces             Type = "index_faces"
	TypeDeleteObjects          Type = "delete_objects"
	TypePurgeExpiredEmbeddings Type = "purge_expired_embeddings"
)

// MaxAttempts é o número máximo de tentativas antes de um job ir para
// "failed" (docs/ARQUITETURA.md §6).
const MaxAttempts = 5

// Job é uma linha da tabela jobs já reivindicada por este worker.
type Job struct {
	ID       int64
	Type     Type
	Payload  json.RawMessage
	Attempts int
}

// IndexFacesPayload é o payload de um job "index_faces" (docs/CONTRATO.md §4).
type IndexFacesPayload struct {
	PhotoID string `json:"photo_id"`
}

// DeleteObjectsPayload é o payload de um job "delete_objects".
type DeleteObjectsPayload struct {
	Keys []string `json:"keys"`
}

// Photo é a projeção de `photos` que o worker precisa para indexar rostos.
type Photo struct {
	ID             string
	EventID        string
	StorageKey     string
	ContainsMinors *bool
}
