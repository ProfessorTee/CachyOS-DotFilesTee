#!/usr/bin/env python3
"""
Logitech H-Shifter (InterBiometrics-Adapter) -> virtuelles Joystick-Geraet.

Hintergrund (Ergebnis der Analyse):
  - Der Adapter meldet sich als generisches Gamepad (Vendor 1209 / Product
    f00d, "InterBiometrics Logitech@ Shifter V3").
  - Jeder Gang ist ein normaler Tastendruck (EV_KEY), siehe
    gear_to_input_button in config.json.
  - Der zusaetzlich vorhandene ABS_MISC-Analogkanal ist unabhaengiges
    Rauschen (vermutlich ein nicht sauber beschalteter ADC-Pin) und wird
    hier komplett ignoriert.

Dieses Skript liest die echten Tasten-Events und spiegelt sie sauber
benannt (Gang 1-6 + R) auf ein virtuelles Joystick-Geraet, damit Spiele
(Assetto Corsa, Assetto Corsa EVO, ...) einen normalen H-Schalter sehen.

Geraete-Erkennung (in dieser Reihenfolge):
  1. Vendor-/Product-ID (robust gegen wechselnde /dev/input/eventX-Nummern
     nach Neustart oder Neustecken - der empfohlene Normalfall)
  2. Fest eingetragener device_path_fallback, falls (1) fehlschlaegt
  3. Namens-Suche (device_name_hint_fallback), falls auch (2) fehlschlaegt
"""

import json
import sys
from pathlib import Path

import evdev
from evdev import ecodes, UInput, InputDevice, AbsInfo

CONFIG_PATH = Path(__file__).with_name("config.json")

CLASSIC_OUTPUT_BUTTONS = {
    "1": ecodes.BTN_TRIGGER,
    "2": ecodes.BTN_THUMB,
    "3": ecodes.BTN_THUMB2,
    "4": ecodes.BTN_TOP,
    "5": ecodes.BTN_TOP2,
    "6": ecodes.BTN_PINKIE,
    "R": ecodes.BTN_BASE,
}

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


def find_by_vid_pid(vendor_hex, product_hex):
    vendor = int(vendor_hex, 16)
    product = int(product_hex, 16)
    for path in evdev.list_devices():
        dev = InputDevice(path)
        if dev.info.vendor == vendor and dev.info.product == product:
            return dev
    return None


def find_by_name(name_hint):
    for path in evdev.list_devices():
        dev = InputDevice(path)
        if name_hint.lower() in dev.name.lower():
            return dev
    return None


def find_source_device(cfg):
    vendor_hex = cfg.get("vendor_id")
    product_hex = cfg.get("product_id")
    if vendor_hex and product_hex:
        dev = find_by_vid_pid(vendor_hex, product_hex)
        if dev:
            return dev, "vendor/product-id"

    fallback_path = cfg.get("device_path_fallback")
    if fallback_path and Path(fallback_path).exists():
        return InputDevice(fallback_path), "fester Pfad (Fallback)"

    name_hint = cfg.get("device_name_hint_fallback")
    if name_hint:
        dev = find_by_name(name_hint)
        if dev:
            return dev, "Namens-Suche (Fallback)"

    return None, None


def resolve_button_code(name):
    return getattr(ecodes, name)


def main():
    cfg = load_config()
    grab = cfg.get("grab_device", True)
    use_generic_names = cfg.get("generic_button_names", False)
    advertise_xy_axes = cfg.get("advertise_xy_axes", False)

    output_buttons = GENERIC_OUTPUT_BUTTONS if use_generic_names else CLASSIC_OUTPUT_BUTTONS

    input_code_to_gear = {
        resolve_button_code(name): gear
        for gear, name in cfg["gear_to_input_button"].items()
    }

    src, method = find_source_device(cfg)
    if src is None:
        print(
            "Shifter-Geraet nicht gefunden (weder ueber Vendor/Product-ID "
            "noch ueber die Fallback-Optionen in config.json).",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Lese von: {src.path} ({src.name})  [gefunden ueber: {method}]")
    print(f"Tastennamen: {'generisch (TRIGGER_HAPPY)' if use_generic_names else 'klassisch (BTN_TRIGGER etc.)'}")
    print(f"Dummy-XY-Achsen: {'ja' if advertise_xy_axes else 'nein'}")
    print("Mapping:")
    for gear, name in cfg["gear_to_input_button"].items():
        print(f"  Gang {gear:>2s}  <-  {name}")
    print()

    if grab:
        src.grab()

    capabilities = {ecodes.EV_KEY: list(output_buttons.values())}

    if advertise_xy_axes:
        center = AbsInfo(value=127, min=0, max=255, fuzz=0, flat=0, resolution=0)
        capabilities[ecodes.EV_ABS] = [
            (ecodes.ABS_X, center),
            (ecodes.ABS_Y, center),
        ]

    vdev = UInput(capabilities, name="Logitech H-Shifter (virtual)")

    try:
        for event in src.read_loop():
            if event.type != ecodes.EV_KEY:
                continue  # ABS_MISC und alles andere wird ignoriert

            gear = input_code_to_gear.get(event.code)
            if gear is None:
                continue

            out_code = output_buttons[gear]
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
