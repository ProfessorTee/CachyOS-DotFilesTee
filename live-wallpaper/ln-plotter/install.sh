#!/usr/bin/env bash
# Installiert den "LN Plotter" Wallpaper für Wallpaper Engine (KDE-Plugin):
#  - Wallpaper nach Steam/…/wallpaper_engine/projects/myprojects/ln-plotter
#  - Formeln nach ~/.config/ln-plotter/formeln.txt (wird nie überschrieben)
#  - systemd-Timer: alle 30 min neue Zeichnungen, sofort bei Änderung der Formeln
#  - SVGs (plotterfertig) landen in ~/Bilder/LN-Plotter
#   ./install.sh [/pfad/zu/Steam | /pfad/zum/projektordner]
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/ln-plotter"
OUT="${LN_OUT:-$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Bilder")/LN-Plotter}"

ARG="${1:-}"
if [[ -n "$ARG" && -f "$ARG/project.json" ]]; then
  DEST="$(readlink -f "$ARG")"
else
  STEAM="$ARG"
  if [[ -z "$STEAM" ]]; then
    cands=("$HOME/Games/Steam" "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam")
    for vdf in "$HOME"/.local/share/Steam/steamapps/libraryfolders.vdf "$HOME"/.steam/steam/steamapps/libraryfolders.vdf; do
      [[ -f "$vdf" ]] && while read -r p; do cands+=("$p"); done < <(sed -n 's/.*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf")
    done
    for d in "${cands[@]}"; do
      [[ -d "$d/steamapps/common/wallpaper_engine" ]] && { STEAM="$(readlink -f "$d")"; break; }
    done
  fi
  [[ -n "${STEAM:-}" ]] || { echo "Wallpaper Engine nicht gefunden. Aufruf: $0 /pfad/zu/Steam"; exit 1; }
  DEST="$STEAM/steamapps/common/wallpaper_engine/projects/myprojects/ln-plotter"
fi
mkdir -p "$DEST"; DEST="$(readlink -f "$DEST")"
if [[ "$DEST" != "$SRC" ]]; then
  cp "$SRC"/{index.html,project.json,preview.jpg,generate.sh,lnart,ln-plotter-ctl} "$DEST"/
  [[ -f "$DEST/drawings.js" ]] || cp "$SRC/drawings.js" "$DEST/"
fi
chmod +x "$DEST/generate.sh" "$DEST/lnart" "$DEST/ln-plotter-ctl"
echo "✔ Wallpaper: $DEST"

mkdir -p "$CONF" "$OUT"
[[ -f "$CONF/formeln.txt" ]] || { cp "$SRC/formeln.txt" "$CONF/"; echo "✔ Formeln: $CONF/formeln.txt"; }
echo "✔ Zeichnungen (SVG): $OUT"

printf 'DEST=%q\nOUT=%q\n' "$DEST" "$OUT" > "$CONF/paths.env"

mkdir -p "$HOME/.local/bin"
install -m755 "$SRC/lnart" "$HOME/.local/bin/lnart"
install -m755 "$SRC/ln-plotter-ctl" "$HOME/.local/bin/ln-plotter-ctl"
echo "✔ CLI: ~/.local/bin/lnart, ~/.local/bin/ln-plotter-ctl"
"$HOME/.local/bin/ln-plotter-ctl" resume   # legt control.js an

# KDE-Widgets: Steuer-Widget + Panel-Leiste
install_widget() { # $1 = Ordner, $2 = Id, $3 = Name
  if kpackagetool6 -t Plasma/Applet -l 2>/dev/null | grep -qx "$2"; then
    kpackagetool6 -t Plasma/Applet -u "$SRC/$1" >/dev/null && echo "✔ Widget aktualisiert: $3"
  else
    kpackagetool6 -t Plasma/Applet -i "$SRC/$1" >/dev/null && echo "✔ Widget installiert: $3"
  fi
}
if command -v kpackagetool6 >/dev/null; then
  install_widget plasmoid de.professortee.lnplotter "LN Plotter"
  # das frühere Panel-Widget "LN Plotter Leiste" ist ersetzt (Leiste zeichnet jetzt der Wallpaper)
  kpackagetool6 -t Plasma/Applet -r de.professortee.lnplotter.panel >/dev/null 2>&1 && echo "✔ altes Panel-Widget 'LN Plotter Leiste' entfernt"
else
  echo "⚠ kpackagetool6 nicht gefunden – Widgets nicht installiert"
fi

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

# vpype
if ! command -v vpype >/dev/null && [[ ! -x "$HOME/.local/bin/vpype" ]]; then
  echo "⚠ vpype nicht gefunden – ohne vpype keine Linien-Optimierung (Plotter-Reihenfolge)."
  if command -v pipx >/dev/null && [[ -t 0 ]]; then
    read -rp "  Jetzt mit pipx installieren? [J/n] " ans
    [[ "${ans,,}" == "n" ]] || pipx install vpype
  else
    echo "  Installieren mit:  sudo pacman -S python-pipx && pipx install vpype"
  fi
fi

UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNITS"
cat > "$UNITS/ln-plotter-gen.service" <<UNIT
[Unit]
Description=LN Plotter: neue Zeichnungen erzeugen

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin
Environment=LN_OUT=$OUT
ExecStart="$DEST/generate.sh" 2
Nice=15
UNIT
cat > "$UNITS/ln-plotter-gen.timer" <<UNIT
[Unit]
Description=LN Plotter: alle 30 Minuten neue Zeichnungen

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
cat > "$UNITS/ln-plotter-gen.path" <<UNIT
[Unit]
Description=LN Plotter: Formeln überwachen

[Path]
PathChanged=$CONF/formeln.txt
Unit=ln-plotter-gen.service

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now ln-plotter-gen.timer ln-plotter-gen.path >/dev/null
echo "✔ Timer aktiv (systemctl --user list-timers ln-plotter-gen.timer)"

echo "… erste Zeichnungen werden erzeugt"
PATH="$HOME/.local/bin:$PATH" LN_OUT="$OUT" "$DEST/generate.sh" 8 >/dev/null && echo "✔ 8 Zeichnungen erzeugt"

echo
echo "Fertig. Desktop-Einstellungen → Wallpaper Engine → Liste neu laden → 'LN Plotter'."
echo "Widget: Rechtsklick aufs Panel → Widgets hinzufügen → 'LN Plotter'."
echo "  (Taucht es nicht auf: einmal abmelden/anmelden oder 'plasmashell --replace &')"
echo "Formeln bearbeiten: $CONF/formeln.txt  (wird beim Speichern sofort neu generiert)"
