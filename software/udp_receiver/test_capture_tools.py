import math
import tempfile
import unittest
import wave

from analyze_capture import analyze


def write_tone(path, sample_rate=48000, seconds=1.0):
    with wave.open(path, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        frames = bytearray()
        for n in range(int(sample_rate * seconds)):
            left = round(4000 * math.sin(2 * math.pi * 997 * n / sample_rate))
            right = round(5000 * math.sin(2 * math.pi * 1597 * n / sample_rate))
            frames.extend(left.to_bytes(2, "little", signed=True))
            frames.extend(right.to_bytes(2, "little", signed=True))
        wav.writeframes(frames)


class CaptureToolsTest(unittest.TestCase):
    def test_detects_stereo_tones_in_order(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as temp:
            write_tone(temp.name)
            frames, channels = analyze(temp.name)
        self.assertEqual(frames, 48000)
        self.assertEqual([channel[0] for channel in channels], ["left", "right"])
        self.assertAlmostEqual(channels[0][1], 997, delta=2)
        self.assertAlmostEqual(channels[1][1], 1597, delta=2)

    def test_rejects_wrong_channel_format(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as temp:
            with wave.open(temp.name, "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(48000)
                wav.writeframes(b"\x00\x00" * 24000)
            with self.assertRaises(ValueError):
                analyze(temp.name)


if __name__ == "__main__":
    unittest.main()
