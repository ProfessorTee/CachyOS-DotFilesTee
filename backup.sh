#!/usr/bin/env bash
# Automatisches Commit + Push für ~/DotFiles
set -e
cd "$HOME/DotFiles"
git add -A
if ! git diff --cached --quiet; then
    git commit -m "Auto-Backup $(date '+%Y-%m-%d %H:%M:%S')"
    git push origin master
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup gepusht" >> "$HOME/DotFiles/.backup.log"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Keine Änderungen" >> "$HOME/DotFiles/.backup.log"
fi
