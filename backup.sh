#!/usr/bin/env bash
# Automatisches Commit + Push für ~/DotFiles
set -e
cd "$HOME/DotFiles"
# Live-Wallpaper: Einstellungen + Formeln als Kopie mitsichern (siehe README Abschnitt 10)
for f in primitive-live/einstellungen.conf ln-plotter/formeln.txt; do
    if [ -f "$HOME/.config/$f" ]; then
        install -D -m 644 "$HOME/.config/$f" "$HOME/DotFiles/config/$f"
    fi
done
git add -A
if ! git diff --cached --quiet; then
    git commit -m "Auto-Backup $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin master
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup gepusht" >> "$HOME/DotFiles/.backup.log"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Keine Änderungen" >> "$HOME/DotFiles/.backup.log"
fi
