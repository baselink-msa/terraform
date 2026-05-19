# Terraform State 버킷 부트스트랩 가이드

> Terraform이 자신의 state를 저장할 S3 버킷을 **한 번만 수동으로** 만드는 절차입니다.
> Terraform은 자기 state 버킷을 스스로 만들 수 없습니다(닭-달걀 문제).
> 팀에서 **한 명이 1회만** 실행하면 됩니다.

> ⚠️ **이 문서에는 실제 버킷명·AWS 계정 ID·자격증명을 적지 마세요.**
> 아래 값은 전부 예시이며, 실제 값은 각자 터미널에서만 사용합니다.

---

## 사전 준비

- AWS CLI 설치
- AWS 자격증명 설정 (`aws configure` 또는 SSO 로그인)
- S3 버킷을 생성할 수 있는 권한

---

## 0. 변수 설정 (예시 값 — 실제 값으로 교체)

```bash
# ▼ 아래는 예시입니다. 실제 값으로 바꾸되, 이 문서에는 실제 값을 적지 마세요.
BUCKET="example-tfstate-bucket-0000"   # S3 버킷명 (전 세계에서 유일해야 함)
REGION="ap-northeast-2"                # 사용할 AWS 리전
```

> 버킷명은 S3 전체에서 유일해야 합니다. 추측이 어렵도록 임의 접미사를 붙이는 것을 권장합니다.

---

## 1. 버킷 생성

```bash
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
```

> `us-east-1` 리전이라면 `--create-bucket-configuration` 줄을 빼야 합니다.

## 2. 버저닝 활성화 — state 손상 시 복구용

```bash
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

state 파일이 잘못 덮어써지거나 손상돼도 이전 버전으로 되돌릴 수 있습니다. **필수.**

## 3. 퍼블릭 접근 전면 차단 — 보안

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

state 파일에는 인프라 구성 정보가 담기므로 절대 공개되면 안 됩니다.

## 4. 기본 암호화 — 저장 시 암호화 (SSE-S3)

```bash
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

## 5. (선택) TLS 아닌 요청 거부 — 추가 보안

암호화되지 않은(HTTP) 접근까지 막으려면 버킷 정책을 추가합니다.

```bash
# 아래 EXAMPLE_BUCKET 두 곳을 실제 버킷명으로 바꿔 실행하세요.
aws s3api put-bucket-policy --bucket "$BUCKET" --policy '{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::EXAMPLE_BUCKET",
      "arn:aws:s3:::EXAMPLE_BUCKET/*"
    ],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}'
```

---

## 완료 후 — backend.tf 연결

각 `environments/<env>/<layer>/backend.tf`의 `bucket` 값을 위에서 만든 버킷명으로 교체합니다.

```
environments/dev/infra/backend.tf    →  bucket = "<만든 버킷명>"
environments/dev/addon/backend.tf    →  bucket = "<만든 버킷명>"
environments/prod/infra/backend.tf   →  bucket = "<만든 버킷명>"
environments/prod/addon/backend.tf   →  bucket = "<만든 버킷명>"
```

> State Lock은 `backend.tf`의 `use_lockfile = true`(Terraform 1.10+)로 처리됩니다. 별도의 DynamoDB Lock 테이블은 필요 없습니다. (DynamoDB 방식으로 갈 경우 이 가이드와 `backend.tf` 모두 수정 필요)

---

## 주의

- 이 절차는 환경마다 반복하지 않습니다. **버킷 1개**를 만들고, 그 안에서 `key`(예: `dev/infra/...`, `prod/infra/...`)로 환경·레이어별 state가 나뉩니다.
- 실제 버킷명·계정 정보는 팀 내부 채널로만 공유하고, 공개 문서·커밋에는 남기지 마세요.
