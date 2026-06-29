import importlib.util
import unittest
from pathlib import Path


PATH = Path(__file__).parents[1] / "slack_capacity_advisor_notify.py"
SPEC = importlib.util.spec_from_file_location("slack_capacity_advisor_notify", PATH)
notify = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notify)


class SlackCapacityAdvisorNotifyTest(unittest.TestCase):
    def report(self, **overrides):
        values = {
            "generatedAt": "2026-06-29T01:00:00+00:00",
            "gameId": 9001,
            "status": "RECOMMENDED",
            "confidence": "HIGH",
            "currentPolicyEnterPerMinute": 40,
            "recommendedPolicyEnterPerMinute": 18,
            "effectiveEnterPerMinuteNow": 18,
            "currentDbConnections": 22,
            "dbConnectionBudget": 60,
            "dbPressureLevel": "NORMAL",
            "samples": {
                "waitingEntered": 394,
                "accessTokensIssued": 154,
                "reservationRequested": 128,
                "reservationConfirmed": 127,
            },
            "reasons": [
                "안정 구간 예약 확정 처리량은 분당 23.00건입니다.",
                "예약 요청 대비 확정률은 99.2%입니다.",
            ],
            "capacitySignals": {
                "throttle_applied": 2,
                "stop_applied": 1,
                "throttle_recovered": 1,
                "latest_event_type": "ADMISSION_THROTTLE_RECOVERED",
                "latest_occurred_at": "2026-06-29T00:59:00Z",
                "latest_db_pressure_level": "NORMAL",
                "latest_current_db_connections": 18,
                "latest_db_connection_budget": 60,
                "latest_db_throttle_percent": 100,
                "latest_effective_enter_per_minute": 40,
            },
            "sqsWorker": {
                "source_queue_name": "ticket-confirm-queue",
                "dlq_queue_name": "ticket-confirm-dlq",
                "status": "HEALTHY",
                "visible_messages": 0,
                "not_visible_messages": 0,
                "oldest_message_age_seconds": 0,
                "dlq_visible_messages": 0,
                "dlq_oldest_message_age_seconds": 0,
                "backlog_threshold": 10,
                "oldest_age_threshold_seconds": 300,
                "dlq_threshold": 1,
            },
            "valkeyStatus": {
                "cluster_ids": ["baselink-dev-redis-001", "baselink-dev-redis-002"],
                "replica_cluster_ids": ["baselink-dev-redis-002"],
                "status": "HEALTHY",
                "max_engine_cpu_percent": 12.5,
                "max_memory_usage_percent": 34.1,
                "total_evictions": 0,
                "max_replication_lag_seconds": 0.0,
                "lookback_minutes": 15,
                "cpu_threshold_percent": 80,
                "memory_threshold_percent": 80,
                "replication_lag_threshold_seconds": 5,
                "eviction_threshold": 0,
            },
            "kafkaPipelineHealth": {
                "status": "HEALTHY",
                "lookback_days": 1,
                "expected_producers": ["ticket-service", "waiting-room-service"],
                "expected_event_types": [
                    "WAITING_ENTERED",
                    "ACCESS_TOKEN_ISSUED",
                    "RESERVATION_REQUESTED",
                    "RESERVATION_CONFIRMED",
                ],
                "total_events": 24,
                "latest_occurred_at": "2026-06-29T00:59:00Z",
                "producer_counts": {
                    "ticket-service": 12,
                    "waiting-room-service": 12,
                },
                "event_type_counts": {
                    "WAITING_ENTERED": 6,
                    "ACCESS_TOKEN_ISSUED": 6,
                    "RESERVATION_REQUESTED": 6,
                    "RESERVATION_CONFIRMED": 6,
                },
                "missing_producers": [],
                "missing_event_types": [],
                "producer_failures": 0,
                "invalid_events": 0,
                "skipped_events": 0,
                "sink_completed_events": 1,
                "stale_after_hours": 24,
            },
        }
        values.update(overrides)
        return values

    def payload_text(self, report):
        payload = notify.build_slack_payload(report, "https://example.com/report")
        return "\n".join(
            block.get("text", {}).get("text", "")
            for block in payload["blocks"]
            if isinstance(block.get("text"), dict)
        )

    def test_payload_contains_recommendation_and_capacity_signals(self):
        payload = notify.build_slack_payload(self.report(), "https://example.com/report")
        text = self.payload_text(self.report())

        self.assertIn("Game 9001 Capacity Advisor", payload["text"])
        self.assertIn("추천 18명/분", payload["text"])
        self.assertIn("최근 감속/복구 신호", text)
        self.assertIn("ADMISSION_THROTTLE_RECOVERED", text)
        self.assertIn("18/60", text)
        self.assertIn("SQS/Worker 상태", text)
        self.assertIn("ticket-confirm-queue", text)
        self.assertIn("Valkey/좌석 잠금 계층 상태", text)
        self.assertIn("baselink-dev-redis-001", text)
        self.assertIn("Kafka 파이프라인 상태", text)
        self.assertIn("ticket-service=12", text)

    def test_payload_explains_when_no_capacity_signals_exist(self):
        report = self.report(
            capacitySignals={
                "throttle_applied": 0,
                "stop_applied": 0,
                "throttle_recovered": 0,
            }
        )

        text = self.payload_text(report)

        self.assertIn("감속/복구 이벤트가 없습니다", text)

    def test_warning_emoji_for_insufficient_data(self):
        report = self.report(
            status="INSUFFICIENT_DATA",
            recommendedPolicyEnterPerMinute=None,
            effectiveEnterPerMinuteNow=None,
        )

        self.assertEqual(":warning:", notify.status_emoji(report))

    def test_dlq_status_uses_incident_emoji(self):
        report = self.report(
            sqsWorker={
                "status": "DLQ_DETECTED",
                "source_queue_name": "ticket-confirm-queue",
                "dlq_queue_name": "ticket-confirm-dlq",
                "visible_messages": 0,
                "not_visible_messages": 0,
                "oldest_message_age_seconds": 0,
                "dlq_visible_messages": 1,
            }
        )

        text = self.payload_text(report)

        self.assertEqual(":rotating_light:", notify.status_emoji(report))
        self.assertIn("DLQ_DETECTED", text)

    def test_valkey_evictions_use_incident_emoji(self):
        report = self.report(
            valkeyStatus={
                "status": "EVICTIONS_DETECTED",
                "cluster_ids": ["baselink-dev-redis-001"],
                "replica_cluster_ids": [],
                "max_engine_cpu_percent": 20.0,
                "max_memory_usage_percent": 30.0,
                "total_evictions": 1,
                "max_replication_lag_seconds": 0.0,
            }
        )

        text = self.payload_text(report)

        self.assertEqual(":rotating_light:", notify.status_emoji(report))
        self.assertIn("EVICTIONS_DETECTED", text)

    def test_valkey_cpu_high_uses_warning_emoji(self):
        report = self.report(
            valkeyStatus={
                "status": "CPU_HIGH",
                "cluster_ids": ["baselink-dev-redis-001"],
                "replica_cluster_ids": [],
                "max_engine_cpu_percent": 81.0,
                "max_memory_usage_percent": 30.0,
                "total_evictions": 0,
                "max_replication_lag_seconds": 0.0,
            }
        )

        self.assertEqual(":large_yellow_circle:", notify.status_emoji(report))

    def test_kafka_producer_failure_uses_incident_emoji(self):
        report = self.report(
            kafkaPipelineHealth={
                "status": "PRODUCER_FAILURE",
                "total_events": 10,
                "latest_occurred_at": "2026-06-29T00:59:00Z",
                "producer_counts": {"ticket-service": 10},
                "event_type_counts": {"KAFKA_PRODUCE_FAILED": 1},
                "missing_producers": [],
                "missing_event_types": [],
                "producer_failures": 1,
                "invalid_events": 0,
                "skipped_events": 0,
                "sink_completed_events": 0,
            }
        )

        text = self.payload_text(report)

        self.assertEqual(":rotating_light:", notify.status_emoji(report))
        self.assertIn("PRODUCER_FAILURE", text)

    def test_kafka_partial_pipeline_uses_warning_emoji(self):
        report = self.report(
            kafkaPipelineHealth={
                "status": "PARTIAL",
                "total_events": 12,
                "latest_occurred_at": "2026-06-29T00:59:00Z",
                "producer_counts": {"ticket-service": 12},
                "event_type_counts": {"RESERVATION_REQUESTED": 12},
                "missing_producers": ["waiting-room-service"],
                "missing_event_types": ["ACCESS_TOKEN_ISSUED"],
                "producer_failures": 0,
                "invalid_events": 0,
                "skipped_events": 0,
                "sink_completed_events": 0,
            }
        )

        text = self.payload_text(report)

        self.assertEqual(":large_yellow_circle:", notify.status_emoji(report))
        self.assertIn("waiting-room-service", text)
        self.assertIn("ACCESS_TOKEN_ISSUED", text)


if __name__ == "__main__":
    unittest.main()
