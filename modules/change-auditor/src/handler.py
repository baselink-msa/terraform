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
from datetime import datetime, timezone

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

## 이벤트 정보
- 시간: {event_time}
- 서비스: {event_source}
- 이벤트: {event_name}
- 호출자: {user_identity}
- 호출 경로: {actor_type} (Terraform/Console/AWS CLI/SDK/Service 중 하나)
- 소스 IP: {source_ip}
- 리소스: {resources}
- 요청 파라미터: {request_params}
- 환경: {environment}

## Config 변경 정보
{config_diff}

## 위험도 판단 기준
- Critical: 전체 인터넷(0.0.0.0/0) 노출, 암호화 키 삭제, S3 퍼블릭 오픈, Root 계정 사용
- High: Security Group 변경, IAM 정책/역할 변경, 인증/권한 관련
- Medium: RDS/ElastiCache 설정 변경, 네트워크 라우팅 변경
- Low: 일반적인 리소스 생성/수정

## 의도 추정 기준
- 정상 변경: Terraform 또는 GitHub Actions에서 호출, CI/CD 파이프라인 패턴
- 수동 변경: Console 또는 CLI에서 개인 IAM 사용자가 호출
- 실수 가능성: dev 환경에서 의도하지 않았을 수 있는 넓은 범위 변경
- 보안 위험: 외부 노출, 권한 상승, 암호화 비활성화

## 출력 형식 (반드시 아래 JSON만 출력)
{{
  "summary": "한 줄 요약 (30자 이내, 핵심만)",
  "detail": "상세 설명 (2-3문장, 변경 내용과 영향 범위)",
  "severity": "Low | Medium | High | Critical",
  "intent": "정상 변경 | 수동 변경 | 실수 가능성 | 보안 위험",
  "recommendation": "추천 대응 (구체적 행동 1-2가지)"
}}

JSON만 출력하세요."""


def ai_analyze(event_detail: dict, actor_type: str, config_diff: dict | None) -> dict:
    """Bedrock Claude로 이벤트를 분석한다."""
    user_identity = event_detail.get("userIdentity", {})
    user_name = user_identity.get("userName", user_identity.get("principalId", "unknown"))

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
        source_ip=event_detail.get("sourceIPAddress", ""),
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

    user_identity = event_detail.get("userIdentity", {})
    user_name = user_identity.get("userName", user_identity.get("principalId", "unknown"))

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
                {"type": "mrkdwn", "text": f"*언제:* {event_detail.get('eventTime', '')}"},
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
            "text": {"type": "mrkdwn", "text": f"*의도 추정:* {analysis.get('intent', '')}\n*추천 대응:* {analysis.get('recommendation', '')}"},
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
            "user_name": event_detail.get("userIdentity", {}).get("userName", "unknown"),
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

            # 2. AWS Config 변경 이력 조회 (리소스 정보가 있는 경우)
            config_diff = None
            resources = event_detail.get("resources", [])
            if resources:
                for resource in resources:
                    resource_type = resource.get("type", "")
                    resource_id = resource.get("ARN", "").split("/")[-1] if resource.get("ARN") else ""
                    if resource_type and resource_id:
                        config_diff = get_config_diff(resource_type, resource_id)
                        break

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
