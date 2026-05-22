###############################################################################
# modules/elasticache/outputs.tf
###############################################################################

output "primary_endpoint_address" {
  description = "쓰기용 엔드포인트 (앱이 쓰기 시 접속)"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "읽기용 엔드포인트 (replica로 읽기 분산)"
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "Redis 포트"
  value       = var.port
}

output "security_group_id" {
  description = "Redis 보안 그룹 ID"
  value       = aws_security_group.redis.id
}

output "replication_group_id" {
  description = "replication group ID"
  value       = aws_elasticache_replication_group.this.id
}
