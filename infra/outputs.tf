output "r2_bucket_name" {
  description = "Name of the R2 bucket. The worker and galeria-web reference this, not the bucket ID."
  value       = cloudflare_r2_bucket.gallery.name
}
