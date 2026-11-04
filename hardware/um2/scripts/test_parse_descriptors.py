import unittest
from pathlib import Path
from parse_descriptors import parse

class DescriptorParserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.blob = (Path(__file__).parents[1] / "device_descriptors.bin").read_bytes()

    def test_observed_device_and_capture_alternates(self):
        parsed = parse(self.blob)
        self.assertEqual((parsed["device"]["vid"], parsed["device"]["pid"]), ("08bb", "2902"))
        self.assertEqual(parsed["configuration"]["total_length"], 1191)
        capture = [i for i in parsed["configuration"]["interfaces"] if i["number"] == 2]
        self.assertEqual(len(capture), 19)  # alt 0 plus alts 1..18
        alt1 = next(i for i in capture if i["alternate_setting"] == 1)
        self.assertEqual(alt1["endpoints"][0]["address"], 0x84)
        self.assertEqual(alt1["endpoints"][0]["max_packet_size"], 196)

    def test_truncated_configuration_rejected(self):
        with self.assertRaises(ValueError):
            parse(self.blob[:-1])

    def test_invalid_descriptor_length_rejected(self):
        damaged = bytearray(self.blob)
        damaged[18] = 1  # config descriptor bLength must be >= 9
        with self.assertRaises(ValueError):
            parse(bytes(damaged))

if __name__ == "__main__":
    unittest.main()
