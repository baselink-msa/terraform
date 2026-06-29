#!/usr/bin/env python3
"""Record SQS worker state as an infra audit event in the S3/Athena event lake."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from kafka_s3_sink import object_key, parse_event, put_s3_event
from ticket_capacity_advisor import SqsWorkerSummary, collect_sqs_worker_summary


def event_type_for_status(status: str) -> str:
    if status == "DLQ_DETECTED":
        return "SQS_DLQ_DETECTED"
    if status in {"BACKLOG", "DELAYED"}:
        return "SQS_BACKLOG_DETECTED"
    return "SQS_WORKER_STATUS_RECORDED"


def build_sqs_worker_audit_event(
    summary: SqsWorkerSummary,
    producer: str = "sqs-worker-audit-recorder",
) -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    payload = {
        "status": summary.status,
        "sourceQueueName": summary.source_queue_name,
        "dlqQueueName": summary.dlq_queue_name,
        "visibleMessages": summary.visible_messages,
        "notVisibleMessages": summary.not_visible_messages,
        "oldestMessageAgeSeconds": summary.oldest_message_age_seconds,
        "dlqVisibleMessages": summary.dlq_visible_messages,
        "dlqOldestMessageAgeSeconds": summary.dlq_oldest_message_age_seconds,
        "reason": summary.error or f"SQS worker status is {summary.status}.",
    }
    return {
        "eventId": str(uuid4()),
        "eventType": event_type_for_status(summary.status),
        "schemaVersion": 1,
        "occurredAt": now.isoformat().replace("+00:00", "Z"),
        "producer": producer,
        "aggregateType": "INFRA_AUDIT",
        "aggregateId": f"sqs-worker:{summary.source_queue_name}",
        "gameId": None,
        "userKey": None,
        "traceId": None,
        "payload": payload,
    }


def write_event(
    event: dict[str, Any],
    bucket: str,
    prefix: str,
    region: str,
    dry_run: bool,
) -> str:
    _, occurred_at = parse_event(json.dumps(event))
    key = object_key(event, occurred_at, prefix)
    put_s3_event(event, key, bucket, region, dry_run)
    return key


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--prefix", default="ticket-events")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--source-queue-name", default="ticket-confirm-queue")
    parser.add_argument("--dlq-name", default="ticket-confirm-dlq")
    parser.add_argument("--backlog-threshold", type=int, default=10)
    parser.add_argument("--oldest-age-threshold-seconds", type=int, default=300)
    parser.add_argument("--dlq-threshold", type=int, default=1)
    parser.add_argument("--producer", default="sqs-worker-audit-recorder")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    summary = collect_sqs_worker_summary(
        args.source_queue_name,
        args.dlq_name,
        args.region,
        args.backlog_threshold,
        args.oldest_age_threshold_seconds,
        args.dlq_threshold,
    )
    event = build_sqs_worker_audit_event(summary, args.producer)
    key = write_event(event, args.bucket, args.prefix, args.region, args.dry_run)
    print(
        json.dumps(
            {
                "summary": asdict(summary),
                "eventType": event["eventType"],
                "bucket": args.bucket,
                "key": key,
                "dryRun": args.dry_run,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
