#!/usr/bin/env python3
"""Send a Capacity Advisor report summary to Slack.

The script intentionally depends only on the Python standard library so it can
run in GitHub Actions without installing extra packages.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def _value(value: Any, default: str = "정보 없음") -> str:
    if value is None or value == "":
        return default
    return str(value)


def _format_counts(counts: dict[str, int]) -> str:
    if not counts:
        return "정보 없음"
    return ", ".join(f"{key}={value}" for key, value in sorted(counts.items()))


def _percent_value(value: Any) -> str:
    if value is None or value == "":
        return "정보 없음"
    return f"{value}%"


def status_emoji(report: dict[str, Any]) -> str:
    status = report.get("status")
    pressure = report.get("dbPressureLevel")
    sqs_status = (report.get("sqsWorker") or {}).get("status")
    valkey_status = (report.get("valkeyStatus") or {}).get("status")
    kafka_status = (report.get("kafkaPipelineHealth") or {}).get("status")
    seat_lock_status = (report.get("seatLock") or {}).get("status")
    if status == "INSUFFICIENT_DATA":
        return ":warning:"
    if kafka_status == "PRODUCER_FAILURE":
        return ":rotating_light:"
    if valkey_status in {"EVICTIONS_DETECTED", "REPLICATION_LAG"}:
        return ":rotating_light:"
    if sqs_status == "DLQ_DETECTED":
        return ":rotating_light:"
    if pressure in {"WARNING", "CRITICAL", "STOP"}:
        return ":rotating_light:"
    if seat_lock_status == "FAILURE_RATE_HIGH":
        return ":large_yellow_circle:"
    if kafka_status in {"NO_EVENTS", "STALE", "PARTIAL", "INVALID_EVENTS"}:
        return ":large_yellow_circle:"
    if valkey_status in {"CPU_HIGH", "MEMORY_HIGH"}:
        return ":large_yellow_circle:"
    if sqs_status in {"BACKLOG", "DELAYED"}:
        return ":large_yellow_circle:"
    if pressure == "CAUTION":
        return ":large_yellow_circle:"
    return ":white_check_mark:"


def build_slack_payload(report: dict[str, Any], report_url: str | None = None) -> dict[str, Any]:
    game_id = report["gameId"]
    recommendation = report.get("recommendedPolicyEnterPerMinute")
    recommendation_text = recommendation if recommendation is not None else "보류"
    effective_now = report.get("effectiveEnterPerMinuteNow")
    signals = report.get("capacitySignals") or {}
    sqs_worker = report.get("sqsWorker") or {}
    valkey_status = report.get("valkeyStatus") or {}
    kafka_health = report.get("kafkaPipelineHealth") or {}
    seat_lock = report.get("seatLock") or {}
    signal_total = (
        int(signals.get("throttle_applied") or 0)
        + int(signals.get("stop_applied") or 0)
        + int(signals.get("throttle_recovered") or 0)
    )
    emoji = status_emoji(report)
    title = f"{emoji} Game {game_id} Capacity Advisor"
    text = (
        f"{title}: 추천 {recommendation_text}명/분, "
        f"DB {report.get('dbPressureLevel')} "
        f"({report.get('currentDbConnections')}/{report.get('dbConnectionBudget')})"
    )

    fields = [
        {"type": "mrkdwn", "text": f"*상태*\n`{report.get('status')}`"},
        {"type": "mrkdwn", "text": f"*신뢰도*\n`{report.get('confidence')}`"},
        {
            "type": "mrkdwn",
            "text": f"*현재 정책*\n`{report.get('currentPolicyEnterPerMinute')}명/분`",
        },
        {"type": "mrkdwn", "text": f"*추천 정책*\n`{recommendation_text}명/분`"},
        {"type": "mrkdwn", "text": f"*현재 DB 반영 입장량*\n`{_value(effective_now)}명/분`"},
        {
            "type": "mrkdwn",
            "text": (
                f"*DB 상태*\n`{report.get('dbPressureLevel')}` "
                f"({report.get('currentDbConnections')}/{report.get('dbConnectionBudget')})"
            ),
        },
    ]

    sample = report.get("samples") or {}
    sample_text = (
        f"대기열 진입 `{sample.get('waitingEntered', 0)}` / "
        f"입장권 `{sample.get('accessTokensIssued', 0)}` / "
        f"예약 요청 `{sample.get('reservationRequested', 0)}` / "
        f"예약 확정 `{sample.get('reservationConfirmed', 0)}`"
    )
    calculation = report.get("calculation") or {}
    calculation_items = []
    if calculation:
        calculation_items = [
            (
                "안정 확정 처리량",
                f"{_value(calculation.get('stableConfirmedPerMinute'))}건/분",
            ),
            (
                "예약 확정률",
                f"{_value(calculation.get('reservationConversionPercent'))}%",
            ),
            ("안전계수", _value(calculation.get("safetyFactor"))),
            ("대기시간 보정", _value(calculation.get("waitingFactor"))),
            (
                "관측 입장량 상한",
                f"{_value(calculation.get('averageObservedEffectiveEnterPerMinute'))}명/분",
            ),
            (
                "원시 추천",
                f"{_value(calculation.get('rawRecommendedPolicyEnterPerMinute'))}명/분",
            ),
            (
                "운영 하한",
                f"{_value(calculation.get('policyFloorGuardrail'))}명/분",
            ),
        ]
    calculation_text = " / ".join(
        f"{label} `{value}`" for label, value in calculation_items
    )
    reasons = report.get("reasons") or []
    reason_text = "\n".join(f"• {reason}" for reason in reasons[:4])
    if len(reasons) > 4:
        reason_text += f"\n• 외 {len(reasons) - 4}개 근거는 리포트 원문 참고"

    blocks: list[dict[str, Any]] = [
        {"type": "header", "text": {"type": "plain_text", "text": f"Game {game_id} 안전 입장량 보고서"}},
        {"type": "section", "fields": fields},
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*표본*\n{sample_text}"}},
    ]

    if calculation_text:
        blocks.append(
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*산출 지표*\n{calculation_text}",
                },
            }
        )

    if reason_text:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*판단 근거*\n{reason_text}"}})

    blocks.append({"type": "divider"})
    if signal_total == 0:
        signal_text = "조회 기간 동안 `capacity.signals` 감속/복구 이벤트가 없습니다."
    else:
        signal_text = (
            f"감속 적용 `{signals.get('throttle_applied', 0)}회`, "
            f"입장 중지 `{signals.get('stop_applied', 0)}회`, "
            f"정상 복구 `{signals.get('throttle_recovered', 0)}회`"
        )
        if signals.get("latest_event_type"):
            connection_text = "정보 없음"
            if signals.get("latest_current_db_connections") is not None:
                connection_text = (
                    f"{signals.get('latest_current_db_connections')}/"
                    f"{signals.get('latest_db_connection_budget')}"
                )
            signal_text += (
                "\n최근 신호: "
                f"`{signals.get('latest_event_type')}` / "
                f"DB `{signals.get('latest_db_pressure_level')}` / "
                f"connection `{connection_text}` / "
                f"감속률 `{signals.get('latest_db_throttle_percent')}%` / "
                f"입장량 `{signals.get('latest_effective_enter_per_minute')}명/분`"
            )

    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*최근 감속/복구 신호*\n{signal_text}"}})

    sqs_status = sqs_worker.get("status", "UNKNOWN")
    sqs_oldest_age = sqs_worker.get("oldest_message_age_seconds")
    sqs_oldest_age_text = (
        f"{sqs_oldest_age}초" if sqs_oldest_age is not None else "정보 없음"
    )
    sqs_text = (
        f"상태 `{sqs_status}` / "
        f"원본 큐 `{sqs_worker.get('source_queue_name', 'ticket-confirm-queue')}` "
        f"대기 `{_value(sqs_worker.get('visible_messages'))}` "
        f"처리중 `{_value(sqs_worker.get('not_visible_messages'))}` "
        f"oldest `{sqs_oldest_age_text}` / "
        f"DLQ `{sqs_worker.get('dlq_queue_name', 'ticket-confirm-dlq')}` "
        f"대기 `{_value(sqs_worker.get('dlq_visible_messages'))}`"
    )
    if sqs_worker.get("error"):
        sqs_text += f"\n조회 오류: `{sqs_worker.get('error')}`"
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*SQS/Worker 상태*\n{sqs_text}"}})

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
    valkey_text = (
        f"상태 `{valkey_status.get('status', 'UNKNOWN')}` / "
        f"clusters `{', '.join(valkey_cluster_ids) if valkey_cluster_ids else '정보 없음'}` / "
        f"replicas `{', '.join(valkey_replica_ids) if valkey_replica_ids else '없음'}`\n"
        f"Engine CPU `{valkey_cpu_text}` / "
        f"memory `{valkey_memory_text}` / "
        f"evictions `{_value(valkey_status.get('total_evictions'))}` / "
        f"replication lag `{valkey_lag_text}`"
    )
    if valkey_status.get("error"):
        valkey_text += f"\n조회 오류: `{valkey_status.get('error')}`"
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*Valkey/좌석 잠금 계층 상태*\n{valkey_text}"}})

    seat_lock_text = (
        f"상태 `{seat_lock.get('status', 'UNKNOWN')}` / "
        f"producer `{seat_lock.get('producer', 'seat-lock-service')}`\n"
        f"요청 `{seat_lock.get('requested', 0)}` "
        f"성공 `{seat_lock.get('locked', 0)}` "
        f"실패 `{seat_lock.get('failed', 0)}` "
        f"해제 `{seat_lock.get('unlocked', 0)}`\n"
        f"성공률 `{_percent_value(seat_lock.get('success_rate_percent'))}` / "
        f"실패율 `{_percent_value(seat_lock.get('failure_rate_percent'))}` / "
        f"해제율 `{_percent_value(seat_lock.get('unlock_rate_percent'))}`\n"
        f"latest `{_value(seat_lock.get('latest_event_type'))}` "
        f"at `{_value(seat_lock.get('latest_occurred_at'))}`"
    )
    if seat_lock.get("latest_seat_id") is not None:
        seat_lock_text += f" / seat `{seat_lock.get('latest_seat_id')}`"
    if seat_lock.get("error"):
        seat_lock_text += f"\n조회 오류: `{seat_lock.get('error')}`"
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*좌석 잠금 이벤트 상태*\n{seat_lock_text}"}})

    kafka_missing_producers = kafka_health.get("missing_producers") or []
    kafka_missing_event_types = kafka_health.get("missing_event_types") or []
    kafka_text = (
        f"상태 `{kafka_health.get('status', 'UNKNOWN')}` / "
        f"events `{_value(kafka_health.get('total_events'))}` / "
        f"latest `{_value(kafka_health.get('latest_occurred_at'))}`\n"
        f"producer counts `{_format_counts(kafka_health.get('producer_counts') or {})}`\n"
        f"event type counts `{_format_counts(kafka_health.get('event_type_counts') or {})}`\n"
        f"missing producers `{', '.join(kafka_missing_producers) if kafka_missing_producers else '없음'}` / "
        f"missing event types `{', '.join(kafka_missing_event_types) if kafka_missing_event_types else '없음'}`\n"
        f"producer failures `{_value(kafka_health.get('producer_failures'))}` / "
        f"invalid `{_value(kafka_health.get('invalid_events'))}` / "
        f"skipped `{_value(kafka_health.get('skipped_events'))}` / "
        f"sink completed `{_value(kafka_health.get('sink_completed_events'))}`"
    )
    if kafka_health.get("error"):
        kafka_text += f"\n조회 오류: `{kafka_health.get('error')}`"
    blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*Kafka 파이프라인 상태*\n{kafka_text}"}})

    if report_url:
        blocks.append(
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": f"<{report_url}|리포트 원문 보기> · generatedAt `{_value(report.get('generatedAt'))}`",
                    }
                ],
            }
        )
    else:
        blocks.append(
            {
                "type": "context",
                "elements": [
                    {"type": "mrkdwn", "text": f"generatedAt `{_value(report.get('generatedAt'))}`"}
                ],
            }
        )

    return {"text": text, "blocks": blocks}


def send_to_slack(webhook_url: str, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        webhook_url,
        data=body,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            status = response.getcode()
            if status < 200 or status >= 300:
                raise RuntimeError(f"Slack webhook returned HTTP {status}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Slack webhook failed: HTTP {exc.code} {detail}") from exc


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser()
    parser.add_argument("--report-json", required=True, help="Path to game-*-capacity.json")
    parser.add_argument("--webhook-url", default=os.getenv("CAPACITY_ADVISOR_SLACK_WEBHOOK_URL"))
    parser.add_argument("--report-url", help="Optional URL to the full report or workflow artifact.")
    parser.add_argument("--dry-run", action="store_true", help="Print Slack payload without sending.")
    args = parser.parse_args()

    report = json.loads(Path(args.report_json).read_text(encoding="utf-8"))
    payload = build_slack_payload(report, args.report_url)

    if args.dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return

    if not args.webhook_url:
        raise SystemExit("Slack webhook URL is required. Set CAPACITY_ADVISOR_SLACK_WEBHOOK_URL or pass --webhook-url.")

    send_to_slack(args.webhook_url, payload)
    print(json.dumps({"sent": True, "gameId": report["gameId"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
