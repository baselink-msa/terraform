output "db_instance_endpoint" {
  description = "DB 접속 엔드포인트 주소 (포트 포함)"
  value       = aws_db_instance.this.endpoint
}

output "db_instance_address" {
  description = "DB 호스트 주소 (포트 제외)"
  value       = aws_db_instance.this.address
}

output "db_name" {
  description = "생성된 데이터베이스 이름"
  value       = aws_db_instance.this.db_name
}