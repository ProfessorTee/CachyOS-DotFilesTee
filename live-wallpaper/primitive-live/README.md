# Primitive Live – Wallpaper Engine (KDE)

Live-Port von [fogleman/primitive](https://github.com/fogleman/primitive): Das Bild wird direkt auf
dem Desktop Form für Form aus Dreiecken/Ellipsen/Rechtecken aufgebaut, bleibt kurz stehen und
blendet dann ins nächste Bild über. Kein Video – alles wird in Echtzeit berechnet und als
Vektor in voller Auflösung gezeichnet.

## Installation

    ./install.sh                 # findet Steam automatisch (nativ + Flatpak)
    ./install.sh /pfad/zu/Steam  # alternativ

Das kopiert den Wallpaper nach
`Steam/steamapps/common/wallpaper_engine/projects/myprojects/primitive-live/`
und das CLI-Binary nach `~/.local/bin/primitive`.

Dann: Rechtsklick Desktop → *Hintergrundbild einrichten* → *Wallpaper Engine* → Liste neu
laden → **Primitive Live**.

Voraussetzung für Web-Wallpaper im KDE-Plugin: QtWebEngine (Arch: `qt6-webengine`,
Fedora: `qt6-qtwebengine`, Debian/Ubuntu: `qml6-module-qtwebengine`).

## Eigene Bilder: ~/Bilder/Primitive

Bilder einfach in `~/Bilder/Primitive` legen (Unterordner gehen auch – außer `Off`, `Aus` und Ordner mit `_` vorne: dort kannst du Bilder parken, die gerade nicht dran sein sollen). Ein systemd-Watcher
(`primitive-live.path`) bemerkt die Änderung, bettet die Bilder ein (verkleinert, mit Cache)
und der Wallpaper nimmt sie beim nächsten Bildwechsel mit. Kein Neustart nötig.
Die Reihenfolge ist zufällig, und jedes Bild kommt einmal dran, bevor sich eins wiederholt.

Status/Log: `systemctl --user status primitive-live.path` · `journalctl --user -u primitive-live`
Manuell:    `<wallpaper-ordner>/add-images.sh ~/Bilder/Primitive`
Entfernen:  `./uninstall.sh`

Formate: jpg, png, webp, bmp, gif, avif, jxl (avif/jxl mit ImageMagick).

## KDE-Widget

Rechtsklick aufs Panel → *Widgets hinzufügen* → **Primitive Live**:
Pause · nächstes Bild · aktuelles neu malen · sofort fertig, Formen einzeln an/aus
(mehrere = Mischung, „Alle“ = alle fünf), **Überlagern** (nächstes Bild wird über das
aktuelle gemalt und verwandelt es Form für Form),
Regler für Deckkraft, Formen pro Bild, Tempo, Standzeit, Genauigkeit und CPU,
Bilderordner öffnen und neu einlesen. Panel-Icon: Mittelklick/Mausrad = nächstes Bild.

## Einstellungen

Das KDE-Plugin reicht bei Web-Wallpapern **nur die Standardwerte** aus `project.json` durch –
was du im Plugin-Dialog umstellst, kommt nicht an. Deshalb gibt es eine eigene Einstellungsdatei:

    ~/.config/primitive-live/einstellungen.conf

Speichern genügt, der Wallpaper übernimmt die Werte nach ca. 2 Sekunden. Oder per Terminal:

    primitive-live-ctl set formen gedrehte-ellipsen
    primitive-live-ctl set anzahl 1500
    primitive-live-ctl            # aktuelle Werte
    primitive-live-ctl edit       # Datei öffnen
    primitive-live-ctl reset      # Standardwerte

formen: dreiecke · rechtecke · ellipsen · gedrehte-rechtecke · gedrehte-ellipsen · alle
        (Komma-Liste = Mischung, z. B. `dreiecke,ellipsen`)
weitere: deckkraft · anzahl · tempo · aufloesung · cpu · standzeit · zufall · fortschritt · ueberlagern

Im normalen Browser testen: `index.html?mode=3&speed=0&hud=1`

## Das CLI

`primitive` ist das originale Go-Tool (statisch gebaut, linux-amd64):

    primitive -i foto.jpg -o out.png -n 200 -m 1
    primitive -i foto.jpg -o out.svg -n 500 -m 0 -s 3840
