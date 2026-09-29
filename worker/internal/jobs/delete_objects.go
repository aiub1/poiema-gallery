package jobs

import (
	"context"
	"fmt"
)

// ObjectDeleter remove objetos do R2 (docs/CONTRATO.md §7).
type ObjectDeleter interface {
	DeleteObjects(ctx context.Context, keys []string) error
}

func HandleDeleteObjects(ctx context.Context, objects ObjectDeleter, payload DeleteObjectsPayload) error {
	if len(payload.Keys) == 0 {
		return nil
	}
	if err := objects.DeleteObjects(ctx, payload.Keys); err != nil {
		return fmt.Errorf("delete_objects: %w", err)
	}
	return nil
}
