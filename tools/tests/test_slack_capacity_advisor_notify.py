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


if __name__ == "__main__":
    unittest.main()
