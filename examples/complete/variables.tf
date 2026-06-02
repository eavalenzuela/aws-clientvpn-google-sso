variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpn_server_domain" {
  description = "Domain on the ACM server certificate."
  type        = string
  default     = "vpn.yourco.com"
}

variable "target_subnet_ids" {
  description = "Subnets to associate (one per AZ)."
  type        = list(string)
}

variable "dns_servers" {
  description = "DNS servers pushed to clients (e.g. VPC resolver)."
  type        = list(string)
  default     = []
}
