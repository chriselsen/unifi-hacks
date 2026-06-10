#!/bin/sh
# gre1-prefix-monitor — watch for IPv6 address changes on gre1, update radvd.
# Runs as a systemd service (gre1-prefix-monitor.service).
#
# Cellular prefix: re-advertises the cellular /64 on the cellular VLAN (BR_CELLULAR)
# so clients get real cellular GUAs via SLAAC.
#
# Failover: when primary WAN default disappears from table 201, adds PI prefix
# on BR_LAN with short lifetimes (300s) so LAN clients get a GUA that survives
# the ~1h odhcpd lease expiry window. On recovery, deprecates PI prefix
# (preferred_lft 0) so RFC 6724 Rule 3 makes clients prefer ISP GUA, then
# removes the block and addresses expire naturally within ~5 minutes.
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# --- Configuration ---
PI_PREFIX="2001:db8:fe::/64"   # Your PI /64 — replace with your own
BR_CELLULAR="br100"             # Bridge interface for cellular VLAN
BR_LAN="br0"                    # Bridge interface for primary LAN
WAN_TABLE="201.eth4.0"          # UCG policy routing table for primary WAN
U5GBACKUP_LINK_LOCAL="fe80::c0a8:1eda"  # U5GBackup link-local on gre1
                                         # (derived from LAN IP: 192.168.x.y
                                         #  → fe80::c0a8:xxxx where c0a8=192.168)

CONF=/etc/radvd.conf
FAILOVER_STATE=/run/gre1-monitor-failover

write_radvd_conf() {
    local PREFIX="$1"
    local FAILOVER="${2:-0}"
    cat > "$CONF" << EOF
interface $BR_CELLULAR {
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 10;
    AdvDefaultLifetime 30;

    prefix $PREFIX {
        AdvOnLink on;
        AdvAutonomous on;
        AdvValidLifetime 86400;
        AdvPreferredLifetime 14400;
    };
};
EOF
    # During failover, advertise PI prefix on LAN with short lifetimes.
    # 300s valid_lft: addresses expire naturally ~5min after recovery.
    # AdvDefaultLifetime 1800: matches odhcpd router lifetime so clients
    # keep the UCG as default router for the full failover duration.
    if [ "$FAILOVER" = "1" ]; then
        cat >> "$CONF" << EOF

interface $BR_LAN {
    AdvSendAdvert on;
    MinRtrAdvInterval 10;
    MaxRtrAdvInterval 30;
    AdvDefaultLifetime 1800;

    prefix $PI_PREFIX {
        AdvOnLink on;
        AdvAutonomous on;
        AdvValidLifetime 300;
        AdvPreferredLifetime 300;
    };
};
EOF
    fi
}

