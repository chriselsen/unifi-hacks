# unifi-hacks

Community guides for extending UniFi gateway functionality beyond what the UI exposes.

## IPv6 Failover Is Not Optional

Multi-WAN failover that works for IPv4 but silently drops IPv6 is not
"partial support" — it is broken. Here's why.

### IPv6 is no longer optional infrastructure

IPv6 is not a future technology. It is the present:

- Mobile carriers (T-Mobile, AT&T, Verizon, and virtually every carrier
  globally) run IPv6 as their **primary** protocol. IPv4 on mobile networks
  is provided via carrier-grade NAT (CGNAT) with 464XLAT translation — IPv4
  is the compatibility layer, not the native path.
- Content delivery networks (Google, Meta, Cloudflare, Akamai) serve the
  majority of their traffic over IPv6. IPv6 paths are typically faster, with
  lower latency and fewer NAT-induced connection failures.
- An increasing number of services, APIs, and IoT platforms are IPv6-only
  or advertise IPv6 as the preferred endpoint.

When your failover WAN is a cellular link (as with the U5G Backup), it is
almost certainly carrying IPv6 natively. Ignoring IPv6 failover means that
your "backup" connection is working at reduced capacity from the moment it
activates.

### IPv4-only failover leaves half your network broken

A gateway that fails over IPv4 but not IPv6 produces the worst of all
outcomes: IPv6-capable applications try IPv6 first, fail silently, and
then fall back to IPv4 — adding latency and connection setup time to every
request. Users see degraded performance and unexplained timeouts, not a
clear failure they can diagnose. The network appears to be "working" while
actually being broken.

### Why this is genuinely hard without BGP

The correct enterprise solution to multi-homing and failover is BGP: announce
your own Provider Independent (PI) prefix via multiple upstream providers, and
let BGP routing converge when one path fails. This is how large organizations
handle it and it is completely transparent to clients.

BGP is not realistic for consumer or SMB setups:

- Requires a PI address block from a Regional Internet Registry (ARIN, RIPE, etc.)
- Requires BGP sessions with one or more ISPs — not offered on residential or
  most business-class connections
- Requires routing hardware and operational expertise beyond typical SMB budgets

Without BGP, every approach to IPv6 multi-homing involves a tradeoff:
clients either see a prefix change (disruptive), or address translation is
applied at the border (NAT66/NPTv6, which breaks end-to-end transparency).
There is no clean solution at the consumer/SMB level — only less-bad ones.

The guides in this repo represent the current best achievable outcomes given
these constraints, implemented on top of UniFi hardware that should be doing
this natively. The feature requests included here describe what Ubiquiti needs
to implement so that none of this manual configuration is necessary.

## Contents

### [u5g-backup-fix](./u5g-backup-fix/)

Fixes firmware bugs in the UniFi 5G Backup (U5G-US) that prevent IPv6 from
working in failover mode. The fix is a small idempotent script deployed to the
U5GBackup's persistent storage and triggered every minute via SSH from the
parent UCG. **This is a prerequisite for the IPv6 failover implementation below.**

### [ucg-ipv6-failover](./ucg-ipv6-failover/)

IPv6 failover for UniFi Cloud Gateway Ultra (UCG) using the U5G Backup as
secondary WAN. Two approaches are documented:

- **[Approach 1: ISP-as-primary](./ucg-ipv6-failover/approach-1-att-primary/)** —
  clients use their primary ISP GUA normally; PI prefix is advertised temporarily
  during failover (necessary because the UCG withdraws the ISP prefix when the
  primary WAN goes down — no userspace workaround exists for this). Works for
  Windows, Linux, macOS. Android requires WiFi toggle to recover.

- **[Approach 2: PI-as-primary](./ucg-ipv6-failover/approach-2-pi-primary/)** —
  clients always use a stable PI GUA; NPTv6 translates to primary ISP normally,
  NAT66 translates to cellular during failover. Fully transparent to all clients
  including Android. *(Architecture documented, implementation in progress.)*

## Prerequisites

- UniFi Cloud Gateway Ultra (UCG) running UniFi OS 4.x / firmware 5.x
- UniFi 5G Backup (U5G-US) adopted in failover mode
- SSH access to both devices
- A Provider Independent (PI) IPv6 /48 block from your RIR (ARIN, RIPE, APNIC)
- The first /64 of your PI block available for use (e.g. `2001:db8:fe::/64`)

> **Note on PI space:** If you do not have PI space, Approach 1 still works
> for the primary failover path but without the extended coverage for new
> clients after the ~1 hour odhcpd lease expiry window. Approach 2 requires
> PI space.

## Background

The UniFi 5G Backup ships with two firmware bugs that prevent IPv6 from
working in failover mode:

1. The `activate_ipv6()` function assigns a `/128` host address to the GRE
   tunnel interface instead of a `/64` prefix, so odhcpd finds no subnet to
   advertise and sends RAs without a Prefix Information Option (PIO).
2. GRE tunnel interfaces lack `IFF_MULTICAST` by default, which odhcpd
   requires before advertising on an interface.

Additionally, a blackhole route drops all IPv6 traffic forwarded via the
GRE tunnel. The `u5g-backup-fix` script corrects all three issues idempotently
on every run.

On the gateway side, the UCG's traffic routing system only generates IPv4
policy routing rules. IPv6 equivalents must be added manually. The
`ucg-ipv6-failover` scripts handle this.

## Related

- [Ubiquiti Community: Feature Request — Fix IPv6 failover on UniFi 5G Backup](https://community.ui.com/questions/Feature-Request-Fix-IPv6-failover-on-UniFi-5G-Backup/c14612e6-a774-4f41-9f99-621b26e80219)

## License

MIT — see [LICENSE](./LICENSE)
