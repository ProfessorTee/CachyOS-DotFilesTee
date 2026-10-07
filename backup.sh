#!/usr/bin/env bash
# Spiegelt die Live-Konfigs nach ~/DotFiles, dann Commit + Push.
# Neue Datei sichern = eine Zeile in MIRROR ergänzen ("Repo-Pfad|Live-Pfad").
set -e
cd "$HOME/DotFiles"
C="$HOME/.config"

MIRROR=(
    "config/fish/config.fish|$C/fish/config.fish"
    "config/fish/fish_variables|$C/fish/fish_variables"
    "config/kitty/kitty.conf|$C/kitty/kitty.conf"
    "config/fastfetch/config.jsonc|$C/fastfetch/config.jsonc"
    "config/primitive-live/einstellungen.conf|$C/primitive-live/einstellungen.conf"
    "config/ln-plotter/formeln.txt|$C/ln-plotter/formeln.txt"
    "config/environment.d/gaming.conf|$C/environment.d/gaming.conf"
    "etc/environment|/etc/environment"
    "systemd/dotfiles-backup.service|$C/systemd/user/dotfiles-backup.service"
    "systemd/dotfiles-backup.timer|$C/systemd/user/dotfiles-backup.timer"
)
# Nicht gespiegelt: etc/udev/... (Repo-Version hat die Doku-Kommentare)

for entry in "${MIRROR[@]}"; do
    src="${entry#*|}" dst="${entry%%|*}"
    if [ -f "$src" ] && ! cmp -s "$src" "$dst"; then install -D -m 644 "$src" "$dst"; fi
done

log() { echo "$(date '+%F %T') - $1" >> .backup.log; }
git add -A
if git diff --cached --quiet; then
    log "Keine Änderungen"
else
    git commit -q -m "Auto-Backup $(date '+%F %T')"
    git push -q origin master && log "Backup gepusht" || { log "PUSH FEHLGESCHLAGEN"; exit 1; }
fi
