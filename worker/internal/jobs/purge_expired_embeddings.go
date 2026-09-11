package jobs

import "errors"

// ErrNotImplemented sinaliza que o tipo de job é reconhecido mas não tem
// implementação ainda — o runner marca o job como "skipped", não "failed"
// (um job que sempre falha polui a fila e as métricas com 5 tentativas e
// last_error permanente; falha é reservada para erro de verdade).
var ErrNotImplemented = errors.New("job sem implementação")

// HandlePurgeExpiredEmbeddings ainda não roda de verdade.
//
// ARQUITETURA.md §12 já propõe a regra ("1 ano após o evento"), mas o que
// falta não é o número: é a revisão jurídica que o próprio §12 lista como
// pendente do checklist LGPD. Implementar a exclusão antes dessa revisão
// fixaria em código uma decisão que ainda precisa de aval externo.
func HandlePurgeExpiredEmbeddings() error {
	return ErrNotImplemented
}
