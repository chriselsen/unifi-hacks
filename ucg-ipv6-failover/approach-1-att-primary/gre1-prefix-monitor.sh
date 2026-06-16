#!/bin/sh
# gre1-prefix-monitor — watch for IPv6 address changes on gre1, update radvd.
# Runs as a systemd service (gre1-prefix-monitor.service).
#
# Cellular prefix: re-advertises the cellular /64 on the cellular VLAN (BR_CELLULAR)
# so clients get real cellular GUAs via SLAAC.
#
# Architecture:
#   1. Periodic poll (every 30s) reconciles ALL state: radvd, SNAT, ipsets,
#      routes, sysctls. This is the source of truth — if anything drifts,
#      the next poll fixes it within 30s.
#   2. Event-driven path (ip monitor) triggers immediate reconciliation on
#      address or route changes for fast failover reaction.
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
VLAN_ID="100"                   # Your cellular VLAN ID
BR_CELLULAR="br${VLAN_ID}"      # Bridge interface for cellular VLAN
BR_LAN="br0"                    # Bridge interface for primary LAN
WAN_TABLE="201.eth4.0"          # UCG policy routing table for primary WAN
U5GBACKUP_LL="fe80::c0a8:1eda" # U5GBackup link-local on gre1
                                 # Derived from LAN IP — see setup script comment

CONF=/etc/radvd.conf
FAILOVER_STATE=/run/gre1-monitor-failover
STATE_FILE=/run/gre1-monitor-prefix

# --- Helper: get current GUA on gre1 ---
# Uses valid_lft (not preferred_lft) since we deprecate the gre1 GUA
# for RFC 6724 source address selection (preferred_lft=0).
get_gre1_gua() {
    ip -6 addr show dev gre1 scope global 2>/dev/null \
        | awk '
            BEGIN { best = -1 }
            /inet6/     { addr = $2 }
            /valid_lft/ {
                lft = ($2 == "forever") ? 999999999 : $2+0
                if (lft > best) { best = lft; best_addr = addr }
            }
            END { gsub(/\/.*/, "", best_addr); print best_addr }
        '
}

# --- Helper: compute /64 prefix from address (strips any existing CIDR) ---
get_prefix64() {
    python3 -c "
import ipaddress
a = '$1'.split('/')[0]
print(str(ipaddress.ip_network(a + '/64', strict=False)))
" 2>/dev/null
}

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

# --- Core reconciliation: ensures ALL state matches current prefix ---
# Called on startup, every 30s, and on events. Idempotent.
reconcile() {
    FORCE=${1:-0}

    # Ensure sysctls are correct (udapi can reset these)
    CUR_RA=$(sysctl -n net.ipv6.conf.gre1.accept_ra 2>/dev/null)
    CUR_DEFRTR=$(sysctl -n net.ipv6.conf.gre1.accept_ra_defrtr 2>/dev/null)
    CUR_AUTO=$(sysctl -n net.ipv6.conf.gre1.autoconf 2>/dev/null)
    [ "$CUR_RA" != "2" ] && sysctl -qw net.ipv6.conf.gre1.accept_ra=2
    [ "$CUR_DEFRTR" != "0" ] && sysctl -qw net.ipv6.conf.gre1.accept_ra_defrtr=0
    [ "$CUR_AUTO" != "1" ] && sysctl -qw net.ipv6.conf.gre1.autoconf=1

    # Get current GUA
    GUA=$(get_gre1_gua)
    [ -z "$GUA" ] && return

    PREFIX=$(get_prefix64 "$GUA")
    [ -z "$PREFIX" ] && return

    # Check if anything changed
    PREV_PREFIX=$(cat "$STATE_FILE" 2>/dev/null)
    if [ "$FORCE" = "0" ] && [ "$PREFIX" = "$PREV_PREFIX" ]; then
        # Prefix unchanged — ensure GUA is deprecated, SNAT correct, failover state
        ensure_deprecated "$GUA"
        ensure_snat "$GUA" "$PREFIX"
        check_failover_state "$PREFIX"
        return
    fi

    # --- Prefix changed (or forced) — full reconciliation ---
    logger -t gre1-prefix-monitor "reconcile: prefix $PREFIX (was: ${PREV_PREFIX:-none})"
    echo "$PREFIX" > "$STATE_FILE"

    # Deprecate GUA for RFC 6724 source selection
    ensure_deprecated "$GUA"

    # Determine failover state
    FAILOVER=0
    ip -6 route show table "$WAN_TABLE" | grep -q 'default.*eth4' || FAILOVER=1
    echo "$FAILOVER" > "$FAILOVER_STATE"

    # Update radvd
    write_radvd_conf "$PREFIX" "$FAILOVER"
    service radvd restart
    logger -t gre1-prefix-monitor "radvd restarted with $PREFIX (failover=$FAILOVER)"

    # Remove gre1 default from main table (RA side-effect)
    ip -6 route del default dev gre1 proto ra table main 2>/dev/null

    # Ensure static default in table 178
    ip -6 route replace default via "$U5GBACKUP_LL" dev gre1 table 178.gre1

    # Update ipsets
    ipset test UBIOS6trafficroute_net4_1 "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6trafficroute_net4_1 "$PREFIX"
    ipset test UBIOS6LAN_subnets "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6LAN_subnets "$PREFIX"
    ipset test UBIOS6local_zoned_subnets "$PREFIX" 2>/dev/null || \
        ipset add UBIOS6local_zoned_subnets "$PREFIX"

    # Cellular return route
    ip -6 route show "$PREFIX" | grep -q "$BR_CELLULAR" || \
        ip -6 route add "$PREFIX" dev "$BR_CELLULAR" metric 100 2>/dev/null
    logger -t gre1-prefix-monitor "ipset and $BR_CELLULAR route updated for $PREFIX"

    # Update SNAT rule
    ensure_snat "$GUA" "$PREFIX"

    # Remove stale cellular prefixes from ipsets and routes
    ULA_PREFIX=$(echo "$BR_CELLULAR" | sed 's/br/fd/')
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
            ADDR_PREFIX=$(get_prefix64 "$ADDR")
            if [ "$ADDR_PREFIX" != "$PREFIX" ]; then
                ip -6 addr del "$ADDR" dev gre1 2>/dev/null && \
                    logger -t gre1-prefix-monitor "removed stale GUA $ADDR from gre1"
                ip -6 route del "$ADDR_PREFIX" dev gre1 2>/dev/null
            fi
        done
}

