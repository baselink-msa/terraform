import importlib.util
import sys
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).parents[1]
sys.path.insert(0, str(TOOLS_DIR))

PATH = TOOLS_DIR / "record_sqs_worker_audit.py"
SPEC = importlib.util.spec_from_file_location("record_sqs_worker_audit", PATH)
recorder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = recorder
SPEC.loader.exec_module(recorder)


class SqsWorkerAuditRecorderTest(unittest.TestCase):
    def test_event_type_for_status(self):
        self.assertEqual(
            "SQS_DLQ_DETECTED",
            recorder.event_type_for_status("DLQ_DETECTED"),
        )
        self.assertEqual(
            "SQS_BACKLOG_DETECTED",
            recorder.event_type_for_status("BACKLOG"),
        )
        self.assertEqual(
            "SQS_WORKER_STATUS_RECORDED",
            recorder.event_type_for_status("HEALTHY"),
        )

    def test_build_sqs_worker_audit_event(self):
        summary = recorder.SqsWorkerSummary(
            status="BACKLOG",
            visible_messages=12,
            not_visible_messages=3,
            oldest_message_age_seconds=180,
            dlq_visible_messages=0,
            dlq_oldest_message_age_seconds=0,
        )

        event = recorder.build_sqs_worker_audit_event(summary)

        self.assertEqual("SQS_BACKLOG_DETECTED", event["eventType"])
        self.assertEqual("sqs-worker-audit-recorder", event["producer"])
        self.assertEqual("INFRA_AUDIT", event["aggregateType"])
        self.assertEqual(12, event["payload"]["visibleMessages"])


if __name__ == "__main__":
    unittest.main()
