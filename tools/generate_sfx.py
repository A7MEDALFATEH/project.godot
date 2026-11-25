#!/usr/bin/env python3
"""Generate the Wellbore Fluid Race's original mono PCM sound effects."""

import argparse
from array import array
import math
from pathlib import Path
import random
import sys
import wave


SAMPLE_RATE = 32_000
TAU = math.tau


def frames(seconds):
    return round(seconds * SAMPLE_RATE)


def noise_band(length, rng, low_hz, high_hz, loop=False):
    """Band-limit white noise with two one-pole filters."""
    source = [rng.uniform(-1.0, 1.0) for _ in range(length)]
    lower = math.exp(-TAU * low_hz / SAMPLE_RATE)
    upper = math.exp(-TAU * high_hz / SAMPLE_RATE)
    slow = fast = 0.0
    if loop:
        # The period is far longer than the filter memory. A warm pass
        # gives the first sample the same history it has during repetition.
        for value in source:
            slow = lower * slow + (1.0 - lower) * value
            fast = upper * fast + (1.0 - upper) * value
    result = []
    for value in source:
        slow = lower * slow + (1.0 - lower) * value
        fast = upper * fast + (1.0 - upper) * value
        result.append(fast - slow)
    return result


def envelope(position, attack, release):
    return max(0.0, min(1.0, position / attack, (1.0 - position) / release))


def add_sweep(signal, start, duration, start_hz, end_hz, gain, decay=4.0,
              harmonics=(), loop=False):
    """Add a short pitch glide with a softer onset and an exponential tail."""
    phase = 0.0
    start_frame = frames(start)
    length = frames(duration)
    count = min(length, len(signal) - start_frame) if not loop else length
    for offset in range(count):
        position = offset / length
        frequency = start_hz + (end_hz - start_hz) * position
        phase += TAU * frequency / SAMPLE_RATE
        value = math.sin(phase)
        for multiple, level in harmonics:
            value += level * math.sin(multiple * phase)
        level = envelope(position, 0.045, 0.15) * math.exp(-decay * position)
        index = start_frame + offset
        signal[index % len(signal)] += gain * level * value


def oil_flow(rng):
    length = frames(8.0)
    body = noise_band(length, rng, 45, 470, loop=True)
    ripple = noise_band(length, rng, 240, 1300, loop=True)
    return [
        low * (0.72 + 0.16 * math.sin(3 * TAU * i / length))
        + high * (0.22 + 0.07 * math.sin(5 * TAU * i / length))
        for i, (low, high) in enumerate(zip(body, ripple))
    ]


def gas_bubbles(rng):
    duration = 7.0
    signal = noise_band(frames(duration), rng, 300, 1600, loop=True)
    signal = [0.08 * value for value in signal]
    for i in range(26):
        start = (i + rng.random()) * duration / 26
        pitch = rng.uniform(310, 1000)
        add_sweep(signal, start, rng.uniform(0.065, 0.14), pitch, pitch * 1.55,
                  rng.uniform(0.12, 0.32), decay=4.8, harmonics=((2, 0.16),),
                  loop=True)
    return signal


def bubble_flow(rng):
    duration = 8.0
    length = frames(duration)
    stream = noise_band(length, rng, 120, 1200, loop=True)
    air = noise_band(length, rng, 450, 2400, loop=True)
    signal = [
        (0.44 + 0.07 * math.sin(6 * TAU * i / length)) * wet + 0.13 * dry
        for i, (wet, dry) in enumerate(zip(stream, air))
    ]
    for i in range(50):
        start = (i + rng.random()) * duration / 50
        pitch = rng.uniform(400, 1350)
        add_sweep(signal, start, rng.uniform(0.045, 0.105), pitch, pitch * 1.25,
                  rng.uniform(0.04, 0.12), harmonics=((2, 0.12),), loop=True)
    return signal


def slug_flow(rng):
    duration = 8.0
    length = frames(duration)
    body = noise_band(length, rng, 30, 430, loop=True)
    splash = noise_band(length, rng, 230, 1700, loop=True)
    signal = []
    for i, (low, high) in enumerate(zip(body, splash)):
        cycle = (1.0 + math.sin(4 * TAU * i / length - 0.45)) * 0.5
        signal.append(low * (0.32 + 0.96 * cycle) + high * (0.12 + 0.5 * cycle ** 4))
    for i in range(4):
        add_sweep(signal, i * 2.0 + 0.49, 0.58, 155, 64, 0.12, decay=2.6,
                  harmonics=((1.58, 0.28), (2.04, 0.13)), loop=True)
        add_sweep(signal, i * 2.0 + 0.63, 0.22, 250, 460, 0.07, loop=True)
    return signal


def pressure_drop(rng):
    length = frames(1.16)
    jet = noise_band(length, rng, 285, 3500)
    tremor = noise_band(length, rng, 45, 220)
    signal = [
        envelope(i / length, 0.05, 0.4) * math.exp(-1.8 * i / length)
        * (1.1 * high + 0.62 * low)
        for i, (high, low) in enumerate(zip(jet, tremor))
    ]
    add_sweep(signal, 0.035, 1.025, 830, 118, 0.16, decay=2.2,
              harmonics=((1.5, 0.19), (2, 0.1)))
    return signal


