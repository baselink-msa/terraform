import importlib.util
import unittest
from pathlib import Path


PATH = Path(__file__).parents[1] / "ticket_capacity_advisor.py"
SPEC = importlib.util.spec_from_file_location("ticket_capacity_advisor", PATH)
advisor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(advisor)


class CapacityAdvisorTest(unittest.TestCase):
    def inputs(self, **overrides):
        values = {
            "game_id": 1,
            "lookback_days": 7,
            "current_policy_enter_per_minute": 40,
            "waiting_entered": 200,
            "access_tokens_issued": 160,
            "reservation_requested": 120,
            "reservation_confirmed": 96,
            "stable_confirmed_per_minute": 30.0,
            "average_waiting_seconds": 60.0,
            "average_effective_enter_per_minute": 40.0,
            "current_db_connections": 20,
            "producer_filter": None,
            "producer_filters": (),
        }
        values.update(overrides)
        return advisor.CapacityInputs(**values)

    def test_recommends_policy_without_double_applying_normal_db_headroom(self):
        report = advisor.calculate_recommendation(self.inputs())

        self.assertEqual("RECOMMENDED", report["status"])
        self.assertEqual(30, report["recommendedPolicyEnterPerMinute"])
        self.assertEqual(30, report["effectiveEnterPerMinuteNow"])

    def test_current_db_pressure_only_changes_effective_value(self):
        normal = advisor.calculate_recommendation(self.inputs(current_db_connections=20))
        warning = advisor.calculate_recommendation(self.inputs(current_db_connections=52))

        self.assertEqual(
            normal["recommendedPolicyEnterPerMinute"],
            warning["recommendedPolicyEnterPerMinute"],
        )
        self.assertEqual(15, warning["effectiveEnterPerMinuteNow"])

    def test_stops_current_admission_at_budget(self):
        report = advisor.calculate_recommendation(
            self.inputs(current_db_connections=60)
        )

        self.assertEqual("STOP", report["dbPressureLevel"])
        self.assertEqual(0, report["effectiveEnterPerMinuteNow"])

    def test_withholds_recommendation_when_samples_are_insufficient(self):
        report = advisor.calculate_recommendation(
            self.inputs(
                access_tokens_issued=2,
                reservation_requested=3,
                reservation_confirmed=1,
            )
        )

        self.assertEqual("INSUFFICIENT_DATA", report["status"])
        self.assertIsNone(report["recommendedPolicyEnterPerMinute"])

    def test_limits_single_increase_to_twenty_five_percent(self):
        report = advisor.calculate_recommendation(
            self.inputs(
                current_policy_enter_per_minute=40,
                stable_confirmed_per_minute=100,
                average_effective_enter_per_minute=200,
            )
        )

        self.assertEqual(50, report["recommendedPolicyEnterPerMinute"])

    def test_report_contains_multi_producer_filter(self):
        report = advisor.calculate_recommendation(
            self.inputs(producer_filters=("ticket-service", "waiting-room-service"))
        )

        self.assertEqual(
            ["ticket-service", "waiting-room-service"],
            report["producerFilters"],
        )

    def test_report_includes_capacity_signal_summary(self):
        signals = advisor.CapacitySignalSummary(
            throttle_applied=2,
            stop_applied=1,
            throttle_recovered=1,
            latest_event_type="ADMISSION_THROTTLE_RECOVERED",
            latest_occurred_at="2026-06-29T01:00:00Z",
            latest_db_pressure_level="NORMAL",
            latest_current_db_connections=18,
            latest_db_connection_budget=60,
            latest_db_throttle_percent=100,
            latest_effective_enter_per_minute=40,
        )

        report = advisor.calculate_recommendation(
            self.inputs(),
            capacity_signals=signals,
        )
        markdown = advisor.markdown_report(report)

        self.assertEqual(2, report["capacitySignals"]["throttle_applied"])
        self.assertIn("## 최근 감속/복구 신호", markdown)
        self.assertIn("ADMISSION_THROTTLE_RECOVERED", markdown)
        self.assertIn("18/60", markdown)

    def test_report_explains_when_no_capacity_signals_exist(self):
        report = advisor.calculate_recommendation(self.inputs())
        markdown = advisor.markdown_report(report)

        self.assertIn("## 최근 감속/복구 신호", markdown)
        self.assertIn("감속/복구 이벤트가 없습니다", markdown)

    def test_report_includes_sqs_worker_summary(self):
        sqs_worker = advisor.SqsWorkerSummary(
            source_queue_name="ticket-confirm-queue",
            dlq_queue_name="ticket-confirm-dlq",
            status="BACKLOG",
            visible_messages=12,
            not_visible_messages=3,
            oldest_message_age_seconds=180,
            dlq_visible_messages=0,
            dlq_oldest_message_age_seconds=0,
        )

        report = advisor.calculate_recommendation(
            self.inputs(),
            sqs_worker=sqs_worker,
        )
        markdown = advisor.markdown_report(report)

        self.assertEqual("BACKLOG", report["sqsWorker"]["status"])
        self.assertIn("## SQS/Worker 처리 상태", markdown)
        self.assertIn("ticket-confirm-queue", markdown)
        self.assertIn("`12`", markdown)

    def test_sqs_worker_status_prioritizes_dlq_over_backlog(self):
        status = advisor._sqs_worker_status(
            visible_messages=12,
            not_visible_messages=0,
            oldest_message_age_seconds=0,
            dlq_visible_messages=1,
            backlog_threshold=10,
            oldest_age_threshold_seconds=300,
            dlq_threshold=1,
        )

        self.assertEqual("DLQ_DETECTED", status)

    def test_sqs_worker_status_detects_processing_without_backlog(self):
        status = advisor._sqs_worker_status(
            visible_messages=0,
            not_visible_messages=2,
            oldest_message_age_seconds=0,
            dlq_visible_messages=0,
            backlog_threshold=10,
            oldest_age_threshold_seconds=300,
            dlq_threshold=1,
        )

        self.assertEqual("PROCESSING", status)

    def test_aws_json_error_includes_cli_stderr(self):
        original_run = advisor.subprocess.run

        class FailedProcess:
            returncode = 254
            stdout = ""
            stderr = "An error occurred (AccessDenied) when calling the GetQueueAttributes operation"

        def fake_run(*args, **kwargs):
            return FailedProcess()

        advisor.subprocess.run = fake_run
        try:
            with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
                advisor._aws_json(["sqs", "get-queue-attributes"])
        finally:
            advisor.subprocess.run = original_run

    def test_queue_attributes_reads_oldest_age_from_cloudwatch_metric(self):
        original_aws_json = advisor._aws_json
        original_oldest_age = advisor._sqs_oldest_message_age
        calls = []

        def fake_aws_json(arguments):
            calls.append(arguments)
            if arguments[:2] == ["sqs", "get-queue-url"]:
                return {
                    "QueueUrl": "https://sqs.ap-northeast-2.amazonaws.com/740831361032/ticket-confirm-queue"
                }
            if arguments[:2] == ["sqs", "get-queue-attributes"]:
                return {
                    "Attributes": {
                        "ApproximateNumberOfMessages": "2",
                        "ApproximateNumberOfMessagesNotVisible": "1",
                    }
                }
            self.fail(f"unexpected aws call: {arguments}")

        def fake_oldest_age(queue_name, region):
            self.assertEqual("ticket-confirm-queue", queue_name)
            self.assertEqual("ap-northeast-2", region)
            return 42

        advisor._aws_json = fake_aws_json
        advisor._sqs_oldest_message_age = fake_oldest_age
        try:
            attributes = advisor._queue_attributes(
                "ticket-confirm-queue", "ap-northeast-2"
            )
        finally:
            advisor._aws_json = original_aws_json
            advisor._sqs_oldest_message_age = original_oldest_age

        self.assertEqual(
            {"visible": 2, "not_visible": 1, "oldest_age": 42},
            attributes,
        )
        get_attributes_call = calls[1]
        self.assertNotIn("ApproximateAgeOfOldestMessage", get_attributes_call)

    def test_sqs_oldest_message_age_uses_cloudwatch_metric(self):
        original_cloudwatch = advisor._cloudwatch_metric_statistics

        def fake_cloudwatch(**kwargs):
            self.assertEqual("AWS/SQS", kwargs["namespace"])
            self.assertEqual(
                "ApproximateAgeOfOldestMessage", kwargs["metric_name"]
            )
            self.assertEqual(
                {"QueueName": "ticket-confirm-queue"}, kwargs["dimensions"]
            )
            self.assertEqual("ap-northeast-2", kwargs["region"])
            self.assertEqual(("Maximum",), kwargs["statistics"])
            return [{"Maximum": 17.0}]

        advisor._cloudwatch_metric_statistics = fake_cloudwatch
        try:
            age = advisor._sqs_oldest_message_age(
                "ticket-confirm-queue", "ap-northeast-2"
            )
        finally:
            advisor._cloudwatch_metric_statistics = original_cloudwatch

        self.assertEqual(17, age)

    def test_report_includes_valkey_status_summary(self):
        valkey_status = advisor.ValkeyStatusSummary(
            cluster_ids=("baselink-dev-redis-001", "baselink-dev-redis-002"),
            replica_cluster_ids=("baselink-dev-redis-002",),
            status="HEALTHY",
            max_engine_cpu_percent=12.5,
            max_memory_usage_percent=34.1,
            total_evictions=0,
            max_replication_lag_seconds=0.0,
        )

        report = advisor.calculate_recommendation(
            self.inputs(),
            valkey_status=valkey_status,
        )
        markdown = advisor.markdown_report(report)

        self.assertEqual("HEALTHY", report["valkeyStatus"]["status"])
        self.assertIn("## Valkey/좌석 잠금 계층 상태", markdown)
        self.assertIn("baselink-dev-redis-001", markdown)
        self.assertIn("12.5%", markdown)

    def test_report_includes_kafka_pipeline_health_summary(self):
        kafka_health = advisor.KafkaPipelineHealthSummary(
            status="HEALTHY",
            lookback_days=1,
            total_events=24,
            latest_occurred_at="not-a-date",
            producer_counts={"ticket-service": 12, "waiting-room-service": 12},
            event_type_counts={
                "WAITING_ENTERED": 6,
                "ACCESS_TOKEN_ISSUED": 6,
                "RESERVATION_REQUESTED": 6,
                "RESERVATION_CONFIRMED": 6,
            },
            producer_failures=0,
            invalid_events=0,
            skipped_events=0,
            sink_completed_events=1,
        )

        report = advisor.calculate_recommendation(
            self.inputs(),
            kafka_pipeline_health=kafka_health,
        )
        markdown = advisor.markdown_report(report)

        self.assertEqual("HEALTHY", report["kafkaPipelineHealth"]["status"])
        self.assertIn("## Kafka 파이프라인 상태", markdown)
        self.assertIn("ticket-service=12", markdown)
        self.assertIn("RESERVATION_CONFIRMED=6", markdown)

    def test_report_includes_seat_lock_summary(self):
        seat_lock = advisor.SeatLockSummary(
            status="COMPETITION_DETECTED",
            requested=2,
            locked=1,
            failed=1,
            unlocked=1,
            success_rate_percent=50.0,
            failure_rate_percent=50.0,
            unlock_rate_percent=100.0,
            latest_event_type="SEAT_UNLOCKED",
            latest_occurred_at="2026-06-29T07:57:30Z",
            latest_seat_id=123,
        )

        report = advisor.calculate_recommendation(
            self.inputs(),
            seat_lock=seat_lock,
        )
        markdown = advisor.markdown_report(report)

        self.assertEqual("COMPETITION_DETECTED", report["seatLock"]["status"])
        self.assertIn("## 좌석 잠금 이벤트 상태", markdown)
        self.assertIn("SEAT_UNLOCKED", markdown)
        self.assertIn("50.0%", markdown)

    def test_seat_lock_status_detects_high_failure_rate(self):
        status = advisor._seat_lock_status(
            requested=10,
            failed=7,
            failure_rate_percent=70.0,
            failure_rate_threshold_percent=60,
        )

        self.assertEqual("FAILURE_RATE_HIGH", status)

    def test_valkey_status_prioritizes_evictions(self):
        status = advisor._valkey_status(
            max_engine_cpu_percent=90.0,
            max_memory_usage_percent=90.0,
            total_evictions=1,
            max_replication_lag_seconds=10.0,
            cpu_threshold_percent=80,
            memory_threshold_percent=80,
            replication_lag_threshold_seconds=5,
            eviction_threshold=0,
        )

        self.assertEqual("EVICTIONS_DETECTED", status)

    def test_valkey_status_detects_replication_lag_before_cpu(self):
        status = advisor._valkey_status(
            max_engine_cpu_percent=90.0,
            max_memory_usage_percent=10.0,
            total_evictions=0,
            max_replication_lag_seconds=5.0,
            cpu_threshold_percent=80,
            memory_threshold_percent=80,
            replication_lag_threshold_seconds=5,
            eviction_threshold=0,
        )

        self.assertEqual("REPLICATION_LAG", status)

    def test_kafka_pipeline_status_prioritizes_producer_failure(self):
        status = advisor._kafka_pipeline_status(
            total_events=20,
            missing_producers=(),
            missing_event_types=(),
            latest_occurred_at="not-a-date",
            producer_failures=1,
            invalid_events=0,
            stale_after_hours=24,
        )

        self.assertEqual("PRODUCER_FAILURE", status)

    def test_kafka_pipeline_status_detects_partial_event_lake(self):
        status = advisor._kafka_pipeline_status(
            total_events=20,
            missing_producers=("waiting-room-service",),
            missing_event_types=("ACCESS_TOKEN_ISSUED",),
            latest_occurred_at="not-a-date",
            producer_failures=0,
            invalid_events=0,
            stale_after_hours=24,
        )

        self.assertEqual("PARTIAL", status)

    def test_kafka_pipeline_status_detects_no_events(self):
        status = advisor._kafka_pipeline_status(
            total_events=0,
            missing_producers=("ticket-service",),
            missing_event_types=("RESERVATION_CONFIRMED",),
            latest_occurred_at=None,
            producer_failures=0,
            invalid_events=0,
            stale_after_hours=24,
        )

        self.assertEqual("NO_EVENTS", status)

    def test_csv_tuple_trims_empty_values(self):
        self.assertEqual(
            ("baselink-dev-redis-001", "baselink-dev-redis-002"),
            advisor._csv_tuple("baselink-dev-redis-001, baselink-dev-redis-002,"),
        )


if __name__ == "__main__":
    unittest.main()
