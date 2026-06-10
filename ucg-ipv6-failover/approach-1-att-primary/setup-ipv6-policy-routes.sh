#!/bin/sh
# setup-ipv6-policy-routes.sh — IPv6 policy routing for UCG with U5G Backup.
#
# Adds IPv6 equivalents of the rules the UCG's Traffic Routes UI generates
# for IPv4 only. Must be re-run after every UCG reboot or udapi restart.
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# --- Configuration — edit these for your setup ---
PI_PREFIX="2001:db8:fe::/64"   # Your PI /64 — replace with your own
VLAN_ID="100"                   # Your cellular VLAN ID
BR_CELLULAR="br${VLAN_ID}"     # Cellular VLAN bridge (e.g. br100)
BR_LAN="br0"                    # Primary LAN bridge
WAN_TABLE="201.eth4.0"          # UCG policy table for primary WAN
GRE_TABLE="178.gre1"            # UCG policy table for cellular (gre1)
U5GBACKUP_LL="fe80::c0a8:1eda" # U5GBackup link-local on gre1
                                 # Derived from LAN IP 192.168.x.y:
                                 # e.g. 192.168.1.218 → fe80::c0a8:1da
                                 # hex: c0=192 a8=168 01=1 da=218

# Traffic route ipset names (created by UCG UI for your Traffic Route)
# Replace net4_1 with your actual traffic route number if different
IPSET="UBIOS_trafficroute_net4_1"
IPSET6="UBIOS6trafficroute_net4_1"
ULA_PREFIX="fd${VLAN_ID}::/64"  # ULA prefix for cellular VLAN (e.g. fd100::/64)
MARK="0x6b0000/0x7f0000"
LOCAL_SET="UBIOS_local_zoned_subnets"

# Add cellular VLAN ULA prefix to traffic route ipset
if ! ipset test "$IPSET6" "$ULA_PREFIX" 2>/dev/null; then
    ipset add "$IPSET6" "$ULA_PREFIX"
    logger -t ipv6-pbr "added $ULA_PREFIX to $IPSET6"
fi

# Ensure primary ISP GUA prefixes are in LAN and zoned ipsets so return
# traffic from WAN is accepted by UBIOS_WAN_LAN_USER firewall chain.
for PREFIX in $(ipset list UBIOS6ALL_NETv6_br0 | awk '/^[0-9a-f]/{print $1}') \
              $(ipset list UBIOS6ALL_NETv6_br10 | awk '/^[0-9a-f]/{print $1}'); do
    ipset test UBIOS6LAN_subnets "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6LAN_subnets "$PREFIX"
    ipset test UBIOS6local_zoned_subnets "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6local_zoned_subnets "$PREFIX"
done

