# AWS Client VPN → Google Workspace SSO: Complete Setup & Migration Guide

This guide migrates an AWS **Client VPN** endpoint from certificate/OVPN-based
authentication to **SAML 2.0 federated authentication** with **Google Workspace**
as the identity provider (IdP), including **per-group network authorization**.

The Terraform module under `modules/clientvpn-google-sso/` builds the entire AWS
side. The Google Workspace SAML app is configured by hand in the Admin console
(the Google Terraform/`gcloud` tooling does not reliably manage custom SAML apps).

**Audience:** an engineer with AWS admin (IAM + EC2/VPC) access and Google
Workspace **Super Admin** (or a delegated admin role with the *Apps* and
*Security* privileges). Budget ~half a day end-to-end, most of it testing.

---

## Table of contents

1. [Concepts: how SAML federation works here](#1-concepts-how-saml-federation-works-here)
2. [Prerequisites & access checklist](#2-prerequisites--access-checklist)
3. [Hard constraints (read before you start)](#3-hard-constraints-read-before-you-start)
4. [The server certificate (ACM)](#4-the-server-certificate-acm)
5. [Google Workspace setup (manual)](#5-google-workspace-setup-manual)
6. [AWS setup with the Terraform module](#6-aws-setup-with-the-terraform-module)
7. [Authorization & routing model in depth](#7-authorization--routing-model-in-depth)
8. [Distributing the client config](#8-distributing-the-client-config)
9. [Installing & using the AWS VPN Client](#9-installing--using-the-aws-vpn-client)
10. [Verifying the group contract (critical)](#10-verifying-the-group-contract-critical)
11. [Migrating from the old cert/OVPN endpoint](#11-migrating-from-the-old-certovpn-endpoint)
12. [Security hardening](#12-security-hardening)
13. [Operations: day-2 tasks](#13-operations-day-2-tasks)
14. [Cost model](#14-cost-model)
15. [Troubleshooting](#15-troubleshooting)
16. [FAQ](#16-faq)
17. [Reference: field values & commands](#17-reference-field-values--commands)

---

## 1. Concepts: how SAML federation works here

AWS Client VPN supports three mutually exclusive client-authentication types,
fixed at endpoint creation: **mutual certificate**, **Active Directory**, and
**SAML federated**. You are moving to the third.

In federated mode the AWS VPN Client performs an **SP-initiated SAML flow** over
a loopback redirect:

```
1. User clicks Connect in the AWS VPN Client.
2. Client opens the system browser to Google's SSO URL (an AuthnRequest,
   SP entity ID = urn:amazon:webservices:clientvpn).
3. Google authenticates the user (password + MFA + any Context-Aware Access).
4. Google POSTs a signed SAML assertion to the Assertion Consumer Service (ACS)
   URL the client is listening on:  http://127.0.0.1:35001
   (35002 is used for the optional self-service portal app.)
5. The client forwards the assertion to the Client VPN endpoint as the VPN
   credential. AWS validates the signature against the IAM SAML provider's
   metadata, then establishes the tunnel.
6. AWS reads the `NameID` (the user, an email) and the `memberOf` attribute
   (the user's groups) from the assertion.
7. For each packet's destination, AWS checks the authorization rules: a rule
   matches when its `access_group_id` equals one of the user's `memberOf`
   values AND the destination falls in the rule's target CIDR.
```

**The contract that governs everything per-group:** `access_group_id` on an
authorization rule is compared **literally** to the strings Google placed in the
`memberOf` attribute. Google sends the **group's email address** (e.g.
`eng@yourco.com`). If your Terraform key is `engineering` but Google sends
`eng@yourco.com`, the user authenticates and then reaches nothing. Section 10
shows how to confirm the real value before trusting it.

ASCII overview:

```
  Google Workspace                  AWS                          Client device
  ----------------                  ---                          -------------
  Custom SAML app   --metadata--->  IAM SAML provider
   • NameID = email                       |
   • memberOf = group emails        Client VPN endpoint  <--TLS-- AWS VPN Client
                                     (federated-auth)            opens browser
                                           |                     -> Google + MFA
                                     authorization rules         -> assertion to
                                     access_group_id == memberOf    127.0.0.1:35001
```

---

## 2. Prerequisites & access checklist

**AWS**

- An AWS account with permission to manage: `iam:CreateSAMLProvider`,
  `ec2:*ClientVpn*`, `ec2:DescribeSubnets/Vpcs/SecurityGroups`,
  `acm:DescribeCertificate` / `ImportCertificate` / `RequestCertificate`,
  `logs:CreateLogGroup`.
- A target **VPC** with private subnets in the AZ(s) you want to serve.
- A non-overlapping **client CIDR** (`/22` minimum) — e.g. `10.100.0.0/22`.
  It must not overlap the target VPC, peered VPCs, or on-prem ranges.
- Terraform `>= 1.3` and AWS provider `>= 5.0`.

**Google Workspace**

- Super Admin (or delegated admin with *Apps → Web and mobile apps* and the
  ability to edit SAML apps and group assignments).
- The Google **groups** you intend to authorize already exist (Groups for
  Business). Note their **email addresses** — those are your authorization keys.

**Endpoints / DNS**

- A DNS name + ACM certificate for the VPN server (section 4).
- The DNS servers you want pushed to clients (commonly the VPC resolver,
  i.e. the VPC network base address + 2).

---

## 3. Hard constraints (read before you start)

- **No in-place auth change.** You cannot change the authentication type of an
  existing Client VPN endpoint. This is a *new endpoint + cutover*, never an
  edit of the running one. Plan a parallel-run window (section 11).
- **Clients must use the AWS VPN Client desktop app** (Windows/macOS/Linux),
  or a client that explicitly supports `auth-federate` (OpenVPN's SAML flow).
  Plain Tunnelblick / raw `openvpn` CLI / Viscosity do **not** perform the
  browser SSO step. The exported `.ovpn` contains `auth-federate`, not certs.
- **A server certificate is still mandatory** (ACM) for server-side TLS, even
  though clients present a SAML assertion rather than a client certificate.
- **Default action is deny.** A user who authenticates but matches no
  authorization rule connects successfully yet can reach nothing. This is
  usually the desired posture, but surprises people during testing.
- **`client_cidr_block` must be `/22` or larger** and not overlap target CIDRs.
  It also cannot be changed after creation.
- **One assertion, one set of groups.** AWS evaluates the `memberOf` values
  present in the assertion at connect time; changing group membership takes
  effect on the next connection, not mid-session.

---

## 4. The server certificate (ACM)

The endpoint needs an ACM certificate for `vpn.yourco.com` (or whatever name you
choose). Three common ways to get one:

**A. Public ACM-issued cert (recommended if the name is in a public zone).**
Request in ACM with DNS validation; if the zone is in Route 53, ACM can write
the validation record for you. No private CA needed. The cert is referenced by
the example via a data source:

```hcl
data "aws_acm_certificate" "vpn_server" {
  domain   = "vpn.yourco.com"
  statuses = ["ISSUED"]
}
```

**B. Private CA cert.** If you run AWS Private CA, issue a server cert from it
and import/reference its ARN. Clients trust it via the CA chain baked into the
exported `.ovpn`.

**C. Self-signed / easy-rsa import.** Generate a server cert (the old AWS Client
VPN mutual-auth flow used easy-rsa) and `acm import-certificate`. Acceptable for
internal use; public ACM (A) is cleaner.

> The certificate's **domain name does not need to be publicly resolvable** —
> Client VPN uses the endpoint's AWS-assigned DNS name for the actual
> connection. The cert just provides the TLS identity. Match SANs to whatever
> name you expect clients to validate.

Pass the resulting ARN to the module as `server_certificate_arn`.

---

## 5. Google Workspace setup (manual)

All steps in the **Admin console** at `admin.google.com`.

### 5a. Create the primary VPN SAML app

1. **Apps → Web and mobile apps → Add app → Add custom SAML app.**
2. **App details:** Name `AWS Client VPN`. (Logo/description optional.) Continue.
3. **Google Identity Provider details:** click **Download metadata** — this is
   the IdP metadata XML. Save it as `google-idp-metadata.xml` beside your
   Terraform. (You can also re-download it later from the app's page.) Continue.
4. **Service provider details:**
   | Field | Value |
   |---|---|
   | ACS URL | `http://127.0.0.1:35001` |
   | Entity ID | `urn:amazon:webservices:clientvpn` |
   | Start URL | *(leave blank)* |
   | Signed response | leave unchecked (assertion is signed by default) |
   | Name ID format | `EMAIL` |
   | Name ID | **Basic Information → Primary email** |

   Continue.
5. **Attribute mapping → Group membership:** this is what makes per-group access
   work.
   - Click **Add mapping** under *Group membership (optional)*.
   - In **Google groups**, search and add each group you want to authorize
     (e.g. `eng@yourco.com`, `ops@yourco.com`). You may add up to the
     documented limit; only listed groups are evaluated/sent.
   - Set the **App attribute** name to exactly `memberOf`.
   - Google emits each matched group's **email address** as a value of the
     `memberOf` attribute in the assertion.
6. **Finish.**

> If you also need user attributes (rare for VPN), add them under *Attributes*;
> they are not required for authorization.

### 5b. (Optional) Self-service portal app

The AWS self-service portal lets users download the client config and connect
without you distributing files. It is a **separate** SAML app:

1. Repeat 5a with App name `AWS Client VPN Self-Service`.
2. **ACS URL `http://127.0.0.1:35002`**, same **Entity ID**
   `urn:amazon:webservices:clientvpn`, same Name ID = Primary email.
3. Add the same `memberOf` group mapping (so the portal can scope downloads).
4. Download its metadata as `google-idp-metadata-selfservice.xml`.

### 5c. Enable user access

For each app: open it → **User access** → set **ON for everyone** or, better,
**ON** only for the org units / groups that should use the VPN → **Save**.
Propagation can take a few minutes (occasionally up to ~24h, usually fast).

### 5d. (Optional) Context-Aware Access / MFA

- Enforce **2-Step Verification** for the relevant OUs so VPN login requires MFA.
- Optionally attach **Context-Aware Access** levels to the SAML app (device
  posture, IP ranges, geography) — these are evaluated during step 3 of the
  flow, before any assertion is issued.

---

## 6. AWS setup with the Terraform module

Reference the server cert and call the module:

```hcl
data "aws_acm_certificate" "vpn_server" {
  domain   = "vpn.yourco.com"
  statuses = ["ISSUED"]
}

module "clientvpn" {
  source = "../../modules/clientvpn-google-sso"

  name                   = "corp"
  server_certificate_arn = data.aws_acm_certificate.vpn_server.arn
  client_cidr_block      = "10.100.0.0/22"

  google_idp_metadata = file("google-idp-metadata.xml")

  # Optional self-service portal
  enable_self_service_portal       = true
  google_idp_metadata_self_service = file("google-idp-metadata-selfservice.xml")

  target_subnet_ids = ["subnet-aaa", "subnet-bbb"]
  dns_servers       = ["10.0.0.2"]

  # SAML group email -> reachable CIDRs
  group_access = {
    "eng@yourco.com" = ["10.0.1.0/24", "10.0.2.0/24"]
    "ops@yourco.com" = ["10.0.0.0/16"]
  }

  # Routes for destinations outside the associated subnet's own VPC CIDR
  additional_route_cidrs = ["10.0.0.0/16"]

  split_tunnel          = true
  session_timeout_hours = 12

  tags = {
    Team        = "platform"
    Environment = "prod"
  }
}
```

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

### What gets created

| Resource | Purpose |
|---|---|
| `aws_iam_saml_provider.vpn` | Uploads Google's primary IdP metadata |
| `aws_iam_saml_provider.self_service` | Optional — backs the self-service portal |
| `aws_cloudwatch_log_group.vpn` | Connection logs (default on) |
| `aws_ec2_client_vpn_endpoint.this` | The endpoint, `type = federated-authentication` |
| `aws_ec2_client_vpn_network_association.this` | One association per target subnet |
| `aws_ec2_client_vpn_authorization_rule.per_group` | One rule per (group, CIDR) pair |
| `aws_ec2_client_vpn_route.additional` | Explicit routes for out-of-VPC CIDRs |

### Apply ordering

Subnet associations must exist before authorization rules and routes — the
module enforces this with `depends_on`. The first association also triggers
endpoint provisioning, which can take a few minutes; `terraform apply` will
block until the endpoint reaches `available`.

---

## 7. Authorization & routing model in depth

### Authorization rules (who can reach what)

Each `(group, cidr)` pair in `group_access` becomes one
`aws_ec2_client_vpn_authorization_rule` with `access_group_id = <group>` and
`target_network_cidr = <cidr>`. Semantics:

- A user may reach a destination **iff** some rule's `target_network_cidr`
  contains it **and** that rule's `access_group_id` is in the user's `memberOf`.
- Rules are **allow-only**; there is no explicit deny. The absence of a matching
  rule is the deny.
- To grant **all authenticated users** access to a CIDR, you'd use a rule with
  `authorize_all_groups = true` and no `access_group_id`. This module
  intentionally does not expose that for `group_access` entries — every entry is
  group-scoped. (Add a dedicated rule outside the module if you need a catch-all.)

### Routing (can a packet physically get there)

Authorization controls *permission*; routes control *reachability*. Both must
line up.

- The **VPC CIDR of each associated subnet is routed automatically** by AWS. Do
  **not** put it in `additional_route_cidrs` — that attempts a duplicate route
  and errors.
- Destinations in **other** VPCs (peering), via **Transit Gateway**, or
  **on-prem** (VPN/DX) need an explicit route → list them in
  `additional_route_cidrs`. The module creates one route per CIDR per associated
  subnet (routes are per-association).
- For **full-tunnel internet egress**: set `split_tunnel = false`, add
  `0.0.0.0/0` to `additional_route_cidrs`, and ensure the associated subnets can
  reach a NAT gateway. Also add an authorization rule covering `0.0.0.0/0` for
  the relevant group(s) (add it to that group's CIDR list).

### Worked example

```hcl
group_access = {
  "eng@yourco.com" = ["10.0.1.0/24"]   # app subnet only
  "ops@yourco.com" = ["10.0.0.0/16"]   # entire VPC
}
additional_route_cidrs = []            # both CIDRs are inside the VPC -> auto-routed
```

Here no explicit routes are needed because `10.0.1.0/24` and `10.0.0.0/16` are
within the associated subnet's VPC. If `ops` also needed a peered VPC
`10.9.0.0/16`, you'd add `"10.9.0.0/16"` to both that group's list **and**
`additional_route_cidrs`.

---

## 8. Distributing the client config

After `apply`, export the OpenVPN config (it contains `auth-federate`, the
server cert chain, and the endpoint DNS name — **no** client cert/key):

```bash
aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id "$(terraform output -raw endpoint_id)" \
  --output text > corp.ovpn
```

Distribution options:

- **Self-service portal** (if enabled): send users to the
  `self_service_portal_url` output. They authenticate with Google and download
  the profile themselves — no file handling for you.
- **Managed distribution:** push `corp.ovpn` via MDM (Jamf, Intune, etc.) so the
  profile is preloaded in the AWS VPN Client.
- **Manual:** share `corp.ovpn` over a trusted channel; users import it once.

The profile is **not a secret** (it carries no credentials), but treat it as
internal config.

---

## 9. Installing & using the AWS VPN Client

**Install** the AWS VPN Client (download from AWS's Client VPN download page):

- **Windows / macOS:** native installer.
- **Linux:** AWS provides Ubuntu packages; on other distros use a compatible
  OpenVPN 3 client built with the AWS SAML patches, or run the VPN Client in a
  supported environment. (Generic `openvpn` will not do the SAML flow.)

**First connect:**

1. AWS VPN Client → **File → Manage Profiles → Add Profile** → choose `corp.ovpn`
   → give it a display name → **Add Profile**.
2. Select the profile → **Connect**.
3. The system browser opens to Google. Sign in + complete MFA / Context-Aware
   checks.
4. On success the browser shows an "authentication details received" page; the
   client establishes the tunnel.

**Reconnects** reuse the Google session where possible; once the SAML session
expires the browser prompt reappears.

---

## 10. Verifying the group contract (critical)

Do this **before** you trust your `group_access` keys. The string Google sends
is authoritative; your Terraform must match it.

1. `terraform apply` with at least one `group_access` entry and connection
   logging enabled (default).
2. Connect once as a test user who is a member of one of the mapped groups.
3. Read the connection log group (the `connection_log_group` output points to
   it):

   ```bash
   LG="$(terraform output -raw connection_log_group)"
   aws logs tail "$LG" --since 15m --format short
   ```

   A connection record looks roughly like:

   ```json
   {
     "connection-log-type": "connection-attempt",
     "username": "alice@yourco.com",
     "device-type": "AWS VPN Desktop",
     "connection-attempt-status": "successful",
     ...
   }
   ```

   The **group values** come from the SAML assertion. To see them definitively,
   you can also inspect the assertion in the browser (SAML-tracer extension) or
   check the **Google Workspace audit log** (Reporting → Audit → SAML) which
   records the attributes released. Confirm the exact `memberOf` value — almost
   always the **group email** (e.g. `eng@yourco.com`).
4. If it differs from your `group_access` keys (display name vs. email, alias
   vs. primary address, casing), update the keys to match and re-apply.

**Symptom that means a mismatch:** the user connects successfully but cannot
reach any authorized CIDR. That is the signature of `access_group_id` not
matching `memberOf`.

---

## 11. Migrating from the old cert/OVPN endpoint

Auth type can't change in place, so run both endpoints in parallel and cut over:

1. **Stand up** the new SAML endpoint (sections 4–6) alongside the existing
   cert-based one. Different `client_cidr_block`, different DNS name.
2. **Mirror reachability:** replicate the routes the old endpoint provided, but
   now expressed per group in `group_access`. Map your old "everyone gets X"
   posture into specific groups (this is the opportunity to tighten access).
3. **Pilot:** a handful of users install the AWS VPN Client, import the new
   profile, and validate they can reach exactly what they should — and *cannot*
   reach what they shouldn't.
4. **Verify the group contract** (section 10) with real users from each group.
5. **Roll out:** distribute the new profile / publish the self-service portal.
   Communicate the **client app change** clearly — this is the biggest user-
   facing difference (browser SSO instead of importing a cert profile).
6. **Drain:** monitor connections on the old endpoint until they fall to zero.
7. **Decommission:** `terraform destroy` (or remove from config) the old
   endpoint, then retire its PKI — server cert, client CA, issued client certs,
   and any CRL automation. Revoke the easy-rsa CA if it has no other use.

**Rollback during the window** is trivial: users still hold the old cert profile
until you tear the old endpoint down, so you can pause the cutover at any point.

---

## 12. Security hardening

- **Require MFA at Google** (2-Step Verification enforced for VPN-eligible OUs).
  Federation means VPN access is exactly as strong as the Google login.
- **Context-Aware Access**: gate the SAML app on device posture, corp IP ranges,
  or geography. Evaluated before the assertion is issued.
- **Least privilege via groups**: prefer many narrow groups over one broad one.
  Each `group_access` entry should map to a real need-to-reach.
- **Restrict the endpoint with security groups**: set `vpc_id` +
  `security_group_ids` so VPN client traffic is constrained by SG rules on the
  ENIs, in addition to authorization rules.
- **Split tunnel vs. full tunnel**: split tunnel (default) keeps non-corp
  traffic off the VPN (less cost, better UX). Use full tunnel only if you must
  inspect/route all egress.
- **Short session timeout** for sensitive environments (`session_timeout_hours`
  8–12 instead of 24) so revocation takes effect sooner.
- **Connection logging on** (default) and shipped to a retained log group for
  audit. Pair with Google's SAML audit log for the IdP side.
- **Offboarding**: removing a user from the Google group (or suspending the
  account) revokes access on next connect; suspending the account blocks new
  logins immediately.

---

## 13. Operations: day-2 tasks

| Task | Action |
|---|---|
| Grant a group access to a new CIDR | Add the CIDR to that group's list in `group_access` (and `additional_route_cidrs` if out-of-VPC); `apply`. |
| Add a brand-new group | Add it to the Google SAML app's *Group membership* mapping **and** add a `group_access` entry; `apply`. |
| Remove a user's access | Remove them from the Google group, or suspend the account. No Terraform change. |
| Add an AZ / more bandwidth | Add the subnet ID to `target_subnet_ids`; `apply`. (Raises cost — section 14.) |
| Rotate the server cert | Replace the ACM cert; update `server_certificate_arn`; `apply`. |
| Re-download IdP metadata after a Google cert rotation | Download fresh metadata from the SAML app; replace the XML file; `apply` (updates the IAM SAML provider). |
| Audit who connected | `aws logs tail` the connection log group; cross-check Google SAML audit log. |

---

## 14. Cost model

Client VPN has **two** hourly charges plus data:

1. **Per subnet association-hour** — billed for *every* associated subnet, the
   whole time it's associated, regardless of connections. Associating 3 AZs ≈ 3×
   this charge continuously.
2. **Per active client connection-hour** — billed per connected user-session.
3. Plus normal data transfer / NAT charges.

Practical implications:

- **Associate only the AZs you actually need.** Each extra `target_subnet_ids`
  entry adds a continuous association charge.
- Idle associations still cost money — there's no "scale to zero" for
  associations.
- Split tunnel reduces data charges by keeping non-corp traffic off the tunnel.

Check current per-hour rates in the AWS Client VPN pricing page for your region
before committing to a multi-AZ layout.

---

## 15. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Connects, but no network access | `group_access` key ≠ Google `memberOf` value. Confirm via section 10 and align the key. |
| Browser SSO never opens | Using a non-AWS / non-`auth-federate` OpenVPN client. Use the AWS VPN Client. |
| "No groups" / only `NameID` in assertion | Group not added under *Group membership* in the SAML app, or app not enabled for the user's OU. |
| Authorization-rule `apply` fails | No subnet associated yet. The module orders this via `depends_on`; if you removed all subnets, re-add at least one and `apply`. |
| Duplicate-route error on `apply` | A VPC-local CIDR was placed in `additional_route_cidrs`. Remove it — the VPC CIDR is auto-routed. |
| SAML error page at Google | ACS URL or Entity ID mismatch (must be `http://127.0.0.1:35001` and `urn:amazon:webservices:clientvpn`), or the app isn't ON for the user. |
| Connects then drops after N hours | `session_timeout_hours` reached — expected; user reconnects. |
| Can reach some CIDRs, not others | Missing route (`additional_route_cidrs`) **or** missing authorization rule for that CIDR/group. Both are required. |
| User reachable to too much | A `group_access` CIDR is broader than intended, or a catch-all rule exists outside the module. |
| Endpoint stuck `pending-associate` | No subnet association; add `target_subnet_ids`. |
| Metadata upload rejected by IAM | XML is the *SP* metadata or truncated. Re-download the **IdP** metadata from the Google SAML app. |

Diagnostic commands:

```bash
# Endpoint + auth config
aws ec2 describe-client-vpn-endpoints --client-vpn-endpoint-ids <id>

# Active connections
aws ec2 describe-client-vpn-connections --client-vpn-endpoint-id <id>

# Authorization rules actually in effect
aws ec2 describe-client-vpn-authorization-rules --client-vpn-endpoint-id <id>

# Routes
aws ec2 describe-client-vpn-routes --client-vpn-endpoint-id <id>

# Tail connection logs
aws logs tail "$(terraform output -raw connection_log_group)" --since 30m
```

---

## 16. FAQ

**Can I keep certificate auth as a fallback alongside SAML?**
A single endpoint has one auth type. You can run a second cert-based endpoint in
parallel, but you can't mix both auth types on one endpoint. (Mutual-cert +
federated can be combined only in the sense of also requiring a client cert; the
module uses pure federated.)

**Does Google Workspace support sending groups at all?**
Yes — via the *Group membership* mapping in the custom SAML app, emitting group
emails in your chosen attribute (`memberOf` here). You must explicitly list the
groups; it does not send the user's entire group graph.

**Why the group *email* and not a friendly name?**
That's what Google's SAML app releases for group membership. Use the primary
group email as the `access_group_id`. Verify in section 10.

**Can I use SCIM / automatic provisioning instead?**
SCIM provisions accounts; it's orthogonal to VPN authorization, which is driven
at connect time by the SAML assertion's `memberOf`. No SCIM needed for this.

**What about nested groups?**
Behavior depends on whether Google includes indirect membership in the released
attribute. Don't assume nesting flows through — test with a nested member
(section 10) before relying on it.

**Can users self-serve the config?**
Yes — enable the self-service portal (section 5b / `enable_self_service_portal`)
and share the `self_service_portal_url` output.

**Is the `.ovpn` a secret?**
No credentials are embedded, but treat it as internal configuration.

---

## 17. Reference: field values & commands

**Google SAML app — primary VPN**

| Field | Value |
|---|---|
| ACS URL | `http://127.0.0.1:35001` |
| Entity ID | `urn:amazon:webservices:clientvpn` |
| Name ID format | `EMAIL` |
| Name ID | Primary email |
| Group attribute (App attribute) | `memberOf` |
| Group values released | group email addresses |

**Google SAML app — self-service portal**

| Field | Value |
|---|---|
| ACS URL | `http://127.0.0.1:35002` |
| Entity ID | `urn:amazon:webservices:clientvpn` |

**Module inputs that map to the above**

| Input | Meaning |
|---|---|
| `google_idp_metadata` | XML downloaded from the primary SAML app |
| `google_idp_metadata_self_service` | XML from the portal SAML app |
| `group_access` keys | must equal the `memberOf` group emails |

**Export the client config**

```bash
aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id <endpoint_id> --output text > corp.ovpn
```
