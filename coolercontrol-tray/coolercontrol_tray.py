#!/usr/bin/env python3
"""
CoolerControl Tray - zeigt ausgewaehlte Temperaturen aus CoolerControl im KDE-Tray an.

Warum kein "echtes" CoolerControl-Plugin?
CoolerControl-Plugins (gRPC-basiert, siehe cc-plugins) sind fuer neue
Geraete-Backends (z.B. weitere USB-Kuehler) gedacht, nicht fuer UI/Tray-
Anzeigen. Fuer reine Hardware-Sensoren (CPU/GPU/NVMe) haette KDE selbst
schon fertige Plasmoids (z.B. "Thermal Monitor" im KDE Store). Der Grund,
warum sich ein eigenes kleines Tool trotzdem lohnt: ein per "Custom Sensor"
in CoolerControl gebauter virtueller Sensor (z.B. Maximum beider RAM-DIMMs)
existiert NUR in CoolerControl selbst, nicht als rohes hwmon/lm-sensors-
Sensor -- KDE-eigene Sensor-Widgets koennen ihn also nicht sehen. Dieses
Skript spricht stattdessen direkt die lokale REST-API von coolercontrold an.

Ersteinrichtung:
    1. In der CoolerControl-GUI: Einstellungen -> Access Protection ->
       Access Tokens -> neuen Token erzeugen (NICHT das Login-Passwort!).
    2. python3 coolercontrol_tray.py
       -> legt ~/.config/coolercontrol-tray/config.toml an und beendet sich.
    3. Token in der Config eintragen.
    4. python3 coolercontrol_tray.py --list-sensors
       -> zeigt alle verfuegbaren Sensornamen auf deinem System, damit du
          die "match"-Strings in der Config exakt setzen kannst.
    5. python3 coolercontrol_tray.py --dump
       -> falls --list-sensors leer bleibt: rohe JSON-Antwort zur Fehlersuche.
    6. python3 coolercontrol_tray.py
       -> startet den Tray dauerhaft.

Benoetigt: python-pyqt6 (pacman), Python 3.11+ (fuer tomllib).
"""

import sys
import json
import urllib.request
import urllib.error
import argparse
import tomllib
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "coolercontrol-tray"
CONFIG_FILE = CONFIG_DIR / "config.toml"

DEFAULT_CONFIG = """\
# CoolerControl Tray - Konfiguration
#
# base_url: Adresse des coolercontrold-Daemons (Standard passt fast immer)
# token:    Access Token aus CoolerControl -> Einstellungen -> Access
#           Protection -> Access Tokens -> "Neuer Token" (KEIN Login-PW!)
# poll_interval: Abfrage-Intervall in Sekunden

base_url = "http://localhost:11987"
token = "HIER_DEIN_ACCESS_TOKEN_EINTRAGEN"
poll_interval = 3

# Jeder Eintrag zeigt einen Sensor im Tray-Icon/Tooltip/Menue.
# "match" ist ein Teilstring (Gross-/Kleinschreibung egal), der im
# Sensornamen gesucht wird. Der ERSTE Eintrag wird gross im Tray-Icon
# angezeigt, alle weiteren nur im Tooltip + Rechtsklick-Menue.
#
# Nutz --list-sensors, um die exakten Namen auf deinem System zu sehen
# (z.B. den Namen, den du deinem RAM-"Mix"-Custom-Sensor gegeben hast),
# und passe die "match"-Werte hier entsprechend an.

[[sensors]]
label = "RAM"
match = "ram"

[[sensors]]
label = "CPU"
match = "tctl"

[[sensors]]
label = "GPU"
match = "edge"
"""


def load_config():
    if not CONFIG_FILE.exists():
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        CONFIG_FILE.write_text(DEFAULT_CONFIG)
        CONFIG_FILE.chmod(0o600)
        print(f"Neue Konfiguration angelegt: {CONFIG_FILE}")
        print("Bitte Access Token eintragen, 'match'-Werte per --list-sensors")
        print("pruefen, dann das Skript erneut starten.")
        sys.exit(0)
    with open(CONFIG_FILE, "rb") as f:
        return tomllib.load(f)


def fetch_status(base_url: str, token: str) -> dict:
    req = urllib.request.Request(
        f"{base_url.rstrip('/')}/status",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode("utf-8"))


def flatten_sensors(data):
    """
    Durchsucht die Status-JSON rekursiv nach Objekten mit einem 'name'-
    (oder 'label'-)Feld und einem numerischen Wert (temp/value/celsius/
    duty/rpm), unabhaengig von der genauen Verschachtelung. Das macht das
    Skript robust gegen kleinere API-Unterschiede zwischen CoolerControl-
    Versionen, da die exakte Schema-Doku zum Zeitpunkt des Schreibens
    nicht vollstaendig einsehbar war -- mit --dump kannst du jederzeit
    die Rohantwort pruefen, falls hier mal ein Feld fehlt.
    """
    found = []
    if isinstance(data, dict):
        name = data.get("name") or data.get("label")
        value = None
        value_kind = None
        for key in ("temp", "value", "celsius", "duty", "rpm"):
            v = data.get(key)
            if isinstance(v, (int, float)):
                value = v
                value_kind = key
                break
        if name and value is not None:
            found.append((str(name), float(value), value_kind))
        for v in data.values():
            found.extend(flatten_sensors(v))
    elif isinstance(data, list):
        for item in data:
            found.extend(flatten_sensors(item))
    return found


