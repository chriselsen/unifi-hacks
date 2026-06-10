# unifi-hacks

Community guides for extending UniFi gateway functionality beyond what the UI exposes.

## Contents

### [u5g-backup-fix](./u5g-backup-fix/)

Fixes firmware bugs in the UniFi 5G Backup (U5G-US) that prevent IPv6 from
working in failover mode. The fix is a small idempotent script deployed to the
U5GBackup's persistent storage and triggered every minute via SSH from the
parent UCG. **This is a prerequisite for the IPv6 failover implementation below.**

### [ucg-ipv6-failover](./ucg-ipv6-failover/)

IPv6 failover for UniFi Cloud Gateway Ultra (UCG) using the U5G Backup as
secondary WAN. Two approaches are documented:

- **[Approach 1: AT&T-as-primary](./ucg-ipv6-failover/approach-1-att-primary/)** —
  clients use their primary ISP GUA normally; PI prefix is advertised temporarily
  during failover. Works for Windows, Linux, macOS. Android requires WiFi toggle
  to recover.

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
