# CachyOS DotFiles – Restore Guide

Backup & Restore-Anleitung für professortee's CachyOS-Setup
(ASUS ROG Strix X870E-E Gaming WiFi Neo, Ryzen 7 9800X3D, RTX 3090).

Dieses Repo sichert automatisch täglich (systemd-Timer, siehe unten).
Diese Anleitung ist für den Fall gedacht: neue Festplatte, frische
CachyOS-Installation, oder ein komplett neuer Rechner.

---

## 0. Reihenfolge auf einen Blick

1. CachyOS frisch installieren
2. SSH-Key für GitHub einrichten
3. Dieses Repo klonen
4. Configs zurückspielen (fish, kitty, fastfetch)
5. Bluetooth-Fix (MediaTek MT7927/MT6639)
6. OpenRGB-Fix (i2c-Gruppe + udev + Kernel-Parameter)
7. Laufwerke/fstab einrichten
8. Logitech H-Shifter-Treiber einrichten (falls Sim-Racing-Setup genutzt wird)
9. Auto-Backup-Timer aktivieren

---

## 1. CachyOS Grundinstallation

Normale CachyOS-Installation durchführen. `yay` ist meistens schon
vorinstalliert (sonst: `sudo pacman -S --needed base-devel git` und
yay aus dem AUR selbst bauen).

---

## 2. SSH-Key für GitHub einrichten

**Wichtig:** Der private SSH-Key selbst liegt NICHT in diesem Repo
(aus gutem Grund – Secrets gehören nie in Git). Er muss separat
gesichert sein (Passwort-Manager, verschlüsselter USB-Stick o.ä.)
oder neu erzeugt werden:

```bash
ssh-keygen -t ed25519 -C "tee.winkler@live.de" -f ~/.ssh/id_ed25519_github
```

Bei der Passphrase-Abfrage **zweimal Enter drücken (leer lassen)** –
wichtig, damit der automatische Backup-Timer später ohne Passworteingabe
pushen kann.

```bash
cat ~/.ssh/id_ed25519_github.pub
```

Diesen Public Key auf GitHub eintragen: **Settings → SSH and GPG keys
→ New SSH key**.

SSH-Config anlegen:

```bash
echo "Host github.com" >> ~/.ssh/config
echo "    IdentityFile ~/.ssh/id_ed25519_github" >> ~/.ssh/config
echo "    IdentitiesOnly yes" >> ~/.ssh/config
chmod 600 ~/.ssh/config
```

---

## 3. Repo klonen

```bash
git clone git@github.com:ProfessorTee/CachyOS-DotFilesTee.git ~/DotFiles
```

(Falls SSH-Key noch nicht fertig eingerichtet: erstmal per HTTPS
klonen, reicht zum Lesen/Wiederherstellen —
`git clone https://github.com/ProfessorTee/CachyOS-DotFilesTee.git ~/DotFiles`
— SSH-Key danach nachrüsten für Push-Zugriff.)

---

## 4. Configs zurückspielen

```bash
mkdir -p ~/.config
cp -r ~/DotFiles/config/fish ~/.config/
cp -r ~/DotFiles/config/kitty ~/.config/
cp -r ~/DotFiles/config/fastfetch ~/.config/
```

**Hinweis:** Das sind aktuell Kopien, keine Symlinks. Änderungen an
den echten Configs unter `~/.config/...` landen NICHT automatisch in
diesem Repo – vor dem nächsten großen Umzug lohnt sich ein Umstieg auf
GNU Stow (Symlinks statt Kopien), damit sowas nicht mehr veraltet.

---

## 5. Bluetooth-Fix (MediaTek MT7927 / MT6639)

Betrifft: Bluetooth verbindet/trennt sich ständig, weil die BT-Firmware
für den MT7927-Chip (noch) nicht offiziell in `linux-firmware` enthalten
ist (Stand Sept. 2026, siehe linux-firmware MR !946).

```bash
yay -S --noconfirm mediatek-mt7927-dkms
```

Danach neu starten, prüfen mit:

```bash
bluetoothctl show    # sollte "Powered: yes" zeigen
```

Falls zusätzlich der `linux-zen`-Kernel genutzt wird: vorher
`linux-zen-headers` installieren, sonst baut DKMS für den Zen-Kernel
nicht mit (Fehler ist harmlos, wenn Zen nicht gebootet wird).

---

## 6. OpenRGB-Fix

Betrifft: OpenRGB erkennt Geräte, kann sie aber nicht steuern
(hängt sich beim Zugriff auf).

### a) i2c-Gruppenzugriff

```bash
sudo groupadd i2c 2>/dev/null
sudo usermod -aG i2c $USER
echo 'KERNEL=="i2c-[0-9]*", GROUP="i2c", MODE="0660"' | sudo tee /etc/udev/rules.d/60-openrgb-i2c.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=i2c-dev
```

Danach einmal ab- und wieder anmelden (oder neu starten), damit die
Gruppenmitgliedschaft aktiv wird. Prüfen mit `id` (sollte `i2c` in der
Gruppenliste zeigen).

### b) ACPI-Ressourcenkonflikt (GRUB-Kernel-Parameter)

Ohne das hängt sich OpenRGB beim Zugriff auf den SMBus auf (ACPI
reserviert dieselben I/O-Bereiche wie der Kernel-I2C-Treiber):

