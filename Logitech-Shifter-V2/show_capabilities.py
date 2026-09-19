#!/usr/bin/env python3
"""Zeigt alle unterstuetzten Event-Typen/Codes eines Input-Geraets an.

Aufruf: python3 show_capabilities.py [/dev/input/eventX]
"""

import sys
import evdev

path = sys.argv[1] if len(sys.argv) > 1 else "/dev/input/event10"
dev = evdev.InputDevice(path)

print(f"Geraet: {dev.path} ({dev.name})\n")

for k, v in dev.capabilities(verbose=True).items():
    print(k)
    for item in v:
        print("   ", item)
