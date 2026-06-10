# UniFi 5G Backup: IPv6 Fix

Fixes three firmware bugs in the UniFi 5G Backup (U5G-US) that prevent IPv6
from working in failover mode.

## The Problem

When the U5G Backup is adopted in failover mode, the `activate_ipv6()` function
in the firmware does the following:

1. **Assigns a `/128` host address to `gre1`** instead of a `/64` prefix.
   On a point-to-point interface like `gre1`, a `/128` creates only a host
   route with no subnet. `odhcpd` finds no `/64` prefix on `gre1` and sends
   Router Advertisements without a Prefix Information Option — clients cannot
   do SLAAC and get no IPv6 address.

2. **Does not set `IFF_MULTICAST` on `gre1`**. `odhcpd` requires the
   multicast flag before it will advertise on an interface.

3. **Adds a blackhole route** in table 3 that silently drops all IPv6 traffic
   forwarded via the GRE tunnel from the parent gateway.

The fix is a small idempotent shell script that corrects all three issues.
It runs every minute via SSH from the parent UCG so it reapplies automatically
after every U5GBackup reboot or cellular reconnect.

## Prerequisites

- UniFi 5G Backup (U5G-US) adopted in failover mode on a UCG
- SSH access to both the UCG and the U5GBackup
- The U5GBackup's root password or SSH key authentication configured

## Setup

### Step 1 — Generate a dedicated SSH key on the UCG

SSH into your UCG and generate a new ed25519 keypair specifically for this
purpose. Using a dedicated key limits the blast radius if the key is ever
compromised.

```bash
ssh-keygen -t ed25519 -f /etc/ipv6-policy-routes/u5g-backup-key -N ""
```

This creates:
- `/etc/ipv6-policy-routes/u5g-backup-key` — private key (stays on UCG)
- `/etc/ipv6-policy-routes/u5g-backup-key.pub` — public key (goes to U5GBackup)

Display the public key:

```bash
cat /etc/ipv6-policy-routes/u5g-backup-key.pub
```

### Step 2 — Add the public key to the U5GBackup

In the UniFi UI, go to **UniFi Devices → Device Updates and Settings** (left
bar, bottom) → **Device SSH Settings** (right bar, bottom) → **SSH Keys** and
paste the contents of `u5g-backup-key.pub`.

Verify it works:

```bash
ssh -i /etc/ipv6-policy-routes/u5g-backup-key \
    -o StrictHostKeyChecking=no root@<U5GBACKUP_IP> "echo ok"
```

### Step 3 — Deploy the fix script to the U5GBackup

Copy `patch-u5g-ipv6.sh` to the U5GBackup's persistent storage:

```bash
scp -i /etc/ipv6-policy-routes/u5g-backup-key \
    -O patch-u5g-ipv6.sh \
    root@<U5GBACKUP_IP>:/etc/persistent/patch-u5g-ipv6.sh
```

> **Note:** The `-O` flag forces legacy SCP protocol, required for U5GBackup
> compatibility.

The `/etc/persistent/` directory survives reboots and firmware upgrades on
the U5GBackup.

### Step 4 — Deploy the trigger script to the UCG

Copy `trigger-u5g-patch.sh` to the UCG and edit the configuration variables
at the top:

```bash
# On your local machine:
scp trigger-u5g-patch.sh root@<UCG_IP>:/etc/ipv6-policy-routes/trigger-u5g-patch.sh

# On the UCG:
chmod +x /etc/ipv6-policy-routes/trigger-u5g-patch.sh
```

Edit `/etc/ipv6-policy-routes/trigger-u5g-patch.sh` and set:
- `U5GBACKUP_IP` — LAN IP address of your U5GBackup
- `SSH_KEY` — path to the private key (default is fine if you used Step 1)

### Step 5 — Add the cron job on the UCG

On the UCG, add a crontab entry to run the trigger script every minute:

```bash
crontab -e
```

Add this line:

```
* * * * * /etc/ipv6-policy-routes/trigger-u5g-patch.sh
```

### Step 6 — Survive firmware upgrades on the UCG

UCG firmware upgrades wipe the crontab. Create a systemd service to restore
it automatically on every boot:

```bash
cat > /etc/systemd/system/restore-u5g-crontab.service << 'EOF'
[Unit]
Description=Restore U5G patch crontab entry after firmware upgrade
After=cron.service
Requires=cron.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'crontab -l 2>/dev/null | grep -q trigger-u5g-patch || \
    (crontab -l 2>/dev/null; echo "* * * * * /etc/ipv6-policy-routes/trigger-u5g-patch.sh") | crontab -'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable restore-u5g-crontab.service
```

