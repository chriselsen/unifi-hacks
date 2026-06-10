# Approach 2: PI-as-Primary IPv6 Failover

> **Status: Architecture documented. Implementation in progress.**
>
> The implementation for Approach 1 is complete and working. This document
> describes the target architecture for Approach 2. Implementation will follow.

## Why Approach 2?

Approach 1 has one significant limitation: **Android** loses its IPv6 default
gateway during failover and requires a WiFi toggle to recover. This is a
fundamental Android OS limitation:

- Android does not send a Router Solicitation when it detects router loss
- Android does not reliably add a new default router from unsolicited RAs
  when already in a "no router" state from the same source address
- All network-side workarounds have been exhausted: separate router
  link-local identity, SIGHUP on radvd recovery, multiple RS on failover,
  PI prefix deprecation on recovery — none fully resolve the issue without
  a WiFi toggle

Approach 2 eliminates this limitation entirely by ensuring clients never
experience a prefix or router change during failover.

## Architecture

Clients always use a stable PI GUA (examples use `2001:db8:fe::/64` —
replace with your actual PI /64). The UCG handles
translation at the WAN border:

```
Normal operation (primary WAN up):
  LAN client (PI GUA 2001:db8:fe::xxx)
    → UCG NPTv6: 2001:db8:fe::/64 ↔ <ISP /64>
    → primary ISP WAN
    → internet sees ISP GUA

Failover (primary WAN down):
  LAN client (PI GUA 2001:db8:fe::xxx)  ← same address, nothing changed
    → UCG NAT66: SNAT → cellular GUA
    → gre1 → U5GBackup → cellular WAN
    → internet sees cellular GUA
```

**During failover, clients see no change whatsoever.** The same PI GUA,
the same default router, the same DNS. Only the border
translation changes. Android, Windows, Linux, macOS — all transparent.

## What the Internet Sees

The PI prefix never appears on the public internet:

| State | Internet sees | Clients see |
|-------|---------------|-------------|
| Normal | ISP GUA (via NPTv6) | PI GUA (stable) |
| Failover | Cellular GUA (via NAT66) | PI GUA (unchanged) |

Geolocation, CDN optimization, and ISP-based filtering all see real ISP
addresses — identical to the current setup.

## Prerequisites

Everything from Approach 1, plus:

- **Suppress primary ISP RA on LAN** via UniFi UI.
  Go to Settings → Networks → [your LAN network] → IPv6 and disable RA
  advertisement for the primary ISP prefix. The UCG will instead advertise
  only the PI prefix via radvd.
- **NPTv6 kernel module** — `ip6t_NPT` is available on UCG firmware 5.x
  (confirmed working). No additional installation needed.

## Comparison with Approach 1

| | Approach 1 | Approach 2 |
|---|---|---|
| Client GUA during normal operation | Primary ISP GUA | PI GUA |
| Client GUA during failover | PI GUA (temporary) | PI GUA (always) |
| Android recovery | WiFi toggle required ⚠️ | Automatic ✓ |
| Normal operation overhead | None | NPTv6 (stateless, near-zero) |
| Primary ISP prefix rotation handling | Automatic | NPTv6 rule rebuild needed |
| Complexity | Lower | Higher |

## Implementation Plan

### On the UCG

1. **Suppress primary ISP RA** via UniFi UI (Settings → Networks → IPv6)
2. **radvd on LAN** — permanently advertise PI prefix on br0 (not just during
   failover as in Approach 1)
3. **NPTv6 rule** — stateless 1:1 translation:
   ```
   ip6tables -t nat -A POSTROUTING -s 2001:db8:fe::/64 -o <WAN_IF> \
       -j NETMAP --to <ISP /64>
   ip6tables -t nat -A PREROUTING -d <ISP /64> -i <WAN_IF> \
       -j NETMAP --to 2001:db8:fe::/64
   ```
4. **Failover switch** — when primary WAN goes down, remove NPTv6 rules
   and activate NAT66 SNAT to cellular GUA (same as Approach 1)
5. **Recovery switch** — when primary WAN returns, remove NAT66 and
   restore NPTv6 rules

### Watchdog considerations

- NPTv6 rule must be rebuilt when the primary ISP rotates its DHCPv6-PD
  prefix (detectable via `ip monitor` watching for br0 prefix changes)
- The NPTv6 ↔ NAT66 transition must be atomic to avoid double-translation:
  remove old rule before adding new one
- UCG-originated traffic needs explicit routing rules since NPTv6 only
  handles forwarded traffic

## Known Limitations

Approach 2 fully solves the Android default gateway issue and works well
for all clients. However, it still requires custom scripts and PI address
space.

The cleanest long-term solution would be for Ubiquiti to fix the root cause:
when the primary WAN goes down, the UCG should keep advertising the primary
ISP prefix to LAN clients rather than immediately withdrawing it. If that
behavior were fixed, the primary ISP GUA would remain valid throughout the
outage, the UCG would silently reroute traffic via the backup WAN, and
clients — including Android — would never notice the failover at all.
Neither Approach 1 nor Approach 2 would be necessary.

This has been requested on the
[Ubiquiti Community forum](https://community.ui.com/questions/Feature-Request-Fix-IPv6-failover-on-UniFi-5G-Backup/c14612e6-a774-4f41-9f99-621b26e80219).
