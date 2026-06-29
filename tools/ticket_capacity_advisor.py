#!/usr/bin/env python3
"""Generate an explainable ticket admission recommendation from Athena events."""

import argparse
import json
import math
import subprocess
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class CapacityInputs:
    game_id: int
    lookback_days: int
    current_policy_enter_per_minute: int
    waiting_entered: int
    access_tokens_issued: int
    reservation_requested: int
    reservation_confirmed: int
    stable_confirmed_per_minute: float
    average_waiting_seconds: float
    average_effective_enter_per_minute: float
    current_db_connections: int
    db_connection_budget: int = 60
    producer_filter: str | None = None
    producer_filters: tuple[str, ...] = ()


@dataclass(frozen=True)
class CapacitySignalSummary:
    throttle_applied: int = 0
    stop_applied: int = 0
    throttle_recovered: int = 0
    latest_event_type: str | None = None
    latest_occurred_at: str | None = None
    latest_db_pressure_level: str | None = None
    latest_current_db_connections: int | None = None
    latest_db_connection_budget: int | None = None
    latest_db_throttle_percent: int | None = None
    latest_effective_enter_per_minute: int | None = None


@dataclass(frozen=True)
class SqsWorkerSummary:
    source_queue_name: str = "ticket-confirm-queue"
    dlq_queue_name: str = "ticket-confirm-dlq"
    status: str = "UNKNOWN"
    visible_messages: int | None = None
    not_visible_messages: int | None = None
    oldest_message_age_seconds: int | None = None
    dlq_visible_messages: int | None = None
    dlq_oldest_message_age_seconds: int | None = None
    backlog_threshold: int = 10
    oldest_age_threshold_seconds: int = 300
    dlq_threshold: int = 1
    error: str | None = None


@dataclass(frozen=True)
class ValkeyStatusSummary:
    cluster_ids: tuple[str, ...] = ("baselink-dev-redis-001", "baselink-dev-redis-002")
    replica_cluster_ids: tuple[str, ...] = ("baselink-dev-redis-002",)
    status: str = "UNKNOWN"
    max_engine_cpu_percent: float | None = None
    max_memory_usage_percent: float | None = None
    total_evictions: int | None = None
    max_replication_lag_seconds: float | None = None
    lookback_minutes: int = 15
    cpu_threshold_percent: int = 80
    memory_threshold_percent: int = 80
    replication_lag_threshold_seconds: int = 5
    eviction_threshold: int = 0
    error: str | None = None


@dataclass(frozen=True)
class KafkaPipelineHealthSummary:
    status: str = "UNKNOWN"
    lookback_days: int = 7
    expected_producers: tuple[str, ...] = ("ticket-service", "waiting-room-service")
    expected_event_types: tuple[str, ...] = (
        "WAITING_ENTERED",
        "ACCESS_TOKEN_ISSUED",
        "RESERVATION_REQUESTED",
        "RESERVATION_CONFIRMED",
    )
    total_events: int | None = None
    latest_occurred_at: str | None = None
    producer_counts: dict[str, int] = field(default_factory=dict)
    event_type_counts: dict[str, int] = field(default_factory=dict)
    missing_producers: tuple[str, ...] = ()
    missing_event_types: tuple[str, ...] = ()
    producer_failures: int | None = None
    invalid_events: int | None = None
    skipped_events: int | None = None
    sink_completed_events: int | None = None
    stale_after_hours: int = 24
    error: str | None = None


def db_pressure(connection_count: int, budget: int) -> tuple[str, int]:
    if connection_count >= budget:
        return "STOP", 0
    if connection_count >= 55:
        return "CRITICAL", 25
    if connection_count >= 50:
        return "WARNING", 50
    if connection_count >= 40:
        return "CAUTION", 75
    return "NORMAL", 100


