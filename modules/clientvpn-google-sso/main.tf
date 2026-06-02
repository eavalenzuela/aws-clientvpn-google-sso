locals {
  # One authorization rule per (group, cidr) pair.
  auth_rules = merge([
    for grp, cidrs in var.group_access : {
      for cidr in cidrs : "${grp}::${cidr}" => {
        group = grp
        cidr  = cidr
      }
    }
  ]...)

  # Explicit routes: every additional CIDR across every associated subnet.
  vpn_routes = merge([
    for cidr in var.additional_route_cidrs : {
      for subnet in var.target_subnet_ids : "${cidr}::${subnet}" => {
        cidr   = cidr
        subnet = subnet
      }
    }
  ]...)
}

# --- SAML identity providers (uploaded Google Workspace metadata) ---
resource "aws_iam_saml_provider" "vpn" {
  name                   = "${var.name}-google-clientvpn"
  saml_metadata_document = var.google_idp_metadata
  tags                   = var.tags
}

resource "aws_iam_saml_provider" "self_service" {
  count                  = var.enable_self_service_portal ? 1 : 0
  name                   = "${var.name}-google-clientvpn-selfservice"
  saml_metadata_document = var.google_idp_metadata_self_service
  tags                   = var.tags
}

# --- Connection logging ---
resource "aws_cloudwatch_log_group" "vpn" {
  count             = var.connection_log_enabled ? 1 : 0
  name              = "/aws/clientvpn/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# --- The endpoint ---
resource "aws_ec2_client_vpn_endpoint" "this" {
  description            = "Client VPN (${var.name}) - Google Workspace SSO"
  server_certificate_arn = var.server_certificate_arn
  client_cidr_block      = var.client_cidr_block
  split_tunnel           = var.split_tunnel
  transport_protocol     = var.transport_protocol
  vpn_port               = var.vpn_port
  session_timeout_hours  = var.session_timeout_hours
  dns_servers            = var.dns_servers

  vpc_id             = var.vpc_id
  security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : null

  authentication_options {
    type                           = "federated-authentication"
    saml_provider_arn              = aws_iam_saml_provider.vpn.arn
    self_service_saml_provider_arn = var.enable_self_service_portal ? aws_iam_saml_provider.self_service[0].arn : null
  }

  connection_log_options {
    enabled               = var.connection_log_enabled
    cloudwatch_log_group  = var.connection_log_enabled ? aws_cloudwatch_log_group.vpn[0].name : null
  }

  dynamic "client_login_banner_options" {
    for_each = var.client_login_banner != "" ? [1] : []
    content {
      enabled     = true
      banner_text = var.client_login_banner
    }
  }

  tags = merge(var.tags, { Name = var.name })
}

# --- Associate subnets ---
resource "aws_ec2_client_vpn_network_association" "this" {
  for_each               = toset(var.target_subnet_ids)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  subnet_id              = each.value
}

# --- Per-group authorization rules ---
resource "aws_ec2_client_vpn_authorization_rule" "per_group" {
  for_each               = local.auth_rules
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = each.value.cidr
  access_group_id        = each.value.group

  # Wait until at least one subnet association exists, otherwise the rule fails.
  depends_on = [aws_ec2_client_vpn_network_association.this]
}

# --- Explicit routes for out-of-VPC destinations ---
resource "aws_ec2_client_vpn_route" "additional" {
  for_each               = local.vpn_routes
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  destination_cidr_block = each.value.cidr
  target_vpc_subnet_id   = each.value.subnet

  depends_on = [aws_ec2_client_vpn_network_association.this]
}
