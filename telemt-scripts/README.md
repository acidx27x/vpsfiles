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

Defaults:

```text
TCP port:            443
Public host:         detected public IPv4, public IPv6, or hostname
TLS masking domain:  www.cloudflare.com
Modes:               secure + Fake-TLS enabled, classic disabled
Global max conn:     10000
Initial clients:     none
```

Changing the TLS masking domain later breaks existing Fake-TLS links, so choose it before creating clients.

`public_host` may be a domain, IPv4 address, or IPv6 address. For IPv6, enter the bare address, for example `2001:db8::10`, not `[2001:db8::10]`; Telemt generates the final `tg://` links from this value.

## Client Commands

After install, the server starts with an empty client list. Create the first client with a generated 32-hex Telemt secret:

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
telemt-<name>-api.json
telemt-<name>-links.txt
telemt-<name>-qrcode.txt
```

Import a link from `telemt-<name>-links.txt` into Telegram. The links are fetched from Telemt's local API at `http://127.0.0.1:9091/v1/users`; the scripts do not hand-build Telemt links.

## Notes

Client names may contain only letters, numbers, dot, underscore, and dash.

The scripts keep generated public host, port, TLS domain, config path, service name, and binary path state in files next to the scripts. The Telemt config remains the source of truth for active clients.

References:

- https://github.com/telemt/telemt
- https://github.com/telemt/telemt/blob/main/docs/Quick_start/QUICK_START_GUIDE.en.md
- https://github.com/telemt/telemt/blob/main/docs/FAQ.en.md
