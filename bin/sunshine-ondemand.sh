#!/usr/bin/env bash
# Sunshine nur bei Bedarf: Solange es aus ist, lauscht dieses Script auf 47989 (Moonlight)
# und 47990 (Web-UI). Bei der ersten Anfrage startet Sunshine, Moonlight verbindet sich
# nach ein paar Sekunden beim nächsten Versuch. Ohne laufenden Stream (keine NVENC-Session)
# wird Sunshine nach IDLE_MIN Minuten wieder gestoppt, damit die GPU in den Sparmodus kann.
SVC=app-dev.lizardbyte.app.Sunshine.service
IDLE_MIN=5
idle=0
while true; do
  # nur lauschen, wenn Sunshine wirklich aus ist (nicht beim Starten/Neustarten, sonst blockieren wir dessen Ports)
  if [[ $(systemctl --user show -p ActiveState --value "$SVC") =~ ^(inactive|failed)$ ]]; then
    python3 - <<'PY' || { sleep 10; continue; }   # blockiert bis zur ersten Verbindung
import socket, selectors
sel = selectors.DefaultSelector()
for port in (47989, 47990):
    sel.register(socket.create_server(("", port), family=socket.AF_INET6, dualstack_ipv6=True), selectors.EVENT_READ)
sel.select()
PY
    systemctl --user reset-failed "$SVC" 2>/dev/null; systemctl --user start "$SVC"
    idle=0
  fi
  sleep 60
  if [ "$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader)" -gt 0 ]; then
    idle=0
  else
    idle=$((idle + 1))
  fi
  [ "$idle" -ge "$IDLE_MIN" ] && systemctl --user stop "$SVC"
done
