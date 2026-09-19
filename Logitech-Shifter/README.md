# Logitech H-Shifter Treiber (CachyOS / Arch / Linux)

Virtueller Joystick-Treiber fuer den Logitech-Shifter (InterBiometrics-
USB-Adapter, Vendor 1209 / Product f00d), fuer Assetto Corsa und
Assetto Corsa EVO.

## Was das Problem war (Zusammenfassung)

- Der Adapter meldet sich als generisches Gamepad und sendet jeden Gang
  als normalen Tastendruck: `BTN_TL2`=Gang1, `BTN_TR2`=Gang2,
  `BTN_SELECT`=Gang3, `BTN_START`=Gang4, `BTN_MODE`=Gang5,
  `BTN_THUMBL`=Gang6, `BTN_THUMBR`=Rueckwaertsgang.
- Der zusaetzliche `ABS_MISC`-Analogkanal ist unabhaengiges Rauschen
  (kommt nie zur Ruhe, hat nichts mit der Gang-Position zu tun) und wird
  ignoriert.
- **Wichtig:** falls `input-remapper` auf dem System laeuft, kann es
  einen eigenen virtuellen Klon des Geraets erzeugen und eigene
  Tasten-Zuordnungen (z.B. Zahlen-Tasten) aktiv haben, die unabhaengig
  von diesem Treiber Stoerungen verursachen. Mit `diagnose.py` pruefen
  und das Preset dort ggf. deaktivieren.
- Die `/dev/input/eventX`-Nummer des Shifters kann sich nach einem
  Neustart/Neustecken aendern. Deshalb identifiziert dieser Treiber das
  Geraet primaer ueber seine **USB Vendor/Product-ID** (1209:f00d),
  nicht ueber eine feste Geraetenummer.

## Dateien

| Datei | Zweck |
|---|---|
| `shifter_driver.py` | Haupt-Treiber |
| `config.json` | Mapping Gang -> Taste, Geraete-Erkennung, Optionen |
| `diagnose.py` | Findet das Geraet, zeigt Konflikte (z.B. input-remapper) |
| `99-logitech-shifter.rules` | udev-Regel fuer Geraete-Berechtigungen |
| `logitech-shifter.service` | systemd-Service fuer Autostart |

## Einrichtung

### 1. Abhaengigkeit installieren

```bash
sudo pacman -S python-evdev
```

### 2. Benutzer zur Gruppe 'input' hinzufuegen

```bash
sudo usermod -aG input $USER
```

Danach einmal ab- und wieder anmelden (Gruppenaenderung wirkt erst nach
neuem Login).

### 3. Vor dem Einrichten: auf Konflikte pruefen

```bash
python3 diagnose.py
```

Falls dort ein Eintrag mit `Phys=input-remapper/...` oder Bus `virtual`
auftaucht: `input-remapper` GUI oeffnen (oder `pgrep -fa input-remapper`
pruefen) und das Mapping fuer den Shifter deaktivieren/loeschen, sonst
konkurriert es mit diesem Treiber.

### 4. udev-Regel installieren

```bash
sudo cp 99-logitech-shifter.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### 5. Treiber testen

```bash
python3 shifter_driver.py
```

Bei jedem Gangwechsel sollte `Gang X -> DOWN` / `Gang X -> UP` erscheinen.
Mit `evtest` das neue Geraet "Logitech H-Shifter (virtual)" pruefen.

### 6. Autostart per systemd

`logitech-shifter.service` ist bereits auf diesen Ordner
(`/home/professortee/DotFiles/Logitech-Shifter/`) und den Benutzer
`professortee` eingestellt. Falls sich einer von beiden aendert, die
Datei entsprechend anpassen.

```bash
sudo cp logitech-shifter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now logitech-shifter.service
systemctl status logitech-shifter.service
```

Live-Log pruefen (dabei in einem zweiten Fenster/Terminal schalten, nicht
im journalctl-Fenster selbst tippen):

```bash
journalctl -u logitech-shifter.service -f
```

### 7. In Assetto Corsa / Content Manager einrichten

1. Settings -> Assetto Corsa -> Controls
2. Oben den Input-Modus auf **"Wheel"** stellen (nicht "Controller/
   Gamepad" - dort fehlen die einzelnen Gang-Slots)
3. Falls sich dort die Gaenge dem Shifter trotzdem nicht zuweisen lassen
   (bekanntes CM-Verhalten, wenn es das Geraet nicht als "wheel-tauglich"
   einstuft): alternativ ueber das **originale AC-Controls-Menu**
   (im Spiel selbst, Options -> Controls) zuweisen - das speichert in
   derselben `controls.ini`, die auch CM danach verwendet.
4. Fuer Assetto Corsa EVO: gleiches Vorgehen, sobald das Spiel
   verfuegbar ist - da der Treiber auf Betriebssystem-Ebene ein ganz
   normales Joystick-Geraet erzeugt, sollte jedes Spiel/jeder Launcher,
   der Joystick-Eingaben unterstuetzt, es erkennen koennen.

## Fehlerbehebung

- **"Permission denied" beim Start**: Gruppe 'input' und udev-Regel
  pruefen (Schritte 2 und 4), danach neu anmelden.
- **Service startet nicht, `status=217/USER`**: `User=` in
  `logitech-shifter.service` stimmt nicht mit dem echten Linux-Benutzer
  ueberein (`id -un` zum Pruefen).
- **Keine Ausgabe in `journalctl -f`, obwohl der Service laeuft**:
  `Environment=PYTHONUNBUFFERED=1` muss in der Service-Datei stehen,
  sonst puffert Python die Ausgabe.
- **Zahlen erscheinen beim Schalten, obwohl der Service gestoppt ist**:
  `input-remapper` laeuft im Hintergrund und hat ein eigenes Mapping
  aktiv - siehe Schritt 3.
- **Geraet wird nicht gefunden**: `python3 diagnose.py` ausfuehren, um
  zu pruefen, ob sich Vendor/Product-ID oder Name geaendert haben.

## Experimentelle Optionen (config.json)

Falls Content Manager das virtuelle Geraet weiterhin falsch einstuft:

- `"generic_button_names": true` - verwendet durchnummerierte Tasten
  (`BTN_TRIGGER_HAPPY1`..`7`) statt klassischer Joystick-Tasten
- `"advertise_xy_axes": true` - fuegt eine feste, nie bewegte
  ABS_X/ABS_Y-Achse hinzu (udev's Geraete-Klassifizierung verlangt
  historisch beide Achsen gemeinsam, um etwas sicher als "Joystick" statt
  als generisches Eingabegeraet einzustufen)

Nach Aenderung: Treiber neu starten und mit
`udevadm info /dev/input/eventXX | grep ID_INPUT` (XX = Nummer des
virtuellen Geraets, siehe `python3 diagnose.py`) pruefen, ob
`ID_INPUT_JOYSTICK=1` erscheint.
