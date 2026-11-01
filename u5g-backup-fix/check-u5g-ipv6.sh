#!/bin/sh
# check-u5g-ipv6.sh — read-only diagnosis for the U5G Backup IPv6 failover fix.
#
# Deploy to /etc/persistent/check-u5g-ipv6.sh on the U5GBackup.
# Run it manually before/after patch-u5g-ipv6.sh. It changes nothing.
#
# Exit 0 when every failover IPv6 check passes, 1 otherwise.
# A failed CLAT probe is a warning only: the U5G can report
# clat_enabled=false while 192.0.0.2/27 is still translating IPv4.
#
# MIT License — https://github.com/chriselsen/unifi-hacks

FAIL=0
MBB_MODE=$(awk -F= '/^mbb\.mode=/{print $2; exit}' /tmp/system.cfg 2>/dev/null)
PREFIX=$(ip -6 addr show rmnet_data0 2>/dev/null \
    | awk '/scope global/{
        gsub(/\/128/, "")
        split($2, g, ":")
        printf "%s:%s:%s:%s::\n", g[1], g[2], g[3], g[4]
        exit
    }')

say() { printf '%-34s %s\n' "$1" "$2"; }
fail() { say "$1" "FAIL: $2"; FAIL=1; }
ok() { say "$1" "ok: $2"; }

say "mode" "${MBB_MODE:-unknown}"
[ -n "$MBB_MODE" ] && [ "$MBB_MODE" != "failover" ] && \
    say "warning" "patch only applies in failover mode"

if [ -z "$PREFIX" ]; then
    fail "cellular prefix" "rmnet_data0 has no global /128"
else
    ok "cellular prefix" "$PREFIX/64"
fi

if ip link show gre1 >/dev/null 2>&1; then
    if ip link show gre1 | grep -q MULTICAST; then
        ok "gre1 multicast" "IFF_MULTICAST set"
    else
        fail "gre1 multicast" "IFF_MULTICAST missing (odhcpd will not advertise)"
    fi
else
    fail "gre1" "interface missing"
fi

if [ -n "$PREFIX" ]; then
    if ip -6 addr show gre1 2>/dev/null | grep -q "${PREFIX}.*/64"; then
        ok "gre1 /64" "$PREFIX/64 present"
    else
        fail "gre1 /64" "no ${PREFIX}/64 address"
    fi

    if ip -6 route show table 3 2>/dev/null | grep -q "blackhole ${PREFIX}"; then
        fail "table 3 blackhole" "blackhole ${PREFIX} still present"
    else
        ok "table 3 blackhole" "absent"
    fi

    if ip -6 route show table 3 2>/dev/null | grep -q "${PREFIX}.*dev gre1"; then
        ok "table 3 return route" "${PREFIX}/64 dev gre1"
    else
        fail "table 3 return route" "no ${PREFIX}/64 dev gre1"
    fi
fi

if pgrep odhcpd >/dev/null; then
    ok "odhcpd" "running"
else
    fail "odhcpd" "not running"
fi

if command -v uci >/dev/null 2>&1; then
    RA=$(uci -q get dhcp.ipv6.ra)
    if [ "$RA" = "server" ]; then
        ok "odhcpd RA" "server"
    else
        fail "odhcpd RA" "is '${RA:-unset}', 1.5.5 needs 'server'"
    fi
fi

if ip -4 addr show rmnet_data0 2>/dev/null | grep -q '192\.0\.0\.2'; then
    if ping -4 -I 192.0.0.2 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        ok "CLAT IPv4 probe" "192.0.0.2 reaches 1.1.1.1"
    else
        say "CLAT IPv4 probe" "warning: 192.0.0.2 failed (not an IPv6 failure)"
    fi
fi

exit "$FAIL"
