variable "name" {
  description = "Name/identifier for the Client VPN endpoint and associated resources."
  type        = string
}

variable "google_idp_metadata" {
  description = <<-EOT
    SAML IdP metadata XML from the Google Workspace custom SAML app used for
    VPN authentication. Pass the file contents, e.g. file("google-idp-metadata.xml").
  EOT
  type        = string
}

variable "enable_self_service_portal" {
  description = "Create a second SAML provider for the AWS self-service portal."
  type        = bool
  default     = false
}

variable "google_idp_metadata_self_service" {
  description = <<-EOT
    SAML IdP metadata XML from the SECOND Google Workspace SAML app
    (ACS http://127.0.0.1:35002) used for the self-service portal.
    Required only when enable_self_service_portal = true.
  EOT
  type        = string
  default     = ""
}

variable "server_certificate_arn" {
  description = "ACM ARN of the server certificate (required for server-side TLS even with SAML auth)."
  type        = string
}

variable "client_cidr_block" {
  description = "CIDR from which client IPs are assigned. Must be /22 or larger and not overlap target VPC CIDRs."
  type        = string
}

variable "target_subnet_ids" {
  description = "Subnet IDs to associate with the endpoint (one per AZ you want to serve)."
  type        = list(string)
}

variable "group_access" {
  description = <<-EOT
    Map of SAML group identifier (the value Google sends in the `memberOf`
    attribute — typically the group's email) to the list of CIDRs that group
    may reach. Each (group, cidr) pair becomes one authorization rule.

    Example:
      {
        "eng@yourco.com" = ["10.0.1.0/24", "10.0.2.0/24"]
        "ops@yourco.com" = ["10.0.0.0/16"]
      }
  EOT
  type        = map(list(string))
}

variable "additional_route_cidrs" {
  description = <<-EOT
    Destination CIDRs that need an explicit route (e.g. peered VPCs, on-prem
    via TGW, or 0.0.0.0/0 for full-tunnel internet egress). A route is created
    for each CIDR across every associated subnet. The associated subnet's own
    VPC CIDR is routed automatically and must NOT be listed here.
  EOT
  type        = list(string)
  default     = []
}

variable "split_tunnel" {
  description = "If true, only routes for authorized CIDRs go through the VPN."
  type        = bool
  default     = true
}

variable "dns_servers" {
  description = "DNS servers pushed to clients (e.g. the VPC resolver: VPC base + 2)."
  type        = list(string)
  default     = []
}

variable "transport_protocol" {
  description = "Transport protocol for the VPN session (udp or tcp)."
  type        = string
  default     = "udp"

  validation {
    condition     = contains(["udp", "tcp"], var.transport_protocol)
    error_message = "transport_protocol must be \"udp\" or \"tcp\"."
  }
}

variable "vpn_port" {
  description = "VPN port (443 or 1194)."
  type        = number
  default     = 443
}

variable "session_timeout_hours" {
  description = "Max client session duration in hours (8, 10, 12, or 24)."
  type        = number
  default     = 24
}

variable "vpc_id" {
  description = "VPC for endpoint security groups. Leave null to use the default SG of the associated subnets' VPC."
  type        = string
  default     = null
}

variable "security_group_ids" {
  description = "Security groups to apply to the endpoint's network interfaces. Requires vpc_id when set."
  type        = list(string)
  default     = []
}

variable "connection_log_enabled" {
  description = "Enable CloudWatch connection logging (recommended — needed to discover the actual SAML group values)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the connection log group."
  type        = number
  default     = 90
}

variable "client_login_banner" {
  description = "Optional banner text shown to clients on connect. Empty disables it."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources that support tagging."
  type        = map(string)
  default     = {}
}
