-- pgTAP — guardas estruturais dinâmicos (docs/ARQUITETURA.md §10).
-- Varrem o catálogo do schema public inteiro, não uma lista fixa de tabelas
-- ou funções: pegam sozinhos o que for criado nas fases seguintes.

begin;

create extension if not exists pgtap;

select plan(3);

select is_empty(
  $$ select c.relname
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relkind = 'r'
        and not c.relrowsecurity $$,
  'toda tabela em public tem RLS habilitada'
);

select is_empty(
  $$ select p.proname
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prosecdef
        and not exists (
          select 1 from unnest(coalesce(p.proconfig, '{}')) cfg
           where cfg like 'search_path=%pg_temp%'
        ) $$,
  'toda função security definer fixa search_path com pg_temp'
);

select is_empty(
  $$ select table_name || '.' || privilege_type
       from information_schema.role_table_grants
      where grantee = 'anon' and table_schema = 'public' $$,
  'nenhuma tabela em public concede privilégio ao papel anon'
);

select * from finish();
rollback;