update_radvd() {
    FORCE=${1:-0}
    # Pick GUA on gre1 by highest valid_lft.
    # Use valid_lft (not preferred_lft) since we deprecate the gre1 GUA
    # for RFC 6724 source address selection (preferred_lft=0).
    GUA=$(ip -6 addr show dev gre1 scope global 2>/dev/null \
        | awk '
            /inet6/     { addr = $2 }
            /valid_lft/ {
                lft = ($2 == "forever") ? 999999999 : $2+0
                if (lft > best) { best = lft; best_addr = addr }
            }
            END { gsub(/\/.*/, "", best_addr); print best_addr }
        ')

    [ -z "$GUA" ] && return

    PREFIX=$(python3 -c "
import ipaddress
print(str(ipaddress.ip_network('$GUA/64', strict=False)))
" 2>/dev/null)

    [ -z "$PREFIX" ] && return

    [ "$FORCE" = "0" ] && grep -qF "$PREFIX" "$CONF" 2>/dev/null && return

    logger -t gre1-prefix-monitor "new prefix $PREFIX on $BR_CELLULAR"

    FAILOVER=0
    ip -6 route show table "$WAN_TABLE" | grep -q 'default.*eth4' || FAILOVER=1

    write_radvd_conf "$PREFIX" "$FAILOVER"
    echo "$FAILOVER" > "$FAILOVER_STATE"

    service radvd restart
    logger -t gre1-prefix-monitor "radvd restarted with $PREFIX"

    # Remove RA-learned default from main table (would override policy routing)
    ip -6 route del default dev gre1 proto ra table main 2>/dev/null

    # Keep ipset and cellular return route in sync with new prefix
    ipset test UBIOS6trafficroute_net4_1 "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6trafficroute_net4_1 "$PREFIX"
    ipset test UBIOS6LAN_subnets "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6LAN_subnets "$PREFIX"
    ipset test UBIOS6local_zoned_subnets "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6local_zoned_subnets "$PREFIX"
    ip -6 route show "$PREFIX" | grep -q "$BR_CELLULAR" || \
        ip -6 route add "$PREFIX" dev "$BR_CELLULAR" metric 100 2>/dev/null
    logger -t gre1-prefix-monitor "ipset and $BR_CELLULAR route updated for $PREFIX"

    # Remove stale cellular prefixes from ipsets and routes
    ULA_PREFIX=$(echo "$BR_CELLULAR" | sed 's/br/fd/')  # e.g. br100 → fd100::/64
    for STALE in $(ipset list UBIOS6trafficroute_net4_1 \
                    | awk "/^[0-9a-f]/ && !/$ULA_PREFIX/ {print \$1}"); do
        [ "$STALE" = "$PREFIX" ] && continue
        ipset del UBIOS6trafficroute_net4_1 "$STALE" 2>/dev/null
        ipset del UBIOS6LAN_subnets "$STALE" 2>/dev/null
        ipset del UBIOS6local_zoned_subnets "$STALE" 2>/dev/null
        ip -6 route del "$STALE" dev "$BR_CELLULAR" 2>/dev/null
        logger -t gre1-prefix-monitor "removed stale prefix $STALE"
    done

    # Remove stale GUAs from gre1 — keep only current prefix
    ip -6 addr show dev gre1 scope global \
        | awk '/inet6/{print $2}' \
        | while read -r ADDR; do
            ADDR_PREFIX=$(python3 -c "import ipaddress; print(str(ipaddress.ip_network('$ADDR', strict=False).supernet(new_prefix=64)))" 2>/dev/null)
            if [ "$ADDR_PREFIX" != "$PREFIX" ]; then
                ip -6 addr del "$ADDR" dev gre1 2>/dev/null && \
                    logger -t gre1-prefix-monitor "removed stale GUA $ADDR from gre1"
                ip -6 route del "$ADDR_PREFIX" dev gre1 2>/dev/null
            fi
        done
}

# Run once on startup — always rewrite conf and restart radvd
echo 0 > "$FAILOVER_STATE"
update_radvd 1

# Watch for address changes on gre1 and route changes affecting primary WAN table
ip monitor address route | while read -r line; do
    case "$line" in
        # New cellular prefix on gre1
        *"inet6"*"scope global"*gre1*)
            update_radvd
            ;;
        # Primary WAN default route appeared or disappeared
        *"table 201"*|*"eth4"*)
            PREFIX=$(grep 'prefix ' "$CONF" 2>/dev/null | head -1 | awk '{print $2}')
            [ -n "$PREFIX" ] && {
                FAILOVER=0
                ip -6 route show table "$WAN_TABLE" | grep -q 'default.*eth4' || FAILOVER=1
                LAST=$(cat "$FAILOVER_STATE" 2>/dev/null || echo 0)
                echo "$FAILOVER" > "$FAILOVER_STATE"
                if [ "$FAILOVER" = "0" ] && [ "$LAST" = "1" ]; then
                    # Primary WAN recovered — trigger RS so clients get fresh RA
                    rdisc6 -1 "$BR_LAN" 2>/dev/null
                    sleep 1
                    rdisc6 -1 "$BR_LAN" 2>/dev/null
                    sleep 1
                    rdisc6 -1 "$BR_LAN" 2>/dev/null
                    sleep 3
                    # Deprecate PI prefix so RFC 6724 Rule 3 makes clients
                    # prefer ISP GUA for new connections before we remove block
                    cat > "$CONF" << EOF
interface $BR_CELLULAR {
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 10;
    AdvDefaultLifetime 30;

    prefix $PREFIX {
        AdvOnLink on;
        AdvAutonomous on;
        AdvValidLifetime 86400;
        AdvPreferredLifetime 14400;
    };
};

interface $BR_LAN {
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 5;
    AdvDefaultLifetime 1800;

    prefix $PI_PREFIX {
        AdvOnLink on;
        AdvAutonomous on;
        AdvValidLifetime 300;
        AdvPreferredLifetime 0;
    };
};
EOF
                    service radvd restart
                    logger -t gre1-prefix-monitor "deprecated PI prefix on $BR_LAN for recovery"
                    sleep 10
                fi
                write_radvd_conf "$PREFIX" "$FAILOVER"
                if [ "$FAILOVER" = "1" ]; then
                    service radvd restart
                    sleep 1
                    rdisc6 -1 "$BR_LAN" 2>/dev/null
                    sleep 1
                    rdisc6 -1 "$BR_LAN" 2>/dev/null
                    sleep 1
                    rdisc6 -1 "$BR_LAN" 2>/dev/null
                    logger -t gre1-prefix-monitor "failover detected, radvd updated"
                else
                    write_radvd_conf "$PREFIX" 0
                    service radvd restart
                    logger -t gre1-prefix-monitor "primary WAN restored, radvd updated"
                fi
            }
            ;;
    esac
done
