# The PairDesk relay

Normally the phone connects straight to the computer: on the same Wi-Fi, or
through Tailscale. When neither works (the computer is at a friend's house,
behind someone else's router), both sides can meet at a **relay** instead.

The relay is a small program on a server with a public address. It only
joins two connections together:

1. PairDesk on the computer keeps one connection open to the relay and
   registers under an id (a hash of a secret only that computer knows).
2. A phone asks the relay for that id. The relay tells the computer, the
   computer opens a second connection, and the relay joins it to the phone's.
3. The phone then talks TLS to the computer exactly as on Wi-Fi, checking
   the computer's certificate against the fingerprint it got when pairing.

So the relay sees only encrypted bytes, how many, and the two IP addresses.
It can't read the screen, keys or files, and it can't pretend to be the
computer: the phone would refuse the certificate. It stores nothing on disk;
its log (systemd's journal) only has "computer online / offline" and "phone
joined" lines with the IP address and the first characters of the id.

The phone tries direct addresses first and uses the relay only if they
don't answer within about a second and a half.

## What's needed

- A Linux server with a public IPv4 address, x64 or arm64. The relay uses
  very little memory and CPU; the screen picture passes through it, so
  bandwidth is what matters (roughly 1–4 Mbit/s per person watching a screen).
  - **Oracle Cloud "Always Free"**: an Ampere (arm64) VM is enough, and its
    free outbound allowance is large. Check Oracle's current free-tier terms.
  - Or any small VPS (Hetzner, DigitalOcean, Vultr, Linode and so on).
- A DNS name for it. PairDesk uses `relay.pairdesk.madhushan.me:443` by
  default; anyone can enter their own relay in the computer's settings.
- Ports **443** and **47900** open for TCP. 443 gets through most office
  and hotel firewalls; 47900 is the relay's own port.

## Set it up (systemd)

On the server, as root:

```sh
curl -fsSL https://raw.githubusercontent.com/sandunMadhushan/pairdesk/main/packaging/relay/install.sh | sh
```

This downloads `pairdesk-relay-linux-x64` or `-arm64` from the latest
release to `/usr/local/bin`, installs
[`pairdesk-relay.service`](../packaging/relay/pairdesk-relay.service) and
starts it, listening on 443 and 47900. It runs as an unprivileged dynamic
user with only the right to use port 443.

Then open the ports:

- **Server firewall.** Ubuntu: `ufw allow 443/tcp && ufw allow 47900/tcp`.
  Oracle's Ubuntu images also have iptables rules; add
  `iptables -I INPUT 6 -p tcp -m multiport --dports 443,47900 -j ACCEPT`
  and save with `netfilter-persistent save`.
- **Cloud firewall.** Oracle: the subnet's *Security List* → add ingress
  rules for TCP 443 and 47900 from `0.0.0.0/0`. Other providers have a
  similar "firewall" page.

Check from your own computer: `nc -vz <server-ip> 443` should say
"succeeded". `journalctl -u pairdesk-relay -f` shows the relay's log.

Updating later: run the same install command again.

## Or with Docker

From a copy of this repository:

```sh
docker build -f packaging/relay/Dockerfile -t pairdesk-relay .
docker run -d --name pairdesk-relay --restart=always -p 443:47900 -p 47900:47900 pairdesk-relay
```

## DNS

Add an **A record** for `relay.pairdesk` (in the `madhushan.me` zone)
pointing at the server's public IPv4 address. If the domain's DNS is on
Cloudflare, set the record to **DNS only** (grey cloud): Cloudflare's proxy
only passes web traffic, not the relay's.

Within a minute, every PairDesk computer with **Use the relay** on (the
default) connects to it; the PairDesk window shows a green dot under
*Remote access → PairDesk relay*.

## Using your own relay

On the computer: **Remote access → PairDesk relay → Relay server**, enter
`host:port` and save. Phones learn the new route the next time they
connect, and every new pairing link carries it.

## Limits

- At most 64 open connections per IP address; extra ones are refused.
- A connection that sends nothing for 90 seconds is closed (both sides
  ping every 25 seconds).
- Running `pairdesk-relay --listen ADDRESS:PORT` (repeatable) picks the
  ports; `RUST_LOG=debug` shows more detail.

The wire format is in [PROTOCOL.md](PROTOCOL.md#relay).
