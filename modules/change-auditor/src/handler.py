"""
AWS Change Auditor - CloudTrail 변경 이벤트 처리 Lambda

EventBridge → SQS → 이 Lambda
1. CloudTrail 이벤트 파싱
2. userAgent 기반 호출 경로 분류
3. AWS Config 변경 이력 조회 (선택적)
4. AI(Bedrock Claude) 요약 + 위험도 분류
5. Slack 알림 전송
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─── 환경 변수 ──────────────────────────────────────────────────────────────────
SLACK_WEBHOOK_SECRET_ARN = os.environ.get("SLACK_WEBHOOK_SECRET_ARN", "")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")
DYNAMODB_TABLE = os.environ.get("DYNAMODB_TABLE", "")
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")

# ─── AWS 클라이언트 ──────────────────────────────────────────────────────────────
secrets_client = boto3.client("secretsmanager")
bedrock_client = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
config_client = boto3.client("config")
dynamodb = boto3.resource("dynamodb")


# ─── 호출 경로 분류 ──────────────────────────────────────────────────────────────

KNOWN_SERVICE_ACTORS = {
    "karpenter": "Karpenter",
    "keda": "KEDA",
    "eks.amazonaws.com": "EKS",
    "autoscaling.amazonaws.com": "Auto Scaling",
    "elasticloadbalancing.amazonaws.com": "ALB/ELB",
    "load-balancer-controller": "ALB Controller",
    "rds.amazonaws.com": "RDS",
    "lambda.amazonaws.com": "Lambda",
    "cloudformation.amazonaws.com": "CloudFormation",
    "ecs.amazonaws.com": "ECS",
}


def extract_user_display_name(event_detail: dict) -> str:
    """CloudTrail userIdentity에서 사람이 읽을 수 있는 이름을 추출한다."""
    user_identity = event_detail.get("userIdentity", {})
    identity_type = user_identity.get("type", "")

    # IAM User: userName 직접 사용
    if identity_type == "IAMUser":
        return user_identity.get("userName", "unknown")

    # Root
    if identity_type == "Root":
        return "Root"

    # AssumedRole: sessionContext에서 역할명 추출
    if identity_type == "AssumedRole":
        session_context = user_identity.get("sessionContext", {})
        session_issuer = session_context.get("sessionIssuer", {})
        role_name = session_issuer.get("userName", "")
        role_arn = session_issuer.get("arn", "")

        # principalId에서 세션 이름 추출 (AROA...:session-name)
        principal_id = user_identity.get("principalId", "")
        session_name = ""
        if ":" in principal_id:
            session_name = principal_id.split(":", 1)[1]

        # userAgent도 참고 (역할명으로 못 찾을 때 보조)
        user_agent = event_detail.get("userAgent", "").lower()

        # 알려진 서비스 매칭 — role name, session name, role ARN, userAgent 전부 확인
        combined = f"{role_name} {session_name} {role_arn} {user_agent}".lower()
        for keyword, display_name in KNOWN_SERVICE_ACTORS.items():
            if keyword in combined:
                return display_name

        # GitHub Actions
        if "github" in combined:
            return "GitHub Actions"

        # 숫자로만 된 session name (Karpenter instance profile 등)은 역할명 기준으로 표시
        if session_name and session_name.replace("-", "").isdigit():
            if role_name:
                return role_name
            return "AWS Service (auto)"

        # 역할명이 있으면 그걸 표시
        if role_name:
            if session_name and session_name != role_name:
                return f"{role_name} ({session_name})"
            return role_name

        return session_name or principal_id or "unknown"

    # AWSService
    if identity_type == "AWSService":
        invoking_service = user_identity.get("invokedBy", "")
        for keyword, display_name in KNOWN_SERVICE_ACTORS.items():
            if keyword in invoking_service.lower():
                return display_name
        return invoking_service or "AWS Service"

    # Fallback
    return user_identity.get("userName", user_identity.get("principalId", "unknown"))


def format_event_time_kst(event_time: str) -> str:
    """UTC 시간 문자열을 KST(+9) 형식으로 변환한다."""
    try:
        # CloudTrail 시간 형식: 2026-06-18T06:46:45Z
        dt = datetime.fromisoformat(event_time.replace("Z", "+00:00"))
        kst = dt + timedelta(hours=9)
        return kst.strftime("%Y-%m-%d %H:%M:%S KST")
    except Exception:
        return event_time

def classify_actor(event_detail: dict) -> str:
    """userAgent 기반으로 호출 경로를 분류한다."""
    user_agent = event_detail.get("userAgent", "")
    source_ip = event_detail.get("sourceIPAddress", "")
    event_type = event_detail.get("eventType", "")

    ua_lower = user_agent.lower()

    if any(kw in ua_lower for kw in ["terraform", "hashicorp", "terraform-provider"]):
        return "Terraform"
    elif any(kw in ua_lower for kw in ["mozilla", "chrome", "safari"]) or event_type == "AwsConsoleSignIn":
        return "Console"
    elif "aws-cli" in ua_lower:
        return "AWS CLI"
    elif any(kw in ua_lower for kw in ["aws-sdk", "karpenter", "eks.amazonaws.com"]):
        return "AWS SDK / Controller"
    elif any(domain in source_ip for domain in [".amazonaws.com"]):
        return "AWS Service"
    else:
        return "Unknown"


# ─── 위험도 기본 분류 ────────────────────────────────────────────────────────────

CRITICAL_PATTERNS = [
    # Security Group: 0.0.0.0/0 인바운드 오픈
    ("AuthorizeSecurityGroupIngress", "0.0.0.0/0"),
    ("AuthorizeSecurityGroupIngress", "::/0"),
    # S3 Public Access
    ("PutBucketPolicy", '"Effect":"Allow"'),
    ("PutBucketAcl", "public"),
    ("PutBucketPublicAccessBlock", '"value":false'),
    ("DeleteBucketPublicAccessBlock", ""),
    # KMS 키 삭제/비활성화
    ("ScheduleKeyDeletion", ""),
    ("DisableKey", ""),
    # Root 계정 사용
    ("ConsoleLogin", "Root"),
]

HIGH_EVENTS = [
    # Security Group 변경
    "AuthorizeSecurityGroupIngress",
    "RevokeSecurityGroupIngress",
    "AuthorizeSecurityGroupEgress",
    "RevokeSecurityGroupEgress",
    "CreateSecurityGroup",
    "DeleteSecurityGroup",
    # IAM 정책/역할 변경
    "CreateRole",
    "DeleteRole",
    "PutRolePolicy",
    "DeleteRolePolicy",
    "AttachRolePolicy",
    "DetachRolePolicy",
    "CreatePolicy",
    "DeletePolicy",
    "CreatePolicyVersion",
    "CreateUser",
    "DeleteUser",
    "CreateAccessKey",
    "UpdateAccessKey",
    # S3
    "PutBucketPublicAccessBlock",
    "DeleteBucketPolicy",
]

MEDIUM_EVENTS = [
    # RDS 설정 변경
    "ModifyDBInstance",
    "ModifyDBCluster",
    "CreateDBInstance",
    "DeleteDBInstance",
    "RebootDBInstance",
    # ElastiCache
    "ModifyCacheCluster",
    "ModifyReplicationGroup",
    # EKS
    "UpdateClusterConfig",
    "UpdateNodegroupConfig",
    # VPC/Network
    "CreateRoute",
    "DeleteRoute",
    "ModifySubnetAttribute",
]


def classify_severity(event_name: str, request_params: dict) -> str:
    """이벤트명과 요청 파라미터 기반으로 기본 위험도를 분류한다."""
    params_str = json.dumps(request_params, ensure_ascii=False) if request_params else ""

    # Critical: 패턴 매칭 (이벤트명 + 파라미터 내 위험 문자열)
    for pattern_event, pattern_value in CRITICAL_PATTERNS:
        if event_name == pattern_event:
            if not pattern_value or pattern_value in params_str:
                return "Critical"

    if event_name in HIGH_EVENTS:
        return "High"

    if event_name in MEDIUM_EVENTS:
        return "Medium"

    return "Low"


# ─── AWS Config 조회 ─────────────────────────────────────────────────────────────

def _first_present(*values):
    for value in values:
        if value:
            return value
    return None


def extract_config_resource(event_detail: dict) -> tuple[str, str] | tuple[None, None]:
    """CloudTrail 이벤트에서 AWS Config 조회용 resourceType/resourceId를 추출한다."""
    event_source = event_detail.get("eventSource", "")
    event_name = event_detail.get("eventName", "")
    params = event_detail.get("requestParameters", {}) or {}

    if event_source == "ec2.amazonaws.com":
        if "SecurityGroup" in event_name:
            group_id = _first_present(
                params.get("groupId"),
                params.get("GroupId"),
                params.get("sourceSecurityGroupId"),
            )
            if not group_id:
                group_name = params.get("groupName") or params.get("GroupName")
                group_id = group_name
            if group_id:
                return "AWS::EC2::SecurityGroup", group_id

        if "RouteTable" in event_name or event_name in ("CreateRoute", "DeleteRoute", "ReplaceRoute"):
            route_table_id = params.get("routeTableId") or params.get("RouteTableId")
            if route_table_id:
                return "AWS::EC2::RouteTable", route_table_id

        if "Subnet" in event_name:
            subnet_id = params.get("subnetId") or params.get("SubnetId")
            if subnet_id:
                return "AWS::EC2::Subnet", subnet_id

        if "Vpc" in event_name or "VPC" in event_name:
            vpc_id = params.get("vpcId") or params.get("VpcId")
            if vpc_id:
                return "AWS::EC2::VPC", vpc_id

        instance_id = params.get("instanceId")
        if not instance_id:
            instances_set = params.get("instancesSet", {}).get("items", [])
            if instances_set:
                instance_id = instances_set[0].get("instanceId")
        if instance_id:
            return "AWS::EC2::Instance", instance_id

    if event_source == "s3.amazonaws.com":
        bucket_name = params.get("bucketName") or params.get("bucket")
        if bucket_name:
            return "AWS::S3::Bucket", bucket_name

    if event_source == "iam.amazonaws.com":
        role_name = params.get("roleName")
        if role_name:
            return "AWS::IAM::Role", role_name
        policy_arn = params.get("policyArn")
        if policy_arn:
            return "AWS::IAM::Policy", policy_arn
        user_name = params.get("userName")
        if user_name:
            return "AWS::IAM::User", user_name

    if event_source == "rds.amazonaws.com":
        db_id = _first_present(
            params.get("dBInstanceIdentifier"),
            params.get("dbInstanceIdentifier"),
            params.get("DBInstanceIdentifier"),
        )
        if db_id:
            return "AWS::RDS::DBInstance", db_id

    if event_source == "elasticache.amazonaws.com":
        cluster_id = params.get("cacheClusterId") or params.get("replicationGroupId")
        if cluster_id:
            return "AWS::ElastiCache::CacheCluster", cluster_id

    if event_source == "eks.amazonaws.com":
        cluster_name = params.get("name") or params.get("clusterName")
        if cluster_name:
            return "AWS::EKS::Cluster", cluster_name

    for resource in event_detail.get("resources", []) or []:
        resource_type = resource.get("type")
        resource_id = resource.get("resourceName")
        if not resource_id and resource.get("ARN"):
            resource_id = resource["ARN"].split("/")[-1]
        if resource_type and resource_id:
            return resource_type, resource_id

    return None, None

def get_config_diff(resource_type: str, resource_id: str) -> dict | None:
    """AWS Config에서 리소스의 최근 변경 이력을 조회한다."""
    try:
        response = config_client.get_resource_config_history(
            resourceType=resource_type,
            resourceId=resource_id,
            limit=2,
            chronologicalOrder="Reverse",
        )
        items = response.get("configurationItems", [])
        if len(items) >= 2:
            return {
                "current": items[0].get("configuration", ""),
                "previous": items[1].get("configuration", ""),
                "change_time": str(items[0].get("configurationItemCaptureTime", "")),
            }
        elif len(items) == 1:
            return {
                "current": items[0].get("configuration", ""),
                "previous": None,
                "change_time": str(items[0].get("configurationItemCaptureTime", "")),
            }
    except Exception as e:
        logger.warning(f"Config history lookup failed: {e}")

    return None


# ─── AI 요약 (Bedrock Claude) ────────────────────────────────────────────────────

ANALYSIS_PROMPT = """당신은 AWS 인프라 보안 및 운영 전문가입니다.
아래 CloudTrail 이벤트를 분석하고, 운영자가 즉시 판단할 수 있도록 한국어로 요약해주세요.

