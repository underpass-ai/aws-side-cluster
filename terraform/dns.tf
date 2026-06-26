# Zona Route53 PRIVADA para el endpoint WireGuard EC2->PC.
# Es privada (bloque vpc) y solo resuelve dentro de la VPC asociada: NO toca la
# zona publica underpassai.com (la web estatica en CloudFront/S3 queda intacta).
# Las EC2 resuelven aqui su endpoint en vez de en un registro publico.

variable "create_private_wg_zone" {
  description = "Crear zona Route53 PRIVADA (VPC-scoped) para el endpoint WireGuard EC2->PC."
  type        = bool
  default     = true
}

variable "private_wg_zone_name" {
  description = "Nombre DNS del endpoint WireGuard (apex de la zona privada)."
  type        = string
  default     = "aws-vpc-wg.underpassai.com"
}

variable "wg_endpoint_public_ip" {
  description = "IP publica del borde de casa que reenvia UDP/51820 al control-plane. Residencial: puede cambiar. Vacio = no crear el registro A."
  type        = string
  default     = ""
}

resource "aws_route53_zone" "wg_private" {
  count = var.create_vpc && var.create_private_wg_zone ? 1 : 0

  name    = var.private_wg_zone_name
  comment = "aws-side-cluster: WireGuard EC2->PC (PRIVADA, VPC-scoped; no toca la zona publica)"

  vpc {
    vpc_id = aws_vpc.this[0].id
  }

  tags = local.common_tags
}

resource "aws_route53_record" "wg_endpoint" {
  count = var.create_vpc && var.create_private_wg_zone && var.wg_endpoint_public_ip != "" ? 1 : 0

  zone_id = aws_route53_zone.wg_private[0].zone_id
  name    = var.private_wg_zone_name
  type    = "A"
  ttl     = 60
  records = [var.wg_endpoint_public_ip]
}
