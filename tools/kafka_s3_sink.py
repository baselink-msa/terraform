#!/usr/bin/env python3
"""Drain MSK Serverless topic messages into the existing S3/Athena event lake.

This is a bounded dev/demo sink runner. It intentionally reuses the same event
envelope and S3 partition layout as modules/ticket-event-writer so Athena and
Capacity Advisor can analyze events regardless of whether they came through the
legacy SQS/Lambda writer or the Kafka streaming path.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable
from uuid import UUID


REQUIRED_FIELDS = {
    "eventId",
    "eventType",
    "schemaVersion",
    "occurredAt",
    "producer",
    "aggregateType",
    "aggregateId",
    "payload",
}

SUPPORTED_EVENT_TYPES = {
    "WAITING_ENTERED",
    "ACCESS_TOKEN_ISSUED",
    "RESERVATION_REQUESTED",
    "RESERVATION_CONFIRMED",
    "ADMISSION_THROTTLE_APPLIED",
    "ADMISSION_STOP_APPLIED",
    "ADMISSION_THROTTLE_RECOVERED",
}


@dataclass(frozen=True)
class SinkResult:
    accepted: int = 0
    written: int = 0
    skipped: int = 0
    invalid: int = 0

    def add(self, **updates: int) -> "SinkResult":
        values = {
            "accepted": self.accepted,
            "written": self.written,
            "skipped": self.skipped,
            "invalid": self.invalid,
        }
        for key, value in updates.items():
            values[key] += value
        return SinkResult(**values)


def parse_event(line: str) -> tuple[dict[str, Any], datetime]:
    event = json.loads(line)
    if not isinstance(event, dict):
        raise ValueError("Event body must be a JSON object")

    missing = sorted(REQUIRED_FIELDS - event.keys())
    if missing:
        raise ValueError(f"Missing required fields: {', '.join(missing)}")
    if event["schemaVersion"] != 1:
        raise ValueError(f"Unsupported schemaVersion: {event['schemaVersion']}")
    if event["eventType"] not in SUPPORTED_EVENT_TYPES:
        raise ValueError(f"Unsupported eventType: {event['eventType']}")
    if not isinstance(event["payload"], dict):
        raise ValueError("payload must be a JSON object")

    event["eventId"] = str(UUID(str(event["eventId"])))
    occurred_at = datetime.fromisoformat(str(event["occurredAt"]).replace("Z", "+00:00"))
    if occurred_at.tzinfo is None:
        raise ValueError("occurredAt must include a timezone")
    return event, occurred_at.astimezone(timezone.utc)


def object_key(event: dict[str, Any], occurred_at: datetime, prefix: str) -> str:
    game_id = event.get("gameId")
    game_partition = str(game_id) if game_id is not None else "unknown"
    return (
        f"{prefix.strip('/')}/"
        f"event_date={occurred_at.date().isoformat()}/"
        f"event_type={event['eventType']}/"
        f"game_id={game_partition}/"
        f"{event['eventId']}.json"
    )


def _aws(arguments: list[str]) -> None:
    subprocess.run(["aws", *arguments], check=True)


def put_s3_event(
    event: dict[str, Any],
    key: str,
    bucket: str,
    region: str,
    dry_run: bool,
) -> None:
    body = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    if dry_run:
        print(json.dumps({"dryRun": True, "bucket": bucket, "key": key}, ensure_ascii=False))
        return

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(body)
        path = Path(handle.name)
    try:
        _aws(
            [
                "s3api",
                "put-object",
                "--bucket",
                bucket,
                "--key",
                key,
                "--body",
                str(path),
                "--content-type",
                "application/json",
                "--server-side-encryption",
                "AES256",
                "--region",
                region,
            ]
        )
    finally:
        path.unlink(missing_ok=True)


def sink_lines(
    lines: Iterable[str],
    bucket: str,
    prefix: str,
    region: str,
    dry_run: bool,
    producers: set[str],
) -> SinkResult:
    result = SinkResult()
    seen_event_ids: set[str] = set()
    for raw_line in lines:
        line = raw_line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            event, occurred_at = parse_event(line)
        except Exception as exc:
            print(json.dumps({"invalid": line, "reason": str(exc)}, ensure_ascii=False))
            result = result.add(invalid=1)
            continue

        if producers and event["producer"] not in producers:
            result = result.add(skipped=1)
            continue
        if event["eventId"] in seen_event_ids:
            result = result.add(skipped=1)
            continue

        key = object_key(event, occurred_at, prefix)
        put_s3_event(event, key, bucket, region, dry_run)
        seen_event_ids.add(event["eventId"])
        result = result.add(accepted=1, written=0 if dry_run else 1)
    return result


def consume_with_kubectl(args: argparse.Namespace) -> list[str]:
    topics = " ".join(args.topics)
    group_id = f"{args.group_id_prefix}-{int(time.time())}"
    pod_name = f"kafka-s3-sink-{int(time.time())}"
    command = f"""
