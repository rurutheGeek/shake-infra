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
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ==========================================
# Variables
# ==========================================
variable "server_ip" {
  description = "IP address of the target server for DNS records"
  type        = string
}

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
  content = var.server_ip
  type    = "A"
  proxied = false
}

# 2. Aレコード: ルートドメイン (プロキシ済み・Web用)
resource "cloudflare_record" "root_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "ruruthegeek.dpdns.org"
  content = var.server_ip
  type    = "A"
  proxied = true
}

# 3. Aレコード: www (プロキシ済み・Web用)
resource "cloudflare_record" "www_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "www"
  content = var.server_ip
  type    = "A"
  proxied = true
}

# 3b. Aレコード: ayahuya (プロキシ済み・Web用 / アヤフヤ大辞典・技術デモ)
resource "cloudflare_record" "ayahuya_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "ayahuya"
  content = var.server_ip
  type    = "A"
  proxied = true
}

# 3c. Aレコード: pkhack (プロキシ済み・Web用 / ポケモンクイズ)
resource "cloudflare_record" "pkhack_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "pkhack"
  content = var.server_ip
  type    = "A"
  proxied = true
}

# 3d. Aレコード: shake (プロキシ済み・Web用 / Issues・Shaketter・ToBa・Ikura)
resource "cloudflare_record" "shake_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "shake"
  content = var.server_ip
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

# 注: CF↔オリジンの SSL モードは Full（Cloudflare ダッシュボードで設定済み）。
# 各サブドメインは apex 証明書のまま CF プロキシ経由で TLS 配信できる（CF はオリジン
# 証明書のホスト名検証をしない）。ブラウザ↔CF は Universal SSL が *.ruruthegeek.dpdns.org を
# 自動カバー。Terraform 管理にするには API トークンに Zone Settings:Edit 権限が必要なため、
# ここでは扱わない（cloudflare_zone_settings_override は権限不足でエラーになる）。

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
  location   = "APAC"              # 任意のロケーション
}
# ==========================================
# GitHub Provider & Secrets Configuration
# ==========================================

provider "github" {
  token = var.github_token
  owner = var.github_owner
}

variable "github_token" {
  description = "GitHub Personal Access Token for Terraform (Requires repo permissions)"
  type        = string
  sensitive   = true
}

variable "github_owner" {
  description = "GitHub Username or Organization"
  type        = string
  default     = "rurutheGeek"
}

variable "discord_webhook_url" {
  description = "Discord Webhook URL for CI/CD Notifications"
  type        = string
  sensitive   = true
}

variable "infra_repo_dispatch_token" {
  description = "PAT used by App Repos to trigger dispatch on Infra Repo"
  type        = string
  sensitive   = true
}

variable "cf_r2_access_key_id" {
  description = "Cloudflare R2 Access Key ID (for Terraform CI backend)"
  type        = string
  sensitive   = true
}

variable "cf_r2_secret_access_key" {
  description = "Cloudflare R2 Secret Access Key (for Terraform CI backend)"
  type        = string
  sensitive   = true
}

locals {
  # CI用バックエンド設定（terraform-plan / drift-detection workflow で使用）
  tf_backend_config = <<-EOT
    bucket                      = "shakeserver-backup"
    key                         = "terraform/state/terraform.tfstate"
    region                      = "auto"
    endpoint                    = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  EOT
}

# ------------------------------------------
# インフラリポジトリ (shake-infra)
# ------------------------------------------
data "github_repository" "infra" {
  name = "shake-infra"
}

resource "github_actions_secret" "infra_discord_webhook" {
  repository  = data.github_repository.infra.name
  secret_name = "DISCORD_WEBHOOK_URL"
  value       = var.discord_webhook_url
}

locals {
  ansible_ssh_key_path    = "${path.module}/../local_config/ansible/credentials/id_rsa"
  ansible_vault_pass_path = "${path.module}/../local_config/ansible/credentials/.vault_pass"

  ansible_ssh_key    = fileexists(local.ansible_ssh_key_path) ? file(local.ansible_ssh_key_path) : "dummy_ssh_key"
  ansible_vault_pass = fileexists(local.ansible_vault_pass_path) ? file(local.ansible_vault_pass_path) : "dummy_vault_pass"
}

resource "github_actions_secret" "ansible_ssh_key" {
  repository  = data.github_repository.infra.name
  secret_name = "ANSIBLE_SSH_KEY"
  value       = local.ansible_ssh_key
}

