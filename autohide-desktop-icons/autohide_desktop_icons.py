#!/usr/bin/env python3
"""
AutoHide Desktop Icons - blendet die KDE-Desktop-Icons nach X Minuten ohne
Maus-/Tastatureingabe aus. Links- oder Rechtsklick auf den freien Desktop
blendet sie wieder ein. Tray-Icon: Linksklick = sofort ein/aus, Rechtsklick =
Menue (aktiv, Zeit 1-5 min, beenden).

Wie:
- Ausblenden = Dateifilter der Ordneransicht auf ein Muster setzen, das keine
  Datei trifft (per plasmashell evaluateScript). Icon-Positionen bleiben.
  Der alte Filter wird in derselben Plasma-Config gemerkt und zurueckgesetzt.
- Eingaben kommen per evdev (/dev/input, User muss in Gruppe "input" sein).
  Tastendruecke werden nur als "Aktivitaet" gezaehlt, nie gespeichert.
- Klick auf den Desktop erkennt ein kurzes KWin-Skript: oberstes Fenster
  unter dem Mauszeiger == Desktop-Fenster -> Icons wieder einblenden.

Benoetigt: pyside6, python-evdev (pacman).
"""

import json
import os
import select
import signal
import sys
import threading
import time
from pathlib import Path

import evdev
from evdev import ecodes
from PySide6.QtCore import QObject, QSettings, QTimer, Signal
from PySide6.QtDBus import QDBusConnection, QDBusInterface
from PySide6.QtGui import QAction, QActionGroup, QIcon
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

MARKER = "autohide-desktop-icons-none"

# Laeuft in plasmashell. Nur echte Desktops (Ordneransicht) mit Bildschirm.
JS_DESKTOPS = 'for (const d of desktops()) { if (d.screen < 0 || d.type != "org.kde.plasma.folder") continue; d.currentConfigGroup = ["General"]; %s }'
JS_HIDE = JS_DESKTOPS % (
    f'if (d.readConfig("filterPattern") != "{MARKER}") {{'
    ' d.writeConfig("autohideOrigMode", d.readConfig("filterMode"));'
    ' d.writeConfig("autohideOrigPattern", d.readConfig("filterPattern")); }'
    f' d.writeConfig("filterMode", 1); d.writeConfig("filterPattern", "{MARKER}"); d.reloadConfig();'
)
JS_SHOW = JS_DESKTOPS % (
    f'if (d.readConfig("filterPattern") == "{MARKER}") {{'
    ' d.writeConfig("filterMode", d.readConfig("autohideOrigMode") || 0);'
    ' d.writeConfig("filterPattern", d.readConfig("autohideOrigPattern") || ""); d.reloadConfig(); }'
)
JS_STATE = JS_DESKTOPS % f'if (d.readConfig("filterPattern") == "{MARKER}") print("hidden");'

# Laeuft in KWin: Desktop unter dem Mauszeiger? -> JS_SHOW an plasmashell.
KWIN_PROBE = """
const p = workspace.cursorPos, st = workspace.stackingOrder;
for (let i = st.length - 1; i >= 0; i--) {
    const w = st[i], g = w.frameGeometry;
    if (w.minimized || w.hidden || !(w.onAllDesktops || w.desktops.includes(workspace.currentDesktop))) continue;
    if (p.x >= g.x && p.x < g.x + g.width && p.y >= g.y && p.y < g.y + g.height) {
        if (w.desktopWindow)
            callDBus("org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", %s);
        break;
    }
}
""" % json.dumps(JS_SHOW)
PROBE_FILE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "autohide-desktop-icons-probe.js"


def plasma(js):
    reply = QDBusInterface("org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell").call("evaluateScript", js)
    args = reply.arguments()
    return args[0] if args else ""


def kwin_probe():
    scripting = QDBusInterface("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting")
    scripting.call("unloadScript", "autohide-desktop-icons")
    args = scripting.call("loadScript", str(PROBE_FILE), "autohide-desktop-icons").arguments()
    if args and int(args[0]) >= 0:
        QDBusInterface("org.kde.KWin", f"/Scripting/Script{args[0]}", "org.kde.kwin.Script").call("run")
    scripting.call("unloadScript", "autohide-desktop-icons")


