# ==========================================
# Terraform & Provider Configuration
# ==========================================
terraform {
  backend "s3" {
    bucket                      = "shakeserver-backup"
    key                         = "terraform/state/terraform.tfstate"
    region                      = "auto"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ==========================================
# Variables
# ==========================================
variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID"
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
  sensitive   = true
}

# ==========================================
# DNS Records
# ==========================================

# 1. Aレコード: mc (DNSのみ・非HTTPプロトコル用)
resource "cloudflare_record" "mc_node" {
  zone_id = var.cloudflare_zone_id
  name    = "mc"
  value   = "133.80.183.83"
  type    = "A"
  proxied = false
}

# 2. Aレコード: ルートドメイン (プロキシ済み・Web用)
resource "cloudflare_record" "root_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "ruruthegeek.dpdns.org"
  value   = "133.80.183.83"
  type    = "A"
  proxied = true
}

# 3. Aレコード: www (プロキシ済み・Web用)
resource "cloudflare_record" "www_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "www"
  value   = "133.80.183.83"
  type    = "A"
  proxied = true
}

# 4. SRVレコード: Pixelmon接続用
resource "cloudflare_record" "pixelmon_srv" {
  zone_id = var.cloudflare_zone_id
  name    = "pixelmon"
  type    = "SRV"

  data {
    service  = "_minecraft"
    proto    = "_tcp"
    name     = "pixelmon"
    priority = 1
    weight   = 1
    port     = 80
    target   = "mc.ruruthegeek.dpdns.org"
  }
}

# ==========================================
# R2 Bucket
# ==========================================

# 5. R2バケットの作成
resource "cloudflare_r2_bucket" "shakeserver_backup_bucket" {
  account_id = var.cloudflare_account_id
  name       = "shakeserver-backup"
  location   = "APAC"
}

# 6. UBSLEEPY用R2バケットの作成
resource "cloudflare_r2_bucket" "ubsleepy_app_data_bucket" {
  account_id = var.cloudflare_account_id
  name       = "ubsleepy-app-data" # UBSLEEPY用のバケット名
  location   = "APAC" # 任意のロケーション
}
