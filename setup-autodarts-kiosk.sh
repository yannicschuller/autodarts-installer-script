#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Debian Trixie Autodarts + Chromium Kiosk Setup
#
# Macht:
# - System aktualisieren
# - Autodarts installieren
# - Chromium Kiosk für https://play.autodarts.io einrichten
# - Netzwerkverbindung vor Kiosk-Start abwarten
# - Autologin auf tty1 aktivieren
# - Robusten systemd-Service für Kiosk erstellen
#
# Ausführen:
#   chmod +x setup-autodarts-kiosk.sh
#   sudo ./setup-autodarts-kiosk.sh
# ============================================================

KIOSK_URL="${KIOSK_URL:-https://play.autodarts.io}"
TTY="${TTY:-tty1}"
KIOSK_SERVICE="autodarts-kiosk.service"

# ------------------------------------------------------------
# Root-Prüfung
# ------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte als root ausführen, z. B.: sudo $0"
  exit 1
fi

# ------------------------------------------------------------
# Aktuell eingeloggten Benutzer erkennen
# ------------------------------------------------------------
detect_user() {
  if [[ -n "${KIOSK_USER:-}" ]]; then
    echo "$KIOSK_USER"
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi

  local logname_user
  logname_user="$(logname 2>/dev/null || true)"
  if [[ -n "$logname_user" && "$logname_user" != "root" ]]; then
    echo "$logname_user"
    return
  fi

  local active_user
  active_user="$(who | awk '$2 ~ /^tty|^pts/ {print $1; exit}' || true)"
  if [[ -n "$active_user" && "$active_user" != "root" ]]; then
    echo "$active_user"
    return
  fi

  echo "autodarts"
}

KIOSK_USER="$(detect_user)"

echo "============================================================"
echo "Autodarts Kiosk Setup"
echo "============================================================"
echo "Kiosk-Benutzer: $KIOSK_USER"
echo "Kiosk-URL:      $KIOSK_URL"
echo "TTY:            $TTY"
echo "============================================================"
echo

# ------------------------------------------------------------
# Benutzer prüfen oder erstellen
# ------------------------------------------------------------
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  echo "==> Benutzer '$KIOSK_USER' existiert nicht und wird angelegt..."
  useradd -m -s /bin/bash "$KIOSK_USER"
fi

KIOSK_HOME="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"

if [[ -z "$KIOSK_HOME" || ! -d "$KIOSK_HOME" ]]; then
  echo "Fehler: Home-Verzeichnis für '$KIOSK_USER' konnte nicht gefunden werden."
  exit 1
fi

# ------------------------------------------------------------
# System aktualisieren
# ------------------------------------------------------------
echo "==> System wird aktualisiert..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get -y full-upgrade
apt-get -y autoremove
apt-get -y autoclean

# ------------------------------------------------------------
# Pakete installieren
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Netzwerkdienste aktivieren
# ------------------------------------------------------------
echo "==> Netzwerkdienste werden aktiviert..."

systemctl enable --now NetworkManager || true
systemctl enable NetworkManager-wait-online.service || true
systemctl enable systemd-networkd-wait-online.service || true

# ------------------------------------------------------------
# Benutzergruppen setzen
# ------------------------------------------------------------
echo "==> Benutzergruppen für Kamera/Grafik/Eingabe werden gesetzt..."

usermod -aG video,render,plugdev,input "$KIOSK_USER" || true

# ------------------------------------------------------------
# Autodarts installieren
# ------------------------------------------------------------
echo "==> Autodarts wird installiert..."

