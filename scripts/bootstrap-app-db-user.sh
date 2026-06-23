#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$TERRAFORM_ROOT/env/dev/infra"

REGION="${AWS_REGION:-ap-northeast-2}"
NAMESPACE="${KUBERNETES_NAMESPACE:-baselink-dev}"
APP_DB_USERNAME="${APP_DB_USERNAME:-baselink_app}"
BOOTSTRAP_SECRET="app-db-account-bootstrap"
BOOTSTRAP_JOB="app-db-account-bootstrap"

TMP_DIR="$(mktemp -d)"

cleanup() {
  kubectl delete job "$BOOTSTRAP_JOB" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "$BOOTSTRAP_SECRET" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  echo "[APP-DB] $1"
}

for command in aws kubectl terraform python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

APP_SECRET_ARN="$(cd "$INFRA_DIR" && terraform output -raw app_database_secret_arn)"
RDS_SECRET_ARN="$(cd "$INFRA_DIR" && terraform output -raw rds_master_user_secret_arn)"
RDS_ENDPOINT="$(cd "$INFRA_DIR" && terraform output -raw rds_endpoint)"
RDS_HOST="${RDS_ENDPOINT%%:*}"

log "Checking application credential secret."
if ! aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "$APP_SECRET_ARN" \
  --query SecretString \
  --output text >"$TMP_DIR/app-secret.json" 2>/dev/null; then
  APP_DB_PASSWORD="$(aws secretsmanager get-random-password \
    --region "$REGION" \
    --password-length 40 \
    --exclude-characters '"@/\\' \
    --query RandomPassword \
    --output text)"

  APP_DB_USERNAME="$APP_DB_USERNAME" APP_DB_PASSWORD="$APP_DB_PASSWORD" \
    python3 -c 'import json, os; print(json.dumps({"username": os.environ["APP_DB_USERNAME"], "password": os.environ["APP_DB_PASSWORD"]}))' \
    >"$TMP_DIR/app-secret.json"

  aws secretsmanager put-secret-value \
    --region "$REGION" \
    --secret-id "$APP_SECRET_ARN" \
    --secret-string "file://$TMP_DIR/app-secret.json" \
    >/dev/null
  log "Created the fixed application credential value in Secrets Manager."
else
  log "Reusing the existing application credential value."
fi

aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id "$RDS_SECRET_ARN" \
  --query SecretString \
  --output text >"$TMP_DIR/master-secret.json"

python3 - "$TMP_DIR/master-secret.json" "$TMP_DIR/app-secret.json" "$TMP_DIR/bootstrap.env" <<'PY'
import json
import pathlib
import sys

master = json.loads(pathlib.Path(sys.argv[1]).read_text())
app = json.loads(pathlib.Path(sys.argv[2]).read_text())

values = {
    "MASTER_USERNAME": master["username"],
    "MASTER_PASSWORD": master["password"],
    "APP_USERNAME": app["username"],
    "APP_PASSWORD": app["password"],
}

for key, value in values.items():
    if "\n" in value or "\r" in value:
        raise SystemExit(f"{key} contains an unsupported newline")

pathlib.Path(sys.argv[3]).write_text(
    "".join(f"{key}={value}\n" for key, value in values.items())
)
PY
chmod 600 "$TMP_DIR/bootstrap.env"

kubectl create namespace "$NAMESPACE" >/dev/null 2>&1 || true
kubectl create secret generic "$BOOTSTRAP_SECRET" \
  -n "$NAMESPACE" \
  --from-env-file="$TMP_DIR/bootstrap.env" \
  --dry-run=client \
  -o yaml |
  kubectl apply -f - >/dev/null

cat >"$TMP_DIR/job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $BOOTSTRAP_JOB
  namespace: $NAMESPACE
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: postgres
          image: postgres:16-alpine
          envFrom:
            - secretRef:
                name: $BOOTSTRAP_SECRET
          env:
            - name: PGHOST
              value: "$RDS_HOST"
            - name: PGPORT
              value: "5432"
            - name: PGDATABASE
              value: "baseball_platform"
            - name: PGSSLMODE
              value: "require"
          command:
            - /bin/sh
            - -ec
            - |
              export PGPASSWORD="\$MASTER_PASSWORD"
              psql \
                --username="\$MASTER_USERNAME" \
                --set=ON_ERROR_STOP=1 \
                --set=app_user="\$APP_USERNAME" \
                --set=app_password="\$APP_PASSWORD" \
                --set=master_user="\$MASTER_USERNAME" <<'SQL'
              SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
              WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec

              SELECT format(
                'ALTER ROLE %I WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
                :'app_user',
                :'app_password'
              ) \gexec

              GRANT CONNECT ON DATABASE baseball_platform TO :"app_user";
              GRANT USAGE ON SCHEMA auth_schema, game_schema, ticket_schema, order_schema, chatbot_schema TO :"app_user";
              GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA auth_schema, game_schema, ticket_schema, order_schema, chatbot_schema TO :"app_user";
              GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA auth_schema, game_schema, ticket_schema, order_schema, chatbot_schema TO :"app_user";
              GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth_schema, game_schema, ticket_schema, order_schema, chatbot_schema TO :"app_user";

              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA auth_schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA game_schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA ticket_schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA order_schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA chatbot_schema GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";

              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA auth_schema GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA game_schema GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA ticket_schema GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA order_schema GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA chatbot_schema GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"app_user";

              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA auth_schema GRANT EXECUTE ON FUNCTIONS TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA game_schema GRANT EXECUTE ON FUNCTIONS TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA ticket_schema GRANT EXECUTE ON FUNCTIONS TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA order_schema GRANT EXECUTE ON FUNCTIONS TO :"app_user";
              ALTER DEFAULT PRIVILEGES FOR ROLE :"master_user" IN SCHEMA chatbot_schema GRANT EXECUTE ON FUNCTIONS TO :"app_user";
              SQL
EOF

kubectl delete job "$BOOTSTRAP_JOB" -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl apply -f "$TMP_DIR/job.yaml" >/dev/null

log "Creating or updating the PostgreSQL application account."
if ! kubectl wait \
  --for=condition=complete \
  "job/$BOOTSTRAP_JOB" \
  -n "$NAMESPACE" \
  --timeout=180s; then
  kubectl logs "job/$BOOTSTRAP_JOB" -n "$NAMESPACE" || true
  exit 1
fi

kubectl logs "job/$BOOTSTRAP_JOB" -n "$NAMESPACE"
log "Application database account bootstrap completed."