```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="nowatchdog nvme_load=YES splash loglevel=3 acpi_enforce_resources=lax"/' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Neu starten, prüfen mit `cat /proc/cmdline | grep acpi_enforce_resources`.

### c) Bekannter OpenRGB-Bug: "ASUS Motherboard" hängt trotzdem

Das Board selbst (Aura-USB-Controller/ARGB Gen2) lässt sich aktuell
NICHT über OpenRGB steuern – bekannter, ungelöster Bug
(GitLab Issue #5172, betrifft auch X670E-E mit demselben Controller).

**Workaround:** In OpenRGB unter Settings → SupportedDevices den
Eintrag "ASUS Motherboard" deaktivieren. Dann funktionieren RAM,
Maus, Tastatur etc. normal, nur die Board-eigene RGB-Zone bleibt
unsteuerbar bis OpenRGB das fixt.

---

## 7. Laufwerke / fstab

`etc/fstab.txt` in diesem Repo ist nur eine Referenz – **UUIDs ändern
sich bei einer neuen Festplatte!** Nicht 1:1 übernehmen:

```bash
lsblk -f              # neue UUIDs der Windows-Partitionen rausfinden
sudo nano /etc/fstab   # Einträge nach diesem Muster ergänzen, mit den NEUEN UUIDs:
```

Muster (aus `etc/fstab.txt`):
```
UUID=<neue-uuid-windows1> /mnt/windows1 ntfs3 defaults,nofail,uid=1000,gid=1000,rw,exec,umask=000 0 0
UUID=<neue-uuid-windows2> /mnt/windows2 ntfs3 defaults,nofail,uid=1000,gid=1000,rw,exec,umask=000 0 0
```

Danach:
```bash
systemctl daemon-reload
sudo mount -a
```

Siehe auch `Notizen.txt` für weitere Laufwerks-Notizen (z.B. NTFS-Fix
mit `ntfsfix`, falls eine Windows-Partition mal "dirty" ist).

---

## 8. Logitech H-Shifter Treiber (nur falls Sim-Racing-Setup genutzt wird)

**Empfohlen: [hid-logishifter](https://github.com/AngryNui/hid-logishifter)**
– ein echter Kernel-HID-Treiber für genau dieses Gerät (Vendor/Product
`1209:f00d`, "InterBiometrics Logitech@ Shifter"), der die 7 Gänge
(1-6 + Rückwärtsgang) sauber als eigene Buttons exponiert. Deutlich
robuster als die eigene Python-Bastellösung weiter unten, da echter
Kernel-Treiber statt virtuellem evdev-Gerät im Userspace.

Installation (Arch/CachyOS, über AUR):
```bash
yay -S hid-logishifter-dkms
```
Danach:
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```
Shifter einmal aus- und wieder einstecken, dann mit `evtest` prüfen,
ob die Gänge als eigene Buttons ankommen.

**Falls der Quellcode lokal geklont wird** (z.B. zum manuellen Bauen
via `makepkg` oder zum Anpassen): direkt in diesen DotFiles-Ordner
klonen, damit es automatisch vom täglichen Backup mit erfasst wird:

```bash
git clone https://github.com/AngryNui/hid-logishifter.git ~/DotFiles/hid-logishifter
rm -rf ~/DotFiles/hid-logishifter/.git
```

**Wichtig:** Das `rm -rf .../.git` danach ist kein Versehen, sondern
nötig! Ohne das würde unser eigenes Repo den geklonten Ordner nur als
leere "Submodul-Referenz" (Commit-Zeiger) erfassen statt als echte
Kopie der Dateien – bei einem Restore stünde dann ein leerer Ordner
da, falls das Original-Repo auf GitHub inzwischen nicht mehr existiert.
Mit entferntem `.git` wird der komplette Dateiinhalt stattdessen ganz
normal von unserem eigenen Repo (und damit vom Auto-Backup-Timer)
mitversioniert.

**Alte eigene Lösung (Fallback, falls hid-logishifter aus irgendeinem
Grund nicht funktioniert):** Ausführliche Anleitung in
`Logitech-Shifter/README.md`, Kurzfassung:

```bash
sudo pacman -S python-evdev
sudo usermod -aG input $USER
# neu anmelden!
cd ~/DotFiles/Logitech-Shifter
python3 diagnose.py                       # auf Konflikte (z.B. input-remapper) prüfen
sudo cp 99-logitech-shifter.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo cp logitech-shifter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now logitech-shifter.service
```

`Logitech-Shifter-V2/` enthält eine neuere, in Arbeit befindliche
Version dieser Eigenbau-Lösung (v2/v3 Treiber-Skripte) – nur relevant,
falls hid-logishifter aus irgendeinem Grund nicht in Frage kommt.

---

## 9. Auto-Backup-Timer aktivieren

Damit sich dieser Ordner ab sofort wieder täglich von selbst sichert:

```bash
mkdir -p ~/.config/systemd/user
cp ~/DotFiles/systemd/dotfiles-backup.service ~/.config/systemd/user/
cp ~/DotFiles/systemd/dotfiles-backup.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now dotfiles-backup.timer
systemctl --user list-timers dotfiles-backup.timer   # zur Kontrolle
```

Manueller Test (sollte ohne Rückfrage durchlaufen):
```bash
~/DotFiles/backup.sh
cat ~/DotFiles/.backup.log
```

---

## Was NICHT in diesem Repo ist (separat sichern!)

- Der private SSH-Key (`~/.ssh/id_ed25519_github`) – niemals in Git
- GitHub Personal Access Tokens / Passwörter
- Steam-Bibliotheken, große Downloads, Spiele-Saves
- Windows-Partitionen selbst (nur die Mount-Konfiguration ist hier dokumentiert)

---

## Changelog / bekannte Themen

Siehe `Notizen.txt` für laufende Notizen (Laufwerks-Historie, NTFS-Fixes etc.).
