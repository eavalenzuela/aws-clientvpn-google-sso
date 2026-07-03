variable "name" {
  description = "Name/identifier for the Client VPN endpoint and associated resources."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,98}$", var.name))
    error_message = "name must be 1-99 characters of letters, digits, '.', '_' or '-' (it is embedded in IAM SAML provider and log group names)."
  }
}

variable "google_idp_metadata" {
  description = <<-EOT
    SAML IdP metadata XML from the Google Workspace custom SAML app used for
    VPN authentication. Pass the file contents, e.g. file("google-idp-metadata.xml").
  EOT
  type        = string
}

variable "enable_self_service_portal" {
  description = "Enable the AWS self-service portal and create a second SAML provider backing it."
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

  validation {
    condition = (
      can(regex("^\\d{1,3}(\\.\\d{1,3}){3}/\\d{1,2}$", var.client_cidr_block)) &&
      can(cidrhost(var.client_cidr_block, 0)) &&
      try(tonumber(split("/", var.client_cidr_block)[1]) >= 12, false) &&
      try(tonumber(split("/", var.client_cidr_block)[1]) <= 22, false)
    )
    error_message = "client_cidr_block must be a valid IPv4 CIDR with a prefix between /12 and /22 (AWS Client VPN requirement)."
  }
}

variable "target_subnet_ids" {
  description = "Subnet IDs to associate with the endpoint (one per AZ you want to serve)."
  type        = list(string)

  validation {
    condition     = length(var.target_subnet_ids) > 0
    error_message = "target_subnet_ids must contain at least one subnet ID."
  }
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

  validation {
    condition = alltrue([
      for grp, cidrs in var.group_access : (
        length(trimspace(grp)) > 0 &&
        alltrue([for cidr in cidrs : can(cidrhost(cidr, 0))])
      )
    ])
    error_message = "Every group_access key must be non-empty and every value must be valid CIDR notation."
  }
}

variable "authorize_all_groups_cidrs" {
  description = <<-EOT
    CIDRs that EVERY authenticated user may reach, regardless of group
    membership. Each entry becomes one authorization rule with
    authorize_all_groups = true. Prefer group_access; reserve this for
    genuinely universal destinations (e.g. an internal DNS resolver).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.authorize_all_groups_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every entry in authorize_all_groups_cidrs must be valid CIDR notation."
  }
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

  validation {
    condition     = alltrue([for cidr in var.additional_route_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every entry in additional_route_cidrs must be valid CIDR notation."
  }
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

  validation {
    condition     = contains([443, 1194], var.vpn_port)
    error_message = "vpn_port must be 443 or 1194."
  }
}

variable "session_timeout_hours" {
  description = "Max client session duration in hours (8, 10, 12, or 24)."
  type        = number
  default     = 24

  validation {
    condition     = contains([8, 10, 12, 24], var.session_timeout_hours)
    error_message = "session_timeout_hours must be 8, 10, 12, or 24."
  }
}

variable "client_connect_lambda_arn" {
  description = <<-EOT
    ARN of a Lambda function invoked on every connection attempt (client
    connect handler) for custom authorization — device posture, banned source
    IPs, time-of-day rules, etc. AWS requires the function name to start with
    "AWSClientVPN-". Null disables the handler.
  EOT
  type        = string
  default     = null

  validation {
    condition = var.client_connect_lambda_arn == null || can(
      regex("^arn:aws[a-zA-Z-]*:lambda:[a-z0-9-]+:\\d{12}:function:AWSClientVPN-", var.client_connect_lambda_arn)
    )
    error_message = "client_connect_lambda_arn must be a Lambda function ARN whose function name starts with \"AWSClientVPN-\" (an AWS requirement for client connect handlers)."
  }
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

variable "create_security_group" {
  description = <<-EOT
    Create a dedicated security group for the endpoint's network interfaces
    (requires vpc_id). It allows egress to security_group_egress_cidrs and no
    ingress (return traffic is stateful). Reference the security_group_id
    output as a source in workload security groups to allow VPN traffic by
    reference instead of by CIDR.
  EOT
  type        = bool
  default     = false
}

variable "security_group_egress_cidrs" {
  description = "Egress CIDRs allowed from the managed security group (VPN client traffic entering the VPC)."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for cidr in var.security_group_egress_cidrs : can(cidrhost(cidr, 0))])
    error_message = "Every entry in security_group_egress_cidrs must be valid CIDR notation."
  }
}

variable "connection_log_enabled" {
  description = "Enable CloudWatch connection logging (recommended — needed to discover the actual SAML group values)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention for the connection log group (0 = never expire)."
  type        = number
  default     = 90

  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of the retention values CloudWatch Logs supports (0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "create_log_insights_queries" {
  description = <<-EOT
    Save CloudWatch Logs Insights query definitions (recent connection
    attempts, and failures with reasons) over the connection log group.
    Only takes effect when connection_log_enabled = true.
  EOT
  type        = bool
  default     = true
}

variable "create_auth_failure_alarm" {
  description = "Create a CloudWatch alarm on the endpoint's AuthenticationFailures metric (catches group-mapping drift, expired IdP metadata, brute force)."
  type        = bool
  default     = false
}

variable "auth_failure_alarm_threshold" {
  description = "Alarm when the Sum of AuthenticationFailures within one period reaches this value."
  type        = number
  default     = 5

  validation {
    condition     = var.auth_failure_alarm_threshold >= 1
    error_message = "auth_failure_alarm_threshold must be at least 1."
  }
}

variable "auth_failure_alarm_period" {
  description = "Evaluation period for the authentication-failure alarm, in seconds."
  type        = number
  default     = 300

  validation {
    condition     = contains([60, 300, 900, 3600], var.auth_failure_alarm_period)
    error_message = "auth_failure_alarm_period must be 60, 300, 900, or 3600 seconds."
  }
}

variable "alarm_actions" {
  description = "ARNs (e.g. SNS topics) notified when the authentication-failure alarm fires or returns to OK."
  type        = list(string)
  default     = []
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