resource "github_actions_secret" "ansible_vault_pass" {
  repository  = data.github_repository.infra.name
  secret_name = "ANSIBLE_VAULT_PASS"
  value       = local.ansible_vault_pass
}

resource "github_actions_secret" "ansible_vars" {
  repository  = data.github_repository.infra.name
  secret_name = "ANSIBLE_VARS"                                                                                                                         # pragma: allowlist secret
  value       = fileexists("${path.module}/../local_config/ansible/vars.yml") ? file("${path.module}/../local_config/ansible/vars.yml") : "dummy_vars" # pragma: allowlist secret
}

resource "github_actions_secret" "cloudflare_api_token" {
  repository  = data.github_repository.infra.name
  secret_name = "CLOUDFLARE_API_TOKEN"
  value       = var.cloudflare_api_token
}

resource "github_actions_secret" "cf_r2_access_key_id" {
  repository  = data.github_repository.infra.name
  secret_name = "CF_R2_ACCESS_KEY_ID"
  value       = var.cf_r2_access_key_id
}

resource "github_actions_secret" "cf_r2_secret_access_key" {
  repository  = data.github_repository.infra.name
  secret_name = "CF_R2_SECRET_ACCESS_KEY"
  value       = var.cf_r2_secret_access_key
}

resource "github_actions_secret" "tf_backend_config" {
  repository  = data.github_repository.infra.name
  secret_name = "TF_BACKEND_CONFIG"
  value       = local.tf_backend_config
}

# ------------------------------------------
# アプリリポジトリ (ubsleepy 等)
# ------------------------------------------
data "github_repository" "ubsleepy" {
  name = "ubsleepy"
}

resource "github_actions_secret" "ubsleepy_dispatch_token" {
  repository  = data.github_repository.ubsleepy.name
  secret_name = "INFRA_REPO_DISPATCH_TOKEN"
  value       = var.infra_repo_dispatch_token
}

data "github_repository" "shakeweb" {
  name = "shake-web"
}

resource "github_actions_secret" "shakeweb_dispatch_token" {
  repository  = data.github_repository.shakeweb.name
  secret_name = "INFRA_REPO_DISPATCH_TOKEN"
  value       = var.infra_repo_dispatch_token
}

# ------------------------------------------
# pkhack（ポケモンクイズ / shake-web 3分割 Phase B）
# ------------------------------------------
data "github_repository" "pkhack" {
  name = "pkhack"
}

# push 時に shake-infra へ deploy_pkhack を dispatch するためのトークン
resource "github_actions_secret" "pkhack_dispatch_token" {
  repository  = data.github_repository.pkhack.name
  secret_name = "INFRA_REPO_DISPATCH_TOKEN"
  value       = var.infra_repo_dispatch_token
}

# ------------------------------------------
# ayahuya（アヤフヤ大辞典・技術デモ / shake-web 3分割 Phase A）
# ------------------------------------------
data "github_repository" "ayahuya" {
  name = "ayahuya"
}

# push 時に shake-infra へ deploy_ayahuya を dispatch するためのトークン
resource "github_actions_secret" "ayahuya_dispatch_token" {
  repository  = data.github_repository.ayahuya.name
  secret_name = "INFRA_REPO_DISPATCH_TOKEN"
  value       = var.infra_repo_dispatch_token
}

# 注: pkhack / ayahuya の clone は shakeserver の Deploy Key（/var/www/.ssh/id_ed25519_deploy）で
# 行う。この鍵は既に各リポジトリで使用可能（GitHub は同一鍵を複数リポジトリの Deploy Key として
# 重複登録できず "key already in use" になるため）、Terraform では登録しない。鍵の登録は GitHub 側で
# 管理する（web ロールが未登録時にエラーで公開鍵を表示する仕組みあり）。

# ==========================================
# Cloudflare Workers (Failover / Maintenance)
# ==========================================

variable "maintenance_mode" {
  description = "Enable maintenance mode (routes traffic to Worker)"
  type        = bool
  default     = false
}

resource "cloudflare_workers_script" "failover_script" {
  account_id = var.cloudflare_account_id
  name       = "maintenance-failover"
  content    = replace(file("${path.module}/worker_scripts/failover_worker.js"), "__MAINTENANCE_HTML_CONTENT__", file("${path.module}/worker_scripts/maintenance.html"))

  module = true
}

resource "cloudflare_workers_route" "failover_route" {
  count       = var.maintenance_mode ? 1 : 0
  zone_id     = var.cloudflare_zone_id
  pattern     = "ruruthegeek.dpdns.org/*"
  script_name = cloudflare_workers_script.failover_script.name
}

