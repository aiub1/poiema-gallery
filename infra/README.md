# infra — OpenTofu

Cloudflare R2 e Fly.io. **Custo alvo: R$ 0/mês** — uso interno, gratuito, sem
fins lucrativos.

O que não couber no OpenTofu (configuração manual no Supabase) vai documentado
em `docs/adr/0005-supabase-manual-setup.md` (ARQUITETURA.md §9).

Segredos por variável de ambiente e Fly secrets. Nunca commitar `.env`.
`service_role key` só no worker e em rotas de servidor do galeria-web.

```bash
cd infra && tofu plan
```
