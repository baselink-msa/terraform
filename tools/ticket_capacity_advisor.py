#!/usr/bin/env python3
"""Generate an explainable ticket admission recommendation from Athena events."""

import argparse
import json
import math
import subprocess
from dataclasses import asdict, dataclass
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


def collect_athena_inputs(
    game_id: int,
    lookback_days: int,
    current_policy: int,
    current_db_connections: int,
    database: str,
    workgroup: str,
    region: str,
) -> CapacityInputs:
    start_date = (datetime.now(timezone.utc) - timedelta(days=lookback_days - 1)).date()
    query = f"""
    WITH base AS (
      SELECT *
      FROM ticket_events
      WHERE event_date >= '{start_date.isoformat()}'
        AND gameId = {game_id}
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
    )


def markdown_report(report: dict[str, Any]) -> str:
    recommendation = report.get("recommendedPolicyEnterPerMinute")
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
    return "\n".join(lines) + "\n"


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
    parser.add_argument("--output-dir", default="capacity-reports")
    args = parser.parse_args()

    inputs = collect_athena_inputs(
        args.game_id,
        args.lookback_days,
        args.current_policy,
        args.current_db_connections,
        args.database,
        args.workgroup,
        args.region,
    )
    report = calculate_recommendation(inputs, args.minimum_samples)
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
