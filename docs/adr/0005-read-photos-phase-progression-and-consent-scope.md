# 0005 — Progressão de `read photos` por fase e escopo de `minor_consents`

Status: accepted · Date: 2026-09-11

## Context

Duas decisões surgiram ao implementar a fase 3 (`minors`, `guardians`,
`minor_consents`, `photo_minors`).

## Decisão 1 — `read photos` tem três estados, não dois

`ARQUITETURA.md` §5.2 documentava a policy `read photos` como tendo uma
versão "reduzida" (fase 2) e uma versão "completa" (a partir da fase 3/4),
com a nota: "a migration da fase 3/4 correspondente troca a policy pela
versão completa documentada aqui."

Isso é impreciso. A versão "completa" já documentada em §5.2 inclui o ramo
de `photo_grants`:

```sql
or (
  coalesce(contains_minors, true) = false
  and (
    not is_private
    or exists (select 1 from photo_grants g
                where g.photo_id = photos.id
                  and g.user_id = (select auth.uid())))
)
```

`photo_grants` é tabela da **fase 4** (`ARQUITETURA.md` §13, `CLAUDE.md`
§7). Aplicar essa versão na migration da fase 3 quebraria toda leitura de
foto — `relation "photo_grants" does not exist` — porque a tabela ainda não
existe. A policy de `read photos` tem na verdade **três** estados, um por
fase que a toca:

1. **Fase 2** (`20260910224708_phase2_photos.sql`, já aplicada): sem
   `guardians`/`photo_minors`/`photo_grants`. `contains_minors = true` e
   `is_private = true` ficam visíveis só para admin/uploader dono — fail
   closed nos dois eixos.
2. **Fase 3** (`20260911054031_phase3_minors.sql`, esta migration):
   acrescenta *só* o ramo do responsável vinculado
   (`is_guardian_of_photo(id)`). O ramo de `is_private` continua **igual ao
   da fase 2** — ainda fail closed, porque `photo_grants` não existe. A
   foto marcada com menor passa a ser visível para quem tem vínculo
   declarado; a foto privada de adulto continua sem mecanismo de liberação
   até a fase 4.
3. **Fase 4** (futura, quando `photo_grants` e `search_faces` existirem):
   troca o ramo de `is_private` para incluir `exists (select 1 from
   photo_grants ...)`. É só aí que a policy alcança a forma que
   `ARQUITETURA.md` §5.2 chama de "completa" — o texto atual do documento
   já descreve esse estado final, e não precisa mudar; a nota logo abaixo
   dele é que estava errada ao descrever só dois estados.

### Union das regras dentro da fase 3

Uma foto pode ter `contains_minors = true` **e** `is_private = true` ao
mesmo tempo (`ARQUITETURA.md` §2: "se as duas flags coexistem, vale a
união das regras"). Na policy da fase 3, o ramo `is_guardian_of_photo(id)`
não depende de `is_private` — o responsável vinculado enxerga a foto do
filho independentemente da flag de privacidade, porque `is_private` é o
eixo de "foto privada de **adulto**" (`ARQUITETURA.md` §2), não tem relação
com o vínculo de menor. Coberto por pgTAP
(`supabase/tests/03_minors_rls.sql`, "responsável vinculado ativo lê foto
privada do filho").

## Decisão 2 — `minor_consents` não gateia leitura nesta fase

`minor_consents` registra a autorização do responsável (LGPD,
`ARQUITETURA.md` §12), mas nenhuma policy desta migration a consulta.
`is_guardian_of_photo()` decide só pelo vínculo em `guardians` + perfil
ativo — não verifica `minor_consents.revoked_at`.

Isso é deliberado, não esquecimento: gatear a leitura pelo consentimento
faria com que **revogar** o consentimento cegasse o próprio responsável
para a foto do filho, em vez de tirar a foto de circulação — o efeito
oposto ao que a revogação deveria produzir. Quem decide se a foto continua
publicada depois de uma revogação é uma ação administrativa (despublicar,
excluir, ou uma policy futura que filtre pela consulta em `minor_consents`
para *todos* os papéis, não só o do próprio responsável), não uma trava na
leitura do responsável.

`minor_consents` funciona hoje só como **registro legal**: quem deu
consentimento, quando, e se foi revogado, auditável por admin e pelo
próprio responsável (`read own minor consent`).

### Lacuna conhecida

O item "Remover fotos do meu filho" do checklist LGPD (`ARQUITETURA.md`
§12) não está implementado por nenhum mecanismo desta fase — nem
automático (revogar consentimento não produz efeito no banco) nem manual
documentado (não existe fluxo equivalente a `removal_requests` para
menores). Fica registrado aqui como lacuna conhecida, fora do escopo da
fase 3. Quando for endereçada, revisar esta ADR.

## Consequências

- `ARQUITETURA.md` §5.2 precisa de uma nota descrevendo os três estados de
  `read photos`, não dois.
- O nome `0005-supabase-manual-setup.md`, reservado em `ARQUITETURA.md` §9,
  passa a `0006-supabase-manual-setup.md` — ainda não escrita.
- Fase 4 (`photo_grants`, `search_faces`) precisa trocar o ramo de
  `is_private` em `read photos` — não o ramo de `contains_minors`, que já
  fica pronto nesta migration.
- Se "Remover fotos do meu filho" for implementado como gate automático via
  `minor_consents`, a decisão 2 desta ADR precisa ser revisitada
  explicitamente, não alterada por acidente numa migration futura.
