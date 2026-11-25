#!/usr/bin/env python3
"""Render the Wellbore Fluid Race dialogue library to Godot-ready offline audio."""
import argparse
import asyncio
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

try:
    import edge_tts
except ImportError:
    raise SystemExit("Install Edge TTS with: python -m pip install edge-tts==7.3.1")

PCM_RATE = 24_000
ENVELOPE_RATE = 50
VOICE_PROFILES = {
    "olly": ("en-US-GuyNeural", 10, 29),
    "gizmo": ("en-US-AnaNeural", 16, 16),
    "narrator": ("en-US-AndrewNeural", -4, 0),
}
# Relative rate (percentage points) and pitch (Hz) by delivery.
EMOTION_OFFSETS = {
    "excited": (4, 5),
    "happy": (2, 3),
    "surprised": (0, 6),
    "afraid": (-4, 5),
    "competitive": (2, 1),
    "laughing": (1, 5),
    "celebrating": (-2, 7),
    "frustrated": (-2, -4),
    "mischievous": (3, 2),
    "confident": (0, 0),
    "friendly": (-3, -2),
    "narrating": (0, 0),
    "curious": (-3, 2),
    "determined": (-3, -3),
    "confused": (-4, 3),
    "proud": (-1, 1),
    "playful": (2, 3),
    "relaxed": (-4, -3),
    "dramatic": (-5, 2),
    "worried": (-4, 4),
    "triumphant": (1, 6),
}


def ffmpeg(*args, payload=None):
    return subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", *args],
        input=payload, capture_output=True, check=True,
    ).stdout


def rms(samples):
    return math.sqrt(sum(value * value for value in samples) / max(1, len(samples)))


