#!/usr/bin/env python3
"""
Logitech H-Shifter -> virtuelles Joystick-Geraet (v3, experimentell).

Wie v2, aber mit zwei umschaltbaren Optionen in der Config, um zu testen,
ob sie beeinflussen, wie Wine/Content Manager/Assetto Corsa das
virtuelle Geraet einstuft (Wheel vs. Controller):

  "generic_button_names": true
      Verwendet BTN_TRIGGER_HAPPY1..7 (generische, durchnummerierte
      Tasten) statt der Joystick-Tasten (BTN_TRIGGER, BTN_THUMB, ...).

  "advertise_dummy_axis": true
      Fuegt eine belanglose, nie aendernde ABS-Achse hinzu, falls die
      Kategorisierung von einer vorhandenen Achse abhaengt.

Einfach in shifter_config_v2.json (oder einer Kopie davon) die beiden
Felder hinzufuegen/aendern und den Treiber neu starten, um zu testen.
"""

import json
import sys
from pathlib import Path

import evdev
from evdev import ecodes, UInput, InputDevice, AbsInfo

CONFIG_PATH = Path(__file__).with_name("shifter_config_v2.json")

# Klassische Joystick-Tasten (Standard-Verhalten wie in v2)
CLASSIC_OUTPUT_BUTTONS = {
    "1": ecodes.BTN_TRIGGER,
    "2": ecodes.BTN_THUMB,
    "3": ecodes.BTN_THUMB2,
    "4": ecodes.BTN_TOP,
    "5": ecodes.BTN_TOP2,
    "6": ecodes.BTN_PINKIE,
    "R": ecodes.BTN_BASE,
}

# Generische, durchnummerierte Tasten (Experiment 1)
GENERIC_OUTPUT_BUTTONS = {
    "1": ecodes.BTN_TRIGGER_HAPPY1,
    "2": ecodes.BTN_TRIGGER_HAPPY2,
    "3": ecodes.BTN_TRIGGER_HAPPY3,
    "4": ecodes.BTN_TRIGGER_HAPPY4,
    "5": ecodes.BTN_TRIGGER_HAPPY5,
    "6": ecodes.BTN_TRIGGER_HAPPY6,
    "R": ecodes.BTN_TRIGGER_HAPPY7,
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
    return getattr(ecodes, name)


def main():
    cfg = load_config()
    device_path = cfg.get("device_path")
    device_name_hint = cfg.get("device_name_hint")
    grab = cfg.get("grab_device", True)
    use_generic_names = cfg.get("generic_button_names", False)
    advertise_dummy_axis = cfg.get("advertise_dummy_axis", False)

    output_buttons = GENERIC_OUTPUT_BUTTONS if use_generic_names else CLASSIC_OUTPUT_BUTTONS

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
    print(f"Tastennamen: {'generisch (TRIGGER_HAPPY)' if use_generic_names else 'klassisch (BTN_TRIGGER etc.)'}")
    print(f"Dummy-Achse: {'ja' if advertise_dummy_axis else 'nein'}")
    print("Mapping:")
    for gear, name in cfg["gear_to_input_button"].items():
        print(f"  Gang {gear:>2s}  <-  {name}")
    print()

    if grab:
        src.grab()

    capabilities = {ecodes.EV_KEY: list(output_buttons.values())}

    if advertise_dummy_axis:
        # Feste, sich nie aendernde Achse - nur zu Testzwecken, ob ihre
        # blosse Anwesenheit die Geraete-Klassifizierung beeinflusst.
        dummy_axis_info = AbsInfo(value=0, min=-32768, max=32767, fuzz=0, flat=0, resolution=0)
        capabilities[ecodes.EV_ABS] = [(ecodes.ABS_RX, dummy_axis_info)]

    vdev = UInput(capabilities, name="Logitech H-Shifter (virtual)")

    try:
        for event in src.read_loop():
            if event.type != ecodes.EV_KEY:
                continue

            gear = input_code_to_gear.get(event.code)
            if gear is None:
                continue

            out_code = output_buttons[gear]
            vdev.write(ecodes.EV_KEY, out_code, event.value)
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
