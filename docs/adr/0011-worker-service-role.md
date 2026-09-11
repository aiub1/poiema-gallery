# 0011 — Role restrito para o worker, não `service_role`

Status: accepted · Date: 2026-09-11

## Context

O worker (fase 4b, `worker/`) é o primeiro componente do projeto que roda
por fora das policies RLS: ele grava em `photo_faces`, que não tem policy de
`select` e é `revoke all` para `authenticated`/`anon` (CLAUDE.md §5.2). O
worker conecta **diretamente no Postgres** via `pgx` (driver Go), não pela
API REST/PostgREST do Supabase — então o conceito de credencial não é "JWT
de `service_role`" no sentido do PostgREST, é literalmente qual role
Postgres a connection string usa.

A escolha óbvia seria a `service_role` key, que o resto da arquitetura já
pressupõe em outros lugares (`events.deleted_at` só é gravado por
`service_role`, por exemplo). Mas `service_role` ignora RLS **totalmente**
— acesso irrestrito a toda tabela do schema `public`, inclusive `profiles`,
`guardians`, `minor_consents`, `photo_grants`, `face_consents`.

## Decisão

O worker usa um role Postgres de login dedicado, **`worker_service`**, não
`service_role`:

```sql
create role worker_service login password '...' bypassrls;

grant select, update on photos to worker_service;
grant insert on photo_faces to worker_service;
grant select, update on jobs to worker_service;
```

Nada além disso — sem grant em `profiles`, `guardians`, `minors`,
`minor_consents`, `photo_grants`, `face_consents`, `access_logs`,
`removal_requests`.

`bypassrls` é necessário porque `worker_service` não é dono das tabelas: sem
ele, RLS se aplicaria normalmente e as policies existentes (amarradas a
`is_member()`/`auth.uid()`, que dependem do contexto JWT do PostgREST)
devolveriam vazio para uma conexão direta sem esse contexto — o worker não
conseguiria nem ler as próprias fotos. `bypassrls` resolve isso sem
depender de policy nenhuma, mantendo os grants como único controle de
acesso — mais estrito que `service_role`, que também tem `bypassrls`
implícito mas sobre grants irrestritos.

### Por que não `service_role`

O worker roda em loop, sem supervisão humana por requisição — uma vez
implantado, processa jobs indefinidamente, sem um humano aprovando cada
ação (diferente de uma rota de servidor do galeria-web, que executa uma
ação por requisição de uma pessoa). Um bug de worker com `service_role` tem
alcance total: pode escrever em `profiles.role`, `guardians`,
`minor_consents` — furando as invariantes 6, 8 e 9 do `docs/CONTRATO.md`
(vínculo responsável→menor só por admin; perfil nasce inativo; perfil nunca
é excluído). Essa é uma categoria de risco maior que a de um componente que
executa por requisição humana, e não deve compartilhar a mesma credencial.

### O que continua protegendo `photo_faces` mesmo com um bug no worker

Grants restritos cobrem "o worker não pode escrever fora do seu escopo
declarado", mas a proteção específica contra `contains_minors` é o trigger
`trg_forbid_minor_faces` (`BEFORE INSERT on photo_faces`) — ele dispara
para **qualquer** role, `worker_service` incluído, porque é um trigger, não
uma policy de RLS. RLS (e portanto `bypassrls`) é irrelevante para
triggers. Essa é a camada que efetivamente conteria um bug de camada 1 (a
checagem em `internal/jobs/index_faces.go`); o escopo restrito de grants é
defesa adicional — impede que um bug em *qualquer outro* código do worker
(não só o handler de `index_faces`) alcance tabelas fora do que
`ARQUITETURA.md` §6 descreve que o worker faz.

## Escopo negado deliberadamente

- `delete` em `photo_faces`: não concedido nesta entrega — `purge_expired_
  embeddings` está implementado como esqueleto que marca o job como
  `skipped`, sem excluir nada (regra de retenção pendente de revisão
  jurídica, `ARQUITETURA.md` §12). Se esse job for implementado de verdade
  no futuro, o grant de `delete` em `photo_faces` entra junto, não antes.
- Qualquer grant em `profiles`, `guardians`, `minors`, `minor_consents`,
  `photo_grants`, `face_consents`, `access_logs`, `removal_requests`: o
  worker não toca nenhuma dessas tabelas conforme `ARQUITETURA.md` §6.

## Consequências

- A migration que cria `worker_service` e os grants acima **não está no PR
  do worker** (`feat/phase4b-worker`) — escopo dessa entrega era só
  `worker/`. É a **próxima tarefa**, não um item de backlog: o worker não
  conecta em nenhum banco real até ela existir (`worker/README.md`).
  `docs/ESTADO.md` registra isso como pendência bloqueante.
- Se um job futuro precisar de uma tabela fora da lista acima, o grant
  correspondente entra numa migration nova, revisado explicitamente — nunca
  ampliando `worker_service` "de passagem" dentro de uma migration que trata
  de outra coisa.
- Se o role restrito se revelar inviável por algum detalhe do Supabase não
  previsto aqui (ex.: a connection string do pooler não aceitar um role que
  não seja `postgres`/`anon`/`authenticated`/`service_role`), isso é motivo
  para voltar a esta ADR e revisar a decisão explicitamente — não para o
  worker cair silenciosamente para `service_role`.