class InputWatcher(QObject):
    """Liest Maeuse + Tastaturen per evdev in einem Thread (Hotplug: Rescan alle 3 s)."""
    clicked = Signal()

    def __init__(self):
        super().__init__()
        self.last_activity = time.monotonic()
        threading.Thread(target=self._run, daemon=True).start()

    @staticmethod
    def _wanted(dev):
        keys = dev.capabilities().get(ecodes.EV_KEY, [])
        return ecodes.BTN_LEFT in keys or ecodes.KEY_A in keys

    def _run(self):
        devices, known, next_scan = {}, set(), 0.0
        while True:
            if time.monotonic() >= next_scan:
                next_scan = time.monotonic() + 3
                paths = set(evdev.list_devices())
                for path in paths - known:
                    try:
                        dev = evdev.InputDevice(path)
                        if self._wanted(dev):
                            devices[dev.fd] = dev
                        else:
                            dev.close()
                    except OSError:
                        pass
                known = paths
            r = select.select(list(devices), [], [], 1)[0] if devices else (time.sleep(1) or [])
            for fd in r:
                try:
                    for ev in devices[fd].read():
                        self.last_activity = time.monotonic()
                        if ev.type == ecodes.EV_KEY and ev.value == 1 and ev.code in (ecodes.BTN_LEFT, ecodes.BTN_RIGHT):
                            self.clicked.emit()
                except OSError:  # Geraet abgezogen
                    dev = devices.pop(fd)
                    known.discard(dev.path)
                    dev.close()


class Tray:
    def __init__(self, app):
        self.settings = QSettings("autohide-desktop-icons", "autohide-desktop-icons")
        self.hidden = False
        self.input = InputWatcher()
        self.input.clicked.connect(self.on_click)

        self.tray = QSystemTrayIcon()
        self.tray.activated.connect(lambda reason: reason == QSystemTrayIcon.Trigger and self.set_hidden(not self.hidden))
        menu = QMenu()
        self.act_enabled = menu.addAction("Automatisch ausblenden")
        self.act_enabled.setCheckable(True)
        self.act_enabled.setChecked(self.settings.value("enabled", True, type=bool))
        self.act_enabled.toggled.connect(lambda on: self.settings.setValue("enabled", on))
        sub = menu.addMenu("Ausblenden nach")
        group = QActionGroup(sub)
        for minutes in range(1, 6):
            act = sub.addAction(f"{minutes} min")
            act.setCheckable(True)
            act.setChecked(minutes == self.timeout_min())
            act.triggered.connect(lambda _=False, m=minutes: self.settings.setValue("timeout_min", m))
            group.addAction(act)
        menu.addSeparator()
        self.act_toggle = menu.addAction("", lambda: self.set_hidden(not self.hidden))
        menu.addAction("Beenden", app.quit)
        self.tray.setContextMenu(menu)

        self.set_hidden(False)  # Reste eines Absturzes aufraeumen
        self.tray.show()
        self.idle_timer = QTimer(interval=2000, timeout=self.check_idle)
        self.idle_timer.start()

    def timeout_min(self):
        return self.settings.value("timeout_min", 2, type=int)

    def check_idle(self):
        if self.hidden:  # evtl. extern wieder eingeblendet (Klick, Plasma-Neustart)
            self.refresh()
        idle = time.monotonic() - self.input.last_activity
        if not self.hidden and self.act_enabled.isChecked() and idle >= self.timeout_min() * 60:
            self.set_hidden(True)

    def on_click(self):
        if self.hidden:
            kwin_probe()
            QTimer.singleShot(300, self.refresh)

    def refresh(self):
        self.hidden = "hidden" in plasma(JS_STATE)
        self.update_ui()

    def set_hidden(self, hide):
        plasma(JS_HIDE if hide else JS_SHOW)
        self.input.last_activity = time.monotonic()
        self.refresh()

    def update_ui(self):
        self.tray.setIcon(QIcon.fromTheme("view-hidden" if self.hidden else "user-desktop"))
        self.tray.setToolTip("Desktop-Icons " + ("ausgeblendet" if self.hidden else "sichtbar"))
        self.act_toggle.setText("Icons einblenden" if self.hidden else "Icons ausblenden")


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("AutoHide Desktop Icons")  # Name im Tray-Aufklappfenster
    app.setApplicationDisplayName("AutoHide Desktop Icons")
    app.setQuitOnLastWindowClosed(False)
    if not QDBusConnection.sessionBus().isConnected():
        sys.exit("Keine D-Bus-Session")
    PROBE_FILE.write_text(KWIN_PROBE)
    tray = Tray(app)
    app.aboutToQuit.connect(lambda: plasma(JS_SHOW))  # Icons nie versteckt zuruecklassen
    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    signal.signal(signal.SIGINT, lambda *_: app.quit())
    keepalive = QTimer(interval=500, timeout=lambda: None)  # Python-Signalhandler laufen lassen
    keepalive.start()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
