#!/bin/sh
# shellcheck shell=sh
# =============================================================================
#  Mullvad VPN installer for Void Linux (runit, no systemd)
#  ----------------------------------------------------------------------------
#  Downloads the official Mullvad .deb (amd64), verifies its GPG signature
#  against Mullvad's code-signing key, then installs the payload manually and
#  wires up a runit service for `mullvad-daemon`.
#
#  Why a .deb on Void?  Mullvad does not publish native Void packages, and the
#  .deb is just an ar/tar archive with no real Debian-specific logic. The only
#  Debian-specific bits in the package are two systemd unit files (which we
#  translate into a runit service) and a postinst that calls `systemctl`
#  (which we skip). Everything else is plain files under /opt and /usr.
#
#  Tested on: Void Linux x86_64, kernel 7.1.1_1, runit.
#
#  Usage:
#      doas sh mullvad-vpn-install.sh install [version]   # default 2026.3
#      doas sh mullvad-vpn-install.sh uninstall
#      sh  mullvad-vpn-install.sh status                  # no root needed
#
#  Requires (host): curl, gpg, ar, tar, modprobe, install, sv/svlogd (runit).
#  Requires (network): outbound HTTPS to github.com and a keyserver.
# =============================================================================
set -eu

# ---- Configuration ----------------------------------------------------------
PKGVERSION="${PKGVERSION:-2026.3}"
DEB_NAME="MullvadVPN-${PKGVERSION}_amd64.deb"
DEB_URL="https://github.com/mullvad/mullvadvpn-app/releases/download/${PKGVERSION}/${DEB_NAME}"
ASC_URL="https://github.com/mullvad/mullvadvpn-app/releases/download/${PKGVERSION}/${DEB_NAME}.asc"
# Mullvad (code signing) subkey fingerprint used to sign releases.
SIGN_KEY="CA83A46153BC58D69518ED49A26581F219C8314C"
SIGN_KEY_PRIMARY="A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF"
KEYSERVERS="keys.openpgp.org keyserver.ubuntu.com keys.gnupg.net"
WORKDIR="${WORKDIR:-/tmp/kilo/mullvad}"

# ---- Helpers ----------------------------------------------------------------
log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "This action must be run as root (try: doas sh $0 ...)."
}

need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
  done
}

# ---- Download + verify ------------------------------------------------------
fetch_and_verify() {
  need_cmd curl gpg ar tar
  mkdir -p "$WORKDIR"; cd "$WORKDIR"

  log "Downloading $DEB_NAME ..."
  curl -fsSL -o "$DEB_NAME" "$DEB_URL"
  curl -fsSL -o "$DEB_NAME.asc" "$ASC_URL"

  # Import the signing key if not already present.
  if ! gpg --list-keys "$SIGN_KEY" >/dev/null 2>&1; then
    log "Importing Mullvad code-signing key from keyserver ..."
    for ks in $KEYSERVERS; do
      gpg --keyserver "$ks" --recv-keys "$SIGN_KEY" >/dev/null 2>&1 && break
    done
    gpg --list-keys "$SIGN_KEY" >/dev/null 2>&1 \
      || die "Could not import signing key; cannot verify package."
  fi

  log "Verifying GPG signature ..."
  gpg --verify "$DEB_NAME.asc" "$DEB_NAME" >/tmp/mullvad_gpg.$$ 2>&1 || {
    cat /tmp/mullvad_gpg.$$ >&2; rm -f /tmp/mullvad_gpg.$$; die "Signature verification FAILED."; }
  grep -q "Good signature" /tmp/mullvad_gpg.$$ || die "No 'Good signature' line found."
  rm -f /tmp/mullvad_gpg.$$
  log "Signature OK."

  log "Extracting .deb ..."
  rm -rf extract; mkdir -p extract/data
  ( cd extract && ar x "../$DEB_NAME" )
  tar -xf extract/data.tar.* -C extract/data
  STAGE="$WORKDIR/extract/data"
}

