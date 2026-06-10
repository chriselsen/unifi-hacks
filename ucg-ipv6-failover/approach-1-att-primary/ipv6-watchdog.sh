#!/bin/sh
# ipv6-watchdog.sh — re-apply IPv6 policy routing if udapi wiped our rules.
# Run every minute via cron.
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# --- Configuration ---
SETUP=/etc/ipv6-policy-routes/setup.sh
WAN_TABLE="201.eth4.0"

MARK_RULE="MARK xset 0x6b0000"

# Re-apply setup if our fwmark rule has been wiped (happens after udapi restart)
if ! ip6tables -t mangle -L UBIOS_PREROUTING_PBR -n 2>/dev/null | grep -q "$MARK_RULE"; then
    logger -t ipv6-watchdog "rules missing, re-running setup"
    "$SETUP"
fi

# Ensure 'from' rules exist for current primary ISP prefixes so UCG-originated
# traffic routes via primary WAN (not cellular). These are lost on reboot/udapi
# restart and need updating when DHCPv6-PD prefix rotates.
for PREFIX in $(ipset list UBIOS6ALL_NETv6_br0 2>/dev/null | awk '/^[0-9a-f]/ && !/fe80/{print $1}') \
              $(ipset list UBIOS6ALL_NETv6_br10 2>/dev/null | awk '/^[0-9a-f]/ && !/fe80/{print $1}'); do
    ip -6 rule show | grep -q "from $PREFIX lookup 201" || \
        ip -6 rule add from "$PREFIX" lookup "$WAN_TABLE" priority 32508 2>/dev/null && \
        logger -t ipv6-watchdog "added from $PREFIX lookup $WAN_TABLE"
done