set -eu
echo "KAFKA_S3_SINK_START topics={topics}"
mkdir -p /tmp/msk
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o /tmp/msk/aws-msk-iam-auth.jar https://github.com/aws/aws-msk-iam-auth/releases/download/v2.2.0/aws-msk-iam-auth-2.2.0-all.jar
else
  wget -q -O /tmp/msk/aws-msk-iam-auth.jar https://github.com/aws/aws-msk-iam-auth/releases/download/v2.2.0/aws-msk-iam-auth-2.2.0-all.jar
fi
ls -l /opt/kafka/bin/kafka-console-consumer.sh
cat >/tmp/client.properties <<'EOF'
security.protocol=SASL_SSL
sasl.mechanism=AWS_MSK_IAM
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required;
sasl.client.callback.handler.class=software.amazon.msk.auth.iam.IAMClientCallbackHandler
EOF
export CLASSPATH=/tmp/msk/aws-msk-iam-auth.jar
for topic in {topics}; do
  /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server {args.bootstrap_server} \
    --consumer.config /tmp/client.properties \
    --topic "$topic" \
    --group {group_id} \
    --from-beginning \
    --timeout-ms {args.topic_timeout_ms} || true
done
"""
    manifest = {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": pod_name, "namespace": args.namespace},
        "spec": {
            "serviceAccountName": args.service_account,
            "restartPolicy": "Never",
            "containers": [
                {
                    "name": "consumer",
                    "image": args.kafka_image,
                    "command": ["sh", "-lc", command],
                }
            ],
        },
    }
    try:
        subprocess.run(
            ["kubectl", "apply", "-f", "-"],
            input=json.dumps(manifest),
            text=True,
            check=True,
        )
        logs = subprocess.run(
            [
                "kubectl",
                "logs",
                pod_name,
                "-n",
                args.namespace,
                "--follow",
                f"--pod-running-timeout={args.ready_timeout_seconds}s",
            ],
            capture_output=True,
            text=True,
            timeout=args.max_seconds,
            check=False,
        )
        if logs.returncode != 0 and not logs.stdout:
            status = subprocess.run(
                ["kubectl", "get", "pod", pod_name, "-n", args.namespace, "-o", "wide"],
                capture_output=True,
                text=True,
                check=False,
            )
            raise RuntimeError((logs.stderr + "\n" + status.stdout).strip())
        return logs.stdout.splitlines()
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        return stdout.splitlines()
    finally:
        if args.keep_pod:
            print(f"Keeping pod for debugging: {pod_name}", flush=True)
        else:
            subprocess.run(
                ["kubectl", "delete", "pod", pod_name, "-n", args.namespace, "--ignore-not-found=true"],
                check=False,
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--prefix", default="ticket-events")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--producer-in",
        default="ticket-service,waiting-room-service",
        help="Comma-separated producers to retain. Empty value keeps all supported producers.",
    )

    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input-jsonl", help="Read Kafka JSON lines from a local file.")
    source.add_argument("--consume", action="store_true", help="Consume from Kafka through a temporary Kubernetes pod.")

    parser.add_argument("--bootstrap-server")
    parser.add_argument("--topics", nargs="+", default=["ticket.domain.events", "waiting.operational.events"])
    parser.add_argument("--namespace", default="baselink-dev")
    parser.add_argument("--service-account", default="backend-runtime")
    parser.add_argument("--kafka-image", default="apache/kafka:3.7.2")
    parser.add_argument("--group-id-prefix", default="baselink-kafka-s3-sink")
    parser.add_argument("--topic-timeout-ms", type=int, default=30000)
    parser.add_argument("--ready-timeout-seconds", type=int, default=120)
    parser.add_argument("--max-seconds", type=int, default=90)
    parser.add_argument("--keep-pod", action="store_true")
    args = parser.parse_args()

    producers = {item.strip() for item in args.producer_in.split(",") if item.strip()}
    if args.consume:
        if not args.bootstrap_server:
            parser.error("--bootstrap-server is required with --consume")
        lines = consume_with_kubectl(args)
    else:
        lines = Path(args.input_jsonl).read_text(encoding="utf-8").splitlines()

    result = sink_lines(lines, args.bucket, args.prefix, args.region, args.dry_run, producers)
    print(json.dumps(result.__dict__, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
