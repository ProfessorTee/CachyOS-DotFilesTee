# Thermal Monitor 0.2.8 – gepatcht (01.10.2026)

**Problem:** plasmashell lastete dauerhaft einen CPU-Kern zu 100 % aus, KDE ruckelte.

**Ursache:** In `contents/ui/Sensors.qml` war der Verlauf als `property list<var>` deklariert.
Qt 6 kopiert eine solche Liste bei jedem Elementzugriff komplett. Bei `filter`, `slice`,
Durchschnitt/Min/Max entstehen so pro Sekunde Millionen Kopien (O(n²)), besonders mit hohem `statsHistory`.

**Fix:** Zwei Zeilen geändert:
    property list<var> values         -> property var values
    property list<var> filteredValues -> property var filteredValues

Original liegt daneben als `contents/ui/Sensors.qml.original`.

**Wiederherstellen** (z. B. nach Neuinstallation oder Widget-Update aus dem KDE-Store):
    cp -r ~/DotFiles/plasma-widgets/org.kde.olib.thermalmonitor ~/.local/share/plasma/plasmoids/
    systemctl --user restart plasma-plasmashell
