import importlib.util
import sys
import unittest
from pathlib import Path


PATH = Path(__file__).parents[1] / "run_kafka_capacity_flow.py"
SPEC = importlib.util.spec_from_file_location("run_kafka_capacity_flow", PATH)
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


class KafkaCapacityFlowRunnerTest(unittest.TestCase):
    def test_extracts_first_json_object_from_kubectl_output(self):
        output = """
        warning: couldn't attach to pod/example
        {"success":true,"data":{"ticketAccessToken":"token-1"}}
        pod "example" deleted from baselink-dev namespace
        """

        value = runner.extract_json_object(output)

        self.assertTrue(value["success"])
        self.assertEqual("token-1", value["data"]["ticketAccessToken"])

    def test_raises_when_no_json_object_exists(self):
        with self.assertRaises(ValueError):
            runner.extract_json_object("pod deleted without response")


if __name__ == "__main__":
    unittest.main()
