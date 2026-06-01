## 업데이트

### 1. GitHub Actions 연동을 위한 AWS OIDC 설정
- **위치:** `modules/github-oidc`
- **설명:** 고정된 AWS Access Key 대신, OpenID Connect(OIDC) 방식을 도입하여 GitHub Actions 파이프라인이 AWS 리소스에 접근할 수 있도록 동적 ID 권한을 부여합니다.
- **신뢰 관계 대상:** `baselink-msa/baselink`