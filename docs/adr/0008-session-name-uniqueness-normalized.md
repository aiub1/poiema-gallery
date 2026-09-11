# 0008 — Unicidade de nome de sessão é normalizada, não literal

Status: accepted · Date: 2026-09-11

## Context

`ARQUITETURA.md` §15 registrava a pendência: duas sessões "Culto da manhã"
no mesmo evento são possíveis hoje, sem nenhuma constraint impedindo. A
forma óbvia de fechar isso é `unique (event_id, name)`.

## Decision

A constraint implementada não é o `unique (event_id, name)` literal, e sim
um índice único sobre a versão normalizada do nome:

```sql
create unique index sessions_event_id_name_key
  on public.sessions (event_id, lower(btrim(name)));
```

O caso real que motivou a pendência é a secretaria recadastrando a mesma
sessão por engano — "Culto da manhã" de novo, digitado com capitalização
ou espaço diferente ("Culto da Manhã ", " culto da manhã") — não duas
sessões deliberadamente distintas que coincidem em maiúscula. Um
`unique (event_id, name)` literal deixa passar exatamente o erro que a
pendência queria fechar.

A alternativa cogitada — deixar a normalização como validação no
`galeria-web`, banco só com a constraint literal — foi descartada: contraria
a regra de ouro do `CONTRATO.md` §1 ("a web nunca decide quem pode ver o
quê... ela pergunta ao banco"), que embora escrita para autorização vale
pelo mesmo motivo aqui — a garantia de integridade de dado tem que estar
onde não pode ser contornada por um segundo client que escreva direto no
banco (o worker, um script de admin, o Studio).

## Consequences

- **Um índice com expressão não é uma `constraint` nomeada na tabela** —
  é um índice único. A diferença aparece em duas frentes:
  - o erro do Postgres na violação é `23505` (`unique_violation`), igual
    ao de qualquer índice único, mas **sem** nome de constraint associável
    via `\d` na tabela — só via `\di` ou consultando `pg_indexes`. Testes
    pgTAP que esperam esse erro checam o SQLSTATE, não um nome de
    constraint (`supabase/tests/04_schema_pendencias.sql`).
  - ferramentas que listam "constraints" de uma tabela (incluindo a
    geração de tipos do `CONTRATO.md` §2, quando `galeria-web` existir)
    não vão mostrar isso como uma constraint de unicidade named — é
    preciso saber olhar os índices.
- **Efeito colateral esperado, não bug**: alguém vai tentar cadastrar
  "Culto Da Manhã" num evento que já tem "culto da manhã" e a inserção vai
  falhar sem motivo óbvio pela UI, a menos que o `galeria-web` traduza o
  `23505` numa mensagem que explique a normalização. Guardado aqui para
  quando isso for reportado como "bug" — é a constraint funcionando.
- Nomes de sessão que diferem só por acentuação (`"Manha"` vs `"Manhã"`)
  continuam sendo tratados como distintos — `lower(btrim(...))` não faz
  normalização Unicode. Fora do escopo desta ADR; revisitar se aparecer
  como problema real.
