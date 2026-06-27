#!/usr/bin/env python3
"""Generate real capacity-advisor sample events through the dev services.

The runner calls the same internal Kubernetes services used during the Kafka
Capacity Advisor E2E verification:

1. waiting-room-service enter
2. waiting-room-service issue-token
3. ticket-service reserve
4. ticket-service confirm

It does not write directly to Kafka or S3. The backend services publish events,
then tools/kafka_s3_sink.py can drain the Kafka topics into S3/Athena.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Any


@dataclass(frozen=True)
class FlowResult:
    index: int
    user_id: int
    seat_id: int
    status: str
    ticket_access_token: str | None = None
    reservation_id: int | None = None
    error: str | None = None


def extract_json_object(text: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise ValueError(f"No JSON object found in command output: {text}")


def kubectl_curl(
    namespace: str,
    pod_name: str,
    method: str,
    url: str,
    user_id: int,
    timeout_seconds: int,
) -> dict[str, Any]:
    completed = subprocess.run(
        [
            "kubectl",
            "run",
            pod_name,
            "-n",
            namespace,
            "--rm",
            "-i",
            "--restart=Never",
            "--image=curlimages/curl:8.8.0",
            "--command",
            "--",
            "curl",
            "-sS",
            "-m",
            str(timeout_seconds),
            "-X",
            method,
            "-H",
            f"X-User-Id: {user_id}",
            url,
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout_seconds + 60,
        check=False,
    )
    combined = "\n".join(part for part in [completed.stdout, completed.stderr] if part)
    if completed.returncode != 0:
        raise RuntimeError(combined.strip())
    try:
        return extract_json_object(combined)
    except ValueError as exc:
        raise ValueError(f"{exc}; returnCode={completed.returncode}") from exc


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run_one_flow(args: argparse.Namespace, index: int, base_suffix: int) -> FlowResult:
    user_id = args.base_user_id + index
    seat_id = args.base_seat_id + index
    pod_suffix = f"{base_suffix}-{index}"

    try:
        log(f"[{index}] enter waiting room: gameId={args.game_id} userId={user_id}")
        enter_response = kubectl_curl(
            args.namespace,
            f"capacity-flow-enter-{pod_suffix}",
            "POST",
            f"{args.waiting_base_url}/api/waiting-room/games/{args.game_id}/enter",
            user_id,
            args.http_timeout_seconds,
        )
        enter_data = enter_response.get("data") or {}
        log(
            f"[{index}] enter result: "
            f"position={enter_data.get('position')} "
            f"canEnter={enter_data.get('canEnter')} "
            f"effectiveEnterPerMinute={enter_data.get('effectiveEnterPerMinute')}"
        )

        token_response: dict[str, Any] | None = None
        last_token_error: str | None = None
        for attempt in range(1, args.issue_token_max_attempts + 1):
            log(f"[{index}] issue token attempt {attempt}/{args.issue_token_max_attempts}")
            try:
                candidate = kubectl_curl(
                    args.namespace,
                    f"capacity-flow-token-{pod_suffix}-{attempt}",
                    "POST",
                    f"{args.waiting_base_url}/api/waiting-room/games/{args.game_id}/issue-token",
                    user_id,
                    args.http_timeout_seconds,
                )
                if candidate.get("success") is True and candidate.get("data"):
                    token_response = candidate
                    log(f"[{index}] issue token succeeded")
                    break
                last_token_error = json.dumps(candidate, ensure_ascii=False)
            except Exception as exc:
                last_token_error = str(exc)

            if attempt < args.issue_token_max_attempts:
                time.sleep(args.issue_token_retry_delay_seconds)

        if token_response is None:
            raise RuntimeError(f"issue-token failed after retries: {last_token_error}")

        token = token_response["data"]["ticketAccessToken"]
        log(f"[{index}] reserve ticket: seatId={seat_id}")
        reservation = kubectl_curl(
            args.namespace,
            f"capacity-flow-reserve-{pod_suffix}",
            "POST",
            (
                f"{args.ticket_base_url}/api/tickets/reserve"
                f"?gameId={args.game_id}&seatId={seat_id}&lockId={token}"
            ),
            user_id,
            args.http_timeout_seconds,
        )
        reservation_id = int(reservation["reservationId"])
        log(f"[{index}] reservation requested: reservationId={reservation_id}")

        if not args.skip_confirm:
            log(f"[{index}] confirm reservation: reservationId={reservation_id}")
            kubectl_curl(
                args.namespace,
                f"capacity-flow-confirm-{pod_suffix}",
                "POST",
                f"{args.ticket_base_url}/api/tickets/{reservation_id}/confirm",
                user_id,
                args.http_timeout_seconds,
            )
            log(f"[{index}] reservation confirmed: reservationId={reservation_id}")

        return FlowResult(
            index=index,
            user_id=user_id,
            seat_id=seat_id,
            status="CONFIRMED" if not args.skip_confirm else "PENDING",
            ticket_access_token=token,
            reservation_id=reservation_id,
        )
    except Exception as exc:
        if args.stop_on_error:
            raise
        return FlowResult(
            index=index,
            user_id=user_id,
            seat_id=seat_id,
            status="FAILED",
            error=str(exc),
        )


def main() -> None:
    now = int(time.time())
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=1)
    parser.add_argument(
        "--game-id",
        type=int,
        default=9001,
        help=(
            "Game id used for sample generation. The default uses an isolated "
            "dev sample id to avoid stale users in the real game 1 waiting queue."
        ),
    )
    parser.add_argument("--namespace", default="baselink-dev")
    parser.add_argument("--waiting-base-url", default="http://waiting-room-service:8084")
    parser.add_argument("--ticket-base-url", default="http://ticket-service:8087")
    parser.add_argument("--base-user-id", type=int, default=960000000 + now)
    parser.add_argument("--base-seat-id", type=int, default=1900000000 + now)
    parser.add_argument("--http-timeout-seconds", type=int, default=30)
    parser.add_argument("--issue-token-max-attempts", type=int, default=20)
    parser.add_argument("--issue-token-retry-delay-seconds", type=int, default=5)
    parser.add_argument("--sleep-between-samples-seconds", type=int, default=0)
    parser.add_argument("--skip-confirm", action="store_true")
    parser.add_argument("--stop-on-error", action="store_true")
    args = parser.parse_args()

    if args.samples <= 0:
        raise ValueError("--samples must be greater than zero")

    started_at = datetime.now(timezone.utc).isoformat()
    results: list[FlowResult] = []
    for index in range(args.samples):
        result = run_one_flow(args, index, now)
        results.append(result)
        print(json.dumps(asdict(result), ensure_ascii=False), flush=True)
        if index < args.samples - 1 and args.sleep_between_samples_seconds > 0:
            time.sleep(args.sleep_between_samples_seconds)

    summary = {
        "startedAt": started_at,
        "finishedAt": datetime.now(timezone.utc).isoformat(),
        "samplesRequested": args.samples,
        "succeeded": sum(1 for result in results if result.status != "FAILED"),
        "failed": sum(1 for result in results if result.status == "FAILED"),
        "results": [asdict(result) for result in results],
    }
    print(json.dumps({"summary": summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
