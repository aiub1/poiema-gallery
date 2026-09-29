# 0004 — Soft delete de events e antecipação de photo_faces

Status: accepted · Date: 2026-09-10

## Context

Duas decisões novas surgiram ao implementar a fase 2 (`photos`,
`removal_requests`, `jobs`, `access_logs`).

## Decisão 1 — `events` ganha soft delete; DELETE real é revogado

`ARQUITETURA.md` §15 registrava uma pendência: `photos.event_id` estava
definido com `on delete cascade`, mas fotos usam soft delete e a limpeza do
R2 depende do job `delete_objects`. Excluir um evento de verdade apagaria as
linhas de `photos` e deixaria objetos órfãos no bucket.

Solução: `events` ganha `deleted_at timestamptz`, e `revoke delete on events
from authenticated` — o mesmo padrão já usado em `profiles`. Não existe mais
nenhum caminho de `DELETE` real em `events` para nenhum papel autenticado,
admin incluído. `photos.event_id` passa a `on delete restrict` como segunda
trava (defesa em profundidade, já que o `DELETE` real está bloqueado no
grant de qualquer forma). A policy `read events` passa a exigir
`deleted_at is null`, e a policy `read photos` passa a exigir também que o
evento da foto não esteja soft-deletado (`exists (select 1 from events e
where e.id = photos.event_id and e.deleted_at is null)`), para que "excluir"
um evento também tire as fotos dele de circulação sem apagar nada de
verdade.

### Efeito colateral não óbvio: `deleted_at` só é gravável por `service_role`

Tentar `update events set deleted_at = now()` autenticado como admin, pelo
próprio JWT, **falha com `42501`** — mesmo admin sendo dono de todas as
policies relevantes. Isso não é bug: o Postgres exige, para `UPDATE` sob RLS,
que a linha resultante também satisfaça a policy de `SELECT` da tabela (não
só o `WITH CHECK` da policy de `UPDATE`). Como `read events` filtra
`deleted_at is null`, qualquer `UPDATE` que grave um `deleted_at` não-nulo
produz uma linha que a própria sessão não teria permissão de enxergar depois
— e o Postgres rejeita a escrita, RLS não permite "cegar a si mesmo".

Na prática isso significa que **excluir um evento é uma operação exclusiva
de rota de servidor com `service_role`** (`CLAUDE.md` §5.3), nunca uma
chamada direta do cliente autenticado — nem para admin. É o comportamento
correto para uma ação privilegiada e auditável, não uma lacuna a corrigir.
O teste pgTAP correspondente (`02_photos_rls.sql`) documenta isso
explicitamente: confirma que o `UPDATE` falha pelo JWT do admin, e simula o
`service_role` executando como `postgres` (que bypassa RLS, igual a
`service_role`) para validar o restante do fluxo.

## Decisão 2 — `photo_faces` entra na fase 2, não na fase 4

`ARQUITETURA.md` §13 previa `photo_faces` só na fase 4, depois de `minors`/
`guardians` (fase 3). Mas os dois triggers de proteção de menores
(`trg_forbid_minor_faces`, `trg_purge_faces_on_minor_flag` — a segunda e a
terceira camada da regra "menor nunca é indexado", `CLAUDE.md` §3) fazem
`insert`/`delete` em `photo_faces`, e não há como criar um trigger `before
insert on photo_faces` sem a tabela existir.

Para evitar retrabalho — criar os triggers de novo na fase 4 quando
`photo_faces` finalmente existisse — a tabela entra completa nesta migration
(schema, índice `hnsw`, RLS sem policy de `select`, `revoke all` de `anon` e
`authenticated`), exatamente como descrita em `ARQUITETURA.md` §4. Não
antecipamos `guardians`, `minors`, `face_consents` nem `photo_grants`: nada
disso é necessário para os dois triggers, e a fase 3 continua sendo
pré-requisito de qualquer *uso* de `photo_faces` (a função `search_faces` e
o worker Go, que só chegam na fase 4).

## Consequências

- `photos.event_id` é `on delete restrict`, não `on delete cascade` como
  `ARQUITETURA.md` §4 ainda documenta — atualizar o diagrama de schema lá
  quando a doc for revisada.
- Qualquer UI de "excluir evento" no `galeria-web` precisa passar por uma
  rota de servidor com `service_role`; não existe (nem pode existir, dado o
  ponto acima) uma chamada direta do Supabase client fazendo isso.
- A fase 4 herda `photo_faces` já pronta; o trabalho que resta lá é
  `face_consents`, `photo_grants`, `search_faces` e o consumo real pelo
  worker/serviço facial.
