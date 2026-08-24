# supabase — banco

Postgres 15 + pgvector. **Fonte da verdade da autorização** (RLS). A web não
decide quem vê o quê; ela pergunta ao banco.

```
migrations/   SQL numerado e IMUTÁVEL depois de aplicado
tests/        pgTAP — um cenário por papel
seed.sql      dados mínimos para desenvolvimento
```

Regras que não se negociam (CLAUDE.md §5.1):

- RLS habilitada em **toda** tabela. Tabela nova sem policy é bug, não pendência.
- Migration que cria tabela já traz `enable row level security`, as policies e
  os índices.
- Nada de `security definer` sem `set search_path = public`.
- O teste de permissão é escrito **junto** com a migration, não depois.

As três travas de proteção a menores vivem aqui em duas delas — os triggers
`trg_forbid_minor_faces` e `trg_purge_faces_on_minor_flag`, e o filtro dentro de
`search_faces`. Ver CLAUDE.md §3 e ARQUITETURA.md §5.3/§5.4.

```bash
npx supabase start      # stack local (Docker)
npx supabase db reset   # recria aplicando migrations + seed
npx supabase test db    # pgTAP
```

Depois de mudar o schema, regerar os tipos para o galeria-web (docs/CONTRATO.md §2).
