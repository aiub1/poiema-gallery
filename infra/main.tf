provider "cloudflare" {
  # Authenticates via CLOUDFLARE_API_TOKEN env var — see infra/README.md.
}

# Private by default: no custom domain and no managed public (r2.dev) URL are
# attached anywhere in this configuration, so the bucket has no public read
# path. Access is only through the app's signed URLs (ARQUITETURA.md §8).
resource "cloudflare_r2_bucket" "gallery" {
  account_id = var.account_id
  name       = var.r2_bucket_name
  location   = var.r2_location
}
