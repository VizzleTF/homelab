
locals {
  images_config = yamldecode(file("./configs/images.yaml"))
}

module "images" {
  for_each = { for image in local.images_config.images : image.image_name => image }
  source   = "./modules/images"

  url       = each.value.image_url
  file_name = "${each.value.image_name}.img"
}

