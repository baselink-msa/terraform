resource "aws_kms_key" "tokyo_backup" {
  provider = aws.tokyo

  description             = "Encrypts Baselink dev AWS Backup copies in the Tokyo DR Region."
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = merge(local.common_tags, {
    Purpose = "cross-region-backup"
    Region  = var.dr_region
  })
}

resource "aws_kms_alias" "tokyo_backup" {
  provider = aws.tokyo

  name          = "alias/${local.name_prefix}-tokyo-backup"
  target_key_id = aws_kms_key.tokyo_backup.key_id
}

resource "aws_backup_vault" "tokyo" {
  provider = aws.tokyo

  name        = "${local.name_prefix}-tokyo-backup-vault"
  kms_key_arn = aws_kms_key.tokyo_backup.arn

  tags = merge(local.common_tags, {
    Purpose = "cross-region-backup"
    Region  = var.dr_region
  })
}
