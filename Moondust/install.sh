#!/usr/bin/env bash
# Moondust one-command setup. On the VPS run:
#   curl -fsSL https://thegamingmahi.github.io/Moondust/install.sh | sudo bash
# Safe to run again later to update the server.
set -euo pipefail

BASE="https://thegamingmahi.github.io/Moondust"
HOST="moondust.arclightsmp.com"
PORT="8787"
DIR="/opt/moondust"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo."; exit 1; }
command -v systemctl >/dev/null || { echo "This needs systemd."; exit 1; }
command -v curl >/dev/null || { echo "This needs curl (sudo apt install curl)."; exit 1; }
( : </dev/tty ) 2>/dev/null || { echo "Run this in an interactive terminal, it asks for your GitHub settings."; exit 1; }

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported CPU: $(uname -m)"; exit 1 ;;
esac
NAME="moondust-server-linux-$ARCH"

if ! systemctl is-active --quiet moondust 2>/dev/null; then
  if command -v ss >/dev/null && ss -ltn | grep -q ":$PORT "; then
    echo "Port $PORT is already used by something else. Change PORT at the top of the script."
    exit 1
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if [ -f "$HERE/$NAME" ]; then
  cp "$HERE/$NAME" "$TMP/$NAME"
else
  echo "Downloading the server..."
  curl -fsSL "$BASE/bin/$NAME" -o "$TMP/$NAME" ||
    { echo "Download failed. Is the Moondust folder (with bin/) pushed to GitHub Pages?"; exit 1; }
  WANT="$(curl -fsSL "$BASE/bin/SHA256SUMS" | awk -v n="$NAME" '$2==n {print $1}')"
  GOT="$(sha256sum "$TMP/$NAME" | awk '{print $1}')"
  [ -n "$WANT" ] && [ "$WANT" = "$GOT" ] ||
    { echo "Checksum did not match. Wait a minute (Pages may still be updating) and run it again."; exit 1; }
fi

NEW=1
if [ -f /etc/moondust.env ]; then
  read -rp "/etc/moondust.env already exists. Keep your settings? [Y/n] " A </dev/tty
  case "${A:-y}" in [nN]*) NEW=1 ;; *) NEW=0 ;; esac
fi

if [ "$NEW" = 1 ]; then
  read -rp  "GitHub OAuth Client ID: " CID </dev/tty
  read -rsp "GitHub OAuth Client secret (hidden): " CSEC </dev/tty; echo
  read -rsp "GitHub token for the registry repo (hidden): " TOK </dev/tty; echo
  { [ -n "$CID" ] && [ -n "$CSEC" ] && [ -n "$TOK" ]; } || { echo "All three are required."; exit 1; }
  SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  install -m 600 /dev/null /etc/moondust.env
  cat > /etc/moondust.env <<EOF
GITHUB_CLIENT_ID=$CID
GITHUB_CLIENT_SECRET=$CSEC
REGISTRY_TOKEN=$TOK
SESSION_SECRET=$SECRET
BASE_URL=https://$HOST
ADDR=127.0.0.1:$PORT
EOF
fi

mkdir -p "$DIR"
install -m 755 "$TMP/$NAME" "$DIR/moondust-server.new"
mv -f "$DIR/moondust-server.new" "$DIR/moondust-server"

cat > /etc/systemd/system/moondust.service <<'EOF'
[Unit]
Description=Moondust registry server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/opt/moondust/moondust-server
EnvironmentFile=/etc/moondust.env
Restart=always
RestartSec=3
MemoryMax=64M
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable moondust >/dev/null 2>&1
systemctl restart moondust
sleep 2
if ! systemctl is-active --quiet moondust; then
  echo "The server did not start. Last log lines:"
  journalctl -u moondust -n 15 --no-pager
  exit 1
fi
echo "Server is running."

CADDYFILE=/etc/caddy/Caddyfile
BLOCK="$HOST {
	reverse_proxy 127.0.0.1:$PORT
}"
if [ -f "$CADDYFILE" ] && command -v caddy >/dev/null; then
  if grep -qF "$HOST" "$CADDYFILE"; then
    echo "Caddy already has $HOST."
  else
    cp "$CADDYFILE" "$CADDYFILE.bak-moondust"
    printf '\n%s\n' "$BLOCK" >> "$CADDYFILE"
    if caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
      systemctl reload caddy
      echo "Added $HOST to Caddy (backup: $CADDYFILE.bak-moondust)."
    else
      cp "$CADDYFILE.bak-moondust" "$CADDYFILE"
      echo "Could not edit Caddy safely. Add this to your Caddyfile yourself, then reload Caddy:"
      echo "$BLOCK"
    fi
  fi
else
  echo "Add this to your Caddyfile, then reload Caddy:"
  echo "$BLOCK"
fi

getent hosts "$HOST" >/dev/null || echo "WARNING: $HOST doesn't resolve yet. Add an A record for 'moondust' pointing at this server."
echo
echo "Done. Test it by opening: https://$HOST/auth/login"