# --- Ensure GUA is deprecated (preferred_lft 0) ---
# RA can re-add the address with preferred_lft forever; fix it every poll.
ensure_deprecated() {
    local GUA="$1"
    local CURRENT_PLFT
    CURRENT_PLFT=$(ip -6 addr show dev gre1 scope global 2>/dev/null \
        | grep "$GUA" -A1 | awk '/preferred_lft/{print $4}')
    if [ "$CURRENT_PLFT" != "0sec" ]; then
        ip -6 addr change "$GUA/64" dev gre1 preferred_lft 0 2>/dev/null
    fi
}

# --- Ensure SNAT rule matches current GUA ---
# Removes any stale SNAT/MASQUERADE rules for gre1, adds the correct one.
ensure_snat() {
    local GUA="$1"
    local PREFIX="$2"

    # Check if correct rule already exists
    if ip6tables -t nat -C POSTROUTING ! -s "$PREFIX" -o gre1 -j SNAT --to-source "$GUA" 2>/dev/null; then
        return
    fi

    # Remove all gre1 SNAT/MASQUERADE rules
    while ip6tables -t nat -D POSTROUTING -o gre1 -j MASQUERADE 2>/dev/null; do :; done
    ip6tables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null \
        | grep "SNAT.*gre1" | awk '{print $1}' | sort -rn \
        | while read -r NUM; do
            ip6tables -t nat -D POSTROUTING "$NUM" 2>/dev/null
        done

    # Add correct rule
    ip6tables -t nat -A POSTROUTING ! -s "$PREFIX" -o gre1 -j SNAT --to-source "$GUA"
    logger -t gre1-prefix-monitor "SNAT updated: $GUA (prefix $PREFIX)"
}

# --- Check/update failover state without full prefix reconciliation ---
check_failover_state() {
    local PREFIX="$1"
    FAILOVER=0
    ip -6 route show table "$WAN_TABLE" | grep -q 'default.*eth4' || FAILOVER=1
    LAST=$(cat "$FAILOVER_STATE" 2>/dev/null || echo 0)

    [ "$FAILOVER" = "$LAST" ] && return

    echo "$FAILOVER" > "$FAILOVER_STATE"

    if [ "$FAILOVER" = "0" ] && [ "$LAST" = "1" ]; then
        # Primary WAN recovered
        rdisc6 -1 "$BR_LAN" 2>/dev/null
        sleep 1
        rdisc6 -1 "$BR_LAN" 2>/dev/null
        sleep 1
        rdisc6 -1 "$BR_LAN" 2>/dev/null
        sleep 3
        # Deprecate PI prefix before removing
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
        write_radvd_conf "$PREFIX" 0
        service radvd restart
        logger -t gre1-prefix-monitor "primary WAN recovered, radvd updated"
    elif [ "$FAILOVER" = "1" ] && [ "$LAST" = "0" ]; then
        # Primary WAN failed
        logger -t gre1-prefix-monitor "primary WAN failed, activating PI failover"
        write_radvd_conf "$PREFIX" 1
        service radvd restart
        sleep 1
        rdisc6 -1 "$BR_LAN" 2>/dev/null
        sleep 1
        rdisc6 -1 "$BR_LAN" 2>/dev/null
        sleep 1
        rdisc6 -1 "$BR_LAN" 2>/dev/null
        logger -t gre1-prefix-monitor "failover active, radvd updated"
    fi
}

# ============================================================
# MAIN
# ============================================================

# Run full reconciliation on startup
echo 0 > "$FAILOVER_STATE"
reconcile 1

# Start event monitor in background — triggers immediate reconciliation
ip monitor address route | while read -r line; do
    case "$line" in
        *gre1*inet6*|*gre1*"scope global"*)
            reconcile
            ;;
        *"table 201"*|*"eth4"*)
            reconcile
            ;;
    esac
done &
MONITOR_PID=$!

# Periodic poll — the safety net that makes everything self-healing
while true; do
    sleep 30
    reconcile
done &
POLL_PID=$!

# Wait for either to exit (shouldn't happen) and clean up
wait $MONITOR_PID $POLL_PID
