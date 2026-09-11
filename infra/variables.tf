variable "account_id" {
  description = "Cloudflare account ID. Provided via TF_VAR_account_id, never committed."
  type        = string
}

variable "r2_bucket_name" {
  description = "Name of the R2 bucket that stores original photos and derivatives."
  type        = string
  default     = "poiema-gallery"
}

variable "r2_location" {
  description = "Location hint for the R2 bucket (WNAM, ENAM, WEUR, EEUR, APAC, OC). No default on purpose — see infra/README.md."
  type        = string
}
