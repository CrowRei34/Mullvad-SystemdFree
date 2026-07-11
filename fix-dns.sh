#!/bin/sh
# Fix DNS conflict between Mullvad VPN and openresolv on Void Linux.
#
# Problem: /etc/resolvconf.conf forces external DNS servers (1.1.1.1, etc.)
# into resolv.conf ALWAYS. When Mullvad connects, its firewall blocks those
# external servers, but they're listed BEFORE Mullvad's DNS (10.64.0.1), so
# glibc tries them first, times out, and DNS resolution fails → "no internet".
#
# Fix: remove the forced external servers and make wg0-mullvad an "exclusive"
# interface in openresolv, so when the VPN is up, ONLY 10.64.0.1 is used.
# When the VPN is down, the ethernet's DNS (9.9.9.9) is used normally.
set -eu

CONF=/etc/resolvconf.conf

echo "[*] Backup: $CONF -> $CONF.bak"
cp -n "$CONF" "$CONF.bak" 2>/dev/null || cp "$CONF" "$CONF.bak"

echo "[*] Writing new $CONF"
cat > "$CONF" <<'EOF'
# Configuration for resolvconf(8)
# See resolvconf.conf(5) for details
resolv_conf=/etc/resolv.conf

# No forced external DNS — let each interface provide its own.
# (Previously: name_servers="1.1.1.1 1.0.0.1 8.8.8.8" — these leaked into
#  resolv.conf while Mullvad was connected, got blocked by its firewall,
#  and broke DNS resolution.)
#name_servers="1.1.1.1 1.0.0.1 8.8.8.8"

# When wg0-mullvad is up, use ONLY its DNS (10.64.0.1).
exclusive_interfaces="wg0-mullvad"
EOF

echo "[*] Done. Testing both states..."
echo
echo "===== DESCONECTADO ====="
mullvad disconnect 2>/dev/null; sleep 2
echo "resolv.conf:"; cat /etc/resolv.conf
echo "DNS lookup: $(getent hosts mullvad.net 2>&1 || echo FAILED)"
echo "ping: $(ping -c1 -W2 1.1.1.1 2>&1 | tail -1)"
echo
echo "===== CONECTADO ====="
mullvad connect 2>&1; sleep 5
echo "status: $(mullvad status 2>&1 | head -1)"
echo "resolv.conf:"; cat /etc/resolv.conf
echo "DNS lookup: $(getent hosts mullvad.net 2>&1 || echo FAILED)"
echo "curl https://mullvad.net: $(curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' --max-time 10 https://mullvad.net 2>&1)"
echo "IP visible: $(curl -s --max-time 8 https://am.i.mullvad.net/json 2>&1 | head -c 200)"
echo
echo "===== RESTAURAR (desconectar) ====="
mullvad disconnect 2>&1; sleep 2
echo "DNS lookup: $(getent hosts mullvad.net 2>&1 || echo FAILED)"
echo "ping: $(ping -c1 -W2 1.1.1.1 2>&1 | tail -1)"
echo
echo "[*] Para revertir: doas cp $CONF.bak $CONF"
