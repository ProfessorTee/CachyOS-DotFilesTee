# Live-Wallpaper: Primitive Live & LN Plotter

Zwei Web-Wallpaper für das KDE-Plugin von Wallpaper Engine, jeweils mit eigenem
Plasma-6-Widget zur Steuerung.

| Ordner | Was | Widget |
|---|---|---|
| `primitive-live/` | malt Bilder aus `~/Bilder/Primitive` live aus geometrischen Formen nach (fogleman/primitive) | **Primitive Live** |
| `ln-plotter/` | rendert Formeln z = f(x, y) als 3D-Linienzeichnung (fogleman/ln + vpype), ein Plotterstift zeichnet sie live | **LN Plotter** |

Die Ordner hier sind nur die **Installer**. Was tatsächlich läuft, kopieren sie an feste Orte
(siehe unten) – diese Ordner können also verschoben oder gelöscht werden, ohne dass
etwas kaputtgeht. Zum Neuinstallieren, Aktualisieren oder Deinstallieren braucht man sie.

---

## Voraussetzungen

```bash
# Wallpaper Engine (Steam) + KDE-Plugin
yay -S plasma6-wallpapers-wallpaper-engine-git   # catsout/wallpaper-engine-kde-plugin (Plasma 6)
sudo pacman -S --needed qt6-webengine imagemagick python-pipx
pipx install vpype                          # nur für den LN Plotter (Linien-Optimierung)
```

Wallpaper Engine muss in Steam einmal installiert sein. Der Installer findet Steam unter
`~/Games/Steam`, `~/.local/share/Steam`, `~/.steam/steam` oder als Flatpak – sonst den
Pfad mitgeben: `./install.sh /pfad/zu/Steam`.

## Installieren / Aktualisieren

(Funktioniert so in Fish und Bash.)

```bash
cd primitive-live && ./install.sh && cd ..
cd ln-plotter     && ./install.sh && cd ..
plasmashell --replace &     # damit Plasma neue/aktualisierte Widgets lädt
```

Danach:
1. Rechtsklick Desktop → *Hintergrundbild einrichten* → *Wallpaper Engine* → Liste neu
   laden → **Primitive Live** oder **LN Plotter** wählen.
2. Rechtsklick aufs Panel → *Widgets hinzufügen* → **Primitive Live** / **LN Plotter**.

Ein erneutes `./install.sh` aktualisiert alles und lässt Bilder, Einstellungen und Formeln
in Ruhe.

## Einstellungen zurückspielen (nach Neuinstallation)

```bash
cp ~/DotFiles/config/primitive-live/einstellungen.conf ~/.config/primitive-live/
cp ~/DotFiles/config/ln-plotter/formeln.txt ~/.config/ln-plotter/
```

(Wirkt sofort – beide Dateien werden überwacht.)

## Wichtig: Einstellungen im Wallpaper-Engine-Dialog wirken nicht

Das KDE-Plugin reicht bei Web-Wallpapern nur die Standardwerte aus `project.json` durch.
Deshalb läuft alles über die Widgets bzw. die Steuerprogramme:

```bash
primitive-live-ctl set formen dreiecke,ellipsen   # oder: primitive-live-ctl edit
ln-plotter-ctl draw "cos(a*6*r)*exp(-b*r)" contour
```

## Wo was liegt

| Was | Primitive Live | LN Plotter |
|---|---|---|
| Wallpaper | `Steam/…/wallpaper_engine/projects/myprojects/primitive-live/` | `…/myprojects/ln-plotter/` |
| Bilder | `~/Bilder/Primitive/` (Vorlagen; Unterordner `Off`/`Aus`/`_…` werden ignoriert) | `~/Bilder/LN-Plotter/` (erzeugte SVGs, plotterfertig) |
| Einstellungen | `~/.config/primitive-live/einstellungen.conf` | `~/.config/ln-plotter/formeln.txt` |
| Programme | `~/.local/bin/primitive-live-ctl`, `primitive` | `~/.local/bin/ln-plotter-ctl`, `lnart` |
| Hintergrunddienste | `primitive-live.path` (Bilderordner), `primitive-live-settings.path` | `ln-plotter-gen.timer` (alle 30 min), `ln-plotter-gen.path` (Formeln) |
| Widgets | `de.professortee.primitivelive` | `de.professortee.lnplotter` |

Status prüfen: `systemctl --user list-units 'primitive-live*' 'ln-plotter*'`

## Deinstallieren

```bash
cd primitive-live && ./uninstall.sh
cd ../ln-plotter  && ./uninstall.sh
```

Entfernt Dienste, Steuerprogramme und Widgets. Bilder, Einstellungen und der Wallpaper-Ordner
in Steam bleiben (den kann man in Wallpaper Engine oder per Hand löschen).

## Fehlersuche

- **Widget taucht nicht auf:** `plasmashell --replace &` oder ab-/anmelden.
- **Neue Bilder erscheinen nicht:** `primitive-live-ctl sync` – zeigt, wie viele Bilder eingebettet sind.
- **Zwei „Primitive Live“ in der Liste:** die mit „(alte Kopie – nicht benutzen)“ ignorieren / löschen.
- Logs: `journalctl --user -u primitive-live -u ln-plotter-gen -n 50`
