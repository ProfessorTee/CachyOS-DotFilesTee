#!/usr/bin/env bash
# Entfernt Timer/Watcher. Wallpaper-Ordner, Formeln und SVGs bleiben.
set -u
systemctl --user disable --now ln-plotter-gen.timer ln-plotter-gen.path 2>/dev/null
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ln-plotter-gen."{service,timer,path}
systemctl --user daemon-reload
kpackagetool6 -t Plasma/Applet -r de.professortee.lnplotter >/dev/null 2>&1 && echo "Widget entfernt."
kpackagetool6 -t Plasma/Applet -r de.professortee.lnplotter.panel >/dev/null 2>&1 && echo "Panel-Widget entfernt."
rm -f "$HOME/.local/bin/ln-plotter-ctl"
echo "Timer entfernt. Wallpaper liegt weiter in Wallpaper Engine/projects/myprojects/ln-plotter."
