#!/bin/sh
# Anoneurx Connect — hosted one-line bootstrap.
#
#   curl -fsSL https://blacklink.anoneurx.com/bash | sudo bash
#
# This script is served statically over HTTPS. It is intentionally thin:
# detect platform, fetch the release bundle + checksum + Ed25519 signature,
# verify, then install idempotently (binary + systemd unit). The operator
# credential is created interactively after install.
#
# Environment overrides:
#   ANON_URL     base URL for artifacts        (default https://blacklink.anoneurx.com)
#   ANON_VERSION release tag to install        (default latest)
#   ANON_NONINTERACTIVE  skip interactive setup (default 0)

set -eu

ANON_URL="${ANON_URL:-https://blacklink.anoneurx.com}"
ANON_VERSION="${ANON_VERSION:-latest}"
ANON_NONINTERACTIVE="${ANON_NONINTERACTIVE:-0}"
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="anoneurx-connect"
CONFIG_DIR="/etc/anoneurx/connect"
SYSTEMD_DIR="/etc/systemd/system"

log() { printf '[*] %s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root, e.g.: curl -fsSL $ANON_URL/bash | sudo bash"

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
    Linux) os="linux" ;;
    *) die "unsupported OS: $os" ;;
esac
case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "unsupported arch: $arch" ;;
esac

[ -d "$SYSTEMD_DIR" ] || die "systemd not found (this script assumes a systemd host)"

release="${ANON_VERSION}"
if [ "$release" = "latest" ]; then
    log "Resolving latest release from $ANON_URL/LATEST"
    release="$(curl -fsSL "$ANON_URL/LATEST" | tr -d '[:space:]')"
    [ -n "$release" ] || die "could not resolve latest release version"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

url() { printf '%s/releases/%s/anoneurx-connect-%s-%s.tar.gz%s' "$ANON_URL" "$release" "$os" "$arch" "$1"; }

log "Fetching $release ($os/$arch)"
curl -fsSL -o "$tmpdir/bundle.tar.gz" "$(url '')"
curl -fsSL -o "$tmpdir/bundle.tar.gz.sha256" "$(url '.sha256')"
if curl -fsSL -o "$tmpdir/bundle.tar.gz.sig" "$(url '.sig')" \
    && curl -fsSL -o "$tmpdir/pubkey.pem" "$ANON_URL/pubkey.pem" 2>/dev/null; then
    log "Verifying Ed25519 signature"
    openssl pkeyutl -verify -pubin -inkey "$tmpdir/pubkey.pem" \
        -keyform PEM -in "$tmpdir/bundle.tar.gz" \
        -sigfile "$tmpdir/bundle.tar.gz.sig" >/dev/null 2>&1 \
        || die "signature verification failed — refusing to install"
else
    log "No Ed25519 signature available; relying on SHA-256 + TLS"
fi

log "Verifying SHA-256 checksum"
expected="$(cat "$tmpdir/bundle.tar.gz.sha256" | sed -E 's/\s.*//' | tr -d '[:space:]')"
actual="$(sha256sum "$tmpdir/bundle.tar.gz" | sed -E 's/\s.*//' | tr -d '[:space:]')"
[ "$expected" = "$actual" ] || die "checksum mismatch (expected $expected, got $actual)"

log "Extracting release"
tar -xzf "$tmpdir/bundle.tar.gz" -C "$tmpdir"

log "Installing binary to $INSTALL_DIR"
install -D -m 0755 -o root -g root "$tmpdir/anoneurx-connect" "$INSTALL_DIR/anoneurx-connect"
ln -sf anoneurx-connect "$INSTALL_DIR/blacklink"

log "Installing systemd unit"
install -D -m 0644 -o root -g root "$tmpdir/anoneurx-connect.service" "$SYSTEMD_DIR/$SERVICE_NAME.service"

log "Creating system user and runtime directories"
if ! id -u anoneurx-connect >/dev/null 2>&1; then
    useradd --system --home /var/lib/anoneurx/connect \
        --shell /usr/sbin/nologin anoneurx-connect
fi
install -d -m 0750 -o anoneurx-connect -g anoneurx-connect /var/lib/anoneurx/connect 2>/dev/null \
    || install -d -m 0750 /var/lib/anoneurx/connect
install -d -m 0600 -o anoneurx-connect -g anoneurx-connect /etc/anoneurx/connect 2>/dev/null \
    || install -d -m 0600 "$CONFIG_DIR"

log "Starting $SERVICE_NAME (generates TLS identity)"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || die "failed to start $SERVICE_NAME"

# Wait briefly for agent to generate identity keys
sleep 2

# Interactive operator setup
if [ "$ANON_NONINTERACTIVE" = "0" ]; then
    log "Setting up operator credential (username + password)"
    if ! "$INSTALL_DIR/blacklink" setup; then
        die "operator setup failed"
    fi
fi

# Get server public IP for the login URL
SERVER_IP="$(curl -fsSL --max-time 5 ifconfig.me 2>/dev/null || curl -fsSL --max-time 5 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')"
LOGIN_URL="https://anoneurx.com/auth?mode=blacklink"

# Generate QR code if qrencode is available
QR_CODE=""
if command -v qrencode >/dev/null 2>&1; then
    QR_CODE="$(qrencode -t UTF8 "$LOGIN_URL" 2>/dev/null || true)"
fi

cat <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║                    Anoneurx Connect v$release installed!              ║
╠══════════════════════════════════════════════════════════════════════╣
║  The daemon runs as 'anoneurx-connect' on port 8443.                ║
║  Your operator credential is configured (argon2id, stored 0600).    ║
╠══════════════════════════════════════════════════════════════════════╣
║  🔗  Dashboard: $LOGIN_URL                                         ║
EOF

if [ -n "$SERVER_IP" ]; then
    printf '║  🌐  Your server IP: %s\n' "$SERVER_IP"
    printf '║     (enter this in the dashboard "Server IP" field)\n'
fi

cat <<'EOF'
╠═══════════════════════════════════════════════════════════════════════╣
║  📱  Scan to open dashboard:                                         ║
EOF

if [ -n "$QR_CODE" ]; then
    echo "$QR_CODE" | while IFS= read -r line; do
        printf '║  %s\n' "$line"
    done
else
    printf '║  (install qrencode for QR code, or visit the URL above)\n'
fi

cat <<EOF
╠═══════════════════════════════════════════════════════════════════════╣
║  Login with the username + password you just set.                    ║
╚══════════════════════════════════════════════════════════════════════╝
EOF