def gas_expand(rng):
    length = frames(0.87)
    air = noise_band(length, rng, 260, 1450)
    signal = [0.43 * envelope(i / length, 0.36, 0.22) * value
              for i, value in enumerate(air)]
    add_sweep(signal, 0.015, 0.68, 165, 710, 0.20, decay=1.15,
              harmonics=((2, 0.24), (3, 0.12)))
    add_sweep(signal, 0.46, 0.22, 470, 1140, 0.11, decay=2.5)
    add_sweep(signal, 0.66, 0.16, 650, 285, 0.18, harmonics=((2, 0.16),))
    return signal


def gas_appeared(rng):
    length = frames(0.63)
    air = noise_band(length, rng, 800, 4000)
    signal = [0.42 * envelope(i / length, 0.018, 0.52)
              * math.exp(-10.0 * i / length) * value for i, value in enumerate(air)]
    add_sweep(signal, 0.0, 0.14, 490, 210, 0.62, decay=5.3,
              harmonics=((2, 0.25), (2.84, 0.13)))
    add_sweep(signal, 0.047, 0.38, 760, 1190, 0.15, decay=2.7,
              harmonics=((2.41, 0.18),))
    add_sweep(signal, 0.151, 0.41, 1100, 1440, 0.10, decay=3.4,
              harmonics=((2.33, 0.16),))
    return signal


def choke_valve(rng):
    length = frames(0.42)
    scrape = noise_band(length, rng, 400, 4700)
    signal = [0.0] * length
    for start, strength in ((0.01, 0.6), (0.095, 0.46), (0.173, 0.5), (0.25, 0.8)):
        tick_length = frames(0.059)
        for i in range(tick_length):
            position = i / tick_length
            index = frames(start) + i
            signal[index] += strength * scrape[index] * envelope(position, 0.04, 0.42)
        add_sweep(signal, start, 0.094, 303, 172, strength * 0.35,
                  harmonics=((2.68, 0.55), (5.01, 0.2)))
    return signal


def jump(rng):
    signal = [0.0] * frames(0.44)
    add_sweep(signal, 0.0, 0.13, 195, 400, 0.4, decay=1.9,
              harmonics=((2, 0.27), (3, 0.09)))
    add_sweep(signal, 0.104, 0.31, 410, 665, 0.43, decay=3.1,
              harmonics=((1.98, 0.25), (4.05, 0.14)))
    return signal


def collision(rng):
    length = frames(0.36)
    spray = noise_band(length, rng, 190, 2600)
    signal = [0.85 * envelope(i / length, 0.022, 0.4)
              * math.exp(-10.0 * i / length) * value for i, value in enumerate(spray)]
    add_sweep(signal, 0.0, 0.22, 154, 52, 0.75, decay=5.6,
              harmonics=((1.71, 0.19), (3.28, 0.16)))
    add_sweep(signal, 0.031, 0.14, 640, 320, 0.21, decay=5.1)
    add_sweep(signal, 0.084, 0.18, 390, 575, 0.09, decay=4.8)
    return signal


def victory(rng):
    signal = [0.0] * frames(2.2)
    harmonics = ((2, 0.25), (3, 0.09), (4.02, 0.17))
    for start, pitch in ((0.0, 523.25), (0.15, 659.25), (0.30, 783.99)):
        add_sweep(signal, start, 0.46, pitch, pitch, 0.46, decay=3.7,
                  harmonics=harmonics)
    for pitch, gain in ((523.25, 0.20), (659.25, 0.15), (783.99, 0.16), (1046.50, 0.40)):
        add_sweep(signal, 0.48, 1.56, pitch, pitch, gain, decay=4.3,
                  harmonics=harmonics)
        add_sweep(signal, 0.57, 1.53, pitch, pitch, gain * 0.19, decay=4.8)
    return signal


EFFECTS = {
    "oil_flow": (oil_flow, 0.29),
    "gas_bubbles": (gas_bubbles, 0.32),
    "bubble_flow": (bubble_flow, 0.35),
    "slug_flow": (slug_flow, 0.39),
    "pressure_drop": (pressure_drop, 0.65),
    "gas_expand": (gas_expand, 0.60),
    "gas_appeared": (gas_appeared, 0.61),
    "choke_valve": (choke_valve, 0.54),
    "jump": (jump, 0.55),
    "collision": (collision, 0.71),
    "victory": (victory, 0.64),
}


def write_wave(path, signal, peak):
    scale = peak * 32767 / max(abs(value) for value in signal)
    data = array("h", (round(value * scale) for value in signal))
    if sys.byteorder != "little":
        data.byteswap()
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(data.tobytes())


def main():
    default = Path(__file__).resolve().parents[1] / "audio" / "sfx"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=default)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name, (render, peak) in EFFECTS.items():
        path = args.output / f"{name}.wav"
        write_wave(path, render(random.Random(f"wellbore-{name}")), peak)
        print(f"Wrote {path}")


if __name__ == "__main__":
    main()
