#!/usr/bin/env bash
# Entfernt den Watcher. Wallpaper-Ordner und deine Bilder bleiben unangetastet.
set -u
systemctl --user disable --now primitive-live.path primitive-live-settings.path 2>/dev/null
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/primitive-live"{,-settings}.{path,service} "$HOME/.local/bin/primitive-live-ctl"
systemctl --user daemon-reload
kpackagetool6 -t Plasma/Applet -r de.professortee.primitivelive >/dev/null 2>&1 && echo "Widget entfernt."
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/primitive-live"
echo "Watcher entfernt. Wallpaper-Projekt ggf. in Wallpaper Engine/projects/myprojects/primitive-live löschen."
