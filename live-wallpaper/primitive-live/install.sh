#!/usr/bin/env bash
# Installiert "Primitive Live" für Wallpaper Engine (KDE-Plugin), richtet den Bilderordner
# ~/Bilder/Primitive mit automatischem Sync ein und installiert das primitive-CLI.
#   ./install.sh                     Steam wird automatisch gesucht
#   ./install.sh /pfad/zu/Steam
#   BILDER=~/woanders ./install.sh   anderer Bilderordner
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
PICS="${BILDER:-$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Bilder")/Primitive}"

ARG="${1:-}"
DEST=""
if [[ -n "$ARG" && -f "$ARG/project.json" ]]; then
  DEST="$(readlink -f "$ARG")"                       # direkt ein Projektordner angegeben
else
  STEAM="$ARG"
  if [[ -z "$STEAM" ]]; then
    cands=("$HOME/Games/Steam" "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam")
    # zusätzliche Steam-Bibliotheken aus libraryfolders.vdf
    for vdf in "$HOME"/.local/share/Steam/steamapps/libraryfolders.vdf "$HOME"/.steam/steam/steamapps/libraryfolders.vdf; do
      [[ -f "$vdf" ]] && while read -r p; do cands+=("$p"); done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf")
    done
    for d in "${cands[@]}"; do
      [[ -d "$d/steamapps/common/wallpaper_engine" ]] && { STEAM="$(readlink -f "$d")"; break; }
    done
  fi
  [[ -n "$STEAM" ]] || { echo "Wallpaper Engine nicht gefunden. Aufruf: $0 /pfad/zu/Steam  oder  $0 /pfad/zum/projektordner"; exit 1; }
  MYP="$STEAM/steamapps/common/wallpaper_engine/projects/myprojects"
  # vorhandene Installation wiederverwenden (egal wie der Ordner heißt)
  # (nur direkt in myprojects/ – tiefer verschachtelt findet das KDE-Plugin es nicht)
  existing=$(grep -l '"Primitive Live"' "$MYP"/*/project.json 2>/dev/null | grep -v "^$SRC/" | head -1 || true)
  if [[ -n "$existing" ]]; then DEST="$(dirname "$existing")"; else DEST="$MYP/primitive-live"; fi
fi
mkdir -p "$DEST"
DEST="$(readlink -f "$DEST")"

# alte, zu tief verschachtelte Kopien markieren (die bekommen keine Bilder-Updates)
if [[ -n "${MYP:-}" ]]; then
  while IFS= read -r pj; do
    d="$(readlink -f "$(dirname "$pj")")"
    [[ "$d" == "$DEST" || "$d" == "$SRC" ]] && continue
    sed -i 's/"title": *"Primitive Live"/"title": "Primitive Live (alte Kopie – nicht benutzen)"/' "$pj"
    echo "⚠ Alte Kopie gefunden und umbenannt: $d"
    echo "  → In Wallpaper Engine die neue 'Primitive Live' wählen; den alten Ordner kannst du löschen."
  done < <(grep -l '"Primitive Live"' "$MYP"/*/*/project.json 2>/dev/null || true)
fi
[[ "$DEST" == "$SRC" ]] || cp "$SRC"/{index.html,primitive.js,project.json,preview.jpg,add-images.sh} "$DEST"/
[[ -f "$DEST/images.js" ]] || cp "$SRC/images.js" "$DEST/"
chmod +x "$DEST/add-images.sh"
echo "✔ Wallpaper: $DEST"
if [[ "$(basename "$(dirname "$DEST")")" != "myprojects" ]]; then
  echo "⚠ $DEST liegt nicht direkt in myprojects/ – das KDE-Plugin findet ihn dort evtl. nicht."
fi

