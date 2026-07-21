# Networking & firewall

## Ports (UDP)

| Port | Purpose |
|---|---|
| Game port (`-port=` in the systemd unit; `2301` as shipped) | DayZ client connections |
| Steam query port (`steamQueryPort` in `serverDZ.cfg`) | Server browser / A2S queries |

LAN-only play needs no router forwarding at all — clients direct-connect to the LAN IP.
An internet-facing host needs both opened:

```bash
sudo ufw allow 2301/udp
sudo ufw allow 27016/udp
```

Adjust the numbers to whatever you actually set in `serverDZ.cfg` / the systemd unit if
you change them from the shipped defaults.

## Don't host behind a VPN

A VPN with a kill-switch firewall blocks direct inbound joins, and most consumer VPN
providers only forward a single, randomly-numbered port — DayZ needs two fixed ports
(game + query), so there's usually no way to make both land where the client expects.
Host on a connection without a VPN; LAN play needs no forwarding in the first place.

## If you're behind an edge/DDoS firewall in front of the host (e.g. OVH)

Some hosting providers put a stateless packet filter *upstream* of the VPS itself, ahead
of the host's own `ufw`/`nftables`. It's worth configuring **in addition to** the host
firewall, not instead of it — it drops denied traffic before it ever reaches the VPS
NIC/CPU. The host firewall stays as the stateful correctness net.

Three properties tend to shape these edge filters generally (confirm the specifics
against your provider's docs):

- **Stateless** — it doesn't track connections, so a blanket "deny all" also blocks
  *replies* to connections the VPS itself initiated (apt, steamcmd, DNS, NTP). Those need
  explicit allow rules for the relevant reply traffic.
- **Inbound-only** — rules apply to traffic *to* the VPS; outbound is untouched.
- **Default-allow with a rule budget** — unmatched traffic passes by default, so a final
  "deny all" is mandatory, and the rule count is usually capped (an edge filter like this
  is a coarse DDoS front line, not a per-service firewall — collapse many services behind
  a reverse proxy on one port rather than adding a rule per service).

### The source-port trap

**This is the one that actually breaks things in practice.** On an inbound service rule
(game port, query port, HTTPS, etc.), leave the **source port** field blank. Real clients
— the Steam browser, NAT'd players, any A2S prober — connect from random ephemeral source
ports, not a fixed one. A rule that matches on source port as well as destination port
will silently drop all of them, while looking completely correct in the rule list.

Source port only belongs on *reply* rules for the VPS's own outbound traffic (e.g.
admitting DNS/NTP replies back in) — never on a rule admitting inbound connections to
your services.

- Match on **destination port** → inbound to your services (game, query, HTTPS).
- Match on **source port** → replies to *your own* outbound requests only.

If your server is listed in the browser but nobody can join, and everything else looks
right, check this first — an A2S probe from an ephemeral source port getting no reply
while a probe forced to a fixed source port succeeds is the fingerprint of this exact bug.

### Game-aware DDoS mitigation

Some providers offer a second, separate firewall layer that isn't an allow/deny list at
all — it tags specific UDP ports as "game traffic" so the provider's anti-DDoS scrubber
applies mitigation profiles tuned for bursty real-time UDP instead of generically
rate-limiting it. If your provider offers this, tag your game and query ports (and any
voice-chat ports, e.g. Mumble) — generic UDP mitigation can otherwise rate-limit or drop
legitimate game traffic under load. Don't tag TCP web ports here; game-mode mitigation is
UDP-oriented and can false-positive on web traffic.

## Baseline host firewall

Whatever edge filtering you do or don't have, keep a stateful host-level firewall as the
correctness layer:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <your-admin-IP> to any port 22 proto tcp   # SSH — restrict to your own IP
sudo ufw allow 2301/udp                                        # DayZ game port
sudo ufw allow 27016/udp                                       # Steam query port
sudo ufw enable
```