# Detect cellular GUA on gre1 (use valid_lft ordering since we deprecate
# the gre1 GUA for RFC 6724 source address selection)
GUA=$(ip -6 addr show dev gre1 scope global 2>/dev/null \
    | awk '
        /inet6/     { addr = $2 }
        /valid_lft/ {
            lft = ($2 == "forever") ? 999999999 : $2+0
            if (lft > best) { best = lft; best_addr = addr }
        }
        END { gsub(/\/.*/, "", best_addr); print best_addr }
    ')
if [ -n "$GUA" ]; then
    GUA_PREFIX=$(python3 -c "import ipaddress; print(str(ipaddress.ip_network('$GUA/64', strict=False)))" 2>/dev/null)
    if [ -n "$GUA_PREFIX" ] && ! ipset test "$IPSET6" "$GUA_PREFIX" 2>/dev/null; then
        ipset add "$IPSET6" "$GUA_PREFIX"
        logger -t ipv6-pbr "added $GUA_PREFIX to $IPSET6"
    fi
    # Return route for cellular GUA prefix to cellular VLAN bridge
    if ! ip -6 route show "$GUA_PREFIX" | grep -q "$BR_CELLULAR"; then
        ip -6 route add "$GUA_PREFIX" dev "$BR_CELLULAR" metric 100 2>/dev/null
        logger -t ipv6-pbr "added route $GUA_PREFIX dev $BR_CELLULAR"
    fi
    ipset test UBIOS6LAN_subnets "$GUA_PREFIX" 2>/dev/null || \
        ipset add UBIOS6LAN_subnets "$GUA_PREFIX"
    ipset test UBIOS6local_zoned_subnets "$GUA_PREFIX" 2>/dev/null || \
        ipset add UBIOS6local_zoned_subnets "$GUA_PREFIX"
fi

# Mark UCG-originated traffic sourced from cellular GUA to route via gre1
if [ -n "$GUA_PREFIX" ]; then
    ip6tables -t mangle -D UBIOS_WF_OUT_WANS \
        -s "$GUA_PREFIX" -j MARK --set-mark 0x6a0000/0x7e0000 2>/dev/null
    ip6tables -t mangle -I UBIOS_WF_OUT_WANS 1 \
        -s "$GUA_PREFIX" -j MARK --set-mark 0x6a0000/0x7e0000
    logger -t ipv6-pbr "added WF_OUT_WANS mark rule for $GUA_PREFIX"
fi

# Routing rules for UCG-originated traffic using primary ISP prefixes.
# iif rules only match forwarded traffic; 'from' rules cover UCG-generated.
for PREFIX in $(ipset list UBIOS6ALL_NETv6_br0 | awk '/^[0-9a-f]/ && !/fe80/{print $1}') \
              $(ipset list UBIOS6ALL_NETv6_br10 | awk '/^[0-9a-f]/ && !/fe80/{print $1}'); do
    ip -6 rule show | grep -q "from $PREFIX lookup 201" || \
        ip -6 rule add from "$PREFIX" lookup "$WAN_TABLE" priority 32508
done

# NAT66 on gre1 — use explicit SNAT to cellular GUA (not MASQUERADE).
# MASQUERADE fails when gre1 GUA has preferred_lft=0 (deprecated for RFC 6724).
# Excludes cellular GUA prefix (br<N> clients route natively without NAT).
while ip6tables -t nat -D POSTROUTING -o gre1 -j MASQUERADE 2>/dev/null; do :; done
while ip6tables -t nat -D POSTROUTING ! -s "$GUA_PREFIX" -o gre1 -j MASQUERADE 2>/dev/null; do :; done
while ip6tables -t nat -D POSTROUTING ! -s "$GUA_PREFIX" -o gre1 -j SNAT --to-source "$GUA" 2>/dev/null; do :; done
if [ -n "$GUA" ] && [ -n "$GUA_PREFIX" ]; then
    ip6tables -t nat -A POSTROUTING ! -s "$GUA_PREFIX" -o gre1 -j SNAT --to-source "$GUA"
    logger -t ipv6-pbr "added SNAT to $GUA on gre1"
else
    ip6tables -t nat -A POSTROUTING -o gre1 -j MASQUERADE
fi

# Fallback default route in table 201 via gre1 — activates when primary WAN
# default (metric 512) disappears. Same pattern as IPv4 failover.
ip -6 route replace default via "$U5GBACKUP_LL" dev gre1 \
    table "$WAN_TABLE" metric 2048 2>/dev/null

# PI prefix routing — always present so clients can use PI GUA immediately
# when radvd advertises it during failover (no race condition).
ip -6 rule show | grep -q "from $PI_PREFIX lookup 201" || \
    ip -6 rule add from "$PI_PREFIX" lookup "$WAN_TABLE" priority 32508
ipset test UBIOS6LAN_subnets "$PI_PREFIX" 2>/dev/null || \
    ipset add UBIOS6LAN_subnets "$PI_PREFIX"
ipset test UBIOS6local_zoned_subnets "$PI_PREFIX" 2>/dev/null || \
    ipset add UBIOS6local_zoned_subnets "$PI_PREFIX"
ipset test UBIOS6ALL_NETv6_br0 "$PI_PREFIX" 2>/dev/null || \
    ipset add UBIOS6ALL_NETv6_br0 "$PI_PREFIX"
# Connected route on LAN bridge — always present, prevents ICMPv6 unreachable
# errors when clients start using PI GUA immediately after radvd RA
ip -6 route replace "$PI_PREFIX" dev "$BR_LAN" metric 100 2>/dev/null

# TCP MSS clamping — prevents PMTUD black hole via gre1.
# gre1 MTU is 1476; SNAT prevents ICMPv6 PTB from reaching originating client.
# MSS = 1476 - 40 (IPv6 header) - 20 (TCP header) = 1416
ip6tables -t mangle -D FORWARD -o gre1 -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss 1416 2>/dev/null
ip6tables -t mangle -A FORWARD -o gre1 -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss 1416

# ip6tables rules for cellular VLAN traffic route (IPv6 equivalent of UI rules)
ip6tables -t mangle -D UBIOS_PREROUTING_PBR \
    -m set --match-set "$IPSET" src \
    -m set ! --match-set "$LOCAL_SET" dst \
    -j MARK --set-mark "$MARK" 2>/dev/null
ip6tables -t mangle -D UBIOS_PREROUTING_PBR \
    -m set --match-set "$IPSET" src \
    -m set ! --match-set "$LOCAL_SET" dst \
    -j CONNMARK --save-mark --mask 0x7f0000 2>/dev/null
ip6tables -t mangle -D UBIOS_PREROUTING_PBR \
    -m set --match-set "$IPSET" src \
    -m set ! --match-set "$LOCAL_SET" dst \
    -j RETURN 2>/dev/null
ip6tables -t mangle -I UBIOS_PREROUTING_PBR 1 \
    -m set --match-set "$IPSET" src \
    -m set ! --match-set "$LOCAL_SET" dst \
    -j MARK --set-mark "$MARK"
ip6tables -t mangle -I UBIOS_PREROUTING_PBR 2 \
    -m set --match-set "$IPSET" src \
    -m set ! --match-set "$LOCAL_SET" dst \
    -j CONNMARK --save-mark --mask 0x7f0000
ip6tables -t mangle -I UBIOS_PREROUTING_PBR 3 \
    -m set --match-set "$IPSET" src \
    -m set ! --match-set "$LOCAL_SET" dst \
    -j RETURN

# gre1 sysctl: accept RAs for SLAAC but suppress RA-learned default from
# landing in main table (would override policy routing)
sysctl -w net.ipv6.conf.gre1.accept_ra=2 >/dev/null
sysctl -w net.ipv6.conf.gre1.accept_ra_defrtr=0 >/dev/null
sysctl -w net.ipv6.conf.gre1.autoconf=1 >/dev/null

# Deprecate gre1 GUA for RFC 6724 source address selection.
# preferred_lft=0 means kernel never picks it as source for UCG-originated
# traffic (e.g. WireGuard) — always uses primary ISP GUA instead.
# SNAT uses explicit --to-source so preferred_lft=0 doesn't affect NAT.
if [ -n "$GUA" ]; then
    ip -6 addr change "$GUA/64" dev gre1 preferred_lft 0 2>/dev/null && \
        logger -t ipv6-pbr "deprecated gre1 GUA $GUA (RFC 6724 source selection)"
fi

# Static default for gre1 policy table — normally installed by RA but
# suppressed above via accept_ra_defrtr=0
ip -6 route replace default via "$U5GBACKUP_LL" dev gre1 table "$GRE_TABLE"

logger -t ipv6-pbr "done — cellular VLAN $VLAN_ID IPv6 routed via gre1"
