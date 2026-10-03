#!/usr/bin/env bash
# LN Plotter – erzeugt neue Zeichnungen und aktualisiert drawings.js im Wallpaper.
#   generate.sh [-f formel] [-s stil] [anzahl]
# Gibt die Namen der neuen Zeichnungen aus (eine pro Zeile).
# Umgebungsvariablen: LN_OUT (Ablage der SVGs), LN_KEEP (wie viele behalten), LN_FORMELN
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LNART="$HERE/lnart"; [[ -x "$LNART" ]] || LNART=lnart
OUT="${LN_OUT:-$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Bilder")/LN-Plotter}"
KEEP="${LN_KEEP:-40}"
FORMELN="${LN_FORMELN:-${XDG_CONFIG_HOME:-$HOME/.config}/ln-plotter/formeln.txt}"

FORMEL=""; STYLE=""
while getopts "f:s:" o; do
  case $o in f) FORMEL="$OPTARG";; s) STYLE="$OPTARG";; *) exit 2;; esac
done
shift $((OPTIND-1))
NEW="${1:-${LN_NEW:-3}}"
mkdir -p "$OUT"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

VPYPE=""
for c in vpype "$HOME/.local/bin/vpype"; do command -v "$c" >/dev/null 2>&1 && { VPYPE="$c"; break; }; done

args=(-q)
[[ -f "$FORMELN" ]] && args+=(-formeln "$FORMELN")
[[ -n "$FORMEL" ]] && args+=(-f "$FORMEL")
[[ -n "$STYLE" ]] && args+=(-style "$STYLE")

for ((i=1; i<=NEW; i++)); do
  name="ln-$(date +%Y%m%d-%H%M%S)-$i"
  "$LNART" render "${args[@]}" -o "$TMP/raw.svg"
  if [[ -n "$VPYPE" ]]; then
    # vpype: Linien zusammenfügen, glätten, Plotter-Reihenfolge optimieren
    "$VPYPE" read "$TMP/raw.svg" \
      linemerge --tolerance 0.6 linesimplify --tolerance 0.15 reloop linesort \
      write --page-size 1920x1080 "$TMP/opt.svg" >/dev/null 2>&1
    "$LNART" meta "$TMP/raw.svg" "$TMP/opt.svg"
    mv "$TMP/opt.svg" "$OUT/$name.svg"
  else
    mv "$TMP/raw.svg" "$OUT/$name.svg"
  fi
  echo "$name"
done
[[ -n "$VPYPE" ]] || echo "Hinweis: vpype nicht gefunden – Linien bleiben unoptimiert (pipx install vpype)." >&2

# nur die neuesten KEEP automatisch erzeugten behalten (eigene SVGs bleiben)
mapfile -t old < <(ls -1t "$OUT"/ln-*.svg 2>/dev/null | tail -n +$((KEEP+1)))
[[ ${#old[@]} -gt 0 ]] && rm -f -- "${old[@]}"

# alle SVGs im Ordner packen (auch selbst hineingelegte, z. B. aus vpype)
shopt -s nullglob
svgs=("$OUT"/*.svg)
"$LNART" pack -o "$HERE/drawings.js" "${svgs[@]}" 2>/dev/null
