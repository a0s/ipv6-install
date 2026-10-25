# ipv6-auto-install

![Lint](https://github.com/a0s/ipv6-auto-install/workflows/Lint/badge.svg)

**A bash script that gives a Mac IPv6 on networks that don't have it.**

When your Mac joins Wi-Fi without IPv6 (a café, a hotel, most offices), ipv6-auto brings up a
WireGuard tunnel to an IPv6 tunnel broker. When you join a network with native IPv6, the tunnel
goes down and you use the native one. You never have to touch it.

Inspired by [openvpn-install](https://github.com/angristan/openvpn-install) and
[wireguard-install](https://github.com/angristan/wireguard-install).

## Requirements

- macOS 13 or later (tested on macOS 26 Tahoe, Apple Silicon)
- [Homebrew](https://brew.sh). The installer adds `bash` and `wireguard-tools` if they are missing
- A WireGuard config that gives you IPv6. [Route64](https://manager.route64.org) hands them out
  for free: Tunnel Management > Add tunnel > IPv6 Tunnelbroker > pick the closest PoP >
  WireGuard, then Raw Config > Download .conf. Your own VPS with IPv6 works too.

## Usage

```bash
curl -O https://raw.githubusercontent.com/a0s/ipv6-auto-install/master/ipv6-auto-install.sh
sudo bash ipv6-auto-install.sh
```

It asks where the config is and how you want IPv6 used, installs a LaunchDaemon and runs a
self-test at the end. Run it again to see status, run the self-test, swap the config or remove
everything. `sudo bash ipv6-auto-install.sh --uninstall` removes it without the menu.

With Homebrew:

```bash
brew install a0s/ipv6-auto/ipv6-auto
sudo ipv6-auto-install
```

After that:

```bash
sudo ipv6-auto status
sudo ipv6-auto selftest
tail -f /var/log/ipv6-auto.log
```

## How it behaves

The daemon sleeps until macOS reports a network change, plus one sanity check every five
minutes, so it costs nothing on battery. It waits a few seconds after you connect, because
routers often announce IPv6 a moment after IPv4. If a network claims IPv6 but it doesn't work,
the tunnel comes back and that network is ignored for 30 minutes. While another system VPN is
connected (a WireGuard.app tunnel, say), the tunnel steps aside. During dark wake (Power Nap)
and while the network is still coming up, it changes nothing.

WireGuard runs over UDP, so it works behind NAT and CGNAT. 6in4 from Hurricane Electric needs
protocol 41 and a pingable public IP, which you won't get in a café.

## The macOS part

A plain `wg-quick` tunnel with `::/0` isn't enough. macOS only asks DNS for AAAA records when
there is a primary IPv6 service, and a utun interface isn't one, so apps never see IPv6
addresses. If you make the tunnel primary, macOS hands it IPv4 and DNS as well and your IPv4
default route disappears. WireGuard.app with `::/0` does the same thing.

ipv6-auto publishes its own service in SystemConfiguration. The IPv6 part points at the tunnel
and the IPv4, DNS and proxy parts are copies of your real network, refreshed on every change.
macOS sees one service with IPv4 through your router and IPv6 through the tunnel.

This relies on undocumented behavior, so there is a fuse. Every time the service is published,
the daemon checks that IPv4 still goes through the real interface. If it doesn't, it rolls back
within two seconds, stops trying on that macOS build and shows a notification. After each macOS
update the self-test runs on its own and tells you the result.

If you'd rather not touch SystemConfiguration, pick mode 2 in the installer. The tunnel still
comes up, but apps only use it for IPv6-only hosts.

## Caveats

Sites that have both IPv4 and IPv6 will go through the tunnel PoP, so pick one close to where
you usually are. Networks that block all UDP except 53 and 443 block WireGuard too.

## Contributing

```bash
git config core.hooksPath .githooks
```

The hook runs [shellcheck](https://github.com/koalaman/shellcheck) and
[shfmt](https://github.com/mvdan/sh) on staged scripts. CI runs the same checks. Please open an
issue first if you want to discuss a larger change.

## Credits & Licence

This project is under the [MIT Licence](https://raw.githubusercontent.com/a0s/ipv6-auto-install/master/LICENSE)
