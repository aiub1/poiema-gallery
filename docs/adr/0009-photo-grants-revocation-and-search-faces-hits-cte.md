# 0009 — Revogabilidade de `photo_grants` e implementação de `search_faces`

Status: accepted · Date: 2026-09-11

## Context

Duas decisões surgiram ao implementar a fase 4a (`face_consents`,
`photo_grants`, `search_faces`).

## Decisão 1 — `photo_grants` é permanente na leitura; só admin remove

`search_faces` concede acesso a foto privada de adulto como efeito
colateral de uma busca (`insert into photo_grants ... on conflict do
nothing`). Nem `ARQUITETURA.md` nem nenhuma ADR anterior diziam se esse
grant é revogável, nem o que acontece com grants já emitidos quando o
adulto revoga `face_consents` depois.

Decisão, por analogia direta com a ADR 0005 (que resolveu o caso análogo
para `minor_consents`):

- **Revogar `face_consents` bloqueia buscas novas** — `search_faces` já
  checa `revoked_at is null` antes de tudo — **mas não apaga grants já
  emitidos**. O mesmo raciocínio da ADR 0005 se aplica: revogação não pode
  punir quem revogou. Quem já foi encontrado por uma busca legítima
  continua enxergando a foto; revogar o consentimento só impede novas
  buscas em nome desse usuário.
- **`photo_grants` ganha policy de `delete`, só para `admin`**:
  ```sql
  create policy "admin removes grants" on photo_grants
    for delete to authenticated using ((select is_admin()));
  ```
  Esta é a válvula de escape para falso positivo do algoritmo. O limiar de
  similaridade (`ARQUITETURA.md` §7, cosseno `< 0.38`) é ponto de partida,
  **ainda não calibrado com fotos reais**. Um falso positivo hoje concede
  acesso permanente e irreversível a uma foto privada de outra pessoa, sem
  a válvula: erro de algoritmo não pode ser definitivo. `member`/`uploader`
  não removem, nem o próprio titular do grant — só `admin`, mesmo padrão de
  `photo_minors`/`minors`/`guardians` (escrita administrativa).
- Nenhuma policy de `insert`/`update` em `photo_grants` para `authenticated`
  — só `search_faces`, como `security definer`, grava.

### Lacunas conhecidas (fora do escopo desta fase)

Registradas aqui deliberadamente, no mesmo espírito da ADR 0005 com
"Remover fotos do meu filho":

- **O dono da foto privada não é notificado** quando um grant é emitido
  sobre a foto dele, e não tem como negar. A decisão de quem vê a própria
  foto privada, uma vez que alguém "se encontrou" nela por busca facial, é
  inteiramente unilateral da pessoa que buscou.
- **Não existe expiração nem auditoria de grants pelo lado do dono** —
  `photo_grants.granted_at` existe, mas nenhuma tela ou consulta expõe ao
  dono da foto quem tem acesso a ela por essa via, nem há job de expiração
  automática.

## Decisão 2 — `search_faces` não usa tabela temporária

`ARQUITETURA.md` §5.4 documentava a implementação com `create temp table
_hits on commit drop`. Isso quebra em qualquer sessão que chame a função
mais de uma vez dentro da mesma transação (constatado rodando os testes
pgTAP desta fase, que envolvem `begin`/`rollback` em torno de múltiplas
chamadas): `on commit drop` só dropa a tabela no commit, não a cada
`RETURN`/statement, e a segunda chamada falha com `relation "_hits"
already exists`.

A implementação usa uma CTE que grava (`INSERT ... RETURNING`) e uma que lê,
no mesmo `WITH`, sem tabela temporária:

```sql
return query
with hits as (
  select f.photo_id as pid, min(f.embedding <=> p_embedding)::real as dist
  from photo_faces f
  join photos p on p.id = f.photo_id
  where p.deleted_at is null
    and coalesce(p.contains_minors, true) = false
    and (p_event_id is null or f.event_id = p_event_id)
    and (f.embedding <=> p_embedding) < p_threshold
  group by f.photo_id
  order by dist
  limit p_limit
),
grant_ins as (
  insert into photo_grants (user_id, photo_id)
  select v_user, h.pid from hits h
  join photos p on p.id = h.pid
  where p.is_private
  on conflict do nothing
  returning 1
)
select h.pid, h.dist from hits h order by h.dist;
```

Uma CTE que modifica dados é sempre executada até o fim pelo Postgres,
independentemente de o resultado ser referenciado na consulta principal —
não é uma otimização arriscada, é comportamento documentado do `WITH`.
Resultado idêntico ao original (mesmos guardas, mesmo filtro de
`contains_minors`, mesmo grant emitido), sem depender de estado de sessão
entre chamadas. `pg_temp` no `search_path` continua obrigatório: a função
é `security definer`, e omitir `pg_temp` deixaria uma tabela temporária do
chamador ser pesquisada antes de `public` na resolução de nomes dentro da
função — o motivo original não tinha relação com a tabela `_hits` em si.

## Consequências

- `ARQUITETURA.md` §5.4 precisa refletir a implementação sem tabela
  temporária (nota, não reescrita do texto didático da seção).
- `ARQUITETURA.md` §12 (checklist LGPD): "Excluir meus dados faciais"
  cobre `face_consents`/`photo_faces`, mas não `photo_grants` — revogar
  consentimento não remove grants emitidos, por decisão 1 acima. Se um
  usuário pedir para não ser mais encontrável em busca alguma, revogar o
  consentimento resolve buscas futuras; grants passados exigem ação
  administrativa (remoção manual pelo admin) até existir fluxo dedicado.
- Se "notificar o dono da foto" ou "expiração de grants" forem
  implementados no futuro, revisar esta ADR explicitamente, não alterar a
  decisão 1 por acidente numa migration futura.