## 우리 인프라 구조 (판단 시 반드시 참고)

이 환경은 EKS 기반 MSA 야구 예매 서비스입니다. 다음 자동화 컨트롤러가 정상적으로 AWS API를 호출합니다:

- **Karpenter**: EKS 노드 오토스케일링. RunInstances, CreateFleet, CreateLaunchTemplate, DeleteLaunchTemplate, TerminateInstances 등을 자동으로 호출. 역할명에 "karpenter" 포함. 이 동작은 모두 **정상 자동화**임.
- **KEDA**: Pod 오토스케일링 컨트롤러. SQS, CloudWatch 메트릭 조회. 역할명에 "keda" 포함.
- **GitHub Actions (Terraform CI/CD)**: 인프라 변경. userAgent에 "terraform" 또는 "hashicorp" 포함. 역할명에 "github" 포함. 이 동작은 **정상 IaC 파이프라인**.
- **EKS 서비스**: ENI 생성/삭제, Security Group 변경 등. sourceIPAddress가 "eks.amazonaws.com". 정상 동작.
- **Auto Scaling**: EC2 Auto Scaling 그룹 동작.

위 자동화 컨트롤러의 동작은 "정상 변경"으로 분류하고, 위험도를 낮게(Low) 판단해야 합니다.
"수동 변경"은 Console이나 CLI에서 사람이 직접 한 경우에만 해당합니다.

