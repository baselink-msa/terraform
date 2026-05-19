# baselink-infra — Terraform 인프라 레포 (스캐폴드)

환경 구성 방식: **디렉터리 분리**
환경(dev/prod) × 레이어(infra/addon) 조합마다 폴더가 있고, 그 폴더 하나가 곧 `terraform apply` 단위입니다.

---

## 폴더 구조

```
baselink-infra/
├─ README.md
├─ BOOTSTRAP.md              # state 버킷 부트스트랩 가이드 (1회 수동 절차)
├─ .gitignore
├─ modules/                  # 재사용 모듈 — '코드'만, state 없음
│  ├─ vpc/  eks/  eks-addons/  elasticache/
│  └─ rds/  sqs/  iam/  s3/
│       (각 모듈 = main.tf · variables.tf · outputs.tf)
└─ environments/             # 환경 × 레이어 = 실제 apply 단위
   ├─ dev/
   │  ├─ infra/   # 레이어1: AWS 자원 전부 (vpc·eks·elasticache·rds·sqs·iam·s3)
   │  └─ addon/   # 레이어2: Helm (eks-addons)
   └─ prod/
      ├─ infra/
      └─ addon/
            (각 셀 = backend.tf · providers.tf · main.tf · variables.tf · outputs.tf)
            ※ terraform.tfvars 는 각자 로컬에서 생성 — .gitignore 대상이라 커밋 안 됨
```

---

## 모든 `.tf`는 빈 스텁입니다

`modules/`와 `environments/`의 모든 `.tf` 파일은 헤더 주석만 있는 **빈 스텁**입니다. 각 담당자가 자신의 모듈/레이어를 채웁니다.

> 모듈 담당 분담은 **팀 내부 문서**를 참고하세요. (이 레포에는 담당자 정보를 포함하지 않습니다)

---

## 초기 세팅 순서

> 사전 요구: **Terraform 1.10 이상** (`backend.tf`의 `use_lockfile` 때문). `terraform version`으로 확인.

1. **tfstate용 S3 버킷을 1회 수동 생성** — 절차는 `BOOTSTRAP.md` 참고 (버저닝 · 퍼블릭 접근 차단 · 기본 암호화 포함).
2. 각 `environments/<env>/<layer>/backend.tf`의 `bucket` 값을 1번에서 만든 버킷명으로 교체.
3. 각 셀에 `terraform.tfvars`를 직접 생성해 값을 채움. 필요한 변수는 그 셀의 `variables.tf`를 참고하고, 값은 팀 채널 공유본을 사용. (`terraform.tfvars`는 .gitignore 대상 — 커밋 안 됨)
4. 각 셀에서: `terraform init` → `terraform fmt` → `terraform validate` → `terraform plan` → `terraform apply`.
5. **apply 순서: infra 레이어 먼저 → addon 레이어.** (addon은 클러스터가 있어야 helm provider가 동작)
