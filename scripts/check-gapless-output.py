#!/usr/bin/env python3
"""Check sample-exact gapless output of the production Coda bridge and bundled libmpv, offline."""

import array
import http.server
import math
from pathlib import Path
import shutil
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
PREFIX = ROOT / ".build/libmpv/prefix"
OUTPUT = ROOT / ".build/gapless-output-check"
# Odd lengths so no track ends on a codec frame boundary.
LENGTHS = {48000: (100001, 91873), 44100: (91877, 88211)}
TOLERANCE = 64  # PCM16 units: FFmpeg CLI and bundled decoder versions may round differently.


def run(*arguments, **options):
    return subprocess.run([str(argument) for argument in arguments], check=True, **options)


def decode(path, rate, channels):
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le",
                                   "-ac", str(channels), "-ar", str(rate), "-"])
    samples = array.array("h")
    samples.frombytes(raw)
    return samples


def encoders():
    listing = subprocess.check_output(["ffmpeg", "-hide_banner", "-encoders"], text=True)
    available = {line.split()[1] for line in listing.splitlines() if line.startswith(" A")}
    # Native FFmpeg AAC writes an edit list; Apple's encoder writes only iTunSMPB.
    codecs = [("flac", ["-c:a", "flac"]), ("opus", ["-c:a", "libopus", "-b:a", "128k"]),
              ("mp3", ["-c:a", "libmp3lame", "-b:a", "192k"]),
              ("m4a", ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]),
              ("ogg", ["-c:a", "libvorbis", "-q:a", "5"])]
    usable = [(ext, args) for ext, args in codecs if args[1] in available]
    if shutil.which("afconvert"):
        usable.append(("apple.m4a", None))
    return usable


def make_fixtures(fixtures):
    tracks = {}
    for rate, channels in [(48000, 1), (44100, 2)]:
        for index, frames in enumerate(LENGTHS[rate]):
            # Distinct chirps make any misalignment visible, unlike a periodic tone.
            source = fixtures / f"{rate}-{index}.wav"
            run("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                f"aevalsrc=0.3*sin(2*PI*({200 + 150 * index}+{300 + 200 * index}*t)*t):s={rate}:d=3",
                "-af", f"atrim=end_sample={frames}", "-ac", channels, source)
            for ext, args in encoders():
                if ext == "opus" and rate != 48000:
                    continue
                encoded = fixtures / f"{rate}-{index}.{ext}"
                if args is None:
                    run("afconvert", "-f", "m4af", "-d", "aac", "-b", "192000", source, encoded)
                else:
                    run("ffmpeg", "-v", "error", "-y", "-i", source, *args, encoded)
                tracks.setdefault((ext, rate, channels), []).append((encoded, frames))
    return tracks


class Server(http.server.BaseHTTPRequestHandler):
    root = None

    def do_GET(self):
        path, _, query = self.path.partition("?")
        data = (self.root / path.lstrip("/")).read_bytes()
        start, end = 0, len(data) - 1
        ranged = query == "range" and "Range" in self.headers
        if ranged:
            first, last = self.headers["Range"].removeprefix("bytes=").split("-")
            start, end = int(first), int(last) if last else end
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", "application/octet-stream")
        if query == "range":
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
        if ranged:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        # Without Content-Length, HTTP/1.0 closes the connection: an unknown-length stream.
        self.end_headers()
        self.wfile.write(data[start:end + 1])

    def log_message(self, *arguments):
        pass


def check(harness, name, tracks, sequence, rate, channels, location, start=0.0):
    pcm = OUTPUT / (name + ".pcm")
    pcm.unlink(missing_ok=True)
    arguments = [harness, pcm, rate, "mono" if channels == 1 else "stereo", start]
    for index in sequence:
        arguments += [location(tracks[index][0]), 0]
    run(*arguments, timeout=60)
    actual = array.array("h")
    actual.frombytes(pcm.read_bytes())

    references = [decode(tracks[index][0], rate, channels) for index in sequence]
    skipped = round(start * rate) * channels
    references[0] = references[0][skipped:]
    expected_frames = sum(len(reference) for reference in references) // channels
    if len(actual) // channels != expected_frames:
        return f"{len(actual) // channels} frames, expected {expected_frames}"

    offset = 0
    for track, reference in enumerate(references):
        # Each occurrence must start and end exactly where its reference does.
        edge = 1024 * channels
        window = list(range(min(edge, len(reference)))) + list(range(max(0, len(reference) - edge), len(reference)))
        error = max(abs(actual[offset + i] - reference[i]) for i in window)
        if error > TOLERANCE:
            return f"track {track + 1} edge error {error}"
        rms = math.sqrt(sum((actual[offset + i] - reference[i]) ** 2
                            for i in range(0, len(reference), 7)) / (len(reference) / 7))
        if rms > TOLERANCE / 4:
            return f"track {track + 1} RMS error {rms:.1f}"
        offset += len(reference)
    return None


def main():
    if not (PREFIX / "lib/libmpv.2.dylib").is_file():
        raise RuntimeError("Build libmpv first with scripts/build-libmpv.sh")
    if not shutil.which("ffmpeg"):
        raise RuntimeError("This check needs the ffmpeg command-line tool to create and decode fixtures")
    fixtures = OUTPUT / "fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    harness = OUTPUT / "render"
    run("xcrun", "clang", ROOT / "scripts/gapless-output-harness.c",
        "-I", ROOT / "Sources/CMpv/include", "-I", PREFIX / "include",
        "-L", PREFIX / "lib", "-lmpv", "-Wl,-rpath," + str(PREFIX / "lib"), "-o", harness)

    Server.root = fixtures
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    locations = {
        "local": str,
        "http-range": lambda path: base + path.name + "?range",
        "http-unknown-length": lambda path: base + path.name,
    }

    failures = 0
    for (ext, rate, channels), tracks in make_fixtures(fixtures).items():
        label = f"{ext} {rate} Hz {'mono' if channels == 1 else 'stereo'}"
        exact = all(len(decode(path, rate, channels)) == frames * channels for path, frames in tracks)
        if not exact:
            print(f"SKIP {label}: this FFmpeg encoder does not record exact track lengths")
            continue
        cases = [(mode, location, [0, 1, 0], 0.0) for mode, location in locations.items()]
        # A resumed first track must not change the following, gapless occurrences.
        cases.append(("resume", locations["http-range"], [0, 1], 0.5))
        for mode, location, sequence, start in cases:
            name = f"{ext}-{rate}-{channels}-{mode}"
            problem = check(harness, name, tracks, sequence, rate, channels, location, start)
            if mode == "resume" and problem:
                # A resume position is not a transition and need not be sample-exact,
                # but every following occurrence must be.
                problem = check_tail(name, tracks, sequence, rate, channels)
            print(f"{'FAIL' if problem else 'PASS'} {label} {mode}" + (f": {problem}" if problem else ""))
            failures += bool(problem)
    server.shutdown()
    if failures:
        sys.exit(f"{failures} gapless case(s) failed")


def check_tail(name, tracks, sequence, rate, channels):
    actual = array.array("h")
    actual.frombytes((OUTPUT / (name + ".pcm")).read_bytes())
    later = array.array("h")
    for index in sequence[1:]:
        later += decode(tracks[index][0], rate, channels)
    tail = actual[len(actual) - len(later):]
    error = max(abs(tail[i] - later[i]) for i in range(len(later)))
    return f"tracks after the resumed one differ by {error}" if error > TOLERANCE else None


if __name__ == "__main__":
    main()
