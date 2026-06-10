#!/bin/sh
# trigger-u5g-patch.sh — Run on UCG. SSHes into U5GBackup every minute
# to apply the IPv6 fix. Called from cron (see README.md).
#
# Deploys to: /etc/ipv6-policy-routes/trigger-u5g-patch.sh on the UCG
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# --- Configuration ---
U5GBACKUP_IP="192.168.1.218"          # IP address of your U5GBackup on LAN
SSH_KEY="/etc/ipv6-policy-routes/u5g-backup-key"  # Private key for U5GBackup SSH

# Run the patch script on the U5GBackup
ssh -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    root@"$U5GBACKUP_IP" \
    "sh /etc/persistent/patch-u5g-ipv6.sh" 2>/dev/null