> **Note:** If you are also following the
> [ucg-ipv6-failover](../ucg-ipv6-failover/approach-1-att-primary/) guide,
> skip this step — the `restore-crontab.service` and `restore-crontab.sh`
> from that guide already manage both crontab entries.

## Verify It Works

After a minute, check that the fix has been applied on the U5GBackup:

```bash
ssh -i /etc/ipv6-policy-routes/u5g-backup-key root@<U5GBACKUP_IP> "
    echo '=== gre1 addresses ==='
    ip -6 addr show dev gre1
    echo '=== blackhole routes (should be empty) ==='
    ip -6 route show table 3 | grep blackhole
    echo '=== odhcpd running ==='
    pgrep odhcpd && echo yes || echo no
"
```

You should see:
- A `/64` global address on `gre1` (not a `/128`)
- `gre1` has the `MULTICAST` flag
- No blackhole routes in table 3
- `odhcpd` running

On the UCG, you should see `gre1` autoconfigure a SLAAC GUA:

```bash
ip -6 addr show dev gre1 | grep 'scope global'
```

## File Layout

```
/etc/persistent/
└── patch-u5g-ipv6.sh          ← on U5GBackup, survives reboots

/etc/ipv6-policy-routes/       ← on UCG, survives firmware upgrades
├── u5g-backup-key             ← SSH private key (UCG → U5GBackup)
├── u5g-backup-key.pub         ← SSH public key (add to U5GBackup via UI)
└── trigger-u5g-patch.sh       ← called by cron every minute

/etc/systemd/system/
└── restore-crontab.service    ← on UCG, restores crontab after firmware upgrade
```

## Notes

- The fix is idempotent — running it when nothing needs fixing is a no-op
- The cellular IPv6 prefix rotates on every U5GBackup reconnect; the script
  handles this automatically by re-deriving the prefix each run
- `/etc/persistent/` on the U5GBackup is committed with `cfgmtd -w -p /etc/`
  automatically by the firmware — no extra step needed
- The `/etc/ipv6-policy-routes/` directory on the UCG survives firmware upgrades
  because it is under `/etc/` on the Debian-based UniFi OS

## What Ubiquiti Needs to Fix

This entire workaround exists because of three bugs in a single firmware script:
`activate_mbb_network_inet_interface.sh` on the U5G Backup. The fixes are
trivial — two lines changed and one line commented out. Once Ubiquiti ships
these changes, this script becomes unnecessary.

**Bug 1: Wrong address type assigned to `gre1` in failover mode**

The script assigns `$ipv6_ui_address` (a `/128` host address) to `gre1`.
On a point-to-point interface a `/128` creates no subnet, so `odhcpd` finds
nothing to advertise. It should assign `$ipv6_ui_prefix` (the `/64`) instead:

```sh
# Change this:
ip -6 addr add "$ipv6_ui_address" dev "$INT_IF"
# To this (in the failover block only):
ip -6 addr add "$ipv6_ui_prefix" dev "$INT_IF"
```

**Bug 2: `IFF_MULTICAST` not set on `gre1`**

`odhcpd` requires the multicast flag on an interface before it will send
Router Advertisements on it. GRE interfaces don't have it by default:

```sh
# Add this line before odhcpd starts:
ip link set "$TUN_IF" multicast on
```

**Bug 3: Blackhole route drops all forwarded IPv6 traffic**

The script adds a blackhole route in table 3 that silently drops all IPv6
traffic arriving on `gre1` from the parent gateway. It exists to prevent
routing loops in primary internet mode but must not be added in failover mode:

```sh
# Comment out or remove this line in the failover block:
# ip -6 route add table 3 blackhole $ipv6_ui_prefix metric 100500
```

These three changes are the complete fix. Everything else — `odhcpd`, the
routing tables, the policy rules — is already correctly configured by the
firmware. The parent gateway (UCG) also needs a minor update to accept RAs
on `gre1` and add a fallback IPv6 default route via the tunnel, but that
is straightforward once the U5G Backup is advertising correctly.

A detailed write-up including logs and verification output has been posted
to the [Ubiquiti Community forum](https://community.ui.com/questions/Feature-Request-Fix-IPv6-failover-on-UniFi-5G-Backup/c14612e6-a774-4f41-9f99-621b26e80219).

## Next Step

With the U5GBackup correctly advertising IPv6 on `gre1`, the UCG can now
autoconfigure a SLAAC GUA and use it for IPv6 failover. See the
[ucg-ipv6-failover](../ucg-ipv6-failover/) guide for the gateway-side
implementation.