## 이벤트 정보
- 시간: {event_time}
- 서비스: {event_source}
- 이벤트: {event_name}
- 호출자: {user_identity}
- 호출 경로: {actor_type} (Terraform/Console/AWS CLI/SDK/Service 중 하나)
- 코드가 식별한 실행 주체: {code_identified_actor}
- 소스 IP: {source_ip}
- userAgent: {user_agent}
- 리소스: {resources}
- 요청 파라미터: {request_params}
- 환경: {environment}

## Config 변경 정보
{config_diff}

## 위험도 판단 기준
- Critical: 전체 인터넷(0.0.0.0/0) 노출, 암호화 키 삭제, S3 퍼블릭 오픈, Root 계정 사용
- High: 사람이 직접 Security Group 변경, IAM 정책/역할 변경, 인증/권한 관련
- Medium: 사람이 직접 RDS/ElastiCache 설정 변경, 네트워크 라우팅 변경
- Low: 자동화 컨트롤러(Karpenter/KEDA/EKS/Terraform)의 정상 동작, 일반적인 리소스 생성/수정

## 의도 추정 기준
- 정상 자동화: Karpenter, KEDA, EKS, Terraform CI/CD, Auto Scaling 등 컨트롤러 동작
- 정상 변경: Terraform 또는 GitHub Actions에서 사람이 의도적으로 트리거한 IaC 변경
- 수동 변경: Console 또는 CLI에서 개인 IAM 사용자가 직접 호출
- 실수 가능성: dev 환경에서 의도하지 않았을 수 있는 넓은 범위 변경
- 보안 위험: 외부 노출, 권한 상승, 암호화 비활성화

