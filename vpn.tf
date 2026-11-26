# Hybrid connectivity: AWS Site-to-Site VPN
# Links your on-premises data center to a VPC.
# Usage:
#   terraform init
#   terraform apply -var="onprem_public_ip=203.0.113.10"
#   # With dynamic BGP routing instead of static routes:
#   terraform apply -var="onprem_public_ip=203.0.113.10" -var="enable_bgp=true"
#
# Plain words: this file builds an encrypted tunnel through the public
# internet between your office router (the "customer gateway") and AWS
# (the "virtual private gateway"). Two tunnels are created automatically
# so one can fail without dropping the connection.

variable "onprem_public_ip" {
  description = "Public IP of your on-premises VPN device (customer gateway)"
  type        = string
}

variable "onprem_cidr" {
  description = "CIDR of the on-premises network, e.g. 192.168.0.0/16 — must NOT overlap the VPC CIDR"
  type        = string
  default     = "192.168.0.0/16"
}

variable "enable_bgp" {
  description = "true = dynamic BGP routing (routes are exchanged automatically, failover is fast). false = static routes (simple, but you maintain them by hand)"
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR of the VPC side of the tunnel"
  type        = string
  default     = "10.0.0.0/16"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "hybrid-vpc" }
}

resource "aws_vpn_gateway" "this" {
  vpc_id          = aws_vpc.main.id
  amazon_side_asn = 64512 # AWS side BGP ASN (64512-65534 are private-use)
  tags            = { Name = "hybrid-vpn-gw" }
}

resource "aws_customer_gateway" "datacenter" {
  bgp_asn    = 65000 # Your side BGP ASN — must differ from amazon_side_asn
  ip_address = var.onprem_public_ip
  type       = "ipsec.1"
  tags       = { Name = "onprem-dc" }
}

resource "aws_vpn_connection" "hybrid" {
  vpn_gateway_id      = aws_vpn_gateway.this.id
  customer_gateway_id = aws_customer_gateway.datacenter.id
  type                = "ipsec.1"
  static_routes_only  = !var.enable_bgp
  tags                = { Name = "hybrid-tunnel" }
}

# Static mode only: tell AWS which on-prem network lives behind the tunnel.
# With BGP enabled this resource is skipped — the routes are learned live.
resource "aws_vpn_connection_route" "onprem" {
  count                  = var.enable_bgp ? 0 : 1
  vpn_connection_id      = aws_vpn_connection.hybrid.id
  destination_cidr_block = var.onprem_cidr
}

# Let the VPN gateway push learned routes into the VPC route tables
# automatically (required for BGP mode, harmless in static mode).
resource "aws_vpn_gateway_route_propagation" "main" {
  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = aws_vpc.main.main_route_table_id
}

# Alarm: TunnelState is 1 when a tunnel is UP, 0 when DOWN.
# Using the Minimum statistic across both tunnels means the alarm fires
# as soon as ANY tunnel drops — a silent dead tunnel is worse than a loud one.
resource "aws_cloudwatch_metric_alarm" "tunnel_down" {
  alarm_name          = "hybrid-vpn-tunnel-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 300
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Fires when at least one Site-to-Site VPN tunnel is DOWN"
  dimensions = {
    VpnId = aws_vpn_connection.hybrid.id
  }
  tags = { Name = "hybrid-vpn-tunnel-down" }
}

output "tunnel1_status" {
  description = "Check this after apply — both tunnels should be UP"
  value       = aws_vpn_connection.hybrid.tunnel1_status
}

output "tunnel2_status" {
  description = "Second tunnel of the pair — UP means redundancy is healthy"
  value       = aws_vpn_connection.hybrid.tunnel2_status
}

output "vpn_gateway_id" {
  description = "Attach Direct Connect or Transit Gateway to this same VGW later"
  value       = aws_vpn_gateway.this.id
}
