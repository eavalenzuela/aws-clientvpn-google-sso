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

  # Managed security group (if any) plus caller-supplied ones.
  endpoint_security_group_ids = concat(
    var.create_security_group ? [aws_security_group.vpn[0].id] : [],
    var.security_group_ids
  )
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

  lifecycle {
    precondition {
      condition     = trimspace(var.google_idp_metadata_self_service) != ""
      error_message = "enable_self_service_portal = true requires google_idp_metadata_self_service (IdP metadata XML from the second Google SAML app, ACS http://127.0.0.1:35002)."
    }
  }
}

# --- Connection logging ---
resource "aws_cloudwatch_log_group" "vpn" {
  count             = var.connection_log_enabled ? 1 : 0
  name              = "/aws/clientvpn/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# --- Optional dedicated security group for the endpoint ENIs ---
resource "aws_security_group" "vpn" {
  count       = var.create_security_group ? 1 : 0
  name        = "${var.name}-clientvpn"
  description = "Client VPN endpoint ENIs (${var.name}): VPN client traffic into the VPC"
  vpc_id      = var.vpc_id

  egress {
    description = "VPN client traffic to authorized destinations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.security_group_egress_cidrs
  }

  tags = merge(var.tags, { Name = "${var.name}-clientvpn" })
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
  self_service_portal    = var.enable_self_service_portal ? "enabled" : "disabled"

  vpc_id             = var.vpc_id
  security_group_ids = length(local.endpoint_security_group_ids) > 0 ? local.endpoint_security_group_ids : null

  authentication_options {
    type                           = "federated-authentication"
    saml_provider_arn              = aws_iam_saml_provider.vpn.arn
    self_service_saml_provider_arn = var.enable_self_service_portal ? aws_iam_saml_provider.self_service[0].arn : null
  }

  connection_log_options {
    enabled              = var.connection_log_enabled
    cloudwatch_log_group = var.connection_log_enabled ? aws_cloudwatch_log_group.vpn[0].name : null
  }

  dynamic "client_connect_options" {
    for_each = var.client_connect_lambda_arn != null ? [1] : []
    content {
      enabled             = true
      lambda_function_arn = var.client_connect_lambda_arn
    }
  }

  dynamic "client_login_banner_options" {
    for_each = var.client_login_banner != "" ? [1] : []
    content {
      enabled     = true
      banner_text = var.client_login_banner
    }
  }

  tags = merge(var.tags, { Name = var.name })

  lifecycle {
    precondition {
      condition     = !(length(var.security_group_ids) > 0 && var.vpc_id == null)
      error_message = "security_group_ids requires vpc_id to be set."
    }
    precondition {
      condition     = !(var.create_security_group && var.vpc_id == null)
      error_message = "create_security_group = true requires vpc_id to be set."
    }
  }
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
  description            = "Group ${each.value.group} -> ${each.value.cidr}"

  # Wait until at least one subnet association exists, otherwise the rule fails.
  depends_on = [aws_ec2_client_vpn_network_association.this]
}

# --- Catch-all authorization rules (every authenticated user) ---
resource "aws_ec2_client_vpn_authorization_rule" "all_groups" {
  for_each               = toset(var.authorize_all_groups_cidrs)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this.id
  target_network_cidr    = each.value
  authorize_all_groups   = true
  description            = "All authenticated users -> ${each.value}"

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

# --- Monitoring: saved Logs Insights queries over the connection log ---
resource "aws_cloudwatch_query_definition" "connection_attempts" {
  count = var.connection_log_enabled && var.create_log_insights_queries ? 1 : 0
  name  = "clientvpn/${var.name}/connection-attempts"

  log_group_names = [aws_cloudwatch_log_group.vpn[0].name]

  query_string = <<-EOT
    fields @timestamp, username, `connection-attempt-status`, `client-ip`, `common-name`
    | filter `connection-log-type` = "connection-attempt"
    | sort @timestamp desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "connection_failures" {
  count = var.connection_log_enabled && var.create_log_insights_queries ? 1 : 0
  name  = "clientvpn/${var.name}/connection-failures"

  log_group_names = [aws_cloudwatch_log_group.vpn[0].name]

  query_string = <<-EOT
    fields @timestamp, username, `connection-attempt-failure-reason`, `client-ip`
    | filter `connection-log-type` = "connection-attempt" and `connection-attempt-status` = "failed"
    | sort @timestamp desc
    | limit 100
  EOT
}

# --- Monitoring: alarm on SAML authentication failures ---
resource "aws_cloudwatch_metric_alarm" "auth_failures" {
  count               = var.create_auth_failure_alarm ? 1 : 0
  alarm_name          = "${var.name}-clientvpn-auth-failures"
  alarm_description   = "SAML authentication failures on Client VPN endpoint ${var.name}. Check for group-mapping drift, expired IdP metadata, or brute force."
  namespace           = "AWS/ClientVPN"
  metric_name         = "AuthenticationFailures"
  dimensions          = { Endpoint = aws_ec2_client_vpn_endpoint.this.id }
  statistic           = "Sum"
  period              = var.auth_failure_alarm_period
  evaluation_periods  = 1
  threshold           = var.auth_failure_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = var.tags
}
