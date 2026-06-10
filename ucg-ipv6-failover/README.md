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
- A Provider Independent (PI) IPv6 `/48` block from your RIR
  (ARIN, RIPE, APNIC, etc.) — the first `/64` is used here

## Approaches

Two approaches are documented. Choose based on your requirements:

| | Approach 1: AT&T-as-primary | Approach 2: PI-as-primary |
|---|---|---|
| **Client GUA** | Primary ISP GUA normally; PI GUA during failover | PI GUA always |
| **Normal operation** | Direct routing via ISP | NPTv6: PI ↔ ISP |
| **Failover** | SNAT to cellular GUA | NAT66: PI → cellular GUA |
| **Internet sees** | ISP GUA normally; cellular during failover | ISP GUA normally; cellular during failover |
| **Android** | Requires WiFi toggle to recover ⚠️ | Fully transparent ✓ |
| **Complexity** | Lower | Higher |
| **Status** | ✅ Implemented | 🚧 Architecture documented |

### [Approach 1: AT&T-as-primary](./approach-1-att-primary/)

Clients use their primary ISP GUA during normal operation. When the primary
WAN fails, a PI prefix is temporarily advertised on the LAN with a short
lifetime (300s). Both the ISP GUA and PI GUA route via the cellular backup
using SNAT. On recovery, the PI prefix is deprecated and expires naturally
within ~5 minutes.

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

## Background: Why Policy Routing is Needed

The UCG's Traffic Routes UI generates IPv4-only `iptables` rules. The
corresponding `ip6tables` rules for IPv6 policy routing must be added
manually. The UCG uses fwmark-based routing with named tables:

| Table | Interface | Purpose |
|-------|-----------|---------|
| `201.eth4.0` | Primary WAN | AT&T / fiber |
| `178.gre1` | GRE tunnel | Cellular via U5G Backup |

Client traffic is directed to a table by matching source prefix in
`UBIOS_PREROUTING_PBR`. The scripts in this guide add the IPv6 equivalents
of the rules the UI creates for IPv4.

## License

MIT — see [LICENSE](../LICENSE)
