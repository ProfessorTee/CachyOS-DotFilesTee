# LN Plotter – Wallpaper Engine (KDE)

Mathematische Flächen z = f(x, y) werden mit [fogleman/ln](https://github.com/fogleman/ln)
als 3D-Linienzeichnung mit echter Hidden-Line-Removal gerendert, mit
[vpype](https://github.com/abey79/vpype) optimiert (linemerge · linesimplify · reloop · linesort)
und auf dem Desktop von einem virtuellen Plotterstift live nachgezeichnet. Dank `linesort`
fährt der Stift genau die Reihenfolge ab, die auch ein echter Plotter nehmen würde.

## Installation

    ./install.sh                  # findet ~/Games/Steam, ~/.local/share/Steam, Flatpak …
    ./install.sh /pfad/zu/Steam

Für die Optimierung braucht es vpype:  `sudo pacman -S python-pipx && pipx install vpype`
(der Installer fragt nach). Ohne vpype geht's auch, nur ohne Plotter-Reihenfolge.

## KDE-Widget

Der Installer richtet auch ein Plasma-6-Widget ein: Rechtsklick aufs Panel → *Widgets
hinzufügen* → **LN Plotter**. Damit steuerst du den Wallpaper live:

- ⏮ von vorn · ⏯ Pause · ⏩ sofort fertig · ⏭ nächste Zeichnung
- Formel eintippen (+ Linienstil) → **Zeichnen**: wird gerendert und sofort geplottet
- Formel-Liste aus `formeln.txt`: Klick übernimmt, Doppelklick zeichnet, ➕ speichert neue
- Farbschema, Zeichendauer, Pause, Strichstärke, Stift/Formel/Leerfahrten
- Generator-Timer an/aus, „3 neue“, Formeln bearbeiten, SVG-Ordner öffnen
- Panel-Icon: Mittelklick = nächste Zeichnung, Mausrad runter = nächste

Alles läuft über `ln-plotter-ctl` (auch fürs Terminal oder eigene Shortcuts):

    ln-plotter-ctl next | toggle | draw "cos(a*6*r)*exp(-b*r)" contour | set theme nacht

## Formeln

`~/.config/ln-plotter/formeln.txt` – eine Formel pro Zeile. Beim Speichern werden sofort neue
Zeichnungen erzeugt, sonst alle 30 Minuten zwei neue (die letzten 40 bleiben).

Variablen: `x y` (−1…1), `r phi` (polar), `a b c` (Zufallsparameter 0.5…2), `pi e`
Funktionen: `sin cos tan atan atan2 exp log sqrt pow abs floor round min max mod sign …`

    sin(a*3*r - phi*b) / (1 + r)
    exp(-a*4*r*r) * cos(b*10*r)
    x^3*a - 3*x*y*y*b

## Linienstile

Zufällig gewählt: `grid · x · y · diag · radial · rings · spiral · contour` (Höhenlinien).

## Die SVGs

Landen in `~/Bilder/LN-Plotter` – plotterfertig (vpype-optimiert). Eigene SVGs, die du dort
ablegst (z. B. aus vpype), zeichnet der Wallpaper ebenfalls.

## CLI

    lnart render -f "cos(a*6*r)*exp(-b*r)" -style contour -o bild.svg
    lnart list            # eingebaute Formeln
    lnart pack *.svg -o drawings.js

Manuell neu generieren:  `systemctl --user start ln-plotter-gen`
Entfernen:               `./uninstall.sh`

## Einstellungen im Wallpaper

Farbschema (Papier, Nacht, Blaupause, Terminal, Sonnenuntergang/Aquarell mit Farbverlauf),
Zeichendauer, Standzeit, Strichstärke, Rand, Stift, Leerfahrten, Formel-Label.
