# CONTRATO — galeria-web ↔ galeria-core

Versão 1.0 · **Este arquivo é idêntico nos dois repositórios.**
Alterou aqui, copie para o outro no mesmo PR.

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
| `search_faces` | sem consentimento | pedir consentimento antes |
| `search_faces` | limite de 20 buscas/hora | tentar mais tarde |
| `/embed` 422 | nenhum rosto | orientar nova foto |
| `/embed` 5xx | serviço fora | falha temporária |

---

## 6. Chaves do R2

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

## 7. Invariantes que nenhum dos lados pode quebrar

1. Foto com `contains_minors` verdadeiro **nunca** tem embedding.
2. `contains_minors` nulo significa "não respondido" e a foto não é publicada.
3. Nenhuma resposta de API contém vetor de embedding.
4. A selfie não é persistida em nenhum ponto do caminho.
5. Somente `admin` executa `DELETE` em fotos.
6. Vínculo responsável→menor só é criado por `admin`.
7. `service_role key` nunca chega ao navegador.

Quebrar qualquer uma delas é incidente, não bug comum.