def calculate_recommendation(
    inputs: CapacityInputs,
    minimum_samples: int = 20,
    safety_factor: float = 0.8,
    capacity_signals: CapacitySignalSummary | None = None,
    sqs_worker: SqsWorkerSummary | None = None,
    valkey_status: ValkeyStatusSummary | None = None,
    kafka_pipeline_health: KafkaPipelineHealthSummary | None = None,
) -> dict[str, Any]:
    pressure_level, throttle_percent = db_pressure(
        inputs.current_db_connections, inputs.db_connection_budget
    )
    insufficient = []
    if inputs.access_tokens_issued < minimum_samples:
        insufficient.append("access token samples")
    if inputs.reservation_requested < minimum_samples:
        insufficient.append("reservation request samples")
    if inputs.reservation_confirmed < minimum_samples:
        insufficient.append("reservation confirmation samples")
    if inputs.stable_confirmed_per_minute <= 0:
        insufficient.append("stable confirmation throughput")

    base = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "gameId": inputs.game_id,
        "lookbackDays": inputs.lookback_days,
        "producerFilter": inputs.producer_filter,
        "producerFilters": list(inputs.producer_filters),
        "currentPolicyEnterPerMinute": inputs.current_policy_enter_per_minute,
        "currentDbConnections": inputs.current_db_connections,
        "dbConnectionBudget": inputs.db_connection_budget,
        "dbPressureLevel": pressure_level,
        "dbThrottlePercent": throttle_percent,
        "samples": {
            "waitingEntered": inputs.waiting_entered,
            "accessTokensIssued": inputs.access_tokens_issued,
            "reservationRequested": inputs.reservation_requested,
            "reservationConfirmed": inputs.reservation_confirmed,
        },
        "capacitySignals": asdict(capacity_signals or CapacitySignalSummary()),
        "sqsWorker": asdict(sqs_worker or SqsWorkerSummary()),
        "valkeyStatus": asdict(valkey_status or ValkeyStatusSummary()),
        "kafkaPipelineHealth": asdict(
            kafka_pipeline_health or KafkaPipelineHealthSummary()
        ),
    }
    if insufficient:
        return {
            **base,
            "status": "INSUFFICIENT_DATA",
            "confidence": "LOW",
            "recommendedPolicyEnterPerMinute": None,
            "effectiveEnterPerMinuteNow": 0 if throttle_percent == 0 else None,
            "reasons": [
                "추천을 보류했습니다: " + ", ".join(insufficient),
                f"최소 표본 기준은 항목별 {minimum_samples}건입니다.",
                "기존 운영 정책은 유지하고 이벤트 표본을 더 수집해야 합니다.",
            ],
        }

    conversion = min(
        1.0, inputs.reservation_confirmed / inputs.reservation_requested
    )
    waiting_factor = (
        0.70
        if inputs.average_waiting_seconds >= 300
        else 0.85
        if inputs.average_waiting_seconds >= 120
        else 1.0
    )
    conversion_adjusted_capacity = (
        inputs.stable_confirmed_per_minute / max(conversion, 0.05)
    )
    raw_recommendation = conversion_adjusted_capacity * safety_factor * waiting_factor

    if inputs.average_effective_enter_per_minute > 0:
        raw_recommendation = min(
            raw_recommendation, inputs.average_effective_enter_per_minute
        )

    increase_guardrail = max(
        1, math.floor(inputs.current_policy_enter_per_minute * 1.25)
    )
    recommended_policy = max(
        1, min(math.floor(raw_recommendation), increase_guardrail)
    )
    effective_now = math.floor(recommended_policy * throttle_percent / 100)

    sample_floor = min(
        inputs.access_tokens_issued,
        inputs.reservation_requested,
        inputs.reservation_confirmed,
    )
    confidence = "HIGH" if sample_floor >= 100 else "MEDIUM"
    return {
        **base,
        "status": "RECOMMENDED",
        "confidence": confidence,
        "recommendedPolicyEnterPerMinute": recommended_policy,
        "effectiveEnterPerMinuteNow": effective_now,
        "calculation": {
            "stableConfirmedPerMinute": round(
                inputs.stable_confirmed_per_minute, 2
            ),
            "reservationConversionPercent": round(conversion * 100, 2),
            "averageWaitingSeconds": round(inputs.average_waiting_seconds, 2),
            "averageObservedEffectiveEnterPerMinute": round(
                inputs.average_effective_enter_per_minute, 2
            ),
            "safetyFactor": safety_factor,
            "waitingFactor": waiting_factor,
            "maximumIncreaseGuardrail": increase_guardrail,
        },
        "reasons": [
            f"안정 구간 예약 확정 처리량은 분당 {inputs.stable_confirmed_per_minute:.2f}건입니다.",
            f"예약 요청 대비 확정률은 {conversion * 100:.1f}%입니다.",
            f"안전계수 {safety_factor:.2f}와 대기시간 보정 {waiting_factor:.2f}를 적용했습니다.",
            "정책 추천값은 현재 설정 대비 한 번에 25% 넘게 증가하지 않습니다.",
            f"현재 DB 상태는 {pressure_level}이며 실시간 자동 감속은 별도로 {throttle_percent}%를 적용합니다.",
        ],
    }