# ---- Install ----------------------------------------------------------------
do_install() {
  need_root
  [ -n "${STAGE:-}" ] || fetch_and_verify   # sets $STAGE to the extracted data dir

  log "[1/8] Stopping any existing mullvad-daemon ..."
  command -v sv >/dev/null 2>&1 && sv down mullvad-daemon 2>/dev/null || true
  pkill -x mullvad-daemon 2>/dev/null || true
  sleep 1

  log "[2/8] Loading WireGuard kernel module ..."
  modprobe wireguard 2>/dev/null || warn "modprobe wireguard failed (may already be built-in)."

  log "[3/8] Installing /opt/Mullvad VPN ..."
  rm -rf "/opt/Mullvad VPN"
  cp -a "$STAGE/opt/Mullvad VPN" /opt/

  log "[4/8] Installing CLI/daemon binaries ..."
  install -m0755 "$STAGE/usr/bin/mullvad"         /usr/bin/mullvad
  install -m0755 "$STAGE/usr/bin/mullvad-daemon"  /usr/bin/mullvad-daemon
  install -m4755 "$STAGE/usr/bin/mullvad-exclude" /usr/bin/mullvad-exclude
  ln -sf "/opt/Mullvad VPN/resources/mullvad-problem-report" /usr/bin/mullvad-problem-report

  log "[5/8] Installing desktop entry, icons, completions ..."
  install -Dm0644 "$STAGE/usr/share/applications/mullvad-vpn.desktop" \
                    /usr/share/applications/mullvad-vpn.desktop
  cp -a "$STAGE/usr/share/icons/hicolor" /usr/share/icons/
  install -Dm0644 "$STAGE/usr/share/bash-completion/completions/mullvad" \
                    /usr/share/bash-completion/completions/mullvad
  install -Dm0644 "$STAGE/usr/share/fish/vendor_completions.d/mullvad.fish" \
                    /usr/share/fish/vendor_completions.d/mullvad.fish

  log "[6/8] Creating runit service /etc/sv/mullvad-daemon ..."
  mkdir -p /etc/sv/mullvad-daemon/log
  cat > /etc/sv/mullvad-daemon/run <<'EOF'
#!/bin/sh
MULLVAD_RESOURCE_DIR="/opt/Mullvad VPN/resources/"
export MULLVAD_RESOURCE_DIR
exec 2>&1
exec /usr/bin/mullvad-daemon -vv --disable-stdout-timestamps
EOF
  chmod 0755 /etc/sv/mullvad-daemon/run
  cat > /etc/sv/mullvad-daemon/log/run <<'EOF'
#!/bin/sh
mkdir -p /var/log/mullvad-daemon
exec svlogd -tt /var/log/mullvad-daemon
EOF
  chmod 0755 /etc/sv/mullvad-daemon/log/run
  mkdir -p /var/log/mullvad-vpn /var/cache/mullvad-vpn

  log "[7/8] Enabling + starting service via /var/service ..."
  ln -sf /etc/sv/mullvad-daemon /var/service/mullvad-daemon
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sv status mullvad-daemon >/dev/null 2>&1 && break || sleep 1
  done

  log "[8/8] Service status:"
  sv status mullvad-daemon 2>&1 || true
  log "Done. Log in with: mullvad account login <account-number> && mullvad connect"
}

# ---- Uninstall --------------------------------------------------------------
do_uninstall() {
  need_root
  log "Stopping + disabling mullvad-daemon ..."
  command -v sv >/dev/null 2>&1 && sv down mullvad-daemon 2>/dev/null || true
  rm -f /var/service/mullvad-daemon
  sleep 1

  log "Removing service directory ..."
  rm -rf /etc/sv/mullvad-daemon

  log "Removing files ..."
  rm -rf "/opt/Mullvad VPN"
  rm -f /usr/bin/mullvad /usr/bin/mullvad-daemon /usr/bin/mullvad-exclude \
        /usr/bin/mullvad-problem-report
  rm -f /usr/share/applications/mullvad-vpn.desktop
  rm -rf /usr/share/icons/hicolor/apps/mullvad-vpn.png
  rm -f /usr/share/bash-completion/completions/mullvad
  rm -f /usr/share/fish/vendor_completions.d/mullvad.fish
  # NOTE: /var/log/mullvad-{daemon,vpn}, /var/cache/mullvad-vpn, /etc/mullvad-vpn
  #       are kept (may contain account settings/logs). Remove manually if desired.
  log "Done."
}

# ---- Status (no root) -------------------------------------------------------
do_status() {
  log "runit service:"
  sv status mullvad-daemon 2>&1 || warn "service not running/installed"
  echo
  log "CLI:"
  command -v mullvad >/dev/null 2>&1 && mullvad --version 2>&1 | head -1 || warn "mullvad CLI not installed"
  echo
  log "Daemon:"
  command -v mullvad >/dev/null 2>&1 && mullvad status 2>&1 || true
}

# ---- Usage ------------------------------------------------------------------
show_usage() {
  cat <<USAGE
Mullvad VPN installer for Void Linux (runit)

Usage:
  sh $0 install [version]   Download, verify and install (default version: $PKGVERSION)
  sh $0 uninstall            Remove binaries, service and /opt payload
  sh $0 status               Show service + daemon status (no root needed)

Examples:
  doas sh $0 install          # install default version
  doas sh $0 install 2026.3   # install a specific version
  sh $0 status                # check current state

Run as root for install/uninstall (e.g. 'doas sh $0 install').
USAGE
}

# ---- Main -------------------------------------------------------------------
case "${1:-}" in
  install)   [ $# -ge 2 ] && PKGVERSION="$2"; do_install ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  ""|-h|--help|help) show_usage ;;
  *) show_usage; die "Unknown action '$1'." ;;
esac
