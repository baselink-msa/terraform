import importlib.util
import json
import sys
import unittest
from pathlib import Path


PATH = Path(__file__).parents[1] / "kafka_s3_sink.py"
SPEC = importlib.util.spec_from_file_location("kafka_s3_sink", PATH)
sink = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sink
SPEC.loader.exec_module(sink)


class KafkaS3SinkTest(unittest.TestCase):
    def event(self, **overrides):
        values = {
            "eventId": "e9104823-50a2-4cca-b9bb-f63dc268f45a",
            "eventType": "RESERVATION_REQUESTED",
            "schemaVersion": 1,
            "occurredAt": "2026-06-26T02:28:09.689020218Z",
            "producer": "ticket-service",
            "aggregateType": "RESERVATION",
            "aggregateId": "4715",
            "gameId": 1,
            "payload": {"reservationId": 4715},
        }
        values.update(overrides)
        return values

    def test_builds_same_partition_key_as_event_writer(self):
        event, occurred_at = sink.parse_event(json.dumps(self.event()))

        key = sink.object_key(event, occurred_at, "ticket-events")

        self.assertEqual(
            "ticket-events/event_date=2026-06-26/"
            "event_type=RESERVATION_REQUESTED/game_id=1/"
            "e9104823-50a2-4cca-b9bb-f63dc268f45a.json",
            key,
        )

    def test_rejects_unsupported_event_type(self):
        with self.assertRaises(ValueError):
            sink.parse_event(json.dumps(self.event(eventType="UNSUPPORTED")))

    def test_accepts_capacity_signal_event_type(self):
        event, occurred_at = sink.parse_event(
            json.dumps(
                self.event(
                    eventType="ADMISSION_THROTTLE_APPLIED",
                    producer="waiting-room-service",
                    aggregateType="CAPACITY_SIGNAL",
                    aggregateId="game-9001",
                    gameId=9001,
                    payload={
                        "reason": "RDS_CONNECTION_PRESSURE",
                        "dbPressureLevel": "CAUTION",
                        "currentDbConnections": 43,
                        "dbConnectionBudget": 60,
                        "dbThrottlePercent": 75,
                        "effectiveEnterPerMinute": 30,
                    },
                )
            )
        )

        key = sink.object_key(event, occurred_at, "ticket-events")

        self.assertIn("event_type=ADMISSION_THROTTLE_APPLIED", key)
        self.assertIn("game_id=9001", key)

    def test_accepts_seat_lock_event_type(self):
        event, occurred_at = sink.parse_event(
            json.dumps(
                self.event(
                    eventType="SEAT_LOCKED",
                    producer="seat-lock-service",
                    aggregateType="SEAT_LOCK",
                    aggregateId="game-9001:seat-123",
                    gameId=9001,
                    payload={
                        "gameId": 9001,
                        "seatId": 123,
                        "status": "LOCKED",
                        "lockTtlSeconds": 300,
                    },
                )
            )
        )

        key = sink.object_key(event, occurred_at, "ticket-events")

        self.assertIn("event_type=SEAT_LOCKED", key)
        self.assertIn("game_id=9001", key)

    def test_dry_run_skips_non_selected_producer(self):
        lines = [
            json.dumps(self.event(producer="ticket-service")),
            json.dumps(
                self.event(
                    eventId="37f40a97-5d0e-4c49-9efa-230d62b3ce2b",
                    producer="capacity-load-test",
                )
            ),
        ]

        original_put_s3_event = sink.put_s3_event
        sink.put_s3_event = lambda *args, **kwargs: None
        try:
            result = sink.sink_lines(
                lines,
                bucket="example",
                prefix="ticket-events",
                region="ap-northeast-2",
                dry_run=True,
                producers={"ticket-service"},
            )
        finally:
            sink.put_s3_event = original_put_s3_event

        self.assertEqual(1, result.accepted)
        self.assertEqual(1, result.skipped)
        self.assertEqual(0, result.written)


if __name__ == "__main__":
    unittest.main()
