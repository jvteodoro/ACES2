#!/usr/bin/env python3
"""Check a captured 48 kHz stereo PCM16 WAV against the two-tone test input."""

import argparse
import math
import statistics
import wave


def positive_crossing_frequency(samples, sample_rate):
    if len(samples) < 3:
        return None
    center = statistics.fmean(samples)
    crossings = [i for i in range(1, len(samples))
                 if samples[i - 1] <= center < samples[i]]
    if len(crossings) < 2:
        return None
    return (len(crossings) - 1) * sample_rate / (crossings[-1] - crossings[0])


def analyze(path, sample_rate=48000, expected=(997.0, 1597.0), tolerance=15.0):
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.getnframes()
        raw = wav.readframes(frames)
    if channels != 2 or width != 2 or rate != sample_rate:
        raise ValueError(f"expected stereo PCM16/{sample_rate} Hz; got "
                         f"{channels} ch, {width * 8} bit, {rate} Hz")
    if frames < sample_rate // 2:
        raise ValueError("capture is shorter than 0.5 seconds")

    samples = [[], []]
    for offset in range(0, len(raw), 4):
        left = int.from_bytes(raw[offset:offset + 2], "little", signed=True)
        right = int.from_bytes(raw[offset + 2:offset + 4], "little", signed=True)
        samples[0].append(left)
        samples[1].append(right)

    results = []
    for name, values, target in zip(("left", "right"), samples, expected):
        mean = statistics.fmean(values)
        rms = math.sqrt(statistics.fmean((value - mean) ** 2 for value in values))
        peak = max(abs(value) for value in values)
        frequency = positive_crossing_frequency(values, rate)
        if frequency is None or abs(frequency - target) > tolerance:
            raise ValueError(f"{name} tone mismatch: expected {target:g}±{tolerance:g} Hz, "
                             f"measured {frequency}")
        if rms < 100 or peak >= 32760:
            raise ValueError(f"{name} level invalid: RMS={rms:.1f}, peak={peak}")
        results.append((name, frequency, rms, peak))
    return frames, results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav")
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--left-hz", type=float, default=997.0)
    parser.add_argument("--right-hz", type=float, default=1597.0)
    parser.add_argument("--tolerance-hz", type=float, default=15.0)
    args = parser.parse_args()
    try:
        frames, results = analyze(args.wav, args.sample_rate,
                                  (args.left_hz, args.right_hz), args.tolerance_hz)
    except (OSError, ValueError, wave.Error) as error:
        parser.error(str(error))
    print(f"PASS: {frames} frames ({frames / args.sample_rate:.3f} s) at "
          f"{args.sample_rate} Hz")
    for name, frequency, rms, peak in results:
        print(f"{name}: {frequency:.2f} Hz, RMS={rms:.1f}, peak={peak}")


if __name__ == "__main__":
    main()
