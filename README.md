# AWS Client VPN + Google Workspace SSO

Terraform module that stands up an AWS Client VPN endpoint authenticating users
against **Google Workspace** via SAML 2.0, with **per-group network access**.

- `modules/clientvpn-google-sso/` — the reusable module
- `examples/complete/` — a working invocation
- `GUIDE.md` — end-to-end setup, migration, and operations guide

## Quick start

```hcl
module "clientvpn" {
  source = "github.com/yourorg/aws-clientvpn-google-sso//modules/clientvpn-google-sso"

  name                   = "corp"
  server_certificate_arn = data.aws_acm_certificate.vpn_server.arn
  client_cidr_block      = "10.100.0.0/22"
  google_idp_metadata    = file("google-idp-metadata.xml")
  target_subnet_ids      = ["subnet-aaa", "subnet-bbb"]

  group_access = {
    "eng@yourco.com" = ["10.0.1.0/24"]
    "ops@yourco.com" = ["10.0.0.0/16"]
  }
  additional_route_cidrs = ["10.0.0.0/16"]
}
```

The Google Workspace SAML app is configured **manually** in the Admin console
(the Google provider can't reliably manage custom SAML apps). See `GUIDE.md`.

> **The contract:** the keys of `group_access` must exactly match the group
> value Google emits in its `memberOf` SAML attribute (the group's email).
> Connect once and read `connection_log_group` to confirm the real value.

## Requirements

| Name | Version |
|---|---|
| terraform | >= 1.3 |
| aws provider | >= 5.0 |

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | — | Name/identifier for the endpoint and associated resources (1–99 chars, `[A-Za-z0-9._-]`). |
| `google_idp_metadata` | `string` | — | IdP metadata XML from the primary Google SAML app. |
| `server_certificate_arn` | `string` | — | ACM ARN of the server certificate. |
| `client_cidr_block` | `string` | — | Client IP CIDR; valid IPv4, prefix /12–/22, non-overlapping. |
| `target_subnet_ids` | `list(string)` | — | Subnets to associate (at least one; one per AZ served). |
| `group_access` | `map(list(string))` | — | SAML group email → CIDRs that group may reach. |
| `authorize_all_groups_cidrs` | `list(string)` | `[]` | CIDRs every authenticated user may reach (catch-all rules). |
| `additional_route_cidrs` | `list(string)` | `[]` | Out-of-VPC destination CIDRs needing explicit routes. |
| `enable_self_service_portal` | `bool` | `false` | Enable the AWS self-service portal (requires the second metadata XML). |
| `google_idp_metadata_self_service` | `string` | `""` | IdP metadata XML from the second (portal) Google SAML app. |
| `split_tunnel` | `bool` | `true` | Only authorized CIDRs route through the VPN. |
| `dns_servers` | `list(string)` | `[]` | DNS servers pushed to clients. |
| `transport_protocol` | `string` | `"udp"` | `udp` or `tcp`. |
| `vpn_port` | `number` | `443` | `443` or `1194`. |
| `session_timeout_hours` | `number` | `24` | `8`, `10`, `12`, or `24`. |
| `client_connect_lambda_arn` | `string` | `null` | Client connect handler Lambda ARN (function name must start with `AWSClientVPN-`). |
| `vpc_id` | `string` | `null` | VPC for endpoint security groups. |
| `security_group_ids` | `list(string)` | `[]` | SGs for the endpoint ENIs (requires `vpc_id`). |
| `create_security_group` | `bool` | `false` | Create a dedicated endpoint SG (requires `vpc_id`). |
| `security_group_egress_cidrs` | `list(string)` | `["0.0.0.0/0"]` | Egress CIDRs allowed from the managed SG. |
| `connection_log_enabled` | `bool` | `true` | CloudWatch connection logging. |
| `log_retention_days` | `number` | `90` | Log retention (a CloudWatch-supported value; `0` = never expire). |
| `create_log_insights_queries` | `bool` | `true` | Save Logs Insights queries for connection attempts/failures. |
| `create_auth_failure_alarm` | `bool` | `false` | Alarm on the `AuthenticationFailures` metric. |
| `auth_failure_alarm_threshold` | `number` | `5` | Failures per period that trigger the alarm. |
| `auth_failure_alarm_period` | `number` | `300` | Alarm period in seconds (60/300/900/3600). |
| `alarm_actions` | `list(string)` | `[]` | ARNs (e.g. SNS) notified on alarm/OK. |
| `client_login_banner` | `string` | `""` | Banner text shown on connect; empty disables. |
| `tags` | `map(string)` | `{}` | Tags for all taggable resources. |

## Outputs

| Name | Description |
|---|---|
| `endpoint_id` | Client VPN endpoint ID. |
| `endpoint_arn` | Client VPN endpoint ARN. |
| `endpoint_dns_name` | DNS name clients connect to. |
| `self_service_portal_url` | Portal URL (`null` when disabled). |
| `saml_provider_arn` | ARN of the primary SAML identity provider. |
| `connection_log_group` | Connection log group name (`null` when logging disabled). |
| `authorization_rule_keys` | The `group::cidr` pairs turned into authorization rules. |
| `all_groups_authorization_cidrs` | CIDRs authorized for every authenticated user. |
| `security_group_id` | Managed endpoint SG ID (`null` unless `create_security_group`). |
| `export_client_config_command` | Ready-to-run CLI command to export the `.ovpn` profile. |