# Bilderordner
mkdir -p "$PICS"
if [[ -z "$(find "$PICS" -type f -print -quit)" && -d "$SRC/beispiele" ]]; then
  cp "$SRC"/beispiele/* "$PICS"/
  echo "✔ Beispielbilder nach $PICS kopiert (kannst du löschen)"
fi
echo "✔ Bilderordner: $PICS"

# systemd-User-Units: Ordner überwachen → images.js neu bauen
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNITS"
cat > "$UNITS/primitive-live.service" <<EOF
[Unit]
Description=Primitive Live: Bilder aus $PICS einbetten

[Service]
Type=oneshot
# kurz warten, damit große Kopiervorgänge fertig sind
ExecStartPre=/usr/bin/sleep 3
ExecStart="$DEST/add-images.sh" "$PICS"
Nice=10
EOF
cat > "$UNITS/primitive-live.path" <<EOF
[Unit]
Description=Primitive Live: $PICS überwachen

[Path]
PathChanged=$PICS
PathModified=$PICS
MakeDirectory=yes
Unit=primitive-live.service

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now primitive-live.path >/dev/null
echo "✔ Watcher aktiv (systemctl --user status primitive-live.path)"

echo "… Bilder werden eingebettet"
"$DEST/add-images.sh" "$PICS"

# Einstellungen (das KDE-Plugin gibt Wallpaper-Eigenschaften nicht an Web-Wallpaper weiter)
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/primitive-live"
mkdir -p "$CONF" "$HOME/.local/bin"
printf 'DEST=%q\nPICS=%q\n' "$DEST" "$PICS" > "$CONF/paths.env"
install -m755 "$SRC/primitive-live-ctl" "$HOME/.local/bin/primitive-live-ctl"
"$HOME/.local/bin/primitive-live-ctl" apply
cat > "$UNITS/primitive-live-settings.service" <<UNIT
[Unit]
Description=Primitive Live: Einstellungen übernehmen

[Service]
Type=oneshot
ExecStart=%h/.local/bin/primitive-live-ctl apply
UNIT
cat > "$UNITS/primitive-live-settings.path" <<UNIT
[Unit]
Description=Primitive Live: Einstellungsdatei überwachen

[Path]
PathChanged=$CONF/einstellungen.conf
Unit=primitive-live-settings.service

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now primitive-live-settings.path >/dev/null
echo "✔ Einstellungen: $CONF/einstellungen.conf  (oder: primitive-live-ctl set formen ellipsen)"

# Aufräumen: frühere Panel-Leiste entfernen (falls installiert)
_U="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [[ -f "$_U/live-leiste.path" || -e "$HOME/.local/bin/live-leiste" ]]; then
  systemctl --user disable --now live-leiste.path >/dev/null 2>&1 || true
  rm -f "$_U/live-leiste.path" "$_U/live-leiste.service" "$HOME/.local/bin/live-leiste"
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/live-wallpaper"
  systemctl --user daemon-reload
  echo "✔ Panel-Leiste entfernt"
fi
rm -f "$DEST/band.js" "$DEST/leiste.js"

# KDE-Widget
if command -v kpackagetool6 >/dev/null; then
  if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx 'de.professortee.primitivelive'; then
    kpackagetool6 -t Plasma/Applet -u "$SRC/plasmoid" >/dev/null && echo "✔ KDE-Widget aktualisiert"
  else
    kpackagetool6 -t Plasma/Applet -i "$SRC/plasmoid" >/dev/null && echo "✔ KDE-Widget installiert"
  fi
else
  echo "⚠ kpackagetool6 nicht gefunden – Widget nicht installiert"
fi

if [[ -f "$SRC/primitive" ]]; then
  mkdir -p "$HOME/.local/bin" && install -m755 "$SRC/primitive" "$HOME/.local/bin/primitive"
  echo "✔ CLI: ~/.local/bin/primitive"
fi
command -v magick >/dev/null || command -v convert >/dev/null || command -v ffmpeg >/dev/null || \
  echo "⚠ Weder ImageMagick noch ffmpeg gefunden: Bilder werden unverkleinert eingebettet. Empfohlen: sudo pacman -S imagemagick"

echo
echo "Fertig. Bilder einfach in $PICS legen – sie werden automatisch übernommen"
echo "und tauchen beim nächsten Bildwechsel auf. Erstes Mal: Desktop-Einstellungen →"
echo "Wallpaper Engine → Liste neu laden → 'Primitive Live'."
echo "Widget: Rechtsklick aufs Panel → Widgets hinzufügen → 'Primitive Live'."
echo "  (Taucht es nicht auf: 'plasmashell --replace &' oder einmal ab-/anmelden)"
