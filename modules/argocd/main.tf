###############################################################################
# modules/argocd/main.tf
# ArgoCD 설치 + (옵션) Image Updater IRSA
#
# 전제: addon 레이어에서 apply. infra 레이어(eks 모듈)가 먼저 완료되어야 함.
#       root 모듈에서 helm provider를 클러스터 엔드포인트로 설정해야 함.
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12, < 3.0"
    }
  }
}

locals {
  # OIDC URL에서 https:// 접두어 제거 (IRSA 신뢰 정책 condition 키에 사용)
  oidc_url = replace(var.oidc_provider_url, "https://", "")

  # Image Updater ServiceAccount 이름 (차트 기본값)
  image_updater_sa = "argocd-image-updater"
}

#==============================================================================
# 1) ArgoCD 설치 (Helm)
#==============================================================================
resource "helm_release" "argo_cd" {
  name             = "argocd"
  namespace        = var.namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version

  atomic  = true
  timeout = 600

  # ArgoCD 서버 Service 타입
  set {
    name  = "server.service.type"
    value = var.server_service_type
  }

  # insecure 모드 파라미터 (ConfigMap 방식 — 차트 5.x 이후 권장)
  set {
    name  = "configs.params.server\\.insecure"
    value = tostring(var.server_insecure)
  }

  # insecure 모드 extraArgs (구형 차트 호환 및 명시적 플래그)
  dynamic "set" {
    for_each = var.server_insecure ? [1] : []
    content {
      name  = "server.extraArgs[0]"
      value = "--insecure"
    }
  }

  # Image Updater IRSA 활성화 시 ServiceAccount에 역할 ARN 어노테이션 주입
  dynamic "set" {
    for_each = var.enable_image_updater_irsa ? [1] : []
    content {
      name  = "imageUpdater.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.argocd_image_updater[0].arn
    }
  }

  # 시스템 노드 taint(CriticalAddonsOnly) 를 허용해 system 노드그룹에 배치
  # argo-cd 차트는 global.tolerations 를 지원하지 않으므로 컴포넌트별로 설정
  set {
    name  = "controller.tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "controller.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "controller.tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "server.tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "server.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "server.tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "repoServer.tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "repoServer.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "repoServer.tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "applicationSet.tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "applicationSet.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "applicationSet.tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "redis.tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "redis.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "redis.tolerations[0].effect"
    value = "NoSchedule"
  }

  # 추가 values (YAML 문자열 — 비어있으면 compact()가 빈 리스트로 만들어 무시)
  values = compact([var.extra_helm_values])
}

#==============================================================================
# 2) ArgoCD Image Updater IRSA (enable_image_updater_irsa = true 일 때만 생성)
#    Image Updater 파드가 ECR 이미지 목록을 읽어 자동 태그 업데이트를 수행
#==============================================================================
data "aws_iam_policy_document" "argocd_image_updater_assume" {
  count = var.enable_image_updater_irsa ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # argocd 네임스페이스의 argocd-image-updater ServiceAccount만 이 역할을 빌릴 수 있음
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${local.image_updater_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "argocd_image_updater" {
  count              = var.enable_image_updater_irsa ? 1 : 0
  name               = "${var.cluster_name}-argocd-image-updater"
  assume_role_policy = data.aws_iam_policy_document.argocd_image_updater_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "argocd_image_updater" {
  count = var.enable_image_updater_irsa ? 1 : 0

  statement {
    sid    = "ECRRead"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "argocd_image_updater" {
  count       = var.enable_image_updater_irsa ? 1 : 0
  name        = "${var.cluster_name}-argocd-image-updater"
  description = "ArgoCD Image Updater — ECR 이미지 조회 권한"
  policy      = data.aws_iam_policy_document.argocd_image_updater[0].json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "argocd_image_updater" {
  count      = var.enable_image_updater_irsa ? 1 : 0
  role       = aws_iam_role.argocd_image_updater[0].name
  policy_arn = aws_iam_policy.argocd_image_updater[0].arn
}
