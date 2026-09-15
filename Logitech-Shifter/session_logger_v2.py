#!/usr/bin/env python3
"""
Session-Logger v2 fuer den Shifter - zeichnet ALLE Events auf (Tasten
UND Achsen), nicht nur ABS_MISC. Das vorherige Skript hat faelschlich
nur ABS_MISC beachtet; die eigentliche Gang-Information kommt vermutlich
ueber Tasten-Events (EV_KEY).

Aufruf:
    python3 session_logger_v2.py [/dev/input/event10] [ausgabe.log]

Ablauf:
    1. Skript starten
    2. Label + Enter eingeben (z.B. "gang1"), DANACH die Aktion am
       Shifter ausfuehren
    3. Naechstes Label, usw.
    4. Zum Beenden 'q' + Enter
"""

import sys
import time
import threading
from pathlib import Path

import evdev
from evdev import ecodes, InputDevice, categorize


def main():
    dev_path = sys.argv[1] if len(sys.argv) > 1 else "/dev/input/event10"
    log_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("shifter_session_v2.log")

    dev = InputDevice(dev_path)
    print(f"Geraet: {dev.path} ({dev.name})")
    print(f"Log-Datei: {log_path.resolve()}\n")
    print("Vor jeder Aktion ein kurzes Label + Enter eingeben (z.B. 'gang1'),")
    print("DANACH die Aktion am Shifter ausfuehren.")
    print("Zum Beenden 'q' + Enter eingeben.\n")

    log_file = open(log_path, "a", buffering=1)
    log_file.write(f"\n=== Neue Session {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")

    def reader():
        for event in dev.read_loop():
            ts = time.strftime("%H:%M:%S", time.localtime(event.timestamp()))
            type_name = ecodes.EV[event.type] if event.type in ecodes.EV else str(event.type)

            if event.type == ecodes.EV_KEY:
                code_name = ecodes.keys.get(event.code, event.code)
                state = {0: "UP", 1: "DOWN", 2: "HOLD"}.get(event.value, event.value)
                line = f"{ts}.{event.usec:06d}  {type_name:8s} {code_name} ({event.code}) = {state}"
            elif event.type == ecodes.EV_ABS:
                code_name = ecodes.ABS.get(event.code, event.code) if hasattr(ecodes, "ABS") else event.code
                line = f"{ts}.{event.usec:06d}  {type_name:8s} code={event.code} value={event.value}"
            elif event.type == ecodes.EV_SYN:
                continue  # SYN_REPORT rauslassen, macht das Log unnoetig lang
            else:
                line = f"{ts}.{event.usec:06d}  {type_name:8s} code={event.code} value={event.value}"

            print(line)
            log_file.write(line + "\n")

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    try:
        while True:
            label = input("> ")
            if label.strip().lower() == "q":
                break
            ts = time.strftime("%H:%M:%S")
            marker = f"{ts}           ---- MARKER: {label.strip()} ----"
            print(marker)
            log_file.write(marker + "\n")
    except (KeyboardInterrupt, EOFError):
        pass
    finally:
        log_file.close()
        print(f"\nLog gespeichert unter: {log_path.resolve()}")


if __name__ == "__main__":
    main()
