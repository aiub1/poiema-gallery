# CLAUDE.md — galeria-core

Banco de dados, worker de indexação e serviço de reconhecimento facial da
galeria de fotos da igreja.
Instruções permanentes para o Claude Code. Leia antes de qualquer alteração.

Repositório irmão: **galeria-web** (Next.js) — **ainda não criado**.
Contrato entre os dois: `docs/CONTRATO.md`.

---

## 1. O que é

Backend da galeria **interna e gratuita** de fotos de uma igreja local.
Conteúdo: **Evento → Sessão → Fotos**. Sistema fechado: `anon` não tem
privilégio em **tabela** alguma. Existe uma única exceção de leitura, as
funções `public_*` de evento marcado `is_public` (só `admin` marca), que nunca
devolvem foto com `contains_minors` verdadeiro ou nulo — ver
`docs/adr/0014-public-events.md`.

Sem fins lucrativos, sem cobrança. Fotógrafos são membros voluntários.

Documentação em português; código, commits e ADRs em **inglês**.

---

## 2. Componentes

| Componente | Tecnologia | Pasta |
|---|---|---|
| Banco | Postgres 15 + pgvector (Supabase) | `supabase/` |
| Worker de indexação | **Go 1.23** | `worker/` |
| Serviço facial | Python 3.12 + FastAPI + InsightFace | `services/face/` |
| Infra como código | OpenTofu (Terraform) | `infra/` |

O worker é em Go de propósito: serviço pequeno, isolado, sem risco para o
sistema, e agrega uma linguagem relevante ao portfólio.

---

## 3. Regra número um: menores nunca são indexados

> Se qualquer decisão conflitar com esta seção, **pare e pergunte**.

Defesa em profundidade, em três camadas independentes:

1. **Worker** — pula qualquer foto com `contains_minors` verdadeiro ou nulo.
   Nunca chama o serviço facial para ela.
2. **Trigger no banco** — `trg_forbid_minor_faces` rejeita `INSERT` em
   `photo_faces` se a foto estiver marcada. E `trg_purge_faces_on_minor_flag`
   apaga embeddings existentes se a foto for marcada depois.
3. **Função de busca** — `search_faces` filtra fotos marcadas mesmo que algo
   tenha escapado.

**Nenhuma das três pode ser removida ou relaxada.** Se uma atrapalhar um teste,
o teste está errado.

Criar índice biométrico de criança para "protegê-la" inverte o resultado
pretendido. Acesso a foto de menor é por **vínculo declarado** (`guardians`),
cadastrado pela secretaria — nunca por biometria, nunca por autodeclaração.

---

## 4. Papéis

`admin` (tudo) · `uploader` (envia, não exclui) · `member` (vê o liberado).

**Somente `admin` executa `DELETE` em fotos.** `uploader` abre
`removal_requests`. Requisito do cliente para não perder acervo. Não relaxar.

Papel só existe enquanto o perfil está ativo: `is_active = false` derruba o
papel para nulo e o usuário deixa de enxergar o acervo. Ver §5.1.

---

## 5. Regras invioláveis

### 5.1 Banco
- **RLS habilitado em toda tabela.** Tabela nova sem policy é bug, não pendência.
- Migrations em `supabase/migrations/`, numeradas e **imutáveis** após aplicadas.
  Mudou de ideia? Nova migration. Convenção em `docs/adr/0002-migration-conventions.md`.
- Toda migration que cria tabela traz junto: `enable row level security`, as
  policies e os índices.
- **Toda policy de leitura passa por `is_member()`**, nunca por
  `auth.uid() is not null`. Autenticado e membro ativo são coisas diferentes:
  um perfil desativado tem JWT válido e não pode ver nada.
- Nada de `security definer` sem `set search_path = public, pg_temp`. Sem
  `pg_temp` na lista, o Postgres pesquisa o schema temporário **primeiro**, e
  uma tabela temporária criada pelo chamador pode sequestrar a resolução de
  nomes dentro da função — que roda com os privilégios do dono.
- **Perfil não se exclui.** `delete` em `profiles` é revogado para todos, sem
  policy nem para admin. Apagar o perfil sem apagar `auth.users` devolve o
  usuário ao sistema no próximo login. Desativar é o único caminho.
- **`role` e `is_active` só mudam por admin**, garantido por trigger
  `before update` (`trg_profiles_privileged_columns`), não por expressão
  `with check`. Trava de escalação de privilégio não pode depender de
  sutileza de snapshot.
