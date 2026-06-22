#!/usr/bin/env python3
"""Generate clearly labelled synthetic capacity events through the SQS pipeline."""

import argparse
import json
import random
import subprocess
import uuid
from datetime import datetime, timedelta, timezone


EVENT_TYPES = (
    "WAITING_ENTERED",
    "ACCESS_TOKEN_ISSUED",
    "RESERVATION_REQUESTED",
    "RESERVATION_CONFIRMED",
)


def envelope(event_type, game_id, occurred_at, payload):
    event_id = str(uuid.uuid4())
    return {
        "eventId": event_id,
        "eventType": event_type,
        "schemaVersion": 1,
        "occurredAt": occurred_at.isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"
        ),
        "producer": "capacity-load-test",
        "aggregateType": "CAPACITY_TEST",
        "aggregateId": event_id,
        "gameId": game_id,
        "userKey": None,
        "traceId": "capacity-load-test",
        "payload": payload,
    }


def build_events(game_id, samples, conversion_rate, seed):
    rng = random.Random(seed)
    now = datetime.now(timezone.utc)
    events = []
    confirmed_samples = math_floor(samples * conversion_rate)
    for index in range(samples):
        occurred_at = now - timedelta(
            minutes=(samples - index - 1) // 5,
            seconds=rng.randint(0, 50),
        )
        waiting_seconds = rng.randint(20, 100)
        effective_enter = rng.randint(28, 36)
        events.extend(
            [
                envelope(
                    "WAITING_ENTERED",
                    game_id,
                    occurred_at - timedelta(seconds=waiting_seconds),
                    {
                        "initialRank": index + 1,
                        "policyMaxEnterPerMinute": 40,
                    },
                ),
                envelope(
                    "ACCESS_TOKEN_ISSUED",
                    game_id,
                    occurred_at,
                    {
                        "waitingSeconds": waiting_seconds,
                        "effectiveEnterPerMinute": effective_enter,
                        "dbPressureLevel": "NORMAL",
                        "dbThrottlePercent": 100,
                    },
                ),
                envelope(
                    "RESERVATION_REQUESTED",
                    game_id,
                    occurred_at + timedelta(seconds=2),
                    {
                        "reservationId": 900000 + index,
                        "seatId": 1000 + index,
                        "status": "PENDING",
                    },
                ),
            ]
        )
        if index < confirmed_samples:
            events.append(
                envelope(
                    "RESERVATION_CONFIRMED",
                    game_id,
                    occurred_at + timedelta(seconds=rng.randint(8, 25)),
                    {
                        "reservationId": 900000 + index,
                        "seatId": 1000 + index,
                        "status": "CONFIRMED",
                        "pendingDurationSeconds": rng.randint(6, 23),
                    },
                )
            )
    return events


def math_floor(value):
    return int(value // 1)


def send_batches(events, queue_url, region):
    for offset in range(0, len(events), 10):
        entries = [
            {
                "Id": str(index),
                "MessageBody": json.dumps(event, separators=(",", ":")),
            }
            for index, event in enumerate(events[offset : offset + 10])
        ]
        subprocess.run(
            [
                "aws",
                "sqs",
                "send-message-batch",
                "--queue-url",
                queue_url,
                "--entries",
                json.dumps(entries, separators=(",", ":")),
                "--region",
                region,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-id", type=int, default=1)
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--conversion-rate", type=float, default=0.8)
    parser.add_argument("--seed", type=int, default=20260622)
    parser.add_argument(
        "--queue-url",
        default=(
            "https://sqs.ap-northeast-2.amazonaws.com/"
            "740831361032/ticket-domain-events"
        ),
    )
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.samples < 1:
        raise SystemExit("--samples must be at least 1")
    if not 0 <= args.conversion_rate <= 1:
        raise SystemExit("--conversion-rate must be between 0 and 1")

    events = build_events(
        args.game_id, args.samples, args.conversion_rate, args.seed
    )
    counts = {
        event_type: sum(1 for event in events if event["eventType"] == event_type)
        for event_type in EVENT_TYPES
    }
    if not args.dry_run:
        send_batches(events, args.queue_url, args.region)
    print(
        json.dumps(
            {
                "producer": "capacity-load-test",
                "gameId": args.game_id,
                "dryRun": args.dry_run,
                "eventCount": len(events),
                "eventsByType": counts,
                "seed": args.seed,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
