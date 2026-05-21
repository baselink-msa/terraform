# VPC Module

이 모듈은 dev/prod 환경에서 공통으로 사용할 VPC 네트워크 기반을 만든다.

현재 dev 환경에서는 Baselink 프로젝트의 EKS, Public ALB, RDS, Redis 같은 리소스가 올라갈 네트워크를 준비하는 역할을 한다.

## 생성 리소스

- VPC
- Internet Gateway
- Public Subnet
- Private App Subnet
- Private Data Subnet
- NAT Gateway
- Elastic IP for NAT Gateway
- Public Route Table
- Private Route Table
- Route Table Association

## 네트워크 구조

dev 기본값은 아래와 같다.

```text
VPC
- CIDR: 10.0.0.0/16

ap-northeast-2a
- Public Subnet A:      10.0.0.0/24
- Private App Subnet A: 10.0.20.0/24
- Private Data Subnet A: 10.0.40.0/24

ap-northeast-2c
- Public Subnet C:      10.0.10.0/24
- Private App Subnet C: 10.0.30.0/24
- Private Data Subnet C: 10.0.50.0/24
```

## Subnet 용도

### Public Subnet

인터넷과 직접 연결되는 리소스를 배치한다.

예상 용도:

- Public ALB
- NAT Gateway
- 필요 시 운영 테스트용 public EC2

Public subnet에는 아래 Kubernetes 태그가 붙는다.

```hcl
"kubernetes.io/role/elb" = "1"
```

이 태그는 AWS Load Balancer Controller가 internet-facing ALB를 만들 때 public subnet을 찾는 데 사용한다.

### Private App Subnet

애플리케이션 실행 영역이다.

예상 용도:

- EKS worker node
- Backend pod
- Internal service

Private app subnet에는 아래 Kubernetes 태그가 붙는다.

```hcl
"kubernetes.io/role/internal-elb" = "1"
```

이 태그는 internal load balancer를 만들 때 사용된다.

### Private Data Subnet

데이터 계층 리소스를 배치한다.

예상 용도:

- RDS PostgreSQL
- ElastiCache Redis
- 기타 외부 직접 노출이 없어야 하는 데이터 리소스

## Routing

Public subnet은 Internet Gateway를 통해 인터넷과 통신한다.

```text
Public Subnet
-> Public Route Table
-> Internet Gateway
-> Internet
```

Private app/data subnet은 NAT Gateway를 통해 외부로 나간다.

```text
Private Subnet
-> Private Route Table
-> NAT Gateway
-> Internet Gateway
-> Internet
```

NAT Gateway는 비용이 발생하므로 dev 기본값은 `single_nat_gateway = true`이다.

이 경우 NAT Gateway는 첫 번째 public subnet에만 1개 생성되고, 모든 private subnet이 이 NAT Gateway를 공유한다.

## EKS 연동 태그

`eks_cluster_name`을 입력하면 subnet에 아래 태그가 추가된다.

```hcl
"kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
```

EKS 클러스터 이름이 아직 정해지지 않았다면 빈 문자열로 두면 된다.

## 주요 입력 변수

| Variable | Description |
| --- | --- |
| `project_name` | 리소스 이름 prefix에 사용할 프로젝트 이름 |
| `environment` | dev/prod 같은 환경 이름 |
| `vpc_cidr` | VPC CIDR |
| `availability_zones` | subnet을 생성할 AZ 목록 |
| `public_subnet_cidrs` | public subnet CIDR 목록 |
| `private_app_subnet_cidrs` | private app subnet CIDR 목록 |
| `private_data_subnet_cidrs` | private data subnet CIDR 목록 |
| `enable_nat_gateway` | NAT Gateway 생성 여부 |
| `single_nat_gateway` | NAT Gateway를 1개만 만들지 여부 |
| `eks_cluster_name` | EKS subnet discovery tag에 사용할 클러스터 이름 |

## 주요 출력값

| Output | Description |
| --- | --- |
| `vpc_id` | 생성된 VPC ID |
| `public_subnet_ids` | Public subnet ID 목록 |
| `private_app_subnet_ids` | Private app subnet ID 목록 |
| `private_data_subnet_ids` | Private data subnet ID 목록 |
| `public_route_table_id` | Public route table ID |
| `private_route_table_id` | 첫 번째 private route table ID |
| `private_route_table_ids` | Private route table ID 목록 |
| `nat_gateway_id` | 첫 번째 NAT Gateway ID |
| `nat_gateway_ids` | NAT Gateway ID 목록 |
| `internet_gateway_id` | Internet Gateway ID |

## dev 환경 호출 위치

dev 환경에서는 아래 파일에서 이 모듈을 호출한다.

```text
env/dev/infra/main.tf
```

현재 backend state key는 아래 위치를 사용한다.

```text
dev/infra/terraform.tfstate
```

## 주의사항

- `enable_nat_gateway = true`이면 NAT Gateway 비용이 발생한다.
- `single_nat_gateway = true`는 dev 비용 절감에는 좋지만, 하나의 AZ 장애에 더 취약하다.
- prod에서는 가용성을 위해 AZ별 NAT Gateway 구성을 고려하는 것이 좋다.
- 팀 공통 태그 정책은 아직 합의 전이므로 이 모듈에는 공통 태그를 적용하지 않았다.
- Public ALB 직접 접근 제한은 이 모듈만으로 완성되지 않는다. ALB Security Group, CloudFront prefix list, Listener Rule header 검증과 함께 설계해야 한다.
