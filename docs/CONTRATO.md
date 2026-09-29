# CONTRATO — galeria-web ↔ galeria-core

Versão 1.1 · **Este arquivo é idêntico nos dois repositórios.**
Alterou aqui, copie para o outro no mesmo PR.

> ⚠️ O **galeria-web ainda não existe**. Até ele ser criado, este documento vive
> apenas no core e a regra de cópia acima fica suspensa. Ao criar o outro
> repositório, a primeira tarefa é copiar este arquivo na íntegra e reativar a
> obrigação.

> **Mudanças da 1.0 para a 1.1** — perfil provisionado nasce inativo e a web
> precisa tratar esse estado; geração de tipos dormente; duas invariantes novas.

---

## 1. Divisão de responsabilidades

| Assunto | Dono | Observação |
|---|---|---|
| Schema e migrations | **core** | web nunca escreve SQL de estrutura |
| Autorização (RLS) | **core** | web apenas reflete na UI |
| Tipos TypeScript do banco | **core** gera, web consome | `supabase gen types` |
| Upload para o R2 | **web** | direto do navegador, URL assinada |
| Conversão WebP e thumbnails | **web** | no navegador, antes do upload |
| Indexação facial | **core** (worker) | web só enfileira o job |
| Embedding da selfie | **core** (serviço facial) | web faz proxy, não guarda |
| Limpeza do R2 | **core** (worker) | job `delete_objects` |
| Ativação de novos perfis | **core** (RLS) + **web** (tela de admin) | perfil nasce inativo |

Regra de ouro: **a web nunca decide quem pode ver o quê.** Ela pergunta ao banco.

---

## 2. Geração de tipos

Depois de qualquer migration, no repositório core:

```bash
npx supabase gen types typescript --local \
  > ../galeria-web/lib/database.types.ts
```

O arquivo é commitado no galeria-web. PR que muda schema sem regenerar os tipos
não passa no CI da web.

**Dormente até o galeria-web existir.** Nenhum PR do core pode ser bloqueado por
um passo que não tem onde escrever. Ao criar o outro repositório, gerar os tipos
cobrindo todas as migrations acumuladas e só então ligar a checagem no CI. Ver
`docs/adr/0002-migration-conventions.md`.

---

## 3. Serviço facial — API HTTP

Base: `FACE_SERVICE_URL`. Autenticação: header `X-Service-Token`.
**Somente o servidor chama.** Nunca exposto ao navegador.

### POST /detect
Usado pelo worker. Recebe URL assinada, devolve os rostos encontrados.

```jsonc
// request
{ "image_url": "https://...", "min_quality": 0.5 }

// response 200
{ "faces": [ { "embedding": [/* 512 floats */], "bbox": {"x":0,"y":0,"w":0,"h":0}, "quality": 0.91 } ] }
```

### POST /embed
Usado pelo BFF da web na busca por selfie. `multipart/form-data`, campo `file`.

```jsonc
// response 200
{ "embedding": [/* 512 floats */], "quality": 0.88 }

// response 422 — nenhum rosto detectado
{ "error": { "code": "no_face_detected", "message": "..." } }
```

**A imagem não é persistida em nenhuma hipótese.**

### GET /health · GET /metrics

---

## 4. Fila de jobs

A web **insere** em `jobs`; o worker **consome**. A web nunca atualiza status.

| type | payload | quando |
|---|---|---|
| `index_faces` | `{ "photo_id": "uuid" }` | após confirmar upload de foto **sem** menores |
| `delete_objects` | `{ "keys": ["..."] }` | após admin excluir foto |
| `purge_expired_embeddings` | `{}` | agendado |

Se `contains_minors` for verdadeiro ou nulo, a web **não enfileira**
`index_faces`. O worker também verifica. O banco também. Três travas.

---

## 5. Busca facial — contrato de ponta a ponta

```
navegador ──selfie──► POST /api/face/search (web, servidor)
                          │
                          ├─► POST /embed (core)          → embedding
                          └─► rpc search_faces(embedding) → [{photo_id, distance}]
                          
resposta ao navegador: [{ photoId, distance }]   ← NUNCA o embedding
```

Erros que a web precisa tratar e traduzir para pt-BR:

| Origem | Situação | Mensagem ao usuário |
|---|---|---|
| `search_faces` | perfil inativo | conta aguardando liberação pela secretaria |
| `search_faces` | sem consentimento | pedir consentimento antes |
| `search_faces` | limite de 20 buscas/hora | tentar mais tarde |
| `/embed` 422 | nenhum rosto | orientar nova foto |
| `/embed` 5xx | serviço fora | falha temporária |

---

## 6. Conta autenticada porém inativa

Perfil criado a partir de `auth.users` nasce com `is_active = false` e só é
liberado por um admin. Consequências para a web:

- O login **funciona**: existe sessão válida e JWT.
- Toda leitura volta vazia, exceto o próprio registro em `profiles`.
- A web deve detectar `profiles.is_active = false` logo após o login e mostrar
  uma tela de "conta aguardando liberação", em vez de uma galeria vazia — que
  o usuário leria como erro.
- Nenhuma tela de upload, busca ou evento é oferecida nesse estado.
- Desativar um perfil existente tem o mesmo efeito, imediatamente.

A tela de administração de membros (ativar, mudar papel) é responsabilidade da
web; a autorização é do banco. Ver `docs/adr/0003-profile-provisioning.md`.

---

## 7. Chaves do R2

Formato fixo, gerado pela web no momento do upload:

```
events/{event_id}/photos/{photo_id}/original.webp
events/{event_id}/photos/{photo_id}/web.webp
events/{event_id}/photos/{photo_id}/thumb.webp
events/{event_id}/cover.webp
```

O worker depende desse formato para o job `delete_objects`. Mudança de formato
exige PR coordenado nos dois repositórios.

---

## 8. Invariantes que nenhum dos lados pode quebrar

1. Foto com `contains_minors` verdadeiro **nunca** tem embedding.
2. `contains_minors` nulo significa "não respondido" e a foto não é publicada.
3. Nenhuma resposta de API contém vetor de embedding.
4. A selfie não é persistida em nenhum ponto do caminho.
5. Somente `admin` executa `DELETE` em fotos.
6. Vínculo responsável→menor só é criado por `admin`.
7. `service_role key` nunca chega ao navegador.
8. Perfil nasce **inativo** e não enxerga nada até ser ativado por um `admin`.
9. Perfil **nunca é excluído** — nem pelo admin. Desativar é o único caminho.

Quebrar qualquer uma delas é incidente, não bug comum.