def prepare_wave(mp3_path):
    raw = ffmpeg(
        "-i", str(mp3_path), "-af", "highpass=f=75", "-ac", "1",
        "-ar", str(PCM_RATE), "-f", "s16le", "-",
    )
    samples = list(sample for (sample,) in struct.iter_unpack("<h", raw))
    block = PCM_RATE // 100
    gate = max(65, max(map(abs, samples), default=0) * 0.014)
    active = [
        offset for offset in range(0, len(samples), block)
        if rms(samples[offset:offset + block]) >= gate
    ]
    if not active:
        raise ValueError("Edge TTS returned audio without measurable speech")
    start = max(0, active[0] - 4 * block)
    end = min(len(samples), active[-1] + 10 * block)
    speech_rms = rms(samples[active[0]:active[-1] + block])
    samples = samples[start:end]
    peak = max(map(abs, samples))
    gain = min(3000 / speech_rms, 26000 / peak)
    fade = min(PCM_RATE // 200, len(samples) // 2)
    for offset in range(fade):
        fade_gain = offset / fade
        samples[offset] *= fade_gain
        samples[-1 - offset] *= fade_gain
    samples = [round(sample * gain) for sample in samples]

    # Attack-smoothed movement calibrated to each clip's syllable energy.
    frame = PCM_RATE // ENVELOPE_RATE
    energies = [rms(samples[index:index + frame]) for index in range(0, len(samples), frame)]
    ordered = sorted(energies)
    reference = max(600.0, ordered[round(0.90 * (len(ordered) - 1))])
    floor = max(90, 0.06 * reference)
    envelope = [
        round(min(1.0, max(0.0, (energy - floor) / (reference - floor)) ** 0.66), 3)
        for energy in energies
    ]
    return struct.pack(f"<{len(samples)}h", *samples), envelope


def stream_file(output, mp3_path):
    samples, envelope = prepare_wave(mp3_path)
    tmp_output = output.with_suffix(".tmp.ogg")
    try:
        ffmpeg(
            "-y", "-f", "s16le", "-ar", str(PCM_RATE), "-ac", "1", "-i", "-",
            "-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", "5", str(tmp_output),
            payload=samples,
        )
        tmp_output.replace(output)
    finally:
        tmp_output.unlink(missing_ok=True)
    return envelope


def atomic_json(path, data):
    temp = path.with_suffix(".tmp.json")
    temp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    temp.replace(path)


def audio_settings(line):
    voice, base_rate, base_pitch = VOICE_PROFILES[line["speaker"]]
    rate, pitch = EMOTION_OFFSETS.get(line["emotion"], (0, 0))
    # Natural spelling keeps elongated cartoon exclamations pronounceable.
    script = line.get("delivery") or line["text"]
    script = {
        "WE MADE IT!": "We made it!",
        "WHOOOAA! What was THAT?": "Whoa! What was that?",
        "Ta-daaa! Guess who's here!": "Ta-da! Guess who's here!",
    }.get(script, script)
    return voice, f"{base_rate + rate:+d}%", f"{base_pitch + pitch:+d}Hz", script


async def generate(args):
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    clips = {
        line_id: line for line_id, line in manifest["lines"].items() if line["speaker"] != "both"
    }
    requested = set(args.line)
    unknown = requested - clips.keys()
    if unknown:
        raise SystemExit("Unknown individual clip IDs: " + ", ".join(sorted(unknown)))

    root = args.manifest.parent / "voices"
    root.mkdir(parents=True, exist_ok=True)
    envelope_path = root / "envelopes.json"
    cache = {"sample_rate": ENVELOPE_RATE, "tracks": {}, "source_hashes": {}}
    if envelope_path.exists():
        previous = json.loads(envelope_path.read_text(encoding="utf-8"))
        if previous.get("sample_rate") == ENVELOPE_RATE:
            cache["tracks"] = previous["tracks"]
            cache["source_hashes"] = previous.get("source_hashes", {})
    if not requested:
        for key in ("tracks", "source_hashes"):
            cache[key] = {line_id: value for line_id, value in cache[key].items() if line_id in clips}

    jobs = asyncio.Semaphore(args.jobs)
    failed = []

    async def synthesize(line_id, line):
        if not re.fullmatch(r"[A-Za-z0-9_]+", line_id):
            raise ValueError(f"Unsafe dialogue identifier: {line_id}")
        voice, rate, pitch, script = audio_settings(line)
        signature = hashlib.sha256(
            json.dumps([2, voice, rate, pitch, script], ensure_ascii=False).encode("utf-8")
        ).hexdigest()
        directory = root / line["speaker"]
        directory.mkdir(exist_ok=True)
        output = directory / f"{line_id.lower()}.ogg"
        if not args.force and (
            cache["source_hashes"].get(line_id) == signature
            and cache["tracks"].get(line_id)
            and output.exists()
            and output.stat().st_size > 400
        ):
            return
        async with jobs:
            for attempt in range(4):
                try:
                    with tempfile.TemporaryDirectory(prefix="wellbore_voice_") as temp_directory:
                        mp3 = Path(temp_directory) / "speech.mp3"
                        communicate = edge_tts.Communicate(
                            script, voice=voice, rate=rate, pitch=pitch, proxy=args.proxy
                        )
                        await communicate.save(str(mp3))
                        envelope = await asyncio.to_thread(stream_file, output, mp3)
                    cache["tracks"][line_id] = envelope
                    cache["source_hashes"][line_id] = signature
                    atomic_json(envelope_path, cache)
                    print(f"OK {line_id} {line['speaker']} {len(envelope) / ENVELOPE_RATE:.2f}s", flush=True)
                    return
                except Exception as error:
                    if attempt < 3:
                        await asyncio.sleep(1.5 * 2 ** attempt)
                    else:
                        detail = error.stderr.decode("utf-8", errors="replace").strip() if (
                            isinstance(error, subprocess.CalledProcessError)
                        ) else str(error)
                        print(f"FAILED {line_id}: {type(error).__name__}: {detail}", file=sys.stderr, flush=True)
                        failed.append(line_id)

    await asyncio.gather(*(
        synthesize(line_id, line) for line_id, line in clips.items()
        if not requested or line_id in requested
    ))
    atomic_json(envelope_path, cache)
    if failed:
        print("Incomplete or failed to regenerate: " + ", ".join(sorted(failed)), file=sys.stderr)
        return 1
    print(f"Voice library updated with {len(cache['tracks'])}/{len(clips)} individual clips.")
    return 0


def main():
    default_manifest = Path(__file__).resolve().parents[1] / "audio" / "dialogue.json"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=default_manifest)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--line", action="append", default=[], help="Render this ID. Repeat for more.")
    parser.add_argument("--force", action="store_true", help="Regenerate unchanged audio.")
    parser.add_argument("--proxy", default=os.getenv("HTTPS_PROXY") or os.getenv("https_proxy"))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if not shutil.which("ffmpeg"):
        parser.error("FFmpeg with libvorbis must be on PATH")
    return asyncio.run(generate(args))


if __name__ == "__main__":
    sys.exit(main())
