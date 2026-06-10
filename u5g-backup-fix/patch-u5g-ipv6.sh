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

# Derive the cellular /64 prefix from rmnet_data0's assigned address.
# The modem gets a /128 SLAAC address; we extract the /64 from it.
PREFIX=$(ip -6 addr show rmnet_data0 2>/dev/null \
    | awk '/scope global/{
        gsub(/\/128/, "")
        split($2, g, ":")
        printf "%s:%s:%s:%s::\n", g[1], g[2], g[3], g[4]
        exit
    }')

# Exit silently if modem not connected or no IPv6 assigned yet
[ -z "$PREFIX" ] && exit 0

# Exit silently if gre1 tunnel is not up yet
ip link show gre1 >/dev/null 2>&1 || exit 0

# Fix 1: Enable multicast on gre1 (required by odhcpd for RA advertisement)
if ! ip link show gre1 | grep -q MULTICAST; then
    ip link set gre1 multicast on
fi

# Fix 2: Assign /64 prefix to gre1 so odhcpd finds a subnet to advertise.
# Uses the well-known ISATAP suffix (::fffe) as a stable host identifier.
if ! ip -6 addr show gre1 | grep -q "${PREFIX}.*\/64"; then
    ip -6 addr add "${PREFIX}fffe/64" dev gre1 2>/dev/null
fi

# Fix 3: Remove all blackhole routes for this prefix.
# activate_mbb_network_inet_interface.sh adds a blackhole that drops all
# forwarded IPv6 traffic arriving on gre1 from the parent gateway.
while ip -6 route show table 3 | grep -q "blackhole ${PREFIX}"; do
    ip -6 route del blackhole "${PREFIX}/64" table 3 2>/dev/null
done

# Fix 3b: Add prefix route in table 3 so return traffic reaches gre1.
# Without this, internet → rmnet_data0 → table 3 has no route back to gre1.
if ! ip -6 route show table 3 | grep -q "${PREFIX}.*dev gre1"; then
    ip -6 route add table 3 "${PREFIX}/64" dev gre1 metric 100499 2>/dev/null
fi

# Ensure odhcpd is running (it may have exited if gre1 wasn't ready at boot)
if ! pgrep odhcpd >/dev/null; then
    /usr/sbin/odhcpd >/dev/null 2>&1 </dev/null &
fi