if command -v curl >/dev/null 2>&1; then
  bash <(curl -fsSL https://get.autodarts.io)
else
  echo "Fehler: curl ist nicht installiert."
  exit 1
fi

# ------------------------------------------------------------
# Kiosk-Startskript erstellen
# ------------------------------------------------------------
echo "==> Kiosk-Startskript wird erstellt..."

cat > /usr/local/bin/autodarts-kiosk <<EOF
#!/usr/bin/env bash
set -euo pipefail

URL="$KIOSK_URL"

export DISPLAY="\${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"

echo "Autodarts Kiosk startet..."
echo "Warte auf Netzwerkverbindung..."

until ip route | grep -q default; do
  echo "Noch keine Default-Route vorhanden..."
  sleep 2
done

until getent hosts play.autodarts.io >/dev/null 2>&1; do
  echo "DNS noch nicht verfügbar..."
  sleep 2
done

until curl -Is --max-time 5 "\$URL" >/dev/null 2>&1; do
  echo "Kiosk-URL noch nicht erreichbar: \$URL"
  sleep 2
done

echo "Netzwerk verfügbar. Starte Browser..."

xset s off || true
xset -dpms || true
xset s noblank || true

unclutter -idle 0.5 -root >/dev/null 2>&1 &

openbox >/dev/null 2>&1 &
sleep 2

CHROMIUM_BIN=""

for bin in chromium chromium-browser google-chrome-stable; do
  if command -v "\$bin" >/dev/null 2>&1; then
    CHROMIUM_BIN="\$bin"
    break
  fi
done

if [[ -z "\$CHROMIUM_BIN" ]]; then
  echo "Fehler: Kein Chromium/Chrome gefunden."
  exit 1
fi

exec "\$CHROMIUM_BIN" \\
  --kiosk "\$URL" \\
  --no-first-run \\
  --disable-infobars \\
  --disable-session-crashed-bubble \\
  --disable-features=TranslateUI \\
  --overscroll-history-navigation=0 \\
  --start-maximized \\
  --user-data-dir="$KIOSK_HOME/.config/chromium-kiosk"
EOF

chmod +x /usr/local/bin/autodarts-kiosk

# ------------------------------------------------------------
# Chromium-Konfigurationsordner vorbereiten
# ------------------------------------------------------------
echo "==> Chromium-Konfigurationsordner wird vorbereitet..."

mkdir -p "$KIOSK_HOME/.config/chromium-kiosk"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"

# ------------------------------------------------------------
# Alte .bash_profile / .profile Kiosk-Autostarts deaktivieren
# ------------------------------------------------------------
echo "==> Alte .bash_profile/.profile Kiosk-Autostarts werden deaktiviert, falls vorhanden..."

timestamp="$(date +%Y%m%d-%H%M%S)"

for profile_file in "$KIOSK_HOME/.bash_profile" "$KIOSK_HOME/.profile"; do
  if [[ -f "$profile_file" ]] && grep -q "startx" "$profile_file"; then
    mv "$profile_file" "${profile_file}.bak-${timestamp}"
    echo "Gesichert: $profile_file -> ${profile_file}.bak-${timestamp}"
  fi
done

# ------------------------------------------------------------
# Autologin auf tty1 aktivieren
# ------------------------------------------------------------
echo "==> Autologin auf $TTY wird aktiviert..."

mkdir -p "/etc/systemd/system/getty@$TTY.service.d"

cat > "/etc/systemd/system/getty@$TTY.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

# ------------------------------------------------------------
# Robusten systemd-Service für Kiosk erstellen
# ------------------------------------------------------------
echo "==> systemd-Service für Kiosk wird erstellt..."

cat > "/etc/systemd/system/$KIOSK_SERVICE" <<EOF
[Unit]
Description=Autodarts Chromium Kiosk
After=network-online.target autodarts.service getty@$TTY.service
Wants=network-online.target
Conflicts=display-manager.service

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
WorkingDirectory=$KIOSK_HOME

Environment=DISPLAY=:0
Environment=XAUTHORITY=$KIOSK_HOME/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/%U

TTYPath=/dev/$TTY
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

StandardInput=tty
StandardOutput=journal
StandardError=journal

ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/startx /usr/local/bin/autodarts-kiosk -- :0 -nocursor vt1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------
# Bildschirm-Blanking systemweit deaktivieren
# ------------------------------------------------------------
echo "==> Bildschirm-Blanking wird deaktiviert..."

mkdir -p /etc/X11/xorg.conf.d

cat > /etc/X11/xorg.conf.d/10-monitor.conf <<'EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF

# ------------------------------------------------------------
# systemd neu laden und Services aktivieren
# ------------------------------------------------------------
echo "==> systemd wird aktualisiert..."

systemctl daemon-reload

systemctl enable "getty@$TTY.service"
systemctl enable "$KIOSK_SERVICE"

# Falls ein alter Kiosk-Service läuft, sauber neu starten
systemctl restart "getty@$TTY.service" || true

echo "==> Kiosk-Service wird gestartet..."
systemctl restart "$KIOSK_SERVICE"

echo
echo "============================================================"
echo "Fertig."
echo "============================================================"
echo "Kiosk-Benutzer: $KIOSK_USER"
echo "Home:           $KIOSK_HOME"
echo "Kiosk-URL:      $KIOSK_URL"
echo "Service:        $KIOSK_SERVICE"
echo
echo "Status prüfen:"
echo "  systemctl status $KIOSK_SERVICE"
echo
echo "Logs prüfen:"
echo "  journalctl -u $KIOSK_SERVICE -b --no-pager"
echo
echo "Empfohlen: Jetzt neu starten:"
echo "  sudo reboot"
echo "============================================================"
