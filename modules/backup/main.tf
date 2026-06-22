terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

data "aws_iam_policy_document" "backup_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name_prefix}-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_vault" "this" {
  name        = var.vault_name != null ? var.vault_name : "${var.name_prefix}-backup-vault"
  kms_key_arn = var.kms_key_arn

  tags = merge(var.tags, {
    Purpose = "backup-vault"
  })
}

resource "aws_backup_plan" "this" {
  name = var.plan_name != null ? var.plan_name : "${var.name_prefix}-backup-plan"

  rule {
    rule_name         = var.rule_name
    target_vault_name = aws_backup_vault.this.name
    schedule          = var.schedule
    start_window      = var.start_window_minutes
    completion_window = var.completion_window_minutes

    lifecycle {
      delete_after = var.delete_after_days
    }

    dynamic "copy_action" {
      for_each = var.copy_destination_vault_arn == null ? [] : [var.copy_destination_vault_arn]

      content {
        destination_vault_arn = copy_action.value

        lifecycle {
          delete_after = var.copy_delete_after_days
        }
      }
    }
  }

  tags = merge(var.tags, {
    Purpose = "backup-plan"
  })
}

resource "aws_backup_selection" "this" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = var.selection_name != null ? var.selection_name : "${var.name_prefix}-backup-selection"
  plan_id      = aws_backup_plan.this.id
  resources    = var.resource_arns
}
