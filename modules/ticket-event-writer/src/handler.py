import json
import logging
import os
from datetime import datetime, timezone
from uuid import UUID

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

S3 = boto3.client("s3")
EVENT_BUCKET = os.environ["EVENT_BUCKET"]
EVENT_PREFIX = os.getenv("EVENT_PREFIX", "ticket-events").strip("/")

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
    "SEAT_LOCK_REQUESTED",
    "SEAT_LOCKED",
    "SEAT_LOCK_FAILED",
    "SEAT_UNLOCKED",
    "KAFKA_PRODUCE_FAILED",
    "KAFKA_S3_SINK_DELAYED",
    "KAFKA_EVENT_SKIPPED",
    "KAFKA_EVENT_INVALID",
    "KAFKA_S3_SINK_COMPLETED",
    "SQS_WORKER_STATUS_RECORDED",
    "SQS_BACKLOG_DETECTED",
    "SQS_DLQ_DETECTED",
}


def _parse_event(body):
    event = json.loads(body)
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
    occurred_at = datetime.fromisoformat(
        str(event["occurredAt"]).replace("Z", "+00:00")
    )
    if occurred_at.tzinfo is None:
        raise ValueError("occurredAt must include a timezone")
    occurred_at = occurred_at.astimezone(timezone.utc)
    return event, occurred_at


def _object_key(event, occurred_at):
    game_id = event.get("gameId")
    game_partition = str(game_id) if game_id is not None else "unknown"
    return (
        f"{EVENT_PREFIX}/"
        f"event_date={occurred_at.date().isoformat()}/"
        f"event_type={event['eventType']}/"
        f"game_id={game_partition}/"
        f"{event['eventId']}.json"
    )


def _write_record(record):
    event, occurred_at = _parse_event(record["body"])
    key = _object_key(event, occurred_at)
    S3.put_object(
        Bucket=EVENT_BUCKET,
        Key=key,
        Body=json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        ),
        ContentType="application/json",
        ServerSideEncryption="AES256",
    )
    LOGGER.info(
        "Ticket event stored: eventId=%s eventType=%s key=%s",
        event["eventId"],
        event["eventType"],
        key,
    )


def lambda_handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        message_id = record.get("messageId", "unknown")
        try:
            _write_record(record)
        except Exception:
            LOGGER.exception("Ticket event write failed: messageId=%s", message_id)
            failures.append({"itemIdentifier": message_id})

    return {"batchItemFailures": failures}
