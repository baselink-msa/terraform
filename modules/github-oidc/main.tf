# GitHub OIDC 공급자의 최신 인증서 지문(Thumbprint)을 자동으로 가져옵니다.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# AWS에 GitHub OIDC Provider 등록
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# GitHub Actions가 임시로 빌려 쓸 IAM 역할(Role) 생성
resource "aws_iam_role" "github_actions" {
  name = "baselink-github-actions-ecr-role"

  # 우리 팀의 GitHub 저장소에서 실행된 파이프라인만 이 역할을 사용할 수 있도록 제한 (핵심 보안 설정)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike   = { "token.actions.githubusercontent.com:sub": "repo:${var.github_repo}:*" }
        StringEquals = { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" }
      }
    }]
  })
}

# IAM 역할에 ECR 로그인 및 이미지 Push 권한 부여
resource "aws_iam_role_policy" "ecr_push" {
  name = "baselink-ecr-push-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = "*" # 모든 ECR 리포지토리에 Push 가능하도록 설정
      }
    ]
  })
}