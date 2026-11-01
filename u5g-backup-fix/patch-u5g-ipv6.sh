#!/bin/sh
# patch-u5g-ipv6.sh — Fix IPv6 in failover mode on UniFi 5G Backup (U5G-US).
#
# Deploys to: /etc/persistent/patch-u5g-ipv6.sh on the U5GBackup
# Triggered:  Every minute via SSH from the parent UCG (see README.md)
#
# Fixes three firmware bugs:
#   1. activate_ipv6() assigns /128 to gre1 instead of /64 — odhcpd finds no
#      prefix to advertise and sends RAs without PIO (no SLAAC possible)
#   2. GRE interface lacks IFF_MULTICAST — odhcpd refuses to advertise on it
#   3. Blackhole route drops all IPv6 forwarded via gre1
#
# This script is fully idempotent — safe to run every minute, only acts when
# something needs fixing.
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# Firmware 1.5.5 writes "option ra 'disabled'" for the MBB LAN. In that
# version the patch must also re-enable RAs, otherwise odhcpd has no PIO to
# advertise even after the /64 address is added. The firmware may rewrite the
# file on every data call, so the block below is intentionally idempotent.
# The patch is for failover mode only; primary_internet uses ui_force_ia_pd and
# usb_nat has a different data path. Require an explicit failover value: if the
# config is missing or unreadable, do not touch addresses, routes or DHCP.
MBB_MODE=$(awk -F= '/^mbb\.mode=/{print $2; exit}' /tmp/system.cfg 2>/dev/null)
if [ "$MBB_MODE" != "failover" ]; then
    echo "u5g-ipv6: mbb.mode=${MBB_MODE:-missing/unreadable}, refusing to patch (need failover)" >&2
    exit 0
fi

# Derive the cellular /64 from uiwwand's normalized ipv6-ui-prefix.
# Do not split the displayed IPv6 address: it may be compressed
# (2001:db8::1234/128), which would produce an invalid prefix.
if ! command -v uiwwand-ctl >/dev/null 2>&1; then
    echo "u5g-ipv6: uiwwand-ctl not found, cannot read the cellular prefix" >&2
    exit 0
fi
PREFIX=$(printf '%s\n' '{"method":"get-ipv6-settings"}' | uiwwand-ctl 2>/dev/null \
    | tr -d '\n' \
    | sed -n 's/.*"ipv6-ui-prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
PREFIX=${PREFIX%/64}

# Exit silently if modem not connected or no IPv6 assigned yet
[ -z "$PREFIX" ] && exit 0

# Exit silently if gre1 tunnel is not up yet
ip link show gre1 >/dev/null 2>&1 || exit 0

# Exact match helpers. A substring match would accept a /128 host route or a
# different prefix that merely shares the first hextets.
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

# Fix 1: Enable multicast on gre1 (required by odhcpd for RA advertisement)
if ! ip link show gre1 | grep -q MULTICAST; then
    ip link set gre1 multicast on
fi

# Fix 2: Assign /64 prefix to gre1 so odhcpd finds a subnet to advertise.
# Uses the well-known ISATAP suffix (::fffe) as a stable host identifier.
if ! prefix_addr; then
    ip -6 addr add "${PREFIX}fffe/64" dev gre1 2>/dev/null
fi

# Fix 3: Remove all blackhole routes for this prefix.
# activate_mbb_network_inet_interface.sh adds a blackhole that drops all
# forwarded IPv6 traffic arriving on gre1 from the parent gateway.
while route_blackhole; do
    ip -6 route del blackhole "${PREFIX}/64" table 3 2>/dev/null
done

# Fix 3b: Add prefix route in table 3 so return traffic reaches gre1.
# Without this, internet → rmnet_data0 → table 3 has no route back to gre1.
if ! route_gre; then
    ip -6 route add table 3 "${PREFIX}/64" dev gre1 metric 100499 2>/dev/null
fi

# Fix 4 (firmware 1.5.5): re-enable Router Advertisements on the generated
# MBB LAN. 1.5.5 sets "option ra 'disabled'" in /etc/config/dhcp, so odhcpd
# sends no PIO and the parent gateway cannot SLAAC from gre1. The firmware may
# regenerate the file on a data call, so this check runs every minute.
if command -v uci >/dev/null 2>&1; then
    if [ "$(uci -q get dhcp.ipv6.ra)" = "disabled" ]; then
        uci set dhcp.ipv6.ra='server'
        uci commit dhcp
        if [ -x /etc/init.d/odhcpd ]; then
            /etc/init.d/odhcpd restart
        else
            pkill odhcpd 2>/dev/null
            /usr/sbin/odhcpd >/dev/null 2>&1 </dev/null &
        fi
    fi
fi

# Ensure odhcpd is running (it may have exited if gre1 wasn't ready at boot)
if ! pgrep odhcpd >/dev/null; then
    /usr/sbin/odhcpd >/dev/null 2>&1 </dev/null &
fi

# The U5G CLAT flag is not runtime state: the API can report
# clat_enabled=false while 192.0.0.2/27 is translating IPv4. Probe the local
# CLAT address as a warning only; the IPv6 fix is independent of IPv4.
if ip -4 addr show rmnet_data0 2>/dev/null | grep -q '192\.0\.0\.2'; then
    if ! ping -4 -I 192.0.0.2 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "u5g-ipv6: warning: CLAT IPv4 probe via 192.0.0.2 failed" >&2
    fi
fi
