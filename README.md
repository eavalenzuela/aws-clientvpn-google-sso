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
