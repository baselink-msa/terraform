###############################################################################
# modules/elasticache/main.tf
# ElastiCache for Redis — replication group (primary + replica)
# cluster mode disabled. seat-lock·waiting-room 등 동시성 제어용.
#
# Valkey 전환 시: engine·engine_version·parameter_group_family 변수만 교체
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

#------------------------------------------------------------------------------
# 1) 보안 그룹 — 6379 포트를 'EKS 노드에서 오는 트래픽'만 허용
#------------------------------------------------------------------------------
resource "aws_security_group" "redis" {
  name        = "${var.name}-redis"
  description = "ElastiCache Redis access"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-redis" })
}

# 허용된 보안 그룹(EKS 노드 등)마다 6379 인바운드 규칙 생성
resource "aws_vpc_security_group_ingress_rule" "redis" {
  count = length(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = var.allowed_security_group_ids[count.index]
  from_port                    = var.port
  to_port                      = var.port
  ip_protocol                  = "tcp"
  description                  = "Redis from ${var.allowed_security_group_ids[count.index]}"
}

# 아웃바운드 전체 허용 (Terraform 생성 SG는 기본 egress가 없음)
resource "aws_vpc_security_group_egress_rule" "redis" {
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

#------------------------------------------------------------------------------
# 2) 서브넷 그룹 — Redis 노드를 둘 프라이빗 서브넷 묶음
#------------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-redis"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

#------------------------------------------------------------------------------
# 3) 파라미터 그룹 — Redis 설정값 묶음
#    maxmemory-policy: 메모리가 꽉 찼을 때의 동작 (락 데이터 보호 고려)
#------------------------------------------------------------------------------
resource "aws_elasticache_parameter_group" "this" {
  name        = "${var.name}-redis"
  family      = var.parameter_group_family
  description = "Parameter group for ${var.name} Redis"

  parameter {
    name  = "maxmemory-policy"
    value = var.maxmemory_policy
  }

  tags = var.tags
}

#------------------------------------------------------------------------------
# 4) Replication group — Redis 본체 (primary + replica)
#    cluster mode disabled → num_cache_clusters = 전체 노드 수
#    ※ automatic_failover/multi_az = true 는 num_cache_clusters >= 2 필요
#------------------------------------------------------------------------------
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-redis"
  description          = "${var.name} Redis (seat-lock / waiting-room)"

  engine         = var.engine
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = var.port

  # 전체 노드 수 (primary 1 + replica N). dev에서 1이면 단일 노드(SPOF)
  num_cache_clusters = var.num_cache_clusters

  # 고가용성
  automatic_failover_enabled = var.automatic_failover_enabled
  multi_az_enabled           = var.multi_az_enabled

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.redis.id]
  parameter_group_name = aws_elasticache_parameter_group.this.name

  # 암호화 (auth_token 사용 시 transit_encryption_enabled = true 필수)
  at_rest_encryption_enabled = var.at_rest_encryption_enabled
  transit_encryption_enabled = var.transit_encryption_enabled
  auth_token                 = var.auth_token

  # 스냅샷 보관일 (락/캐시 용도라 dev 기본 0 = 비활성)
  snapshot_retention_limit = var.snapshot_retention_limit

  # true면 변경을 유지보수 시간대 대기 없이 즉시 적용
  apply_immediately = var.apply_immediately

  tags = var.tags
}
