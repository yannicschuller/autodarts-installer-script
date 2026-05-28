#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Debian Trixie Autodarts + Kiosk Setup
# - System aktualisieren
# - Autodarts installieren
# - Chromium Kiosk für https://play.autodarts.io einrichten
# - Auf Netzwerk warten
# - Autologin auf tty1 aktivieren
# ============================================================

KIOSK_USER="${KIOSK_USER:-autodarts}"
KIOSK_URL="${KIOSK_URL:-https://play.autodarts.io}"
TTY="tty1"

if [[ "$EUID" -ne 0 ]]; then
  echo "Bitte als root ausführen, z. B.: sudo $0"
  exit 1
fi

echo "==> System wird aktualisiert..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
apt-get -y autoremove
apt-get -y autoclean

echo "==> Benötigte Pakete werden installiert..."
apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  xserver-xorg \
  xinit \
  openbox \
  chromium \
  unclutter \
  x11-xserver-utils \
  dbus-x11 \
  systemd-timesyncd \
  network-manager

echo "==> NetworkManager wird aktiviert..."
systemctl enable --now NetworkManager || true
systemctl enable systemd-networkd-wait-online.service || true
systemctl enable NetworkManager-wait-online.service || true

echo "==> Benutzer '$KIOSK_USER' wird angelegt, falls nicht vorhanden..."
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$KIOSK_USER"
fi

echo "==> Benutzergruppen für Kameras/Grafik werden gesetzt..."
usermod -aG video,render,plugdev,input "$KIOSK_USER" || true

echo "==> Autodarts wird installiert..."
# Offizieller Autodarts-Installer
bash <(curl -sL https://get.autodarts.io)

echo "==> Kiosk-Startskript wird erstellt..."
cat > "/usr/local/bin/autodarts-kiosk" <<EOF
#!/usr/bin/env bash
set -euo pipefail

URL="$KIOSK_URL"

echo "Warte auf Netzwerkverbindung..."

until ip route | grep -q default; do
  sleep 2
done

until getent hosts play.autodarts.io >/dev/null 2>&1; do
  sleep 2
done

until curl -Is --max-time 5 "\$URL" >/dev/null 2>&1; do
  sleep 2
done

echo "Netzwerk verfügbar. Starte Kiosk..."

xset s off || true
xset -dpms || true
xset s noblank || true
unclutter -idle 0.5 -root &

exec openbox-session &
sleep 2

CHROMIUM_BIN=""
for bin in chromium chromium-browser google-chrome-stable; do
  if command -v "\$bin" >/dev/null 2>&1; then
    CHROMIUM_BIN="\$bin"
    break
  fi
done

if [[ -z "\$CHROMIUM_BIN" ]]; then
  echo "Kein Chromium/Chrome gefunden."
  exit 1
fi

exec "\$CHROMIUM_BIN" \\
  --kiosk "\$URL" \\
  --no-first-run \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-features=TranslateUI \\
  --overscroll-history-navigation=0 \\
  --start-maximized
EOF

chmod +x "/usr/local/bin/autodarts-kiosk"

echo "==> .xinitrc für Benutzer '$KIOSK_USER' wird erstellt..."
cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/autodarts-kiosk
EOF

chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.xinitrc"
chmod +x "/home/$KIOSK_USER/.xinitrc"

echo "==> Autostart von X/Kiosk nach Autologin wird eingerichtet..."
cat > "/home/$KIOSK_USER/.bash_profile" <<EOF
if [[ -z "\$DISPLAY" ]] && [[ "\$(tty)" == "/dev/$TTY" ]]; then
  startx -- -nocursor
fi
EOF

chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.bash_profile"

echo "==> Autologin auf $TTY wird aktiviert..."
mkdir -p "/etc/systemd/system/getty@$TTY.service.d"

cat > "/etc/systemd/system/getty@$TTY.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

systemctl daemon-reload
systemctl enable "getty@$TTY.service"

echo "==> Kiosk-spezifische Chromium-Ordnerrechte werden vorbereitet..."
mkdir -p "/home/$KIOSK_USER/.config/chromium"
chown -R "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.config"

echo "==> Optional: Bildschirm-Blanking systemweit reduzieren..."
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-monitor.conf <<'EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF

echo
echo "============================================================"
echo "Fertig."
echo
echo "Kiosk-Benutzer: $KIOSK_USER"
echo "Kiosk-URL:      $KIOSK_URL"
echo
echo "Jetzt neu starten mit:"
echo "  sudo reboot"
echo
echo "Nach dem Reboot sollte sich '$KIOSK_USER' automatisch anmelden"
echo "und Chromium im Kiosk-Modus mit $KIOSK_URL starten."
echo "============================================================"