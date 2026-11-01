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
if command -v uiwwand-ctl >/dev/null 2>&1; then
    PREFIX=$(printf '%s\n' '{"method":"get-ipv6-settings"}' | uiwwand-ctl 2>/dev/null \
        | tr -d '\n' \
        | sed -n 's/.*"ipv6-ui-prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    PREFIX=${PREFIX%/64}
else
    PREFIX=""
fi

say() { printf '%-34s %s\n' "$1" "$2"; }
fail() { say "$1" "FAIL: $2"; FAIL=1; }
ok() { say "$1" "ok: $2"; }

if [ "$MBB_MODE" = "failover" ]; then
    ok "mode" "failover"
else
    fail "mode" "${MBB_MODE:-missing/unreadable}, patch requires failover"
fi

if [ -z "$PREFIX" ]; then
    fail "cellular prefix" "cannot read ipv6-ui-prefix from uiwwand-ctl"
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

prefix_addr() {
    ip -6 addr show gre1 2>/dev/null \
        | awk -v p="${PREFIX}/64" '$1 == "inet6" && index($2, p) == 1 { found = 1 } END { exit !found }'
}
route_blackhole() {
    ip -6 route show table 3 2>/dev/null \
        | awk -v p="${PREFIX}/64" '$1 == "blackhole" && $2 == p { found = 1 } END { exit !found }'
}
route_gre() {
    ip -6 route show table 3 2>/dev/null \
        | awk -v p="${PREFIX}/64" '$1 == p && $2 == "dev" && $3 == "gre1" { found = 1 } END { exit !found }'
}

if [ -n "$PREFIX" ]; then
    if prefix_addr; then
        ok "gre1 /64" "$PREFIX/64 present"
    else
        fail "gre1 /64" "no ${PREFIX}/64 address"
    fi

    if route_blackhole; then
        fail "table 3 blackhole" "blackhole ${PREFIX}/64 still present"
    else
        ok "table 3 blackhole" "absent"
    fi

    if route_gre; then
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
