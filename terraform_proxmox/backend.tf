terraform {
  backend "s3" {
    bucket                  = "terraform-state"
    key                     = "homelab/proxmox/terraform.tfstate"
    region                  = "ru-central-1"
    endpoint                = "https://s3.cloud.ru"
    skip_region_validation  = true
    skip_credentials_validation = true
    force_path_style        = true
    skip_metadata_api_check = true
  }
}
