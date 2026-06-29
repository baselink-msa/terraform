import importlib.util
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import Mock


os.environ["EVENT_BUCKET"] = "test-ticket-events"
fake_s3 = Mock()
fake_boto3 = types.SimpleNamespace(client=lambda _service: fake_s3)
sys.modules["boto3"] = fake_boto3

HANDLER_PATH = Path(__file__).parents[1] / "src" / "handler.py"
SPEC = importlib.util.spec_from_file_location("ticket_event_writer_handler", HANDLER_PATH)
handler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(handler)


def envelope(
    event_id="019f1234-7abc-7000-9000-123456789abc",
    event_type="RESERVATION_CONFIRMED",
):
    return {
        "eventId": event_id,
        "eventType": event_type,
        "schemaVersion": 1,
        "occurredAt": "2026-06-22T01:02:03.456Z",
        "producer": "ticket-service",
        "aggregateType": "RESERVATION",
        "aggregateId": "381",
        "gameId": 1,
        "userKey": "sha256:test",
        "traceId": None,
        "payload": {"reservationId": 381, "status": "CONFIRMED"},
    }


class HandlerTest(unittest.TestCase):
    def setUp(self):
        fake_s3.reset_mock()

    def test_writes_partitioned_idempotent_object_key(self):
        result = handler.lambda_handler(
            {
                "Records": [
                    {"messageId": "message-1", "body": json.dumps(envelope())}
                ]
            },
            None,
        )

        self.assertEqual({"batchItemFailures": []}, result)
        _, kwargs = fake_s3.put_object.call_args
        self.assertEqual("test-ticket-events", kwargs["Bucket"])
        self.assertEqual(
            "ticket-events/event_date=2026-06-22/"
            "event_type=RESERVATION_CONFIRMED/game_id=1/"
            "019f1234-7abc-7000-9000-123456789abc.json",
            kwargs["Key"],
        )

    def test_returns_only_invalid_record_as_batch_failure(self):
        result = handler.lambda_handler(
            {
                "Records": [
                    {"messageId": "valid", "body": json.dumps(envelope())},
                    {"messageId": "invalid", "body": json.dumps({"eventId": "bad"})},
                ]
            },
            None,
        )

        self.assertEqual(
            {"batchItemFailures": [{"itemIdentifier": "invalid"}]},
            result,
        )
        self.assertEqual(1, fake_s3.put_object.call_count)

    def test_rejects_unsupported_schema_version(self):
        invalid = envelope()
        invalid["schemaVersion"] = 2

        result = handler.lambda_handler(
            {
                "Records": [
                    {"messageId": "invalid", "body": json.dumps(invalid)}
                ]
            },
            None,
        )

        self.assertEqual(
            {"batchItemFailures": [{"itemIdentifier": "invalid"}]},
            result,
        )
        fake_s3.put_object.assert_not_called()

    def test_accepts_seat_lock_event_type(self):
        seat_lock_event = envelope(event_type="SEAT_LOCKED")
        seat_lock_event["producer"] = "seat-lock-service"
        seat_lock_event["aggregateType"] = "SEAT_LOCK"
        seat_lock_event["aggregateId"] = "game-1:seat-123"
        seat_lock_event["payload"] = {"gameId": 1, "seatId": 123, "status": "LOCKED"}

        result = handler.lambda_handler(
            {
                "Records": [
                    {"messageId": "seat-lock", "body": json.dumps(seat_lock_event)}
                ]
            },
            None,
        )

        self.assertEqual({"batchItemFailures": []}, result)
        _, kwargs = fake_s3.put_object.call_args
        self.assertEqual(
            "ticket-events/event_date=2026-06-22/"
            "event_type=SEAT_LOCKED/game_id=1/"
            "019f1234-7abc-7000-9000-123456789abc.json",
            kwargs["Key"],
        )

    def test_accepts_infra_audit_event_type(self):
        audit_event = envelope(event_type="KAFKA_S3_SINK_COMPLETED")
        audit_event["producer"] = "kafka-s3-sink"
        audit_event["aggregateType"] = "INFRA_AUDIT"
        audit_event["aggregateId"] = "kafka-s3-sink:123"
        audit_event["gameId"] = None
        audit_event["payload"] = {
            "status": "COMPLETED",
            "accepted": 5,
            "written": 5,
            "skipped": 0,
            "invalid": 0,
        }

        result = handler.lambda_handler(
            {
                "Records": [
                    {"messageId": "infra-audit", "body": json.dumps(audit_event)}
                ]
            },
            None,
        )

        self.assertEqual({"batchItemFailures": []}, result)
        _, kwargs = fake_s3.put_object.call_args
        self.assertEqual(
            "ticket-events/event_date=2026-06-22/"
            "event_type=KAFKA_S3_SINK_COMPLETED/game_id=unknown/"
            "019f1234-7abc-7000-9000-123456789abc.json",
            kwargs["Key"],
        )


if __name__ == "__main__":
    unittest.main()
