"""Generate the community notification tone using only the Python standard library.

The synthesized asset is an original project asset distributed under MIT.
"""

import math
from pathlib import Path
import struct
import wave


def main() -> None:
    destination = (
        Path(__file__).resolve().parents[1]
        / "android/app/src/main/res/raw/ding.wav"
    )
    rate = 22050
    duration = 0.8
    frames = bytearray()
    for sample in range(int(rate * duration)):
        instant = sample / rate
        attack = min(1.0, instant / 0.01)
        envelope = attack * math.exp(-6 * instant)
        tone = math.sin(2 * math.pi * 880 * instant)
        tone += 0.3 * math.sin(2 * math.pi * 1320 * instant)
        frames.extend(struct.pack("<h", int(18000 * envelope * tone / 1.3)))
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(frames)


if __name__ == "__main__":
    main()
