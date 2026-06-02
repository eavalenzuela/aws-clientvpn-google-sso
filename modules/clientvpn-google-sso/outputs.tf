output "endpoint_id" {
  description = "Client VPN endpoint ID (use with `aws ec2 export-client-vpn-client-configuration`)."
  value       = aws_ec2_client_vpn_endpoint.this.id
}

output "endpoint_dns_name" {
  description = "DNS name clients connect to."
  value       = aws_ec2_client_vpn_endpoint.this.dns_name
}

output "self_service_portal_url" {
  description = "Self-service portal URL (null when the portal is disabled)."
  value = var.enable_self_service_portal ? (
    "https://self-service.clientvpn.amazonaws.com/endpoints/${aws_ec2_client_vpn_endpoint.this.id}"
  ) : null
}

output "saml_provider_arn" {
  description = "ARN of the primary SAML identity provider."
  value       = aws_iam_saml_provider.vpn.arn
}

output "connection_log_group" {
  description = "CloudWatch log group for connection logs (null when logging disabled). Inspect this to confirm the exact group values Google sends."
  value       = var.connection_log_enabled ? aws_cloudwatch_log_group.vpn[0].name : null
}

output "authorization_rule_keys" {
  description = "The (group::cidr) pairs that were turned into authorization rules."
  value       = keys(local.auth_rules)
}
