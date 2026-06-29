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


if __name__ == "__main__":
    unittest.main()
