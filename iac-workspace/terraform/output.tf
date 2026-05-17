output "ubsleepy_r2_bucket_name" {
  description = "The name of the R2 bucket for UBSLEEPY app data"
  value       = cloudflare_r2_bucket.ubsleepy_app_data_bucket.name
}