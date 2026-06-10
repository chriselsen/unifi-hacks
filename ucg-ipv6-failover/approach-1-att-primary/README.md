# Approach 1: ISP-as-Primary IPv6 Failover

Clients use their primary ISP GUA during normal operation. A PI prefix is
advertised temporarily during failover. All other OSes except Android recover
automatically.

## How It Works

```
Normal operation:
  br0 client (ISP GUA 2600:x::/64)
    → iif br0 → table 201.eth4.0
    → primary ISP WAN

Failover (primary WAN down):
  br0 client (ISP GUA or PI GUA 2001:db8:fe::/64)
    → iif br0 → table 201.eth4.0 → gre1 fallback (metric 2048)
    → SNAT to cellular GUA
    → GRE tunnel → U5GBackup → cellular WAN

br<N> client (cellular GUA via radvd):
  → fwmark 0x6b0000 → table 178.gre1
  → GRE tunnel → U5GBackup → cellular WAN (native, no NAT)
```

During failover, `gre1-prefix-monitor` detects the loss of the primary WAN
default route from table 201 and adds a PI prefix block to radvd on br0.
Clients acquire a PI GUA alongside their ISP GUA. Both route via gre1 SNAT.
On recovery, the PI prefix is deprecated (`preferred_lft 0`) so clients prefer
their ISP GUA again, then the block is removed and addresses expire within ~5min.

## Configuration

Edit the variables at the top of each script before deploying:

| Variable | Description | Example |
|----------|-------------|---------|
| `UCG_IP` | UCG LAN IP | `192.168.1.1` |
| `U5GBACKUP_IP` | U5GBackup LAN IP | `192.168.1.218` |
| `VLAN_ID` | VLAN for cellular clients | `100` |
| `VLAN_SUBNET` | Subnet for cellular VLAN | `192.168.100.0/24` |
| `PI_PREFIX` | Your PI /64 | `2001:db8:fe::/64` |
| `BR_WAN` | UCG WAN interface | `eth4.0` |
| `BR_LAN` | UCG primary LAN bridge | `br0` |
| `BR_CELLULAR` | UCG cellular VLAN bridge | `br100` |

## Setup

### Step 1 — Install radvd

On the UCG:

```bash
apt update && apt install -y radvd
```

Cache the package for post-firmware-upgrade survival:

```bash
mkdir -p /etc/ipv6-policy-routes/packages
cp /var/cache/apt/archives/radvd_*.deb /etc/ipv6-policy-routes/packages/
```

### Step 2 — Deploy scripts to UCG

```bash
# From your local machine
scp setup-ipv6-policy-routes.sh \
    gre1-prefix-monitor.sh \
    ipv6-watchdog.sh \
    restore-crontab.sh \
    root@<UCG_IP>:/etc/ipv6-policy-routes/

# On the UCG
chmod +x /etc/ipv6-policy-routes/*.sh
cp /etc/ipv6-policy-routes/setup-ipv6-policy-routes.sh \
   /etc/ipv6-policy-routes/setup.sh
```

### Step 3 — Deploy systemd services to UCG

```bash
scp systemd/*.service root@<UCG_IP>:/etc/systemd/system/
ssh root@<UCG_IP> "systemctl daemon-reload && \
    systemctl enable --now ipv6-policy-routes.service \
    gre1-prefix-monitor.service \
    reinstall-radvd.service \
    restore-crontab.service"
```

### Step 4 — Apply initial configuration

```bash
ssh root@<UCG_IP> "sh /etc/ipv6-policy-routes/setup.sh"
```

### Step 5 — Add crontab entry on UCG

```bash
ssh root@<UCG_IP> "crontab -e"
```

Add:
```
* * * * * /etc/ipv6-policy-routes/ipv6-watchdog.sh
```

### Step 6 — Configure UniFi UI

In the UniFi UI, create a Traffic Route that sends VLAN `VLAN_ID` traffic via
the U5G Backup. This creates the IPv4 fwmark rules; the scripts add the IPv6
equivalents automatically.

## Verify

```bash
ssh root@<UCG_IP> "
    echo '=== gre1 SLAAC address ==='
    ip -6 addr show dev gre1 scope global

    echo '=== table 201 (should have primary ISP metric 512 + gre1 metric 2048) ==='
    ip -6 route show table 201.eth4.0

    echo '=== SNAT rule ==='
    ip6tables -t nat -S POSTROUTING | grep SNAT

    echo '=== MSS clamping ==='
    ip6tables -t mangle -L FORWARD -nv | grep TCPMSS

    echo '=== radvd running ==='
    systemctl is-active radvd
"
```

## File Layout

```
/etc/ipv6-policy-routes/       ← survives UCG firmware upgrades
├── setup.sh                   ← ip6tables, ipsets, routing rules (run on boot)
├── gre1-prefix-monitor.sh     ← watches gre1, updates radvd, handles failover
├── ipv6-watchdog.sh           ← cron: re-applies rules if missing
├── restore-crontab.sh         ← restores crontab entries on boot
└── packages/
    └── radvd_*_arm64.deb      ← cached for post-upgrade reinstall

/etc/systemd/system/
├── ipv6-policy-routes.service ← runs setup.sh on boot
├── gre1-prefix-monitor.service← runs gre1-prefix-monitor.sh as daemon
├── reinstall-radvd.service    ← reinstalls radvd if wiped by firmware upgrade
└── restore-crontab.service    ← restores crontab on boot

/etc/radvd.conf                ← managed by gre1-prefix-monitor
```

## Known Limitations

**Android** loses its IPv6 default gateway during failover and requires a
WiFi toggle to recover. This is an Android OS limitation — it does not send
a Router Solicitation when it detects router loss and does not reliably add
a new default router from unsolicited RAs. All other major operating systems
(Windows 11, Linux, macOS) recover automatically within seconds.

If Android support is required, see
[Approach 2: PI-as-primary](../approach-2-pi-primary/).