- Nunca ligar `force row level security` em `profiles`: as funções auxiliares
  são `security definer` do dono da tabela e passariam a recursar.

### 5.2 Dados biométricos (LGPD)
- Embedding facial é **dado pessoal sensível** (art. 11). Tratar como senha.
- `photo_faces` não tem policy de `select`. Cliente nunca lê. Acesso só pela
  função `search_faces`.
- Nenhuma API retorna vetor bruto. Nem para debug. Nem em ambiente local.
- Selfie de busca: memória, embedding, descarte. Sem disco, sem log, sem R2.
- Nunca logar embedding, imagem, e-mail completo ou IP em claro.

### 5.3 Segredos
- `service_role key` só no worker e em rotas de servidor do galeria-web.
- Segredos por variável de ambiente e Fly secrets. Nunca commitar `.env`.
- Signup do Supabase Auth fica **restrito a convite**. Se for reaberto, ler
  `docs/adr/0003-profile-provisioning.md` antes.

---

## 6. Convenções

- Tabelas e colunas `snake_case`, plural para tabelas.
- Go: `gofmt`, erros embrulhados com `fmt.Errorf("...: %w", err)`, sem `panic`
  em caminho normal.
- Python: `ruff` + `mypy`, tipagem explícita nos handlers.
- Conventional Commits.
- Decisão relevante vira ADR em `docs/adr/NNNN-title.md`, em inglês.
- **Sem menção de co-autoria do Claude/Claude Code** em commits ou PRs — nada
  de `Co-Authored-By: Claude ...` no rodapé do commit, nem
  `Generated with Claude Code` na descrição do PR. Instrução do cliente.

---

## 7. Estrutura

```
/supabase
  /migrations        SQL numerado e imutável
  /tests             pgTAP — testes de RLS
  seed.sql
  config.toml
/worker              Go: consome jobs, chama o serviço facial
  /internal/jobs
  /internal/faces
  /internal/storage
/services/face       Python: FastAPI + InsightFace
  main.py
  /tests
/infra               OpenTofu: R2, Fly.io
/docs
  ARQUITETURA.md
  CONTRATO.md
  /adr
```

---

## 8. Testes

- **pgTAP para RLS.** Cada papel tem cenário próprio. Cenários obrigatórios:
  - `member` não lê foto com menores de criança não vinculada
  - `member` não lê foto privada sem grant
  - responsável lê a foto do filho vinculado
  - `uploader` não consegue `DELETE` em foto
  - `INSERT` em `photo_faces` de foto marcada falha
  - marcar `contains_minors` apaga embeddings existentes
  - `member` não consegue inserir em `guardians`
  - `member` não consegue se promover a `admin`
  - perfil inativo não lê nada além do próprio registro
  - perfil inativo não executa `search_faces`
  - perfil provisionado a partir de `auth.users` nasce inativo
  - ninguém executa `DELETE` em `profiles`, nem admin
  - `uploader` não edita sessão de evento alheio
  - `anon` não lê foto com menores de evento público
  - `uploader` não torna evento público
- Go: teste de unidade nos jobs, com serviço facial fake.
- Python: teste de `/embed` garantindo que nada é escrito em disco.
- CI roda tudo em todo PR. Vermelho não faz merge.

---

## 9. Comandos

```bash
npx supabase start           # stack local (Docker)
npx supabase db reset        # recria aplicando migrations + seed
npx supabase test db         # pgTAP
npx supabase db push         # aplica no remoto
npx supabase gen types typescript --local > ../galeria-web/lib/database.types.ts

cd worker && go test ./... && go run ./cmd/worker
cd services/face && uvicorn main:app --reload
cd services/face && pytest

cd infra && tofu plan
```

A geração de tipos está **dormente** até o galeria-web existir. Ver
`docs/adr/0002-migration-conventions.md`.

---

## 10. Ao trabalhar aqui

- Antes de criar tabela: ler `docs/ARQUITETURA.md` e as migrations existentes.
- Ao mexer em fotos, menores, exclusão ou faces: reler as seções 3 a 5.
- Escrever o teste de permissão **junto** com a migration, não depois.
- Depois de mudar o schema, regenerar os tipos para o galeria-web (quando existir).
- Mudanças pequenas e revisáveis.
- Se algo contrariar este arquivo, **pare e pergunte**.

---

## 11. Fora de escopo

Pagamentos, comentários, vídeo, marca d'água, notificação em massa,
Kubernetes, microsserviços, e **reconhecimento facial de menores** (nunca).
