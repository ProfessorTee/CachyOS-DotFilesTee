#!/usr/bin/env bash
set -euo pipefail

TARGET="/etc/sysctl.d/99-zram-tuning.conf"

if [ -f "$TARGET" ]; then
    echo "Datei existiert schon: $TARGET"
    echo "Aktueller Inhalt:"
    cat "$TARGET"
    echo
    read -p "Ueberschreiben? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Abgebrochen."
        exit 0
    fi
fi

sudo tee "$TARGET" > /dev/null << 'EOF'
# Tuning fuer zram-basierten Swap (RAM-Geschwindigkeit, keine Seek-Zeit)
vm.swappiness=100
vm.page-cluster=0
EOF

sudo sysctl --system > /dev/null

echo "Fertig. Aktuelle Werte:"
sysctl vm.swappiness vm.page-cluster
