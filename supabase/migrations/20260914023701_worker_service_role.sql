-- Role restrito para o worker Go (docs/adr/0011-worker-service-role.md).
-- Escopo: só `photos`/`photo_faces`/`jobs`, nada além disso.
--
-- Sem senha nesta migration de propósito — segredo nunca entra no git
-- (CLAUDE.md §5.3). `alter role worker_service password '...'` é passo
-- manual, documentado em docs/adr/0006-supabase-manual-setup.md junto dos
-- outros dois segredos que já vivem fora do repo (modo de signup,
-- credencial R2).

create role worker_service login bypassrls;

-- Pré-requisito mecânico dos grants abaixo, não um grant a mais: o
-- pseudo-role PUBLIC não tem USAGE em `public` neste banco (só
-- anon/authenticated/service_role/postgres têm, explicitamente —
-- verificado em \dn+ public no ambiente local). Sem isso os três grants
-- de tabela a seguir nunca seriam alcançáveis pela connection string do
-- worker; ver nota na ADR 0011.
grant usage on schema public to worker_service;

grant select, update on photos to worker_service;
grant insert on photo_faces to worker_service;
grant select, update on jobs to worker_service;

-- Segundo pré-requisito mecânico, não um grant a worker_service: sem isso
-- `set local role worker_service` falha com "permission denied to set
-- role" para quem roda os testes pgTAP (e para um admin no SQL editor).
-- `postgres` já tem essa mesma membership em anon/authenticated/
-- service_role (bootstrap do próprio Supabase) — isto só estende o mesmo
-- padrão ao role novo. Não amplia o que worker_service pode fazer; amplia
-- só quem pode assumir a identidade dele para inspecionar/testar.
grant worker_service to postgres;

-- Terceiro pré-requisito mecânico, também não amplia o alcance de
-- worker_service em dados de aplicação: pgtap (usado por
-- `set local role worker_service` nos testes) mora em `extensions`, não em
-- `public`, neste projeto. Sem USAGE ali, a resolução de nome não
-- qualificado de qualquer função de teste falha com "does not exist", não
-- "permission denied" — comportamento do Postgres para busca em
-- `search_path`. `authenticated`/`anon`/`service_role` já têm esta mesma
-- concessão pelo bootstrap do próprio Supabase; aqui só replica o padrão
-- para o role novo poder ser testado do mesmo jeito.
grant usage on schema extensions to worker_service;

-- Sem grant algum em profiles, guardians, minors, minor_consents,
-- photo_grants, face_consents, access_logs, removal_requests — a lista da
-- ADR 0011 é a defesa em si, não um item de conveniência (bypassrls
-- desliga RLS neste role em toda tabela, não só nas três acima).
--
-- Sem grant de delete em photo_faces: purge_expired_embeddings continua
-- esqueleto (revisão jurídica pendente, ARQUITETURA.md §12). Sem grant de
-- update em photo_faces: o worker só insere embedding novo, nunca
-- sobrescreve um já gravado.
--
-- Sem grant na sequence de jobs.id: o worker nunca insere em `jobs`, só
-- lê e atualiza jobs já enfileirados por outro componente.
