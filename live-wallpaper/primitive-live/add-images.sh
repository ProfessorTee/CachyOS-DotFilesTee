#!/usr/bin/env bash
# Bettet Bilder als data-URLs in images.js ein (der Wallpaper darf lokale Dateien nicht direkt auslesen).
# Nutzung:  ./add-images.sh ~/Bilder/Primitive            (Ordner inkl. Unterordner, ersetzt die Liste)
#           ./add-images.sh -a bild1.jpg bild2.png        (hängt an)
# Normalerweise läuft das automatisch über den systemd-Watcher (primitive-live.path).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
APPEND=0; [[ "${1:-}" == "-a" ]] && { APPEND=1; shift; }
[[ $# -gt 0 ]] || { echo "Nutzung: $0 [-a] <ordner|bilder...>"; exit 1; }

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/primitive-live"
mkdir -p "$CACHE"
if command -v magick >/dev/null; then IM=(magick); elif command -v convert >/dev/null; then IM=(convert); else IM=(); fi

files=()
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    # Unterordner "Off"/"Aus"/"_irgendwas" und versteckte Ordner werden ignoriert (Ablage für Pausiertes)
    while IFS= read -r -d '' f; do files+=("$f"); done < <(find -L "$arg" -mindepth 1 \
        \( -type d \( -iname off -o -iname aus -o -iname 'deaktiviert' -o -name '_*' -o -name '.*' \) -prune \) -o \
        \( -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' -o -iname '*.gif' -o -iname '*.avif' -o -iname '*.jxl' \) -not -name '.*' -print0 \) | sort -z)
  elif [[ -f "$arg" ]]; then files+=("$(realpath "$arg")"); fi
done

encode() { # $1 = Bilddatei → base64-JPEG (max. 512 px) auf stdout
  local f="$1"
  if [[ ${#IM[@]} -gt 0 ]]; then
    "${IM[@]}" "$f[0]" -auto-orient -resize '512x512>' -quality 88 jpg:- 2>/dev/null | base64 -w0
  elif command -v ffmpeg >/dev/null; then
    ffmpeg -loglevel error -i "$f" -frames:v 1 -vf "scale='min(512,iw)':-2" -q:v 3 -f image2 -c:v mjpeg - | base64 -w0
  else
    base64 -w0 < "$f"
  fi
}

entries=(); added=0; skipped=0
for f in "${files[@]}"; do
  key=$(printf '%s|%s|%s' "$f" "$(stat -c '%Y %s' "$f")" "${IM[*]:-x}" | sha1sum | cut -c1-16)
  c="$CACHE/$key.b64"
  if [[ ! -s "$c" ]]; then
    if encode "$f" > "$c.tmp" && [[ -s "$c.tmp" ]]; then mv "$c.tmp" "$c"; added=$((added+1)); echo "  + $(basename "$f")"
    else rm -f "$c.tmp"; skipped=$((skipped+1)); echo "  ! übersprungen: $(basename "$f")"; continue; fi
  fi
  mime=jpeg
  if [[ ${#IM[@]} -eq 0 ]] && ! command -v ffmpeg >/dev/null; then
    case "${f,,}" in *.png) mime=png;; *.webp) mime=webp;; *.gif) mime=gif;; *) mime=jpeg;; esac
  fi
  entries+=("\"data:image/$mime;base64,$(cat "$c")\"")
done

if [[ $APPEND -eq 1 && -f images.js ]]; then
  mapfile -t old < <(grep -o '"data:[^"]*"' images.js || true)
  entries=("${old[@]}" "${entries[@]}")
fi

# atomar schreiben, damit der Wallpaper nie eine halbe Datei liest
{ echo "window.PRIMITIVE_IMAGES = ["
  for i in "${!entries[@]}"; do sep=","; [[ $i -eq $((${#entries[@]}-1)) ]] && sep=""; echo "  ${entries[$i]}$sep"; done
  echo "];"; } > images.js.tmp
mv images.js.tmp images.js
echo "images.js: ${#entries[@]} Bild(er) (neu: $added, übersprungen: $skipped)."

# alten Cache aufräumen (älter als 30 Tage, nicht mehr benutzt)
find "$CACHE" -name '*.b64' -atime +30 -delete 2>/dev/null || true