## 출력 형식 (반드시 아래 JSON만 출력)
{{
  "summary": "한 줄 요약 (30자 이내, 핵심만)",
  "detail": "상세 설명 (2-3문장, 변경 내용과 영향 범위)",
  "severity": "Low | Medium | High | Critical",
  "intent": "정상 자동화 | 정상 변경 | 수동 변경 | 실수 가능성 | 보안 위험",
  "actual_actor": "실제 실행 주체 (예: Karpenter 노드 축소, KEDA 스케일링, Terraform CI/CD, 사용자 mzc-sds 콘솔 수동 변경 등)",
  "recommendation": "추천 대응 (구체적 행동 1-2가지. 정상 자동화면 '조치 불필요'라고 적어도 됨)"
}}

JSON만 출력하세요."""


def ai_analyze(event_detail: dict, actor_type: str, config_diff: dict | None) -> dict:
    """Bedrock Claude로 이벤트를 분석한다."""
    user_identity = event_detail.get("userIdentity", {})
    user_name = user_identity.get("userName", user_identity.get("principalId", "unknown"))
    code_actor = extract_user_display_name(event_detail)

    config_info = "변경 이력 없음"
    if config_diff:
        config_info = f"변경 시각: {config_diff['change_time']}\n현재: {str(config_diff['current'])[:500]}\n이전: {str(config_diff.get('previous', 'N/A'))[:500]}"

    resources = event_detail.get("resources", [])
    resources_str = json.dumps(resources, ensure_ascii=False)[:300] if resources else "N/A"

    prompt = ANALYSIS_PROMPT.format(
        event_time=event_detail.get("eventTime", ""),
        event_source=event_detail.get("eventSource", ""),
        event_name=event_detail.get("eventName", ""),
        user_identity=user_name,
        actor_type=actor_type,
        code_identified_actor=code_actor,
        source_ip=event_detail.get("sourceIPAddress", ""),
        user_agent=event_detail.get("userAgent", "")[:200],
        resources=resources_str,
        request_params=json.dumps(event_detail.get("requestParameters", {}), ensure_ascii=False)[:500],
        config_diff=config_info,
        environment=ENVIRONMENT,
    )

    try:
        response = bedrock_client.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            contentType="application/json",
            accept="application/json",
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 1024,
                "messages": [{"role": "user", "content": prompt}],
            }),
        )

        body = json.loads(response["body"].read())
        content = body.get("content", [{}])[0].get("text", "{}")

        # JSON 파싱
        result = json.loads(content)
        return result

    except Exception as e:
        logger.error(f"Bedrock invocation failed: {e}")
        return {
            "summary": f"{event_detail.get('eventName', 'Unknown')} 이벤트 발생",
            "detail": "AI 분석 실패. 원본 이벤트를 직접 확인하세요.",
            "severity": classify_severity(
                event_detail.get("eventName", ""),
                event_detail.get("requestParameters", {}),
            ),
            "intent": "확인 필요",
            "recommendation": "CloudTrail 콘솔에서 직접 확인하세요.",
        }


# ─── Slack 전송 ──────────────────────────────────────────────────────────────────

SEVERITY_EMOJI = {
    "Critical": "🔴",
    "High": "🟠",
    "Medium": "🟡",
    "Low": "🟢",
}


def get_slack_webhook_url() -> str:
    """Secrets Manager에서 Slack Webhook URL을 가져온다."""
    if not SLACK_WEBHOOK_SECRET_ARN:
        return ""
    try:
        response = secrets_client.get_secret_value(SecretId=SLACK_WEBHOOK_SECRET_ARN)
        secret = json.loads(response["SecretString"])
        return secret.get("webhook_url", secret.get("url", ""))
    except Exception as e:
        logger.error(f"Failed to get Slack webhook: {e}")
        return ""


def send_slack(event_detail: dict, actor_type: str, analysis: dict):
    """Slack으로 변경 알림을 전송한다."""
    import urllib.request

    webhook_url = get_slack_webhook_url()
    if not webhook_url:
        logger.warning("Slack webhook URL not configured, skipping notification")
        return

    severity = analysis.get("severity", "Low")
    emoji = SEVERITY_EMOJI.get(severity, "⚪")

    user_name = extract_user_display_name(event_detail)
    event_time_kst = format_event_time_kst(event_detail.get("eventTime", ""))
    event_id = event_detail.get("eventID", "N/A")

    blocks = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"{emoji} [{severity}] AWS 리소스 변경 감지"},
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*분류:* {actor_type}"},
                {"type": "mrkdwn", "text": f"*누가:* {user_name}"},
                {"type": "mrkdwn", "text": f"*서비스:* {event_detail.get('eventSource', '')}"},
                {"type": "mrkdwn", "text": f"*이벤트:* {event_detail.get('eventName', '')}"},
                {"type": "mrkdwn", "text": f"*언제:* {event_time_kst}"},
                {"type": "mrkdwn", "text": f"*환경:* {ENVIRONMENT}"},
            ],
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*변경 요약:*\n{analysis.get('summary', '')}"},
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*AI 판단:*\n{analysis.get('detail', '')}"},
        },
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"*의도 추정:* {analysis.get('intent', '')}\n*실행 주체:* {analysis.get('actual_actor', actor_type)}\n*추천 대응:* {analysis.get('recommendation', '')}"},
        },
        {
            "type": "context",
            "elements": [
                {"type": "mrkdwn", "text": f"CloudTrail Event ID: `{event_id}`"},
            ],
        },
    ]

    payload = json.dumps({"blocks": blocks}).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    try:
        urllib.request.urlopen(req, timeout=10)
        logger.info("Slack notification sent successfully")
    except Exception as e:
        logger.error(f"Slack notification failed: {e}")


# ─── DynamoDB 저장 ───────────────────────────────────────────────────────────────

def save_to_dynamodb(event_detail: dict, actor_type: str, analysis: dict):
    """처리 결과를 DynamoDB에 저장한다."""
    if not DYNAMODB_TABLE:
        return

    try:
        table = dynamodb.Table(DYNAMODB_TABLE)
        table.put_item(Item={
            "event_id": event_detail.get("eventID", ""),
            "event_time": event_detail.get("eventTime", ""),
            "event_name": event_detail.get("eventName", ""),
            "event_source": event_detail.get("eventSource", ""),
            "actor_type": actor_type,
            "user_name": extract_user_display_name(event_detail),
            "severity": analysis.get("severity", "Low"),
            "summary": analysis.get("summary", ""),
            "detail": analysis.get("detail", ""),
            "intent": analysis.get("intent", ""),
            "recommendation": analysis.get("recommendation", ""),
            "processed_at": datetime.now(timezone.utc).isoformat(),
        })
    except Exception as e:
        logger.error(f"DynamoDB save failed: {e}")


# ─── 변경성 이벤트 필터링 ────────────────────────────────────────────────────────

MUTATING_PREFIXES = [
    "Create", "Update", "Modify", "Delete", "Put", "Attach", "Detach",
    "Authorize", "Revoke", "Add", "Remove", "Enable", "Disable",
    "Start", "Stop", "Terminate", "Run",
]


def is_mutating_event(event_name: str, read_only: str) -> bool:
    """변경성 이벤트인지 필터링한다."""
    if read_only == "true":
        return False
    return any(event_name.startswith(prefix) for prefix in MUTATING_PREFIXES)


# ─── 메인 핸들러 ─────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """SQS에서 CloudTrail 이벤트를 받아 처리한다."""
    records = event.get("Records", [])
    logger.info(f"Processing {len(records)} records")

    for record in records:
        try:
            body = json.loads(record.get("body", "{}"))

            # EventBridge → SQS 구조: detail 안에 CloudTrail 이벤트
            event_detail = body.get("detail", body)

            event_name = event_detail.get("eventName", "")
            read_only = event_detail.get("readOnly", "false")

            # 변경성 이벤트만 처리
            if not is_mutating_event(event_name, str(read_only).lower()):
                logger.info(f"Skipping non-mutating event: {event_name}")
                continue

            # 1. 호출 경로 분류
            actor_type = classify_actor(event_detail)
            display_actor = extract_user_display_name(event_detail)

            # 1.5 자동화 컨트롤러 이벤트는 무조건 Low → Slack 안 보냄
            AUTOMATION_ACTORS = {"Karpenter", "KEDA", "EKS", "Auto Scaling", "Lambda", "ALB Controller", "ALB/ELB"}
            if display_actor in AUTOMATION_ACTORS:
                logger.info(f"Automation event ({display_actor}), skipping: {event_name}")
                continue

            # 2. AWS Config 변경 이력 조회 (리소스 정보가 있는 경우)
            config_diff = None
            resource_type, resource_id = extract_config_resource(event_detail)
            if resource_type and resource_id:
                logger.info(f"Looking up AWS Config history: {resource_type} / {resource_id}")
                config_diff = get_config_diff(resource_type, resource_id)
            else:
                logger.info(f"No AWS Config resource mapping found for event: {event_name}")

            # 3. AI 요약
            analysis = ai_analyze(event_detail, actor_type, config_diff)

            # 4. DynamoDB 저장
            save_to_dynamodb(event_detail, actor_type, analysis)

            # 5. Slack 알림 (Medium 이상)
            severity = analysis.get("severity", "Low")
            if severity in ("Medium", "High", "Critical"):
                send_slack(event_detail, actor_type, analysis)
            else:
                logger.info(f"Low severity event, skipping Slack: {event_name}")

        except Exception as e:
            logger.error(f"Error processing record: {e}", exc_info=True)

    return {"statusCode": 200, "body": f"Processed {len(records)} records"}
