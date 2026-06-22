import importlib.util
import unittest
from pathlib import Path


PATH = Path(__file__).parents[1] / "generate_capacity_test_events.py"
SPEC = importlib.util.spec_from_file_location("capacity_test_events", PATH)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)


class CapacityTestEventGeneratorTest(unittest.TestCase):
    def test_generates_labelled_reproducible_scenario(self):
        first = generator.build_events(1, 10, 0.8, 1234)
        second = generator.build_events(1, 10, 0.8, 1234)

        self.assertEqual(38, len(first))
        self.assertEqual(
            [event["eventType"] for event in first],
            [event["eventType"] for event in second],
        )
        self.assertTrue(
            all(event["producer"] == "capacity-load-test" for event in first)
        )
        self.assertEqual(
            8,
            sum(
                event["eventType"] == "RESERVATION_CONFIRMED"
                for event in first
            ),
        )


if __name__ == "__main__":
    unittest.main()
