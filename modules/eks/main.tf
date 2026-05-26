###############################################################################
# modules/eks/main.tf
# EKS 클러스터 · 시스템 노드그룹 · OIDC provider · 관리형 애드온
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

#------------------------------------------------------------------------------
# 1) 컨트롤 플레인용 IAM 역할
#    클러스터가 ENI·로드밸런서 등 AWS 리소스를 다루기 위한 권한
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

#------------------------------------------------------------------------------
# (옵션) Kubernetes secrets 봉투 암호화용 KMS 키
#   ※ encryption_config는 한 번 켜면 끌 수 없음. 신규 클러스터에만 안전하게 적용.
#------------------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  count                   = var.enable_secrets_encryption ? 1 : 0
  description             = "EKS secrets encryption - ${var.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = var.tags
}

resource "aws_kms_alias" "eks" {
  count         = var.enable_secrets_encryption ? 1 : 0
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks[0].key_id
}

# secrets 암호화 활성화 시, 클러스터 역할이 KMS 키를 쓰도록 허용
resource "aws_iam_role_policy" "cluster_kms" {
  count = var.enable_secrets_encryption ? 1 : 0
  name  = "${var.cluster_name}-cluster-kms"
  role  = aws_iam_role.cluster.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant"]
      Resource = aws_kms_key.eks[0].arn
    }]
  })
}

#------------------------------------------------------------------------------
# 2) EKS 클러스터 (컨트롤 플레인)
#------------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.public_access_cidrs
  }

  # Control plane logging — API audit·인증·스케줄러 로그를 CloudWatch로 전송
  enabled_cluster_log_types = var.cluster_log_types

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  dynamic "encryption_config" {
    for_each = var.enable_secrets_encryption ? [1] : []
    content {
      provider {
        key_arn = aws_kms_key.eks[0].arn
      }
      resources = ["secrets"]
    }
  }

  tags = var.tags

  # 권한 부여가 끝난 뒤 클러스터를 생성하도록 보장
  # secrets 암호화 시 cluster_kms 정책도 선행 (count=0이면 빈 목록이라 무해)
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_kms,
  ]
}

#------------------------------------------------------------------------------
# 3) 노드용 IAM 역할
#    노드(EC2)가 클러스터에 join하고, CNI·ECR을 사용하기 위한 권한
#------------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = var.tags
}

# 노드 동작에 필요한 3종 관리형 정책
#   AmazonEKSWorkerNodePolicy            : 클러스터 join
#   AmazonEKS_CNI_Policy                 : 파드 네트워킹(ENI)
#   AmazonEC2ContainerRegistryReadOnly   : ECR 이미지 pull
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

#------------------------------------------------------------------------------
# 4) 시스템 노드그룹
#    CoreDNS·Karpenter 등 '시스템 파드'의 고정 거처 (기본 t3.large x2)
#    실제 앱 워크로드는 이후 Karpenter(eks-addons 모듈)가 별도 노드로 띄움
#------------------------------------------------------------------------------
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.system_node_instance_types
  capacity_type  = var.system_node_capacity_type
  disk_size      = var.system_node_disk_size

  scaling_config {
    desired_size = var.system_node_desired_size
    min_size     = var.system_node_min_size
    max_size     = var.system_node_max_size
  }

  # 시스템 노드임을 표시하는 라벨 (워크로드 배치 정책에 활용 가능)
  labels = {
    role = "system"
  }

  # OS 업데이트 시 한 번에 한 대만 교체
  update_config {
    max_unavailable = 1
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]
}

#------------------------------------------------------------------------------
# 5) OIDC provider  ── IRSA의 토대
#    파드가 ServiceAccount로 IAM 역할을 빌려 쓰게 해주는 '신뢰 다리'
#    => IAM/IRSA 모듈이 이 모듈의 oidc_provider_arn output을 입력받음
#------------------------------------------------------------------------------
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

#------------------------------------------------------------------------------
# 6) EKS 관리형 애드온 (vpc-cni · coredns · kube-proxy)
#    addon_version 미지정 시 클러스터 버전에 맞는 기본 버전을 AWS가 선택
#    coredns는 노드 위에서 도는 파드이므로 노드그룹 생성 이후 설치
#------------------------------------------------------------------------------
resource "aws_eks_addon" "this" {
  for_each = toset(var.cluster_addons)

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.value
  # 맵에 해당 애드온 버전이 있으면 고정, 없으면 null → EKS 기본 버전 사용
  addon_version = lookup(var.cluster_addon_versions, each.value, null)

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}
