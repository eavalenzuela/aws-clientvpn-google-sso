terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Reference an existing ISSUED ACM cert for the VPN server.
data "aws_acm_certificate" "vpn_server" {
  domain   = var.vpn_server_domain
  statuses = ["ISSUED"]
}

module "clientvpn" {
  source = "../../modules/clientvpn-google-sso"

  name                   = "corp"
  server_certificate_arn = data.aws_acm_certificate.vpn_server.arn
  client_cidr_block      = "10.100.0.0/22"

  google_idp_metadata = file("${path.module}/google-idp-metadata.xml")

  enable_self_service_portal       = true
  google_idp_metadata_self_service = file("${path.module}/google-idp-metadata-selfservice.xml")

  target_subnet_ids = var.target_subnet_ids
  dns_servers       = var.dns_servers

  # SAML group (email Google sends in `memberOf`) -> reachable CIDRs.
  group_access = {
    "eng@yourco.com" = ["10.0.1.0/24", "10.0.2.0/24"]
    "ops@yourco.com" = ["10.0.0.0/16"]
  }

  # Routes for destinations outside the associated subnet's own VPC CIDR.
  additional_route_cidrs = ["10.0.0.0/16"]

  split_tunnel = true

  tags = {
    Team        = "platform"
    Environment = "prod"
  }
}

output "endpoint_id" {
  value = module.clientvpn.endpoint_id
}

output "self_service_portal_url" {
  value = module.clientvpn.self_service_portal_url
}

output "connection_log_group" {
  value = module.clientvpn.connection_log_group
}
