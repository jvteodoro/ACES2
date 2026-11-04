import struct
import unittest

from aces2_udp_receiver import decode_pcm_frames


class DecodePcmFramesTest(unittest.TestCase):
    def test_stereo_unpacks_left_then_right_and_preserves_sign(self):
        payload = struct.pack("<II", 0x7FFF8000, 0x80000001)
        expected = struct.pack("<hhhh", -32768, 32767, 1, -32768)
        self.assertEqual(decode_pcm_frames(payload, channels=2), expected)

    def test_mono_uses_left_channel(self):
        payload = struct.pack("<II", 0x7FFF8000, 0x80000001)
        expected = struct.pack("<hh", -32768, 1)
        self.assertEqual(decode_pcm_frames(payload, channels=1), expected)

    def test_rejects_partial_input_frame(self):
        with self.assertRaises(ValueError):
            decode_pcm_frames(b"\x00", channels=2)


if __name__ == "__main__":
    unittest.main()
