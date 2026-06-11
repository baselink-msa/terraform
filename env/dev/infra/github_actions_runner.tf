data "aws_ami" "github_actions_runner" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_iam_policy_document" "github_actions_runner_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_actions_runner" {
  name               = "${local.name_prefix}-github-actions-runner"
  assume_role_policy = data.aws_iam_policy_document.github_actions_runner_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "github_actions_runner_ssm" {
  role       = aws_iam_role.github_actions_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "github_actions_runner" {
  name = "${local.name_prefix}-github-actions-runner"
  role = aws_iam_role.github_actions_runner.name
}

resource "aws_security_group" "github_actions_runner" {
  name        = "${local.name_prefix}-github-actions-runner"
  description = "GitHub Actions self-hosted runner without inbound access"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-actions-runner"
  })
}

resource "aws_vpc_security_group_egress_rule" "github_actions_runner_all" {
  security_group_id = aws_security_group.github_actions_runner.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound access for GitHub, AWS APIs, package repositories, and EKS API"
}

resource "aws_vpc_security_group_ingress_rule" "eks_api_from_github_actions_runner" {
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.github_actions_runner.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "EKS API access from GitHub Actions self-hosted runner"
}

resource "aws_instance" "github_actions_runner" {
  ami                         = data.aws_ami.github_actions_runner.id
  instance_type               = var.github_actions_runner_instance_type
  subnet_id                   = module.vpc.private_app_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.github_actions_runner.id]
  iam_instance_profile        = aws_iam_instance_profile.github_actions_runner.name
  associate_public_ip_address = false
  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
    ]
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
#!/bin/bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl unzip tar git jq gnupg lsb-release software-properties-common nodejs npm

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" > /etc/apt/sources.list.d/hashicorp.list
apt-get update
apt-get install -y terraform

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

useradd --create-home --shell /bin/bash actions-runner
install -d -o actions-runner -g actions-runner /opt/actions-runner
install -d /opt/baselink

cat >/opt/baselink/register-github-runner.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <github-owner/repo> <registration-token>"
  echo "Example: $0 baselink-msa/terraform AABCD..."
  exit 1
fi

REPO="$1"
TOKEN="$2"
RUNNER_DIR="/opt/actions-runner"
RUNNER_USER="actions-runner"
LABELS="baselink-dev,iac"
RUNNER_NAME="$(hostname)-baselink-dev-iac"

cd "$RUNNER_DIR"

if [ ! -f ./config.sh ]; then
  LATEST_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name | sub("^v"; "")')"
  curl -fsSL "https://github.com/actions/runner/releases/download/v$LATEST_VERSION/actions-runner-linux-x64-$LATEST_VERSION.tar.gz" -o /tmp/actions-runner.tar.gz
  tar xzf /tmp/actions-runner.tar.gz
  ./bin/installdependencies.sh
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"
fi

if systemctl is-active --quiet actions.runner.*.service 2>/dev/null; then
  echo "GitHub Actions runner service is already active."
  exit 0
fi

sudo -u "$RUNNER_USER" ./config.sh \
  --url "https://github.com/$REPO" \
  --token "$TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$LABELS" \
  --work "_work" \
  --unattended \
  --replace

./svc.sh install "$RUNNER_USER"
./svc.sh start
SCRIPT

chmod +x /opt/baselink/register-github-runner.sh
chown root:root /opt/baselink/register-github-runner.sh
EOF

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-actions-runner"
    Role = "github-actions-runner"
  })

  depends_on = [
    aws_iam_role_policy_attachment.github_actions_runner_ssm,
  ]
}
