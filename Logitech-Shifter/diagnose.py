#!/usr/bin/env python3
"""
Diagnose-Hilfsskript: listet alle Input-Geraete mit "Shifter" im Namen
und zeigt, ob es echte USB-Geraete (Bus=usb) oder virtuelle Klone
(z.B. von input-remapper) sind - hilfreich, falls sich die
/dev/input/eventX-Nummer mal wieder verschiebt oder ploetzlich seltsames
Verhalten auftritt (z.B. Zahlen-Tastendruecke statt Joystick-Buttons).

Aufruf: python3 diagnose.py
"""

import evdev
from evdev import InputDevice

print(f"{'Pfad':<20} {'Name':<40} {'Vendor:Product':<16} {'Bus':<8} {'Phys'}")
print("-" * 110)

for path in evdev.list_devices():
    dev = InputDevice(path)
    if "shift" not in dev.name.lower():
        continue
    vid_pid = f"{dev.info.vendor:04x}:{dev.info.product:04x}"
    bus = {0: "?", 1: "pci", 3: "usb", 6: "host", 25: "virtual"}.get(dev.info.bustype, str(dev.info.bustype))
    print(f"{dev.path:<20} {dev.name:<40} {vid_pid:<16} {bus:<8} {dev.phys}")

print()
print("Hinweis: 'virtual' oder ein Phys-Pfad, der mit 'input-remapper/' beginnt,")
print("deutet auf einen von input-remapper erzeugten Klon hin, nicht auf das")
print("echte USB-Geraet. Fuer unseren Treiber ist immer der 'usb'-Eintrag")
print("mit Vendor 1209 / Product f00d relevant.")
