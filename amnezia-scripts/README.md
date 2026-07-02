# AmneziaWG VPS Installer and Client Manager

Bash scripts to install an AmneziaWG VPN server on Debian/Ubuntu VPS, create client configs, and add or remove AmneziaWG peers.

These scripts are separate from `../wireguard-scripts`. The existing WireGuard scripts remain available and are not replaced by this AmneziaWG script set.

## Install

Run on a Debian/Ubuntu VPS:

```bash
cd amnezia-scripts
sudo ./install.sh
```

The installer installs AmneziaWG packages, generates server keys, writes `/etc/amnezia/amneziawg/awg0.conf`, saves generated obfuscation parameters, enables IPv4 and IPv6 forwarding, opens the AmneziaWG UDP port with UFW, and starts `awg-quick@awg0`.

## Update

```bash
sudo ./update.sh
```

This upgrades the AmneziaWG package without rerunning the installer or changing server configuration, obfuscation settings, keys, clients, endpoints, UFW, or sysctl state. If `awg-quick@<saved-interface>` was active, it is restarted and verified; an inactive service remains stopped.

By default the tunnel is dual-stack:

```text
UDP port:    52820
MTU:         1280
IPv4 subnet: 10.9.0.0/24
IPv4 server: 10.9.0.1
IPv6 subnet: fd52:52:52::/64
IPv6 server: fd52:52:52::1
```

`install.sh` generates one AmneziaWG obfuscation parameter set and saves it in `obfuscation.env`. Future clients reuse the saved values so existing clients do not need redistribution after each new client is created. You can override generated values during install with `AWG_MTU`, `AWG_JC`, `AWG_JMIN`, `AWG_JMAX`, `AWG_S1`, `AWG_S2`, `AWG_S3`, `AWG_S4`, `AWG_H1`, `AWG_H2`, `AWG_H3`, `AWG_H4`, and `AWG_I1`.

For AmneziaWG 2.0, generated `H1`-`H4` values are non-overlapping ranges like `123-456`. The range is written directly into server and client configs; AmneziaWG chooses values from that range at runtime.

## Client Commands

Create a new client with a preshared key, add it to the server config, try to add it to the live `awg0` interface, and write client files:

```bash
sudo ./add-client.sh phone
```

Create a client and also print live AmneziaWG output:

```bash
sudo ./add-client.sh --verbose phone
```

Create a client config that connects to the server's saved public IPv6 endpoint:

```bash
sudo ./add-client.sh --ipv6-endpoint phone
```

Add an already generated client back to the server config:

```bash
sudo ./add-peer.sh phone
```

Add an already generated client to the live `awg0` interface only:

```bash
sudo ./add-peer.sh --live-only phone
```

Remove an already generated client from the server config:

```bash
sudo ./remove-peer.sh phone
```

Remove an already generated client from the live `awg0` interface only:

```bash
sudo ./remove-peer.sh --live-only phone
```

Remove a generated client completely: live peer, server config peer block, `/etc/hosts` entry, and client directory:

```bash
sudo ./remove-client.sh phone
```

Remove AmneziaWG data created by this script bundle:

```bash
sudo ./uninstall.sh
```

`uninstall.sh` stops and disables `awg-quick@awg0`, removes the generated server config and keys, removes generated client files while keeping `clients/.gitkeep`, removes script state files and `install-backups`, and tries to remove the saved UFW UDP allow rule. It does not uninstall apt packages and does not remove normal WireGuard files.

## Client Setup

Use the generated `clients/<name>/awg0-<name>.conf` file on the client device.

Install AmneziaWG tools on the client first. The generated config uses native AmneziaWG fields and should be imported into an AmneziaWG-capable client, not a plain WireGuard-only client.

Start the client tunnel with AmneziaWG tooling when available:

```bash
sudo awg-quick up awg0
```

Optionally enable it on boot:

```bash
sudo systemctl enable awg-quick@awg0.service
```

By default, generated client configs route all IPv4 and IPv6 traffic through the VPN:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

To route only VPN subnet traffic, edit `awg0-client.example.conf` before creating clients.

Generated clients include a preshared key. The client template includes `PresharedKey`, and `add-peer.sh` requires `clients/<name>/<name>.psk` before adding the peer to the server config or live interface. Existing clients without a `.psk` are not backfilled; recreate them with `add-client.sh`.

Generated client directories contain `awg0-<name>.conf`, `<name>.pub`, and `<name>.psk`. The private key is embedded in the generated client config and is not retained as a separate file.

## Notes

Client names may contain only letters, numbers, dot, underscore, and dash.

The server template uses `SaveConfig = false` so the config file remains the source of truth for these scripts.

The scripts keep generated address state in `last-ip.txt` and `last-ip6.txt`, generated endpoint state in `server-endpoint.txt` and `server-endpoint6.txt`, generated server subnet state in `server-net.txt` and `server-net6.txt`, and generated AmneziaWG obfuscation state in `obfuscation.env`.

The peer scripts read the saved interface name from `server-interface.txt` and fall back to `awg0`.

Official AmneziaWG references:

- https://docs.amnezia.org/documentation/amnezia-wg/
- https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
- https://github.com/amnezia-vpn/amneziawg-tools
- https://github.com/amnezia-vpn/amneziawg-go
