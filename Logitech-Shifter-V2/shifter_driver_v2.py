#!/usr/bin/env python3
"""
Logitech H-Shifter -> virtuelles Joystick-Geraet (v2).

Der Adapter meldet jeden Gang als ganz normalen Tastendruck (BTN_TL2,
BTN_TR2, BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR).
Der zusaetzlich vorhandene ABS_MISC-Kanal ist unabhaengiges Rauschen
(vermutlich ein nicht sauber beschalteter ADC-Pin) und wird komplett
ignoriert.

Dieses Skript liest die echten Tasten-Events und spiegelt sie sauber
benannt (Gang 1-6 + R) auf ein virtuelles Joystick-Geraet, damit Spiele
nicht mit den kryptischen Gamepad-Tastennamen (BTN_TL2 etc.) hantieren
muessen und das Rauschen auf ABS_MISC nicht in die Kalibrierung des
Spiels einstreut.
"""

import json
import sys
from pathlib import Path

import evdev
from evdev import ecodes, UInput, InputDevice

CONFIG_PATH = Path(__file__).with_name("shifter_config_v2.json")

# Ausgabetasten fuer das virtuelle Geraet, in derselben Reihenfolge wie
# ein klassischer 7-Tasten-H-Schalter (1-6 + Rueckwaertsgang)
OUTPUT_BUTTONS = {
    "1": ecodes.BTN_TRIGGER,
    "2": ecodes.BTN_THUMB,
    "3": ecodes.BTN_THUMB2,
    "4": ecodes.BTN_TOP,
    "5": ecodes.BTN_TOP2,
    "6": ecodes.BTN_PINKIE,
    "R": ecodes.BTN_BASE,
}


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def find_source_device(name_hint):
    for path in evdev.list_devices():
        dev = InputDevice(path)
        if name_hint.lower() in dev.name.lower():
            return dev
    return None


def resolve_button_code(name):
    """z.B. 'BTN_TL2' -> ecodes.BTN_TL2 (312)"""
    return getattr(ecodes, name)


def main():
    cfg = load_config()
    device_path = cfg.get("device_path")
    device_name_hint = cfg.get("device_name_hint")
    grab = cfg.get("grab_device", True)

    # input_code (int) -> gear label, z.B. 312 -> "1"
    input_code_to_gear = {
        resolve_button_code(name): gear
        for gear, name in cfg["gear_to_input_button"].items()
    }

    src = None
    if device_path and Path(device_path).exists():
        src = InputDevice(device_path)
    elif device_name_hint:
        src = find_source_device(device_name_hint)

    if src is None:
        print(
            "Shifter-Geraet nicht gefunden. 'device_path' oder "
            "'device_name_hint' in shifter_config_v2.json setzen.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Lese von: {src.path} ({src.name})")
    print("Mapping:")
    for gear, name in cfg["gear_to_input_button"].items():
        print(f"  Gang {gear:>2s}  <-  {name}")
    print()

    if grab:
        # Verhindert, dass Spiele zusaetzlich das verrauschte ABS_MISC
        # oder die rohen Gamepad-Tastennamen sehen
        src.grab()

    capabilities = {ecodes.EV_KEY: list(OUTPUT_BUTTONS.values())}
    vdev = UInput(capabilities, name="Logitech H-Shifter (virtual)")

    try:
        for event in src.read_loop():
            if event.type != ecodes.EV_KEY:
                continue  # ABS_MISC und alles andere wird ignoriert

            gear = input_code_to_gear.get(event.code)
            if gear is None:
                continue  # nicht gemappte Taste

            out_code = OUTPUT_BUTTONS[gear]
            vdev.write(ecodes.EV_KEY, out_code, event.value)  # 1=DOWN, 0=UP
            vdev.syn()

            state = "DOWN" if event.value == 1 else ("UP" if event.value == 0 else event.value)
            print(f"Gang {gear} -> {state}")

    except KeyboardInterrupt:
        pass
    finally:
        if grab:
            src.ungrab()
        vdev.close()


if __name__ == "__main__":
    main()
