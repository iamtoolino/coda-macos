#!/usr/bin/env python3
"""Check actual bundled-libmpv PCM scaling using the production Coda bridge, offline."""

import array
import math
from pathlib import Path
import struct
import subprocess
import sys
import wave


def main():
    root = Path(__file__).resolve().parents[1]
    prefix = root / ".build/libmpv/prefix"
    if not (prefix / "lib/libmpv.2.dylib").is_file():
        raise RuntimeError("Build libmpv first with scripts/build-libmpv.sh")
    output = root / ".build/replaygain-output-check"
    output.mkdir(parents=True, exist_ok=True)
    tone = output / "tone.wav"
    rate = 48000
    seconds = 4
    # Four seconds exceeds the PCM output buffer; low amplitude leaves ample headroom even for the boost case.
    with wave.open(str(tone), "wb") as wav:
        wav.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        wav.writeframes(b"".join(struct.pack("<h", round(3000 * math.sin(2 * math.pi * 1000 * i / rate)))
                                 for i in range(seconds * rate)))
    harness = output / "render"
    subprocess.run([
        "xcrun", "clang", str(root / "scripts/replaygain-output-harness.c"),
        "-I", str(root / "Sources/CMpv/include"), "-I", str(prefix / "include"),
        "-L", str(prefix / "lib"), "-lmpv", "-Wl,-rpath," + str(prefix / "lib"),
        "-o", str(harness),
    ], check=True)

    cases = [
        ("per-file", -6, -12, 0, [-6, -12]),
        ("updated-next", -6, -12, 1, [-6, -9]),
        ("fallback", -9, -9, 0, [-9, -9]),
        ("boost", 5, 5, 0, [5, 5]),
        ("unity", 0, 0, 0, [0, 0]),
        ("turned-off", -6, -12, 2, [0, 0]),
    ]
    for name, current, next_gain, scenario, expected in cases:
        rendered = output / (name + ".wav")
        rendered.unlink(missing_ok=True)
        subprocess.run([str(harness), str(tone), str(rendered), str(current),
                        str(next_gain), str(scenario)], check=True, timeout=20)
        with wave.open(str(rendered), "rb") as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) != (1, 2, rate, 2 * seconds * rate):
                raise RuntimeError(f"{name}: unexpected output format or duration")
            samples = array.array("h", wav.readframes(wav.getnframes()))
        if sys.byteorder != "little":
            samples.byteswap()
        # Sample early AND late in both files to catch stale initial or transition gain.
        measured = []
        for track, gain in enumerate(expected):
            for start, end in [(0.01, 0.05), (3.1, 3.9)]:
                segment = samples[track * seconds * rate + round(start * rate):track * seconds * rate + round(end * rate)]
                rms = math.sqrt(sum(value * value for value in segment) / len(segment))
                actual = 20 * math.log10(rms / (3000 / math.sqrt(2)))
                if abs(actual - gain) > 0.08:
                    raise RuntimeError(f"{name} track {track + 1}: {actual:.3f}dB, expected {gain}dB")
            measured.append(round(actual, 3))
        print(f"PASS {name}: {measured} dB")


if __name__ == "__main__":
    main()
