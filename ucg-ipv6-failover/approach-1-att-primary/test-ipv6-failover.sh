#!/bin/bash
# test-ipv6-failover.sh — simulate primary WAN failure by bringing eth4 down.
# Run from a machine on the LAN — SSH sessions via LAN are unaffected.
# Saves full log to /tmp/failover-test-<timestamp>.log
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# --- Configuration ---
UCG="root@192.168.1.1"          # UCG SSH target
NAS="user@192.168.1.2"          # Optional: a LAN client to test connectivity from
KEY="$HOME/.ssh/id_ed25519"     # SSH private key for UCG access
WAN_IF="eth4"                   # UCG primary WAN interface
WAN_TABLE="201.eth4.0"          # UCG policy routing table for primary WAN

SSH_UCG="ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5 $UCG"
SSH_NAS="ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5 $NAS"

LOGFILE="/tmp/failover-test-$(date +%Y%m%d-%H%M%S).log"
DOWN_DURATION=180   # seconds primary WAN stays down
SAMPLE_INTERVAL=20  # seconds between mid-failover snapshots

log()     { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
section() { echo -e "\n========== $* ==========" | tee -a "$LOGFILE"; }

snapshot() {
    local LABEL="$1"
    section "$LABEL"

    log "--- table 201 IPv6 ---"
    $SSH_UCG "ip -6 route show table $WAN_TABLE" 2>&1 | tee -a "$LOGFILE"

    log "--- table 201 IPv4 ---"
    $SSH_UCG "ip route show table $WAN_TABLE" 2>&1 | tee -a "$LOGFILE"

    log "--- br0 IPv6 addr ---"
    $SSH_UCG "ip -6 addr show dev br0" 2>&1 | tee -a "$LOGFILE"

    log "--- gre1 IPv6 addr ---"
    $SSH_UCG "ip -6 addr show dev gre1" 2>&1 | tee -a "$LOGFILE"

    log "--- radvd.conf ---"
    $SSH_UCG "cat /etc/radvd.conf" 2>&1 | tee -a "$LOGFILE"

    log "--- SNAT rule ---"
    $SSH_UCG "ip6tables -t nat -S POSTROUTING | grep -E 'SNAT|MASQ'" 2>&1 | tee -a "$LOGFILE"

    log "--- NDP br0 client count ---"
    $SSH_UCG "ip -6 neigh show dev br0 | grep -c REACHABLE" 2>&1 | tee -a "$LOGFILE"

    log "--- ping6 UCG via gre1 (cellular, should always work) ---"
    $SSH_UCG "ping6 -c3 -W2 -I gre1 2606:4700:4700::1111" 2>&1 | tail -2 | tee -a "$LOGFILE"

    log "--- curl IPv6 from LAN client ---"
    $SSH_NAS "curl -6 -s --max-time 5 https://ipv6.icanhazip.com" \
        2>&1 | tee -a "$LOGFILE" || echo "FAILED" | tee -a "$LOGFILE"

    log "--- curl IPv4 from LAN client (should stay up) ---"
    $SSH_NAS "curl -4 -s --max-time 5 https://ipv4.icanhazip.com" \
        2>&1 | tee -a "$LOGFILE" || echo "FAILED" | tee -a "$LOGFILE"
}

# ---- Start background captures on UCG ----
section "STARTING BACKGROUND CAPTURES"

$SSH_UCG "ip monitor route" >> "$LOGFILE.routes" 2>&1 &
MONITOR_PID=$!
log "ip monitor route PID=$MONITOR_PID"

$SSH_UCG "tcpdump -i br0 -l icmp6" >> "$LOGFILE.icmpv6" 2>&1 &
TCPDUMP_PID=$!
log "tcpdump br0 ICMPv6 PID=$TCPDUMP_PID"

$SSH_UCG "journalctl -f -t gre1-prefix-monitor" >> "$LOGFILE.monitor" 2>&1 &
JOURNAL_PID=$!
log "journalctl gre1-prefix-monitor PID=$JOURNAL_PID"

# ---- Baseline ----
snapshot "BASELINE (primary WAN UP)"

# ---- Bring WAN down ----
section "BRINGING $WAN_IF DOWN"
log "Taking $WAN_IF down..."
$SSH_UCG "ip link set $WAN_IF down"
log "$WAN_IF is DOWN — holding for ${DOWN_DURATION}s"

ELAPSED=0
while [ $ELAPSED -lt $DOWN_DURATION ]; do
    sleep $SAMPLE_INTERVAL
    ELAPSED=$((ELAPSED + SAMPLE_INTERVAL))
    snapshot "FAILOVER T+${ELAPSED}s ($WAN_IF DOWN)"
done

# ---- Bring WAN back up ----
section "BRINGING $WAN_IF BACK UP"
log "Bringing $WAN_IF up..."
$SSH_UCG "ip link set $WAN_IF up"
log "$WAN_IF is UP — waiting for recovery"

sleep 30
snapshot "RECOVERY T+30s"
sleep 30
snapshot "RECOVERY T+60s"

# ---- Stop captures ----
section "STOPPING CAPTURES"
kill $MONITOR_PID $TCPDUMP_PID $JOURNAL_PID 2>/dev/null
sleep 1

section "ROUTE MONITOR LOG"
cat "$LOGFILE.routes" >> "$LOGFILE"
section "ICMPv6 CAPTURE (br0)"
cat "$LOGFILE.icmpv6" >> "$LOGFILE"
section "PREFIX MONITOR LOG"
cat "$LOGFILE.monitor" >> "$LOGFILE"
rm -f "$LOGFILE.routes" "$LOGFILE.icmpv6" "$LOGFILE.monitor"

section "DONE"
log "Full log: $LOGFILE"
