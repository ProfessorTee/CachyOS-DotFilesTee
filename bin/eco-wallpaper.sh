#!/usr/bin/env bash
# Pausiert die Live-Wallpaper im KDE-Energiesparprofil und setzt sie in allen anderen Profilen fort.
B="$HOME/.local/bin"
apply() {
  profile=$(powerprofilesctl get)
  [ "$profile" = "$LAST" ] && return   # doppelte Meldung ignorieren
  LAST=$profile
  [ "$profile" = power-saver ] && cmd=pause || cmd=resume
  "$B/primitive-live-ctl" "$cmd"
  "$B/ln-plotter-ctl" "$cmd"
} >/dev/null 2>&1

apply
gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles |
while read -r line; do
  [[ $line == *ActiveProfile* ]] && apply
done
