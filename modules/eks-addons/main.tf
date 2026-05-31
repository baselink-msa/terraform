###############################################################################
# modules/eks-addons/main.tf
# Karpenter(노드 오토스케일러) + KEDA(파드 오토스케일러)
# A 방식: Karpenter 전용 IAM(컨트롤러·노드)도 이 모듈이 소유
#
# 전제: 이 모듈은 'addon 레이어'. 클러스터 레이어 apply 이후에 적용한다.
#       root 모듈에서 helm·kubectl provider를 클러스터 엔드포인트로 설정해야 함.
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12, < 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}

data "aws_partition" "current" {}

locals {
  partition = data.aws_partition.current.partition

  # OIDC URL에서 https:// 접두어 제거 (IRSA 신뢰 정책 condition 키에 사용)
  oidc_url = replace(var.oidc_provider_url, "https://", "")

  # Karpenter 컨트롤러 ServiceAccount 이름 (차트 기본값)
  karpenter_sa = "karpenter"
}

#==============================================================================
# 1) Karpenter 컨트롤러 IAM 역할 (IRSA)
#    Karpenter 파드가 EC2를 run/terminate 하기 위한 권한
#==============================================================================
data "aws_iam_policy_document" "karpenter_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # 'karpenter' 네임스페이스의 'karpenter' ServiceAccount만 이 역할을 빌릴 수 있음
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${var.karpenter_namespace}:${local.karpenter_sa}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "karpenter_controller" {
  # 노드 프로비저닝: 인스턴스·런치템플릿 생성/태깅/삭제
  statement {
    sid    = "KarpenterEC2Write"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = ["*"]
    # prod에서는 ec2:ResourceTag 조건으로 범위를 좁히는 것을 권장
  }

  # 인스턴스 타입·AMI·서브넷 등 조회
  statement {
    sid       = "KarpenterEC2Read"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  # AMI 파라미터 조회 (al2023 등)
  statement {
    sid       = "KarpenterSSMRead"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["*"]
  }

  # 인스턴스 가격 조회 (최적 타입 선택용)
  statement {
    sid       = "KarpenterPricingRead"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  # 노드 instance profile 확인
  statement {
    sid       = "KarpenterInstanceProfileRead"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = ["*"]
  }

  # 노드에 노드 역할을 붙이기 위한 PassRole (노드 역할로만 한정)
  statement {
    sid       = "KarpenterPassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  # 클러스터 엔드포인트 조회
  statement {
    sid       = "KarpenterEKSRead"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["*"]
  }

  # 중단 알림 큐 사용 (enable_interruption_queue = true 일 때만 추가)
  dynamic "statement" {
    for_each = var.enable_interruption_queue ? [1] : []
    content {
      sid    = "KarpenterInterruptionQueue"
      effect = "Allow"
      actions = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes",
      ]
      resources = [aws_sqs_queue.karpenter_interruption[0].arn]
    }
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "${var.cluster_name}-karpenter-controller"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

#==============================================================================
# 2) Karpenter 노드 IAM 역할 + instance profile
#    Karpenter가 띄우는 노드(EC2)가 클러스터 join·CNI·ECR을 쓰기 위한 권한
#==============================================================================
data "aws_iam_policy_document" "karpenter_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.karpenter_node_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
  tags = var.tags
}

# Karpenter가 띄운 노드가 클러스터에 join하도록 access entry 등록
# (관리형 노드그룹과 달리 자동 등록되지 않으므로 직접 만들어야 함)
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

#==============================================================================
# 3) 중단 알림 SQS 큐 + EventBridge 규칙  (enable_interruption_queue)
#    Spot 회수·인스턴스 상태 변경 이벤트를 받아, Karpenter가 노드를
#    미리 안전하게 비우도록(graceful drain) 함
#==============================================================================
resource "aws_sqs_queue" "karpenter_interruption" {
  count                     = var.enable_interruption_queue ? 1 : 0
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

data "aws_iam_policy_document" "interruption_queue" {
  count = var.enable_interruption_queue ? 1 : 0
  statement {
    sid       = "AllowEventBridgeSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption[0].arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  count     = var.enable_interruption_queue ? 1 : 0
  queue_url = aws_sqs_queue.karpenter_interruption[0].url
  policy    = data.aws_iam_policy_document.interruption_queue[0].json
}

locals {
  # Karpenter가 구독하는 4종 중단/상태 이벤트
  interruption_events = var.enable_interruption_queue ? {
    spot_interruption = {
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    rebalance = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    instance_state = {
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
    health_event = {
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
  } : {}
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = local.interruption_events
  name     = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode({
    source      = [each.value.source]
    detail-type = [each.value.detail_type]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = local.interruption_events
  rule     = aws_cloudwatch_event_rule.karpenter[each.key].name
  arn      = aws_sqs_queue.karpenter_interruption[0].arn
}

#==============================================================================
# 4) Karpenter 설치 (Helm) — '엔진'
#==============================================================================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  create_namespace = true

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  # 컨트롤러 ServiceAccount에 IRSA 역할 연결
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }
  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  # 중단 알림 큐 연결 (활성화 시에만)
  dynamic "set" {
    for_each = var.enable_interruption_queue ? [1] : []
    content {
      name  = "settings.interruptionQueue"
      value = aws_sqs_queue.karpenter_interruption[0].name
    }
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "1"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  depends_on = [
    aws_iam_role_policy.karpenter_controller,
    aws_iam_role_policy_attachment.karpenter_node,
    aws_eks_access_entry.karpenter_node,
  ]
}

#==============================================================================
# 5) KEDA 설치 (Helm) — '엔진'
#    ScaledObject CRD를 함께 설치함. 서비스별 ScaledObject는
#    백엔드 팀이 작성한다 (이 모듈 범위 밖).
#==============================================================================
resource "helm_release" "keda" {
  name             = "keda"
  namespace        = var.keda_namespace
  create_namespace = true

  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.keda_version
}

#==============================================================================
# 6) EC2NodeClass — Karpenter가 띄울 노드의 'AWS 측 설정'
#    AMI·서브넷·보안그룹·instance profile
#==============================================================================
resource "kubectl_manifest" "ec2nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiSelectorTerms           = [{ alias = var.ami_alias }]
      instanceProfile            = aws_iam_instance_profile.karpenter_node.name
      subnetSelectorTerms        = [for id in var.node_subnet_ids : { id = id }]
      securityGroupSelectorTerms = [for id in var.node_security_group_ids : { id = id }]
      tags                       = var.tags
    }
  })

  depends_on = [helm_release.karpenter]
}

#==============================================================================
# 7) NodePools — 서비스 등급별 컴퓨트 분리 (critical / general / batch)
#    workload-class 노드 라벨 → Pod nodeSelector 로 라우팅
#==============================================================================

# critical: 결제·락·구매 funnel (ticket·seat-lock·waiting-room·auth)
#   OnDemand only — Spot 중단 허용 불가
#   consolidateAfter 5m (보수적), 티켓 오픈 surge 시간대 disruption 차단
resource "kubectl_manifest" "nodepool_critical" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "critical" }
    spec = {
      template = {
        metadata = {
          labels = { "workload-class" = "critical" }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = var.node_arch
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m"]
            },
          ]
          expireAfter = "720h"
        }
      }
      limits = {
        cpu    = "500"
        memory = "500Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "5m"
        budgets = [
          { nodes = "10%" },
          { nodes = "0", schedule = "50 4 * * *", duration = "2h" }
        ]
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}

# general: 덜 critical (game·order·admin·ai-chatbot)
#   Spot+OnDemand 허용, instance-category r 추가 (메모리 집약 workload 대응)
resource "kubectl_manifest" "nodepool_general" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "general" }
    spec = {
      template = {
        metadata = {
          labels = { "workload-class" = "general" }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = var.node_arch
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
          ]
          expireAfter = "720h"
        }
      }
      limits = {
        cpu    = "300"
        memory = "300Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}

# batch: ticket-worker (SQS 비동기 처리)
#   Spot only — 중단 시 SQS 재처리 가능, 적극 축소(30%)
resource "kubectl_manifest" "nodepool_batch" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "batch" }
    spec = {
      template = {
        metadata = {
          labels = { "workload-class" = "batch" }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = var.node_arch
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m"]
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
          ]
          expireAfter = "720h"
        }
      }
      limits = {
        cpu    = "300"
        memory = "300Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
        budgets = [
          { nodes = "30%" }
        ]
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}
