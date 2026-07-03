# Planned improvements & features

Plan for this pass over the module. Improvements 1–10 harden existing behavior;
features 11–15 add new capability.

## Improvements

1. **Fix the self-service portal actually being off** — the module created the
   second SAML provider but never set `self_service_portal = "enabled"` on the
   endpoint, so the portal URL in the output did not work; set it from
   `enable_self_service_portal`.
2. **Validate `client_cidr_block` at plan time** — must be a valid IPv4 CIDR
   with a /12–/22 prefix (hard AWS constraints that previously only failed at
   apply).
3. **Validate every CIDR in `group_access` and `additional_route_cidrs`** and
   reject empty group keys — a typo'd CIDR previously surfaced as a mid-apply
   API error after the endpoint already existed.
4. **Validate `vpn_port` (443/1194) and `session_timeout_hours` (8/10/12/24)**
   — both are documented constraints but nothing enforced them.
5. **Validate `log_retention_days` against CloudWatch's allowed set, require a
   non-empty `target_subnet_ids`, and constrain `name`** to the charset/length
   that is safe inside IAM SAML provider and log group names.
6. **Plan-time precondition: portal metadata required when portal enabled** —
   `enable_self_service_portal = true` with an empty
   `google_idp_metadata_self_service` previously failed with an opaque IAM
   "malformed metadata" error; fail early with a clear message instead.
7. **Plan-time precondition: `security_group_ids` requires `vpc_id`** — the
   variable docs say so, but nothing enforced it before AWS rejected the apply
   (same for the new `create_security_group`).
8. **`terraform fmt` cleanup and rule descriptions** — fix the misaligned
   `connection_log_options` argument and add `description` to authorization
   rules so the console shows which group/CIDR each rule serves.
9. **README: full requirements + inputs/outputs reference tables** — the module
   has ~29 inputs; the README previously documented none of them.
10. **CI: describe a `terraform fmt -check` + `terraform validate` workflow**
    (module and example, with placeholder IdP metadata files so `file()`
    resolves) so regressions are caught without AWS credentials. Described
    here only — the workflow yaml is intentionally not committed in this pass
    because the publishing token lacks the GitHub `workflow` scope; add
    `.github/workflows/validate.yml` manually with: checkout,
    hashicorp/setup-terraform, `terraform fmt -check -recursive -diff`, then
    `terraform init -backend=false && terraform validate` in
    `modules/clientvpn-google-sso/` and in `examples/complete/` (after
    `printf '<EntityDescriptor/>' > google-idp-metadata.xml` and the
    self-service twin).

## New features

11. **`authorize_all_groups_cidrs`** — catch-all authorization rules
    (`authorize_all_groups = true`) for destinations every authenticated user
    may reach (e.g. the internal resolver); previously the GUIDE told users to
    hand-roll these outside the module.
12. **Optional managed security group** (`create_security_group`,
    `security_group_egress_cidrs`) for the endpoint ENIs, with a
    `security_group_id` output so workload SGs can allow VPN traffic by
    reference instead of by CIDR.
13. **Client connect handler support** (`client_connect_lambda_arn`) — wires an
    `AWSClientVPN-*` Lambda into `client_connect_options` for connect-time
    posture checks / custom deny logic, with the naming rule validated.
14. **Optional CloudWatch alarm on `AuthenticationFailures`**
    (`create_auth_failure_alarm`, threshold/period/actions) — surfaces
    group-mapping drift, expired IdP metadata, or brute force attempts.
15. **Saved CloudWatch Logs Insights queries** over the connection log group
    (recent attempts + failures) — makes the GUIDE's critical "verify the group
    contract" workflow a one-click query in the console.
