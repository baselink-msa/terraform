resource "aws_iam_role" "github_actions_terraform" {
  name = "baselink-github-actions-terraform-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.github_oidc.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:baselink-msa/terraform:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_admin" {
  role       = aws_iam_role.github_actions_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_eks_access_entry" "github_actions_terraform" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions_terraform.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_actions_terraform_admin" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_actions_terraform.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.github_actions_terraform]
}
