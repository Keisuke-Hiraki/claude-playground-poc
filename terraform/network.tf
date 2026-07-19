# Network layer.
#
# Design: everything the workshop runs (gateway + per-user containers) lives
# in one new private subnet with a NAT Gateway for egress. This was added
# after discovering that Claude Code reaches a few auxiliary endpoints
# (api.anthropic.com, statsig, etc.) even when CLAUDE_CODE_USE_BEDROCK=1 —
# without general internet egress those calls hang until they time out and
# the CLI never gets to the point of dispatching the Bedrock request. Only
# the ALB sits in a public subnet with a direct internet-facing listener.
data "aws_vpc" "this" {
  id = var.vpc_id
}

resource "aws_subnet" "private" {
  vpc_id                  = var.vpc_id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.private_subnet_az
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_ids[0] # NAT must sit in a public subnet

  tags = {
    Name = "${var.project_name}-nat"
  }
}

resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.project_name}-private"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${var.project_name}-s3"
  }
}

# Interface endpoints keep ECR/Logs/Bedrock/STS traffic off the NAT path —
# cheaper and it means the workshop containers still function if the NAT
# Gateway or its EIP is ever removed, as long as api.anthropic.com access
# isn't needed (DISABLE_AUTOUPDATER=1 etc. reduce but don't eliminate that).
locals {
  interface_endpoint_services = ["ecr.api", "ecr.dkr", "logs", "bedrock-runtime", "sts"]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.public_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-${each.value}"
  }
}

# --- Security groups --------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.network_resource_prefix}-alb-sg"
  description = "Public ALB ingress on 443/80"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from anywhere (redirected to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_resource_prefix}-alb-sg"
  }
}

resource "aws_security_group" "gateway" {
  name        = "${var.network_resource_prefix}-gateway-sg"
  description = "Gateway task: 8080 from the ALB only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "8080 from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_resource_prefix}-gateway-sg"
  }
}

resource "aws_security_group" "container" {
  name        = "${var.network_resource_prefix}-container-sg"
  description = "Per-user playground task: ttyd (7681) reachable only from the gateway"
  vpc_id      = var.vpc_id

  ingress {
    description     = "7681 from gateway"
    from_port       = 7681
    to_port         = 7681
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_resource_prefix}-container-sg"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.network_resource_prefix}-vpce-sg"
  description = "Interface VPC endpoints: HTTPS from the gateway and container security groups"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from gateway"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  ingress {
    description     = "HTTPS from per-user containers"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.container.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_resource_prefix}-vpce-sg"
  }
}
