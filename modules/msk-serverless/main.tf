locals {
  iam_broker_port = 9098
}

resource "aws_security_group" "this" {
  count = var.enabled ? 1 : 0

  name        = "${var.cluster_name}-msk-serverless"
  description = "MSK Serverless IAM broker access"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-msk-serverless"
  })
}

resource "aws_vpc_security_group_ingress_rule" "iam_broker_from_clients" {
  for_each = var.enabled ? toset(var.client_security_group_ids) : toset([])

  security_group_id            = aws_security_group.this[0].id
  referenced_security_group_id = each.value
  from_port                    = local.iam_broker_port
  to_port                      = local.iam_broker_port
  ip_protocol                  = "tcp"
  description                  = "Kafka IAM broker access from approved clients"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  count = var.enabled ? 1 : 0

  security_group_id = aws_security_group.this[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_msk_serverless_cluster" "this" {
  count = var.enabled ? 1 : 0

  cluster_name = var.cluster_name

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.this[0].id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = var.tags
}
