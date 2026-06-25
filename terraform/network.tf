data "aws_availability_zones" "available" {
  count = var.create_vpc && var.availability_zone == null ? 1 : 0

  state = "available"
}

locals {
  selected_availability_zone = var.availability_zone != null ? var.availability_zone : (var.create_vpc ? data.aws_availability_zones.available[0].names[0] : null)
  created_subnet_id          = try(aws_subnet.public[0].id, null)
  selected_subnet_id         = var.subnet_id != null ? var.subnet_id : local.created_subnet_id
  created_security_group_id  = try(aws_security_group.worker[0].id, null)
  selected_security_group_ids = length(var.vpc_security_group_ids) > 0 ? var.vpc_security_group_ids : (
    local.created_security_group_id != null ? [local.created_security_group_id] : []
  )
}

resource "aws_vpc" "this" {
  count = var.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count = var.create_vpc ? 1 : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.selected_availability_zone
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-a"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  count = var.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route_table_association" "public" {
  count = var.create_vpc ? 1 : 0

  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_security_group" "worker" {
  count = var.create_vpc ? 1 : 0

  name        = "${var.name_prefix}-worker"
  description = "Minimal EC2 worker security group"
  vpc_id      = aws_vpc.this[0].id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-worker"
  })
}

resource "aws_vpc_security_group_egress_rule" "worker_all" {
  count = var.create_vpc ? 1 : 0

  security_group_id = aws_security_group.worker[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow outbound traffic"
}

resource "aws_vpc_security_group_ingress_rule" "worker_ssh" {
  for_each = var.create_vpc ? toset(var.allowed_ssh_cidrs) : toset([])

  security_group_id = aws_security_group.worker[0].id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional SSH access"
}

resource "aws_vpc_security_group_ingress_rule" "worker_wireguard" {
  for_each = var.create_vpc && var.worker_wireguard_enabled ? toset(var.allowed_wireguard_cidrs) : toset([])

  security_group_id = aws_security_group.worker[0].id
  cidr_ipv4         = each.value
  from_port         = var.worker_wireguard_port
  to_port           = var.worker_wireguard_port
  ip_protocol       = "udp"
  description       = "WireGuard worker tunnel"
}