def _aws_json(arguments: list[str]) -> dict[str, Any]:
    completed = subprocess.run(
        ["aws", *arguments, "--output", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def _queue_attributes(queue_name: str, region: str) -> dict[str, int]:
    queue_url = _aws_json(
        [
            "sqs",
            "get-queue-url",
            "--queue-name",
            queue_name,
            "--region",
            region,
        ]
    )["QueueUrl"]
    response = _aws_json(
        [
            "sqs",
            "get-queue-attributes",
            "--queue-url",
            queue_url,
            "--attribute-names",
            "ApproximateNumberOfMessages",
            "ApproximateNumberOfMessagesNotVisible",
            "ApproximateAgeOfOldestMessage",
            "--region",
            region,
        ]
    )
    attributes = response.get("Attributes", {})
    return {
        "visible": int(attributes.get("ApproximateNumberOfMessages", 0)),
        "not_visible": int(
            attributes.get("ApproximateNumberOfMessagesNotVisible", 0)
        ),
        "oldest_age": int(attributes.get("ApproximateAgeOfOldestMessage", 0)),
    }


def _sqs_worker_status(
    visible_messages: int,
    not_visible_messages: int,
    oldest_message_age_seconds: int,
    dlq_visible_messages: int,
    backlog_threshold: int,
    oldest_age_threshold_seconds: int,
    dlq_threshold: int,
) -> str:
    if dlq_visible_messages >= dlq_threshold:
        return "DLQ_DETECTED"
    if visible_messages >= backlog_threshold:
        return "BACKLOG"
    if oldest_message_age_seconds >= oldest_age_threshold_seconds:
        return "DELAYED"
    if visible_messages > 0 or not_visible_messages > 0:
        return "PROCESSING"
    return "HEALTHY"


def collect_sqs_worker_summary(
    source_queue_name: str,
    dlq_queue_name: str,
    region: str,
    backlog_threshold: int = 10,
    oldest_age_threshold_seconds: int = 300,
    dlq_threshold: int = 1,
) -> SqsWorkerSummary:
    try:
        source = _queue_attributes(source_queue_name, region)
        dlq = _queue_attributes(dlq_queue_name, region)
        status = _sqs_worker_status(
            source["visible"],
            source["not_visible"],
            source["oldest_age"],
            dlq["visible"],
            backlog_threshold,
            oldest_age_threshold_seconds,
            dlq_threshold,
        )
        return SqsWorkerSummary(
            source_queue_name=source_queue_name,
            dlq_queue_name=dlq_queue_name,
            status=status,
            visible_messages=source["visible"],
            not_visible_messages=source["not_visible"],
            oldest_message_age_seconds=source["oldest_age"],
            dlq_visible_messages=dlq["visible"],
            dlq_oldest_message_age_seconds=dlq["oldest_age"],
            backlog_threshold=backlog_threshold,
            oldest_age_threshold_seconds=oldest_age_threshold_seconds,
            dlq_threshold=dlq_threshold,
        )
    except Exception as exc:
        return SqsWorkerSummary(
            source_queue_name=source_queue_name,
            dlq_queue_name=dlq_queue_name,
            backlog_threshold=backlog_threshold,
            oldest_age_threshold_seconds=oldest_age_threshold_seconds,
            dlq_threshold=dlq_threshold,
            error=str(exc),
        )


def _cloudwatch_metric_statistics(
    namespace: str,
    metric_name: str,
    dimensions: dict[str, str],
    region: str,
    lookback_minutes: int,
    statistics: tuple[str, ...],
    period: int = 60,
) -> list[dict[str, Any]]:
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=lookback_minutes)
    dimension_args: list[str] = []
    for name, value in dimensions.items():
        dimension_args.append(f"Name={name},Value={value}")
    response = _aws_json(
        [
            "cloudwatch",
            "get-metric-statistics",
            "--namespace",
            namespace,
            "--metric-name",
            metric_name,
            "--dimensions",
            *dimension_args,
            "--start-time",
            start_time.isoformat().replace("+00:00", "Z"),
            "--end-time",
            end_time.isoformat().replace("+00:00", "Z"),
            "--period",
            str(period),
            "--statistics",
            *statistics,
            "--region",
            region,
        ]
    )
    return response.get("Datapoints", [])


def _max_stat(datapoints: list[dict[str, Any]], statistic: str) -> float:
    values = [float(point[statistic]) for point in datapoints if statistic in point]
    return max(values) if values else 0.0


def _sum_stat(datapoints: list[dict[str, Any]], statistic: str) -> float:
    return sum(float(point[statistic]) for point in datapoints if statistic in point)


def _valkey_status(
    max_engine_cpu_percent: float,
    max_memory_usage_percent: float,
    total_evictions: int,
    max_replication_lag_seconds: float,
    cpu_threshold_percent: int,
    memory_threshold_percent: int,
    replication_lag_threshold_seconds: int,
    eviction_threshold: int,
) -> str:
    if total_evictions > eviction_threshold:
        return "EVICTIONS_DETECTED"
    if max_replication_lag_seconds >= replication_lag_threshold_seconds:
        return "REPLICATION_LAG"
    if max_engine_cpu_percent >= cpu_threshold_percent:
        return "CPU_HIGH"
    if max_memory_usage_percent >= memory_threshold_percent:
        return "MEMORY_HIGH"
    return "HEALTHY"


def collect_valkey_status_summary(
    cluster_ids: tuple[str, ...],
    replica_cluster_ids: tuple[str, ...],
    region: str,
    lookback_minutes: int = 15,
    cpu_threshold_percent: int = 80,
    memory_threshold_percent: int = 80,
    replication_lag_threshold_seconds: int = 5,
    eviction_threshold: int = 0,
) -> ValkeyStatusSummary:
    try:
        engine_cpu_values: list[float] = []
        memory_values: list[float] = []
        eviction_total = 0.0
        replication_lag_values: list[float] = []

        for cluster_id in cluster_ids:
            dimensions = {"CacheClusterId": cluster_id}
            engine_cpu_values.append(
                _max_stat(
                    _cloudwatch_metric_statistics(
                        "AWS/ElastiCache",
                        "EngineCPUUtilization",
                        dimensions,
                        region,
                        lookback_minutes,
                        ("Maximum",),
                    ),
                    "Maximum",
                )
            )
            memory_values.append(
                _max_stat(
                    _cloudwatch_metric_statistics(
                        "AWS/ElastiCache",
                        "DatabaseMemoryUsagePercentage",
                        dimensions,
                        region,
                        lookback_minutes,
                        ("Maximum",),
                    ),
                    "Maximum",
                )
            )
            eviction_total += _sum_stat(
                _cloudwatch_metric_statistics(
                    "AWS/ElastiCache",
                    "Evictions",
                    dimensions,
                    region,
                    lookback_minutes,
                    ("Sum",),
                ),
                "Sum",
            )

        for cluster_id in replica_cluster_ids:
            replication_lag_values.append(
                _max_stat(
                    _cloudwatch_metric_statistics(
                        "AWS/ElastiCache",
                        "ReplicationLag",
                        {"CacheClusterId": cluster_id},
                        region,
                        lookback_minutes,
                        ("Maximum",),
                    ),
                    "Maximum",
                )
            )

        max_engine_cpu = max(engine_cpu_values) if engine_cpu_values else 0.0
        max_memory = max(memory_values) if memory_values else 0.0
        total_evictions = int(eviction_total)
        max_replication_lag = (
            max(replication_lag_values) if replication_lag_values else 0.0
        )
        status = _valkey_status(
            max_engine_cpu,
            max_memory,
            total_evictions,
            max_replication_lag,
            cpu_threshold_percent,
            memory_threshold_percent,
            replication_lag_threshold_seconds,
            eviction_threshold,
        )
        return ValkeyStatusSummary(
            cluster_ids=cluster_ids,
            replica_cluster_ids=replica_cluster_ids,
            status=status,
            max_engine_cpu_percent=round(max_engine_cpu, 2),
            max_memory_usage_percent=round(max_memory, 2),
            total_evictions=total_evictions,
            max_replication_lag_seconds=round(max_replication_lag, 2),
            lookback_minutes=lookback_minutes,
            cpu_threshold_percent=cpu_threshold_percent,
            memory_threshold_percent=memory_threshold_percent,
            replication_lag_threshold_seconds=replication_lag_threshold_seconds,
            eviction_threshold=eviction_threshold,
        )
    except Exception as exc:
        return ValkeyStatusSummary(
            cluster_ids=cluster_ids,
            replica_cluster_ids=replica_cluster_ids,
            lookback_minutes=lookback_minutes,
            cpu_threshold_percent=cpu_threshold_percent,
            memory_threshold_percent=memory_threshold_percent,
            replication_lag_threshold_seconds=replication_lag_threshold_seconds,
            eviction_threshold=eviction_threshold,
            error=str(exc),
        )


def _run_athena_query(query: str, database: str, workgroup: str, region: str) -> list[str]:
    started = _aws_json(
        [
            "athena",
            "start-query-execution",
            "--query-string",
            query,
            "--query-execution-context",
            f"Database={database}",
            "--work-group",
            workgroup,
            "--region",
            region,
        ]
    )
    execution_id = started["QueryExecutionId"]
    for _ in range(60):
        import time

        time.sleep(1)
        execution = _aws_json(
            [
                "athena",
                "get-query-execution",
                "--query-execution-id",
                execution_id,
                "--region",
                region,
            ]
        )["QueryExecution"]
        state = execution["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in {"FAILED", "CANCELLED"}:
            raise RuntimeError(execution["Status"].get("StateChangeReason", state))
    else:
        raise TimeoutError("Athena query did not finish within 60 seconds")

    rows = _aws_json(
        [
            "athena",
            "get-query-results",
            "--query-execution-id",
            execution_id,
            "--max-results",
            "2",
            "--region",
            region,
        ]
    )["ResultSet"]["Rows"]
    if len(rows) < 2:
        return []
    return [item.get("VarCharValue", "") for item in rows[1]["Data"]]


def _run_athena_query_rows(
    query: str,
    database: str,
    workgroup: str,
    region: str,
    max_results: int = 1000,
) -> list[list[str]]:
    started = _aws_json(
        [
            "athena",
            "start-query-execution",
            "--query-string",
            query,
            "--query-execution-context",
            f"Database={database}",
            "--work-group",
            workgroup,
            "--region",
            region,
        ]
    )
    execution_id = started["QueryExecutionId"]
    for _ in range(60):
        execution = _aws_json(
            [
                "athena",
                "get-query-execution",
                "--query-execution-id",
                execution_id,
                "--region",
                region,
            ]
        )["QueryExecution"]
        state = execution["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in {"FAILED", "CANCELLED"}:
            raise RuntimeError(execution["Status"].get("StateChangeReason", state))
        time.sleep(1)
    else:
        raise TimeoutError("Athena query did not finish within 60 seconds")

    rows = _aws_json(
        [
            "athena",
            "get-query-results",
            "--query-execution-id",
            execution_id,
            "--max-results",
            str(max_results),
            "--region",
            region,
        ]
    )["ResultSet"]["Rows"]
    if len(rows) < 2:
        return []
    return [
        [item.get("VarCharValue", "") for item in row.get("Data", [])]
        for row in rows[1:]
    ]


def _producer_condition(
    producer_filter: str | None = None,
    producer_filters: tuple[str, ...] = (),
) -> str:
    if producer_filter and producer_filters:
        raise ValueError("Use either producer_filter or producer_filters, not both")

    if producer_filter:
        return "AND producer = '" + producer_filter.replace("'", "''") + "'"
    if producer_filters:
        escaped = [producer.replace("'", "''") for producer in producer_filters]
        quoted = ", ".join(f"'{producer}'" for producer in escaped)
        return f"AND producer IN ({quoted})"
    return ""


KAFKA_INFRA_AUDIT_EVENT_TYPES = {
    "KAFKA_PRODUCE_FAILED",
    "KAFKA_S3_SINK_DELAYED",
    "KAFKA_EVENT_SKIPPED",
    "KAFKA_EVENT_INVALID",
    "KAFKA_S3_SINK_COMPLETED",
}


def _parse_utc_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _kafka_pipeline_status(
    total_events: int,
    missing_producers: tuple[str, ...],
    missing_event_types: tuple[str, ...],
    latest_occurred_at: str | None,
    producer_failures: int,
    invalid_events: int,
    stale_after_hours: int,
) -> str:
    if producer_failures > 0:
        return "PRODUCER_FAILURE"
    if invalid_events > 0:
        return "INVALID_EVENTS"
    if total_events == 0:
        return "NO_EVENTS"
    latest_at = _parse_utc_datetime(latest_occurred_at)
    if latest_at is not None:
        age = datetime.now(timezone.utc) - latest_at
        if age > timedelta(hours=stale_after_hours):
            return "STALE"
    if missing_producers or missing_event_types:
        return "PARTIAL"
    return "HEALTHY"


def _sql_in(values: tuple[str, ...] | set[str]) -> str:
    escaped = [value.replace("'", "''") for value in values]
    return ", ".join(f"'{value}'" for value in escaped)


def collect_kafka_pipeline_health(
    game_id: int,
    lookback_days: int,
    database: str,
    workgroup: str,
    region: str,
    expected_producers: tuple[str, ...],
    expected_event_types: tuple[str, ...],
    stale_after_hours: int = 24,
) -> KafkaPipelineHealthSummary:
    try:
        start_date = (
            datetime.now(timezone.utc) - timedelta(days=lookback_days - 1)
        ).date()
        infra_types_sql = _sql_in(KAFKA_INFRA_AUDIT_EVENT_TYPES)
        query = f"""
        SELECT
          event_type,
          producer,
          count(*) AS event_count,
          coalesce(max(occurredAt), '') AS latest_occurred_at
        FROM ticket_events
        WHERE event_date >= '{start_date.isoformat()}'
          AND (
            gameId = {game_id}
            OR event_type IN ({infra_types_sql})
          )
        GROUP BY event_type, producer
        """
        rows = _run_athena_query_rows(query, database, workgroup, region)
        producer_counts: dict[str, int] = {}
        event_type_counts: dict[str, int] = {}
        latest_values: list[str] = []
        total_events = 0
        for row in rows:
            if len(row) < 4:
                continue
            event_type, producer, count_text, latest = row[:4]
            count = int(count_text or 0)
            total_events += count
            if producer:
                producer_counts[producer] = producer_counts.get(producer, 0) + count
            if event_type:
                event_type_counts[event_type] = event_type_counts.get(event_type, 0) + count
            if latest:
                latest_values.append(latest)

        latest_occurred_at = max(latest_values) if latest_values else None
        missing_producers = tuple(
            producer
            for producer in expected_producers
            if producer_counts.get(producer, 0) == 0
        )
        missing_event_types = tuple(
            event_type
            for event_type in expected_event_types
            if event_type_counts.get(event_type, 0) == 0
        )
        producer_failures = event_type_counts.get("KAFKA_PRODUCE_FAILED", 0)
        invalid_events = event_type_counts.get("KAFKA_EVENT_INVALID", 0)
        skipped_events = event_type_counts.get("KAFKA_EVENT_SKIPPED", 0)
        sink_completed_events = event_type_counts.get("KAFKA_S3_SINK_COMPLETED", 0)
        status = _kafka_pipeline_status(
            total_events,
            missing_producers,
            missing_event_types,
            latest_occurred_at,
            producer_failures,
            invalid_events,
            stale_after_hours,
        )
        return KafkaPipelineHealthSummary(
            status=status,
            lookback_days=lookback_days,
            expected_producers=expected_producers,
            expected_event_types=expected_event_types,
            total_events=total_events,
            latest_occurred_at=latest_occurred_at,
            producer_counts=producer_counts,
            event_type_counts=event_type_counts,
            missing_producers=missing_producers,
            missing_event_types=missing_event_types,
            producer_failures=producer_failures,
            invalid_events=invalid_events,
            skipped_events=skipped_events,
            sink_completed_events=sink_completed_events,
            stale_after_hours=stale_after_hours,
        )
    except Exception as exc:
        return KafkaPipelineHealthSummary(
            lookback_days=lookback_days,
            expected_producers=expected_producers,
            expected_event_types=expected_event_types,
            stale_after_hours=stale_after_hours,
            error=str(exc),
        )


def collect_athena_inputs(
    game_id: int,
    lookback_days: int,
    current_policy: int,
    current_db_connections: int,
    database: str,
    workgroup: str,
    region: str,
    producer_filter: str | None = None,
    producer_filters: tuple[str, ...] = (),
) -> CapacityInputs:
    start_date = (datetime.now(timezone.utc) - timedelta(days=lookback_days - 1)).date()
    producer_condition = _producer_condition(producer_filter, producer_filters)
    query = f"""
    WITH base AS (
      SELECT *
      FROM ticket_events
      WHERE event_date >= '{start_date.isoformat()}'
        AND gameId = {game_id}
        {producer_condition}
    ),
    confirmed_per_minute AS (
      SELECT date_trunc('minute', from_iso8601_timestamp(occurredAt)) AS minute,
             count(*) AS confirmed_count
      FROM base
      WHERE event_type = 'RESERVATION_CONFIRMED'
      GROUP BY 1
    )
    SELECT
      count_if(event_type = 'WAITING_ENTERED'),
      count_if(event_type = 'ACCESS_TOKEN_ISSUED'),
      count_if(event_type = 'RESERVATION_REQUESTED'),
      count_if(event_type = 'RESERVATION_CONFIRMED'),
      coalesce((SELECT approx_percentile(confirmed_count, 0.5)
                FROM confirmed_per_minute), 0),
      coalesce(avg(CASE WHEN event_type = 'ACCESS_TOKEN_ISSUED'
                        THEN payload.waitingSeconds END), 0),
      coalesce(avg(CASE WHEN event_type = 'ACCESS_TOKEN_ISSUED'
                        THEN payload.effectiveEnterPerMinute END), 0)
    FROM base
    """
    values = _run_athena_query(query, database, workgroup, region)
    if len(values) != 7:
        raise RuntimeError("Athena capacity query returned an unexpected result")
    return CapacityInputs(
        game_id=game_id,
        lookback_days=lookback_days,
        current_policy_enter_per_minute=current_policy,
        waiting_entered=int(values[0] or 0),
        access_tokens_issued=int(values[1] or 0),
        reservation_requested=int(values[2] or 0),
        reservation_confirmed=int(values[3] or 0),
        stable_confirmed_per_minute=float(values[4] or 0),
        average_waiting_seconds=float(values[5] or 0),
        average_effective_enter_per_minute=float(values[6] or 0),
        current_db_connections=current_db_connections,
        producer_filter=producer_filter,
        producer_filters=producer_filters,
    )


def _optional_int(value: str) -> int | None:
    if value == "":
        return None
    return int(float(value))


def collect_capacity_signals(
    game_id: int,
    lookback_days: int,
    database: str,
    workgroup: str,
    region: str,
    producer_filter: str | None = None,
    producer_filters: tuple[str, ...] = (),
) -> CapacitySignalSummary:
    start_date = (datetime.now(timezone.utc) - timedelta(days=lookback_days - 1)).date()
    producer_condition = _producer_condition(producer_filter, producer_filters)
    query = f"""
    WITH signals AS (
      SELECT *
      FROM ticket_events
      WHERE event_date >= '{start_date.isoformat()}'
        AND gameId = {game_id}
        AND event_type IN (
          'ADMISSION_THROTTLE_APPLIED',
          'ADMISSION_STOP_APPLIED',
          'ADMISSION_THROTTLE_RECOVERED'
        )
        {producer_condition}
    )
    SELECT
      count_if(event_type = 'ADMISSION_THROTTLE_APPLIED'),
      count_if(event_type = 'ADMISSION_STOP_APPLIED'),
      count_if(event_type = 'ADMISSION_THROTTLE_RECOVERED'),
      coalesce(max_by(event_type, from_iso8601_timestamp(occurredAt)), ''),
      coalesce(max_by(occurredAt, from_iso8601_timestamp(occurredAt)), ''),
      coalesce(max_by(payload.dbPressureLevel, from_iso8601_timestamp(occurredAt)), ''),
      coalesce(CAST(max_by(payload.currentDbConnections, from_iso8601_timestamp(occurredAt)) AS varchar), ''),
      coalesce(CAST(max_by(payload.dbConnectionBudget, from_iso8601_timestamp(occurredAt)) AS varchar), ''),
      coalesce(CAST(max_by(payload.dbThrottlePercent, from_iso8601_timestamp(occurredAt)) AS varchar), ''),
      coalesce(CAST(max_by(payload.effectiveEnterPerMinute, from_iso8601_timestamp(occurredAt)) AS varchar), '')
    FROM signals
    """
    values = _run_athena_query(query, database, workgroup, region)
    if len(values) != 10:
        raise RuntimeError("Athena capacity signal query returned an unexpected result")
    return CapacitySignalSummary(
        throttle_applied=int(values[0] or 0),
        stop_applied=int(values[1] or 0),
        throttle_recovered=int(values[2] or 0),
        latest_event_type=values[3] or None,
        latest_occurred_at=values[4] or None,
        latest_db_pressure_level=values[5] or None,
        latest_current_db_connections=_optional_int(values[6]),
        latest_db_connection_budget=_optional_int(values[7]),
        latest_db_throttle_percent=_optional_int(values[8]),
        latest_effective_enter_per_minute=_optional_int(values[9]),
    )


def _format_counts(counts: dict[str, int]) -> str:
    if not counts:
        return "정보 없음"
    return ", ".join(f"{key}={value}" for key, value in sorted(counts.items()))


def markdown_report(report: dict[str, Any]) -> str:
    recommendation = report.get("recommendedPolicyEnterPerMinute")
    signals = report.get("capacitySignals") or {}
    sqs_worker = report.get("sqsWorker") or {}
    valkey_status = report.get("valkeyStatus") or {}
    kafka_health = report.get("kafkaPipelineHealth") or {}
    sqs_oldest_age = sqs_worker.get("oldest_message_age_seconds")
    sqs_oldest_age_text = (
        f"{sqs_oldest_age}초" if sqs_oldest_age is not None else "정보 없음"
    )
    valkey_cluster_ids = valkey_status.get("cluster_ids") or []
    valkey_replica_ids = valkey_status.get("replica_cluster_ids") or []
    valkey_cpu = valkey_status.get("max_engine_cpu_percent")
    valkey_memory = valkey_status.get("max_memory_usage_percent")
    valkey_lag = valkey_status.get("max_replication_lag_seconds")
    valkey_cpu_text = f"{valkey_cpu}%" if valkey_cpu is not None else "정보 없음"
    valkey_memory_text = (
        f"{valkey_memory}%" if valkey_memory is not None else "정보 없음"
    )
    valkey_lag_text = f"{valkey_lag}초" if valkey_lag is not None else "정보 없음"
    signal_total = (
        int(signals.get("throttle_applied") or 0)
        + int(signals.get("stop_applied") or 0)
        + int(signals.get("throttle_recovered") or 0)
    )
    missing_producers = kafka_health.get("missing_producers") or []
    missing_event_types = kafka_health.get("missing_event_types") or []
    lines = [
        f"# Game {report['gameId']} 안전 입장량 보고서",
        "",
        f"- 상태: `{report['status']}`",
        f"- 신뢰도: `{report['confidence']}`",
        f"- 현재 정책: `{report['currentPolicyEnterPerMinute']}명/분`",
        f"- 추천 정책: `{recommendation if recommendation is not None else '보류'}`",
        f"- 현재 DB 반영 입장량: `{report.get('effectiveEnterPerMinuteNow')}`",
        f"- DB 상태: `{report['dbPressureLevel']}` "
        f"({report['currentDbConnections']}/{report['dbConnectionBudget']})",
        "",
        "## 판단 근거",
        "",
    ]
    lines.extend(f"- {reason}" for reason in report["reasons"])
    lines.extend(
        [
            "",
            "## 최근 감속/복구 신호",
            "",
        ]
    )
    if signal_total == 0:
        lines.append("- 조회 기간 동안 Kafka `capacity.signals` 감속/복구 이벤트가 없습니다.")
    else:
        lines.extend(
            [
                f"- 감속 적용: `{signals.get('throttle_applied', 0)}회`",
                f"- 입장 중지: `{signals.get('stop_applied', 0)}회`",
                f"- 정상 복구: `{signals.get('throttle_recovered', 0)}회`",
            ]
        )
        if signals.get("latest_event_type"):
            connection_text = "정보 없음"
            if signals.get("latest_current_db_connections") is not None:
                connection_text = (
                    f"{signals.get('latest_current_db_connections')}/"
                    f"{signals.get('latest_db_connection_budget')}"
                )
            lines.extend(
                [
                    "",
                    "### 최근 신호",
                    "",
                    f"- 이벤트: `{signals.get('latest_event_type')}`",
                    f"- 발생 시각: `{signals.get('latest_occurred_at')}`",
                    f"- DB pressure: `{signals.get('latest_db_pressure_level')}`",
                    f"- DB connection: `{connection_text}`",
                    f"- 감속률: `{signals.get('latest_db_throttle_percent')}%`",
                    f"- 당시 effective 입장량: `{signals.get('latest_effective_enter_per_minute')}명/분`",
                ]
            )
    lines.extend(
        [
            "",
            "## SQS/Worker 처리 상태",
            "",
            f"- 상태: `{sqs_worker.get('status', 'UNKNOWN')}`",
            f"- 원본 큐: `{sqs_worker.get('source_queue_name', 'ticket-confirm-queue')}`",
            f"- 원본 큐 대기 메시지: `{sqs_worker.get('visible_messages') if sqs_worker.get('visible_messages') is not None else '정보 없음'}`",
            f"- 원본 큐 처리 중 메시지: `{sqs_worker.get('not_visible_messages') if sqs_worker.get('not_visible_messages') is not None else '정보 없음'}`",
            f"- 가장 오래된 메시지 대기 시간: `{sqs_oldest_age_text}`",
            f"- DLQ: `{sqs_worker.get('dlq_queue_name', 'ticket-confirm-dlq')}`",
            f"- DLQ 대기 메시지: `{sqs_worker.get('dlq_visible_messages') if sqs_worker.get('dlq_visible_messages') is not None else '정보 없음'}`",
        ]
    )
    if sqs_worker.get("error"):
        lines.append(f"- SQS 상태 조회 오류: `{sqs_worker.get('error')}`")
    else:
        lines.append(
            "- 해석: `DLQ_DETECTED`는 원인 확인 후 redrive가 필요하고, "
            "`BACKLOG`/`DELAYED`는 worker 처리 지연 또는 downstream 병목을 의심합니다."
        )
    lines.extend(
        [
            "",
            "## Valkey/좌석 잠금 계층 상태",
            "",
            f"- 상태: `{valkey_status.get('status', 'UNKNOWN')}`",
            f"- 조회 대상: `{', '.join(valkey_cluster_ids) if valkey_cluster_ids else '정보 없음'}`",
            f"- replica 대상: `{', '.join(valkey_replica_ids) if valkey_replica_ids else '없음'}`",
            f"- 최대 Engine CPU: `{valkey_cpu_text}`",
            f"- 최대 메모리 사용률: `{valkey_memory_text}`",
            f"- Evictions 합계: `{valkey_status.get('total_evictions') if valkey_status.get('total_evictions') is not None else '정보 없음'}`",
            f"- 최대 replication lag: `{valkey_lag_text}`",
        ]
    )
    if valkey_status.get("error"):
        lines.append(f"- Valkey 상태 조회 오류: `{valkey_status.get('error')}`")
    else:
        lines.append(
            "- 해석: `EVICTIONS_DETECTED`는 좌석 lock/access token 같은 TTL key 유실 위험을, "
            "`CPU_HIGH`/`MEMORY_HIGH`는 대기열·좌석 잠금 요청 집중을, "
            "`REPLICATION_LAG`는 failover/replica 읽기 안정성 저하를 의심합니다."
        )
    lines.extend(
        [
            "",
            "## Kafka 파이프라인 상태",
            "",
            f"- 상태: `{kafka_health.get('status', 'UNKNOWN')}`",
            f"- 조회 기간: `최근 {kafka_health.get('lookback_days', report.get('lookbackDays'))}일`",
            f"- 전체 이벤트 수: `{kafka_health.get('total_events') if kafka_health.get('total_events') is not None else '정보 없음'}`",
            f"- 최신 이벤트 시각: `{kafka_health.get('latest_occurred_at') or '정보 없음'}`",
            f"- producer별 이벤트 수: `{_format_counts(kafka_health.get('producer_counts') or {})}`",
            f"- event type별 이벤트 수: `{_format_counts(kafka_health.get('event_type_counts') or {})}`",
            f"- 누락 producer: `{', '.join(missing_producers) if missing_producers else '없음'}`",
            f"- 누락 event type: `{', '.join(missing_event_types) if missing_event_types else '없음'}`",
            f"- producer failure: `{kafka_health.get('producer_failures') if kafka_health.get('producer_failures') is not None else '정보 없음'}`",
            f"- invalid event: `{kafka_health.get('invalid_events') if kafka_health.get('invalid_events') is not None else '정보 없음'}`",
            f"- skipped event: `{kafka_health.get('skipped_events') if kafka_health.get('skipped_events') is not None else '정보 없음'}`",
            f"- sink completed event: `{kafka_health.get('sink_completed_events') if kafka_health.get('sink_completed_events') is not None else '정보 없음'}`",
        ]
    )
    if kafka_health.get("error"):
        lines.append(f"- Kafka 파이프라인 상태 조회 오류: `{kafka_health.get('error')}`")
    else:
        lines.append(
            "- 해석: `NO_EVENTS`/`STALE`은 Kafka→S3/Athena 적재 지연이나 트래픽 부재를, "
            "`PARTIAL`은 특정 producer 또는 event type 누락을, "
            "`PRODUCER_FAILURE`/`INVALID_EVENTS`는 producer 또는 sink 품질 문제를 의심합니다."
        )
    return "\n".join(lines) + "\n"


def _csv_tuple(value: str) -> tuple[str, ...]:
    return tuple(item.strip() for item in value.split(",") if item.strip())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-id", type=int, required=True)
    parser.add_argument("--current-policy", type=int, required=True)
    parser.add_argument("--current-db-connections", type=int, required=True)
    parser.add_argument("--lookback-days", type=int, default=7)
    parser.add_argument("--minimum-samples", type=int, default=20)
    parser.add_argument("--database", default="baselink_dev_ticket_events")
    parser.add_argument("--workgroup", default="baselink-dev-ticket-events")
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--sqs-source-queue-name", default="ticket-confirm-queue")
    parser.add_argument("--sqs-dlq-name", default="ticket-confirm-dlq")
    parser.add_argument("--sqs-backlog-threshold", type=int, default=10)
    parser.add_argument("--sqs-oldest-age-threshold-seconds", type=int, default=300)
    parser.add_argument("--sqs-dlq-threshold", type=int, default=1)
    parser.add_argument(
        "--valkey-cluster-ids",
        default="baselink-dev-redis-001,baselink-dev-redis-002",
        help="Comma-separated ElastiCache cache cluster IDs to inspect.",
    )
    parser.add_argument(
        "--valkey-replica-cluster-ids",
        default="baselink-dev-redis-002",
        help="Comma-separated replica cache cluster IDs for ReplicationLag.",
    )
    parser.add_argument("--valkey-lookback-minutes", type=int, default=15)
    parser.add_argument("--valkey-cpu-threshold-percent", type=int, default=80)
    parser.add_argument("--valkey-memory-threshold-percent", type=int, default=80)
    parser.add_argument(
        "--valkey-replication-lag-threshold-seconds", type=int, default=5
    )
    parser.add_argument("--valkey-eviction-threshold", type=int, default=0)
    parser.add_argument(
        "--skip-sqs-worker",
        action="store_true",
        help="Do not query SQS queue attributes for the worker status section.",
    )
    parser.add_argument(
        "--skip-valkey-status",
        action="store_true",
        help="Do not query CloudWatch ElastiCache metrics for the Valkey status section.",
    )
    parser.add_argument(
        "--kafka-expected-producers",
        default="",
        help=(
            "Comma-separated producers expected in the event lake. "
            "Defaults to --producer-in when present, otherwise ticket-service,waiting-room-service."
        ),
    )
    parser.add_argument(
        "--kafka-expected-event-types",
        default=(
            "WAITING_ENTERED,ACCESS_TOKEN_ISSUED,"
            "RESERVATION_REQUESTED,RESERVATION_CONFIRMED"
        ),
        help="Comma-separated event types expected for a healthy capacity pipeline.",
    )
    parser.add_argument("--kafka-stale-after-hours", type=int, default=24)
    parser.add_argument(
        "--skip-kafka-pipeline-health",
        action="store_true",
        help="Do not query Athena event lake counts for the Kafka pipeline health section.",
    )
    parser.add_argument(
        "--producer-filter",
        help="Only analyze events from this producer, for example capacity-load-test.",
    )
    parser.add_argument(
        "--producer-in",
        help=(
            "Comma-separated producers to analyze together, "
            "for example ticket-service,waiting-room-service."
        ),
    )
    parser.add_argument("--output-dir", default="capacity-reports")
    args = parser.parse_args()

    producer_filters = tuple(
        item.strip() for item in (args.producer_in or "").split(",") if item.strip()
    )
    valkey_cluster_ids = _csv_tuple(args.valkey_cluster_ids)
    valkey_replica_cluster_ids = _csv_tuple(args.valkey_replica_cluster_ids)
    kafka_expected_producers = _csv_tuple(args.kafka_expected_producers) or (
        producer_filters or ("ticket-service", "waiting-room-service")
    )
    kafka_expected_event_types = _csv_tuple(args.kafka_expected_event_types)
    inputs = collect_athena_inputs(
        args.game_id,
        args.lookback_days,
        args.current_policy,
        args.current_db_connections,
        args.database,
        args.workgroup,
        args.region,
        args.producer_filter,
        producer_filters,
    )
    capacity_signals = collect_capacity_signals(
        args.game_id,
        args.lookback_days,
        args.database,
        args.workgroup,
        args.region,
        args.producer_filter,
        producer_filters,
    )
    sqs_worker = (
        SqsWorkerSummary(
            source_queue_name=args.sqs_source_queue_name,
            dlq_queue_name=args.sqs_dlq_name,
            backlog_threshold=args.sqs_backlog_threshold,
            oldest_age_threshold_seconds=args.sqs_oldest_age_threshold_seconds,
            dlq_threshold=args.sqs_dlq_threshold,
        )
        if args.skip_sqs_worker
        else collect_sqs_worker_summary(
            args.sqs_source_queue_name,
            args.sqs_dlq_name,
            args.region,
            args.sqs_backlog_threshold,
            args.sqs_oldest_age_threshold_seconds,
            args.sqs_dlq_threshold,
        )
    )
    valkey_status = (
        ValkeyStatusSummary(
            cluster_ids=valkey_cluster_ids,
            replica_cluster_ids=valkey_replica_cluster_ids,
            lookback_minutes=args.valkey_lookback_minutes,
            cpu_threshold_percent=args.valkey_cpu_threshold_percent,
            memory_threshold_percent=args.valkey_memory_threshold_percent,
            replication_lag_threshold_seconds=(
                args.valkey_replication_lag_threshold_seconds
            ),
            eviction_threshold=args.valkey_eviction_threshold,
        )
        if args.skip_valkey_status
        else collect_valkey_status_summary(
            valkey_cluster_ids,
            valkey_replica_cluster_ids,
            args.region,
            args.valkey_lookback_minutes,
            args.valkey_cpu_threshold_percent,
            args.valkey_memory_threshold_percent,
            args.valkey_replication_lag_threshold_seconds,
            args.valkey_eviction_threshold,
        )
    )
    kafka_pipeline_health = (
        KafkaPipelineHealthSummary(
            lookback_days=args.lookback_days,
            expected_producers=kafka_expected_producers,
            expected_event_types=kafka_expected_event_types,
            stale_after_hours=args.kafka_stale_after_hours,
        )
        if args.skip_kafka_pipeline_health
        else collect_kafka_pipeline_health(
            args.game_id,
            args.lookback_days,
            args.database,
            args.workgroup,
            args.region,
            kafka_expected_producers,
            kafka_expected_event_types,
            args.kafka_stale_after_hours,
        )
    )
    report = calculate_recommendation(
        inputs,
        args.minimum_samples,
        capacity_signals=capacity_signals,
        sqs_worker=sqs_worker,
        valkey_status=valkey_status,
        kafka_pipeline_health=kafka_pipeline_health,
    )
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    stem = f"game-{args.game_id}-capacity"
    (output_dir / f"{stem}.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (output_dir / f"{stem}.md").write_text(
        markdown_report(report), encoding="utf-8"
    )
    print(json.dumps({"inputs": asdict(inputs), "report": report}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
