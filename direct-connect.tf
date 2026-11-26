# Hybrid connectivity: AWS Direct Connect (dedicated private fiber)
# Use this when the VPN tunnel becomes the bottleneck: steady, heavy
# traffic between your data center and AWS deserves a private circuit
# with consistent latency and no internet in the path.
#
# Plain words: instead of an encrypted tunnel over the public internet,
# you rent a physical fiber line into AWS. The Direct Connect Gateway
# is the junction box that lets that one line reach many VPCs.
#
# HOW TO ORDER (the physical part is not Terraform):
#   1. In the AWS console, create a connection at a Direct Connect
#      location (e.g. an Equinix facility) and download the LOA-CFA.
#   2. Your carrier / colocation provider uses the LOA-CFA to patch
#      the cross-connect. The port starts billing once provisioned.
#   3. Apply this file: it builds the gateway, associates your VPC,
#      and opens the private virtual interface (VIF) with BGP peering.
#
# Usage:
#   terraform init
#   terraform apply -var="dx_connection_id=dxcon-xxxxxxxx" \
#                   -var="onprem_bgp_asn=65000"

variable "dx_connection_id" {
  description = "ID of the Direct Connect connection, e.g. dxcon-xxxxxxxx (created in the console — see steps above)"
  type        = string
}

variable "dx_location" {
  description = "Direct Connect location code, e.g. EqDC2 (Equinix SG2, Singapore) — must match where the connection lives"
  type        = string
  default     = "EqDC2"
}

variable "vgw_id" {
  description = "Virtual private gateway ID of the VPC to connect (output `vpn_gateway_id` from vpn.tf)"
  type        = string
}

variable "onprem_bgp_asn" {
  description = "Your side BGP ASN — must match the customer gateway ASN in vpn.tf"
  type        = number
  default     = 65000
}

variable "vlan" {
  description = "VLAN ID for the private virtual interface (1-4094, must be unique per connection)"
  type        = number
  default     = 100
}

variable "amazon_address" {
  description = "AWS side /30 address for BGP peering on the VIF"
  type        = string
  default     = "169.254.0.1/30"
}

variable "customer_address" {
  description = "Your side /30 address for BGP peering on the VIF"
  type        = string
  default     = "169.254.0.2/30"
}

# The junction box: one DX Gateway can serve many VPCs, even in
# different regions, through their virtual private gateways.
resource "aws_dx_gateway" "this" {
  name            = "hybrid-dx-gateway"
  amazon_side_asn = 64512 # Same AWS-side ASN as the VPN gateway in vpn.tf
}

# Connect the gateway to this VPC's virtual private gateway.
resource "aws_dx_gateway_association" "vpc" {
  dx_gateway_id         = aws_dx_gateway.this.id
  associated_gateway_id = var.vgw_id
}

# The private virtual interface: the actual BGP session that carries
# your traffic between the data center and AWS.
resource "aws_dx_private_virtual_interface" "this" {
  connection_id    = var.dx_connection_id
  dx_gateway_id    = aws_dx_gateway.this.id
  name             = "hybrid-private-vif"
  vlan             = var.vlan
  address_family   = "ipv4"
  bgp_asn          = var.onprem_bgp_asn
  amazon_address   = var.amazon_address
  customer_address = var.customer_address

  # BGP MD5 auth key — set a real secret in production, never commit it.
  # bgp_auth_key = var.bgp_auth_key
}

output "dx_gateway_id" {
  description = "Reuse this gateway for additional VPCs — no new circuit needed"
  value       = aws_dx_gateway.this.id
}

output "vif_bgp_status" {
  description = "Check after apply — BGP should be 'up' once the carrier patches the circuit"
  value       = aws_dx_private_virtual_interface.this.bgp_status
}
