"""Render the original Laboratory loop with Python, NumPy and FFmpeg."""

import argparse
import math
from pathlib import Path
import subprocess

import numpy as np


SAMPLE_RATE = 44_100
BEAT = 0.5
BAR = 4 * BEAT
DURATION = 16 * BAR
SAMPLES = round(DURATION * SAMPLE_RATE)
TAU = math.tau
RNG = np.random.default_rng(93706)


def frequency(note):
    return 440.0 * 2 ** ((note - 69) / 12.0)


def time_axis(duration):
    return np.arange(round(duration * SAMPLE_RATE)) / SAMPLE_RATE


def envelope(time, attack, release):
    fade_in = np.sin(np.minimum(time / attack, 1.0) * math.pi * 0.5) ** 2
    fade_out = np.sin(np.minimum((time[-1] - time) / release, 1.0) * math.pi * 0.5) ** 2
    return fade_in * fade_out


def overlay(mix, signal, start, pan):
    offset = round(start * SAMPLE_RATE) % SAMPLES
    samples_before_wrap = min(signal.size, SAMPLES - offset)
    angle = (pan + 1.0) * math.pi / 4.0
    stereo = signal[:, None] * np.array([math.cos(angle), math.sin(angle)])
    mix[offset:offset + samples_before_wrap] += stereo[:samples_before_wrap]
    mix[:signal.size - samples_before_wrap] += stereo[samples_before_wrap:]


def pad(note, phase):
    time = time_axis(2.88)
    angle = TAU * frequency(note) * time
    warmth = np.sin(angle + phase) + 0.26 * np.sin(2 * angle + 1.0) + 0.09 * np.sin(3 * angle)
    gain = 0.82 + 0.18 * np.sin(TAU * 0.35 * time + phase)
    return warmth * gain * envelope(time, 0.70, 0.78)


def pluck(note):
    time = time_axis(0.89)
    angle = TAU * frequency(note) * time
    brass = np.sin(angle + 0.38 * np.exp(-time * 15.0) * np.sin(2.0 * angle))
    bell = 0.16 * np.sin(2.0 * angle) * np.exp(-time * 8.0)
    return (brass + bell) * np.exp(-time * 6.4) * envelope(time, 0.013, 0.08)


def bass(note):
    time = time_axis(0.47)
    angle = TAU * frequency(note) * time
    tone = np.sin(angle) + 0.24 * np.sin(2.0 * angle - 0.23)
    return tone * np.exp(-time * 3.2) * envelope(time, 0.022, 0.12)


def kick():
    time = time_axis(0.30)
    phase = TAU * (44.0 * time + 3.8 * (1.0 - np.exp(-time * 31.0)))
    return np.sin(phase) * np.exp(-time * 16.0) * envelope(time, 0.011, 0.10)


def shaker(duration):
    time = time_axis(duration)
    noise = RNG.standard_normal(time.size)
    # Differencing approximates a soft high-pass on the percussion.
    bright = np.diff(noise, prepend=0.0)
    return bright * np.exp(-time * 33.0) * envelope(time, 0.006, 0.025)


def render():
    mix = np.zeros((SAMPLES, 2))
    chords = (
        (38, (53, 57, 60, 64), (69, 72, 76, 74)),
        (34, (53, 57, 60, 62), (69, 72, 74, 77)),
        (41, (53, 57, 60, 67), (72, 74, 77, 79)),
        (36, (52, 55, 57, 62), (67, 72, 74, 76)),
    )
    flank = (-0.56, 0.40, -0.26, 0.59)
    pulse = kick()
    for bar in range(16):
        start = bar * BAR
        root, notes, phrase = chords[bar % len(chords)]
        for index, note in enumerate(notes):
            overlay(mix, pad(note, index * 0.91) * 0.048, start - 0.12, flank[index])
        for at, note, strength in (
            (0.0, root, 0.125), (1.5, root + 12, 0.070),
            (2.0, root, 0.095), (3.5, root + 7, 0.067),
        ):
            overlay(mix, bass(note) * strength, start + at * BEAT, 0.0)

        pluck_pattern = (0.5, 1.75, 2.5, 3.25) if bar % 2 == 0 else (0.75, 1.5, 2.75, 3.5)
        for index, at in enumerate(pluck_pattern):
            if bar in (3, 7, 15) and index == 3:
                continue
            note = phrase[(index + (bar // 4) % 2) % len(phrase)]
            melody = pluck(note) * (0.074 - 0.009 * (index % 3))
            placement = start + at * BEAT
            overlay(mix, melody, placement, flank[index])
            overlay(mix, melody * 0.23, placement + 0.375, -flank[index])
            overlay(mix, melody * 0.10, placement + 0.75, flank[index])
        for at, gain in ((0.0, 0.105), (2.0, 0.081)):
            overlay(mix, pulse * gain, start + at * BEAT, 0.0)
        for at in (0.5, 1.5, 2.5, 3.5):
            overlay(mix, shaker(0.125) * 0.011, start + at * BEAT, 0.43 if at % 2 < 1 else -0.44)

    mix *= min(10 ** (-25.0 / 20) / np.sqrt(np.mean(mix ** 2)), 0.26 / np.max(np.abs(mix)))
    return mix.astype("<f4")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "audio/music/laboratory.ogg")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le",
         "-ar", str(SAMPLE_RATE), "-ac", "2", "-i", "pipe:0", "-c:a", "libvorbis",
         "-q:a", "5", "-metadata", "title=Laboratory", str(args.output)],
        check=True, input=render().tobytes(),
    )


if __name__ == "__main__":
    main()
