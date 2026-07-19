# Telemt MTProxy VPS Installer and Client Manager

Bash scripts to install and manage a Telemt MTProxy server on a Debian/Ubuntu VPS.

These scripts are separate from `../wireguard-scripts`, `../amnezia-scripts`, and `../xray-scripts`. They do not replace or modify those bundles.

## Install

Run on a Debian/Ubuntu VPS:

```bash
cd telemt-scripts
sudo ./install.sh
```

The installer downloads the official Telemt release binary, writes `/etc/telemt/telemt.toml`, creates a `telemt` systemd service, opens the Telemt TCP port with UFW, and starts `telemt`.

The optional local SOCKS5 prompt accepts the loopback port exposed by `../xray-scripts/install.sh` on the same VPS. Leave it empty for the existing direct-to-Telegram behavior.

## Update

```bash
sudo ./update.sh
sudo TELEMT_VERSION=v1.2.3 ./update.sh
```

The updater replaces only the Telemt binary and its required packages. It preserves the TOML configuration, TLS-front data, clients, endpoints, systemd unit, UFW, and sysctl state. If binary replacement or startup fails, automatic rollback restores the prior binary and verifies that an originally active service is healthy. An originally inactive service remains stopped. If restoration or service recovery fails, the updater reports that both the update and rollback failed instead of claiming restoration. Required packages upgraded through APT are outside this application rollback and are not automatically downgraded.

Defaults:

```text
TCP port:            10443
Public host:         detected public IPv4, public IPv6, or hostname
TLS masking domain:  www.google.com
Modes:               secure + Fake-TLS enabled, classic disabled
Global max conn:     1000
Initial client:      main
Outbound:            direct by default; optional local SOCKS5 upstream
```

Changing the TLS masking domain later breaks existing Fake-TLS links, so choose it before creating clients.

`public_host` may be a domain, IPv4 address, or IPv6 address. For IPv6, enter the bare address, for example `2001:db8::10`, not `[2001:db8::10]`; Telemt generates the final `tg://` links from this value.

The installer creates one initial client because Telemt refuses to start with an empty `[access.users]` table. The initial client name defaults to `main` and can be overridden during install.

## Optional Two-Hop Xray Setup

Install Xray on the exit VPS first, add a VLESS client for the entry VPS, and copy its generated URI:

```bash
cd xray-scripts
sudo ./install.sh
# Leave the next-hop URI and local SOCKS5 port empty.
sudo ./add-client.sh telemt-vps1
cat clients/telemt-vps1/vless-telemt-vps1.txt
```

On the entry VPS, install Xray, paste that URI at the next-hop prompt, and enter an unused local SOCKS5 port such as `1080`. Then install Telemt on the same entry VPS and enter `1080` at `Local Xray SOCKS5 port (leave empty for direct)`:

```bash
cd xray-scripts
sudo ./install.sh

cd ../telemt-scripts
sudo ./install.sh
```

Telemt verifies that `127.0.0.1:1080` is accepting TCP connections before making installation changes, then appends:

```toml
[[upstreams]]
type = "socks5"
address = "127.0.0.1:1080"
weight = 1
enabled = true
```

The SOCKS5 listener has no authentication and is reachable only over loopback. Xray routes it exclusively through the VLESS next hop, so Telemt does not fall back to a direct exit if VPS2 is unavailable. The template's `use_middle_proxy = false` setting remains unchanged.

For unattended Telemt installation, pass `TELEMT_LOCAL_SOCKS_PORT`, for example `sudo TELEMT_LOCAL_SOCKS_PORT=1080 ./install.sh`. Telemt `update.sh` preserves the generated configuration.

## Client Commands

Create another client with a generated 32-hex Telemt secret:

```bash
sudo ./add-client.sh phone
```

The script asks for the maximum simultaneous unique IPs for that client. This is written to Telemt's `[access.user_max_unique_ips]` table.

Remove a generated client from the Telemt config and delete its generated files:

```bash
sudo ./remove-client.sh phone
```

Remove Telemt data created by this script bundle:

```bash
sudo ./uninstall.sh
```

`uninstall.sh` stops and disables `telemt`, removes the generated config, service, drop-in, binary, data directories, generated client files while keeping `clients/.gitkeep`, script state files, `install-backups`, and the saved UFW TCP allow rule. It does not uninstall apt packages or remove the `telemt` system user.

## Client Setup

Generated client files are written to `clients/<name>/`:

```text
<name>.secret
<name>.max-unique-ips
telemt-<name>-links.txt
```

Import a link from `telemt-<name>-links.txt` into Telegram. The links are fetched from Telemt's local API at `http://127.0.0.1:9091/v1/users`; the scripts do not hand-build Telemt links.

## Notes

Client names may contain only letters, numbers, dot, underscore, and dash.

The scripts keep generated public host, port, TLS domain, config path, service name, and binary path state in files next to the scripts. The Telemt config remains the source of truth for active clients.

References:

- https://github.com/telemt/telemt
- https://github.com/telemt/telemt/blob/main/docs/Quick_start/QUICK_START_GUIDE.en.md
- https://github.com/telemt/telemt/blob/main/docs/FAQ.en.md
