# infra — OpenTofu

Cloudflare R2 e Fly.io. **Custo alvo: R$ 0/mês** — uso interno, gratuito, sem
fins lucrativos.

O que não couber no OpenTofu (configuração manual no Supabase e na
Cloudflare) vai documentado em
[`docs/adr/0006-supabase-manual-setup.md`](../docs/adr/0006-supabase-manual-setup.md)
(`ARQUITETURA.md` §9).

Estado atual: só o bucket R2 (`main.tf`). Apps Fly.io entram na fase 4.

---

## Pré-requisitos

- OpenTofu **1.12.6** fixado (`required_version` em `versions.tf`).
  Instalação standalone oficial:

  ```bash
  curl -Ls https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
  chmod +x install-opentofu.sh
  ./install-opentofu.sh --install-method standalone --opentofu-version 1.12.6
  ```

  Nota de ambiente: se o `gpg` do sistema estiver em locale não-inglês, o
  parser de assinatura do script pode falhar com `signed with the incorrect
  key: .` mesmo com a assinatura correta (o script procura a string em
  inglês `Primary key fingerprint:` na saída do `gpg`). Rodar com
  `LC_ALL=C LANG=C` na frente resolve.

- Provider `cloudflare/cloudflare` fixado em `4.52.9` (`versions.tf`).

## Variáveis de ambiente exigidas

| Variável | Origem | Observação |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare → My Profile → API Tokens | token com permissão de gerenciar R2 bucket (não confundir com a credencial S3-compatible do bucket — ver seção abaixo). Local: export no shell. CI: `secrets.CLOUDFLARE_API_TOKEN` do GitHub Actions. |
| `TF_VAR_account_id` | Cloudflare → barra lateral do dashboard, "Account ID" | não é segredo crítico, mas fica fora do repo por consistência. Alternativa: `terraform.tfvars` local (ver `terraform.tfvars.example`). |

Nunca commitar `terraform.tfvars` com valores reais — só
`terraform.tfvars.example`, com placeholders.

## Rodando

```bash
cd infra
export CLOUDFLARE_API_TOKEN=...
export TF_VAR_account_id=...
tofu init -backend=false   # sem backend remoto ainda — ver seção de state
tofu validate
tofu plan                  # exige credenciais; não é rodado em CI ainda
```

**Não rodar `tofu apply`** sem alinhar com o time — este README documenta
como provisionar, não é sinal verde para provisionar.

## Verificação pós-apply (obrigatória, antes de qualquer foto)

`tofu validate` não autentica na Cloudflare — confirma sintaxe e tipos do
`.tf`, nada sobre o estado real do recurso na API. Ausência de campo de
acesso público no código (seção "Bucket privado" abaixo) é a intenção
declarada, não a confirmação de que o bucket saiu privado.

Na primeira vez que `tofu apply` rodar de verdade, **antes de qualquer
foto ser enviada**, conferir manualmente no dashboard Cloudflare → R2 →
o bucket criado:

- **Public Access** → nenhum domínio customizado anexado;
- **Public Access** → `r2.dev` subdomain **Disabled**.

Só depois disso o bucket está confirmado privado, não só configurado para
ser.

## Credencial S3-compatible do bucket (passo manual, fora do Tofu)

Deliberado: o Tofu cria **só o bucket**, nunca token ou credencial de acesso
(decisão registrada, ver `docs/adr/0006-supabase-manual-setup.md`). Motivos:

- credencial no state é dado sensível persistido em texto plano — o
  `CLAUDE.md` §5.3 trata segredo como algo que só entra por env var/Fly
  secret, nunca por artefato gerenciado;
- o plano é migrar o próprio state para dentro do R2 (seção abaixo);
  credencial do R2 guardada num state que mora no R2 é uma circularidade
  desnecessária.

Passo manual:

1. Dashboard Cloudflare → **R2** → **Manage R2 API Tokens** → **Create API
   Token**.
2. Permissão: **Object Read & Write**, escopo **restrito a este bucket**
   (nunca "Apply to all buckets in this account").
3. Copiar `Access Key ID` e `Secret Access Key` — aparecem uma única vez.
4. Destino: `fly secrets set` no worker (nunca em `.env`, nunca commitado,
   nunca em log). O worker usa essa credencial para assinar as URLs de
   leitura de 15 min (`ARQUITETURA.md` §8) — a assinatura é responsabilidade
   da aplicação, não do Tofu.

## Bucket privado

`cloudflare_r2_bucket` (`main.tf`) não tem nenhum campo de acesso público —
a única forma de expor um bucket R2 publicamente é anexar um domínio
customizado ou o domínio gerenciado `r2.dev`, e nenhum dos dois aparece
nesta configuração. Ausência de recurso é a política: sem
`cloudflare_r2_custom_domain` no código, o bucket não tem caminho de leitura
público. Toda leitura passa por URL assinada, gerada pela aplicação.

## Estado

**Por ora: state local** (`infra/terraform.tfstate`, gitignored — nunca
commitado). Fica assim até o bucket R2 existir de fato (dependência
circular: não dá para guardar o state do bucket dentro do próprio bucket
antes dele existir).

Depois que o bucket for criado (`tofu apply` uma primeira vez com state
local), migrar o backend para S3-compatible apontando para um bucket próprio
de state — decisão registrada em
[`docs/adr/0007-tfstate-separate-bucket.md`](../docs/adr/0007-tfstate-separate-bucket.md).
Comando pronto para rodar nesse momento — não é TODO, é o passo em si:

```bash
cd infra

cat >> versions.tf <<'EOF'

terraform {
  backend "s3" {
    bucket                      = "poiema-gallery-tfstate"   # bucket separado do bucket de fotos
    key                         = "infra/terraform.tfstate"
    region                      = "auto"
    endpoint                    = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
    access_key                  = null # via AWS_ACCESS_KEY_ID
    secret_key                  = null # via AWS_SECRET_ACCESS_KEY
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
EOF

export AWS_ACCESS_KEY_ID=...      # credencial S3-compatible gerada manualmente, ver seção acima
export AWS_SECRET_ACCESS_KEY=...

tofu init -migrate-state
```

Usar um **bucket separado** para o state (`poiema-gallery-tfstate`, criado
manualmente uma única vez, fora do Tofu — o mesmo problema de galinha e ovo
do bucket de fotos) evita misturar state de infraestrutura com o conteúdo
da galeria.
