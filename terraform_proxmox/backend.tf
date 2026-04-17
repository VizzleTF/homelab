terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "homelab/proxmox/terraform.tfstate"
    region = "ru-central-1"
    endpoints = {
      s3 = "https://s3.cloud.ru"
    }
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