def main_list_sensors(cfg):
    data = fetch_status(cfg["base_url"], cfg["token"])
    sensors = flatten_sensors(data)
    if not sensors:
        print("Keine Sensoren gefunden -- probier --dump fuer die Rohantwort.")
        return
    seen = set()
    for name, value, kind in sorted(sensors):
        key = (name, kind)
        if key in seen:
            continue
        seen.add(key)
        unit = "°C" if kind in ("temp", "value", "celsius") else ("%" if kind == "duty" else "rpm")
        print(f"{name!r:50s} {value:>8.1f} {unit}  [{kind}]")


def main_dump(cfg):
    data = fetch_status(cfg["base_url"], cfg["token"])
    print(json.dumps(data, indent=2, ensure_ascii=False))


def run_tray(cfg):
    from PyQt6.QtWidgets import QApplication, QSystemTrayIcon, QMenu
    from PyQt6.QtGui import QIcon, QPixmap, QPainter, QColor, QFont, QAction
    from PyQt6.QtCore import QTimer, Qt

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)

    tray = QSystemTrayIcon()
    menu = QMenu()
    status_actions = {}
    for s in cfg.get("sensors", []):
        act = QAction(f"{s['label']}: --")
        act.setEnabled(False)
        menu.addAction(act)
        status_actions[s["label"]] = act
    menu.addSeparator()
    reload_action = QAction("Jetzt aktualisieren")
    menu.addAction(reload_action)
    quit_action = QAction("Beenden")
    quit_action.triggered.connect(app.quit)
    menu.addAction(quit_action)
    tray.setContextMenu(menu)
    tray.setVisible(True)

    def make_icon(text: str, error: bool = False) -> QIcon:
        size = 64
        pixmap = QPixmap(size, size)
        pixmap.fill(Qt.GlobalColor.transparent)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(QColor("#e05252") if error else QColor("#ffffff"))
        font_size = 30 if len(text) <= 2 else (24 if len(text) == 3 else 18)
        font = QFont("Sans", font_size)
        font.setBold(True)
        painter.setFont(font)
        painter.drawText(pixmap.rect(), Qt.AlignmentFlag.AlignCenter, text)
        painter.end()
        return QIcon(pixmap)

    def update():
        try:
            data = fetch_status(cfg["base_url"], cfg["token"])
            sensors = flatten_sensors(data)
            results = {}
            for s in cfg.get("sensors", []):
                match = s["match"].lower()
                hit = next(
                    (v for n, v, k in sensors
                     if match in n.lower() and k in ("temp", "value", "celsius")),
                    None,
                )
                results[s["label"]] = hit

            tooltip_lines = []
            for label, val in results.items():
                text = f"{val:.0f}°C" if val is not None else "n/v"
                tooltip_lines.append(f"{label}: {text}")
                if label in status_actions:
                    status_actions[label].setText(f"{label}: {text}")

            configured = cfg.get("sensors", [])
            primary_label = configured[0]["label"] if configured else None
            primary_val = results.get(primary_label) if primary_label else None
            icon_text = f"{primary_val:.0f}" if primary_val is not None else "?"
            tray.setIcon(make_icon(icon_text))
            tray.setToolTip("CoolerControl\n" + "\n".join(tooltip_lines))
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            tray.setIcon(make_icon("!", error=True))
            tray.setToolTip(f"CoolerControl Tray: Verbindung fehlgeschlagen\n{e}")

    reload_action.triggered.connect(update)
    timer = QTimer()
    timer.timeout.connect(update)
    timer.start(int(cfg.get("poll_interval", 3)) * 1000)
    update()

    sys.exit(app.exec())


def main():
    parser = argparse.ArgumentParser(description="CoolerControl Tray fuer KDE")
    parser.add_argument("--list-sensors", action="store_true",
                         help="Verfuegbare Sensoren auflisten und beenden")
    parser.add_argument("--dump", action="store_true",
                         help="Rohe Status-JSON ausgeben und beenden")
    args = parser.parse_args()

    cfg = load_config()

    if cfg.get("token", "").startswith("HIER_DEIN"):
        print("Bitte zuerst den Access Token eintragen:")
        print(f"  {CONFIG_FILE}")
        sys.exit(1)

    if args.list_sensors:
        main_list_sensors(cfg)
    elif args.dump:
        main_dump(cfg)
    else:
        run_tray(cfg)


if __name__ == "__main__":
    main()
