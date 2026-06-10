#!/bin/sh
# restore-crontab.sh — idempotently restore crontab entries after firmware upgrade.
# Called by restore-crontab.service on every boot.
#
# MIT License — https://github.com/chriselsen/unifi-hacks

# --- Configuration ---
U5GBACKUP_IP="192.168.1.218"     # LAN IP of your U5GBackup
SSH_KEY="/etc/ipv6-policy-routes/u5g-backup-key"

PATCH_JOB="* * * * * ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes root@$U5GBACKUP_IP 'sh /etc/persistent/patch-u5g-ipv6.sh' 2>/dev/null"
WATCHDOG_JOB="* * * * * /etc/ipv6-policy-routes/ipv6-watchdog.sh"

# Restore both crontab entries idempotently
(crontab -l 2>/dev/null | grep -v 'patch-u5g-ipv6\|ipv6-watchdog'
 echo "$PATCH_JOB"
 echo "$WATCHDOG_JOB"
) | crontab -

logger -t restore-crontab "crontab entries restored"
