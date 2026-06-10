# UCG IPv6 Failover via U5G Backup

IPv6 policy routing for the UniFi Cloud Gateway Ultra (UCG) using the
UniFi 5G Backup as a secondary WAN. Clients retain IPv6 connectivity
during primary WAN outages.

## Prerequisites

- UCG running UniFi OS 4.x / firmware 5.x
- U5G Backup adopted in failover mode with the
  [u5g-backup-fix](../u5g-backup-fix/) applied
- SSH access to the UCG
- `radvd` installable via `apt` (cached deb included for post-upgrade survival)
- At minimum a `/64` from a Provider Independent (PI) IPv6 block
  from your RIR (ARIN, RIPE, APNIC, etc.)

## Approaches

Two approaches are documented. Choose based on your requirements:

| | Approach 1: ISP-as-primary | Approach 2: PI-as-primary |
|---|---|---|
| **Client GUA** | Primary ISP GUA normally; PI GUA during failover | PI GUA always |
| **Normal operation** | Direct routing via ISP | NPTv6: PI ↔ ISP |
| **Failover** | SNAT to cellular GUA | NAT66: PI → cellular GUA |
| **Internet sees** | ISP GUA normally; cellular during failover | ISP GUA normally; cellular during failover |
| **Android** | Requires WiFi toggle to recover ⚠️ | Fully transparent ✓ |
| **Complexity** | Lower | Higher |
| **Status** | ✅ Implemented and tested | 🚧 Architecture documented |

### [Approach 1: ISP-as-primary](./approach-1-att-primary/)

Clients use their primary ISP GUA during normal operation. When the primary
WAN fails, a PI prefix is temporarily advertised on the LAN with a short
lifetime (300s). Both the ISP GUA and PI GUA route via the cellular backup
using SNAT. On recovery, the PI prefix is deprecated and expires naturally
within ~5 minutes.

**Why PI space is needed:** When the primary WAN goes down, the UCG's
`odhcpd` immediately withdraws the primary ISP prefix from its Router
Advertisements — clients lose their ISP GUA. There is no way to prevent
this from userspace without Ubiquiti fixing this behavior (see
[this Ubiquiti feature request](https://community.ui.com/questions/Feature-Request-Fix-IPv6-failover-on-UniFi-5G-Backup/c14612e6-a774-4f41-9f99-621b26e80219)).
The PI prefix fills this gap: since PI space is independent of any ISP,
`radvd` can advertise it during failover regardless of WAN state, giving
clients a working GUA for the duration of the outage.

**Limitation:** Android loses its IPv6 default gateway during failover and
requires a WiFi toggle to recover. This is an Android OS limitation — it does
not send RS on router loss and ignores unsolicited RAs. Windows 11, Linux,
and macOS recover automatically.

### [Approach 2: PI-as-primary](./approach-2-pi-primary/)

Clients always use a stable PI GUA. The UCG uses NPTv6 to translate PI ↔
primary ISP prefix during normal operation, and NAT66 to translate PI →
cellular GUA during failover. Clients never see a prefix change — the failover
is fully transparent including to Android.

**Status:** Architecture documented, implementation in progress.

## What Ubiquiti Needs to Fix

Both approaches in this guide exist as workarounds for missing or broken
functionality in UniFi OS. The following changes would make all of these
scripts unnecessary:

**1. Keep the primary ISP prefix alive during WAN outage**

When the primary WAN goes down, `odhcpd` immediately withdraws the ISP
DHCPv6-PD prefix from Router Advertisements. Clients lose their IPv6 GUA
before the UCG has a chance to reroute traffic via the backup WAN.

The fix: retain the last known prefix in `odhcpd` for the duration of the
outage, exactly as the UCG already honors IPv4 DHCP leases locally when the
WAN is down. The UCG already has the prefix in memory — it simply needs to
keep advertising it until the primary WAN returns. Combined with the existing
metric-based failover routing, this would make failover fully transparent to
all clients including Android, with no custom scripts required.

**2. Add IPv6 rules to Traffic Routes**

The Traffic Routes UI generates IPv4-only `iptables` rules. The identical
logic for IPv6 (`ip6tables` rules in `UBIOS_PREROUTING_PBR` matching source
IPv6 address) is never created. Every setup that uses Traffic Routes to
route a VLAN via a backup WAN must manually add IPv6 equivalents via SSH.

The fix: when a Traffic Route is saved, generate the corresponding `ip6tables`
rules alongside the existing `iptables` rules. The UCG already knows each
client's IPv6 addresses from neighbor discovery.

**3. NAT66 / NPTv6 support in the UI**

IPv6 address translation (NAT66 for many-to-one, NPTv6 for stateless 1:1)
is available in the UCG kernel but not exposed in the UI. Multi-WAN IPv6
failover fundamentally requires translation at the WAN border since the
backup ISP provides a different prefix than the primary.

The fix: expose NAT66 SNAT and NPTv6 as options in the WAN failover
configuration, applied automatically when a backup WAN becomes active.

**4. Suppress ISP prefix RA during failover (alternative to item 1 above)**

If retaining the prefix during outage is not feasible, an alternative is
to give user scripts an API hook to suppress or override `odhcpd`'s RA
advertisement on specific interfaces. This would allow custom failover
scripts to substitute a stable prefix (e.g. PI space) without fighting
the firmware's own RA management.

All four items have been submitted as feature requests to the
[Ubiquiti Community forum](https://community.ui.com/questions/Feature-Request-Fix-IPv6-failover-on-UniFi-5G-Backup/c14612e6-a774-4f41-9f99-621b26e80219).

## Background: Why Policy Routing is Needed

The UCG's Traffic Routes UI generates IPv4-only `iptables` rules. The
corresponding `ip6tables` rules for IPv6 policy routing must be added
manually. The UCG uses fwmark-based routing with named tables:

| Table | Interface | Purpose |
|-------|-----------|---------|
| `201.eth4.0` | Primary WAN | primary ISP (fiber, cable, etc.) |
| `178.gre1` | GRE tunnel | Cellular via U5G Backup |

Client traffic is directed to a table by matching source prefix in
`UBIOS_PREROUTING_PBR`. The scripts in this guide add the IPv6 equivalents
of the rules the UI creates for IPv4.

## License

MIT — see [LICENSE](../LICENSE)
