locals {
  pools_config = yamldecode(file("./configs/pools.yaml"))
}

module "pools" {
  for_each = { for pool in(local.pools_config.pools != null ? local.pools_config.pools : []) : pool.pool_id => pool }
  source   = "./modules/pools"

  pool_id = each.value.pool_id
  comment = try(each.value.comment, "")
} 
