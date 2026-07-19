# WireGuard VPS Installer and Client Manager

Bash scripts to install a WireGuard VPN server on Debian/Ubuntu VPS, create client configs, and add or remove WireGuard peers.

## Install

Run on a Debian/Ubuntu VPS:

```bash
cd wireguard-scripts
sudo ./install.sh
```

The installer installs WireGuard packages, generates server keys, writes `/etc/wireguard/wg0.conf`, enables IPv4 and IPv6 forwarding, opens the WireGuard UDP port with UFW, and starts `wg-quick@wg0`.

## Update

```bash
sudo ./update.sh
```

This validates the existing server configuration, then upgrades WireGuard packages without rerunning the installer or changing server configuration, keys, clients, endpoints, UFW, or sysctl state. The configuration is validated again after the package update. If `wg-quick@<saved-interface>` was active, it is restarted and verified; an inactive service remains stopped.

APT package versions and dependency changes cannot be automatically downgraded after a failure. Create a provider snapshot before updating when full VPS rollback is required.

By default the tunnel is dual-stack:

```text
IPv4 subnet: 10.8.0.0/24
IPv4 server: 10.8.0.1
IPv6 subnet: fd42:42:42::/64
IPv6 server: fd42:42:42::1
```

## Client Commands

Create a new client with a preshared key, add it to the server config, try to add it to the live `wg0` interface, and write client files:

```bash
sudo ./add-client.sh phone
```

Create a client config that connects to the server's saved public IPv6 endpoint:

```bash
sudo ./add-client.sh --ipv6-endpoint phone
```

Add an already generated client to the server config and live `wg0` interface:

```bash
sudo ./add-peer.sh phone
```

Add an already generated client to the server config only:

```bash
sudo ./add-peer.sh --config-only phone
```

Add an already generated client to the live `wg0` interface only:

```bash
sudo ./add-peer.sh --live-only phone
```

Remove an already generated client from the server config and live `wg0` interface:

```bash
sudo ./remove-peer.sh phone
```

Remove an already generated client from the server config only:

```bash
sudo ./remove-peer.sh --config-only phone
```

Remove an already generated client from the live `wg0` interface only:

```bash
sudo ./remove-peer.sh --live-only phone
```

Remove a generated client completely: live peer, server config peer block, `/etc/hosts` entry, and client directory:

```bash
sudo ./remove-client.sh phone
```

Remove WireGuard data created by this script bundle:

```bash
sudo ./uninstall.sh
```

`uninstall.sh` stops and disables `wg-quick@wg0`, removes the generated server config and keys, removes generated client files while keeping `clients/.gitkeep`, removes generated `/etc/hosts` client entries, removes script state files and `install-backups`, and tries to remove the saved UFW UDP allow rule. It does not uninstall apt packages.

## Client Setup

Use the generated `clients/<name>/wg0-<name>.conf` file on the client device.

Install WireGuard on the client first. On modern Debian/Ubuntu systems:

```bash
sudo apt update
sudo apt install wireguard
```

Then copy the generated config to the client WireGuard directory:

```bash
sudo install -m 600 wg0-<name>.conf /etc/wireguard/wg0.conf
```

Start the client tunnel:

```bash
sudo wg-quick up wg0
```

Optionally enable it on boot:

```bash
sudo systemctl enable wg-quick@wg0.service
```

By default, generated client configs route all IPv4 and IPv6 traffic through the VPN:

```ini
AllowedIPs = 0.0.0.0/0, ::/0
```

To route only VPN subnet traffic, edit `wg0-client.example.conf` before creating clients.

Generated client directories contain `wg0-<name>.conf`, `<name>.pub`, and `<name>.psk`. The private key is embedded in the generated client config and is not retained as a separate file.

## Notes

Client names may contain only letters, numbers, dot, underscore, and dash.

The server template uses `SaveConfig = false` so the config file remains the source of truth for these scripts.

The scripts keep generated address state in `last-ip.txt` and `last-ip6.txt`, generated endpoint state in `server-endpoint.txt` and `server-endpoint6.txt`, and generated server subnet state in `server-net.txt` and `server-net6.txt`.

This project was influenced by:

- https://www.ckn.io/blog/2017/11/14/wireguard-vpn-typical-setup/
- https://www.wireguard.com/install/
- https://www.wireguard.com/quickstart/
