# Xray VLESS REALITY VPS Installer and Client Manager

Bash scripts to install and manage an Xray VLESS + REALITY + Vision server on a Debian/Ubuntu VPS.

These scripts are separate from `../wireguard-scripts` and `../amnezia-scripts`. They do not replace or modify either bundle.

## Install

Run on a Debian/Ubuntu VPS:

```bash
cd xray-scripts
sudo ./install.sh
```

The installer uses the official XTLS Xray install script, writes `/usr/local/etc/xray/config.json`, enables BBR-related sysctl settings, opens the Xray TCP port with UFW, validates the generated config, and starts `xray`.

## Update

```bash
sudo ./update.sh
```

This uses the official Xray updater without rerunning this bundle's installer or changing server configuration, REALITY identity, clients, endpoints, UFW, or sysctl state. It validates the current config with the updated binary. If the service was active, the updater restarts and verifies it, restoring the prior binary if validation or startup fails.

The installed server config starts with an empty VLESS client list. It still contains one generated unused REALITY server shortId because Xray requires `realitySettings.shortIds` to be a non-empty list.

Defaults:

```text
TCP port:       443
Protocol:       VLESS
Flow:           xtls-rprx-vision
Transport:      raw
Security:       reality
Target:         www.firefox.com:443
Server name:    www.firefox.com
Fingerprint:    firefox
Initial clients: none
```

## Client Commands

After install, the server starts with an empty client list. Create the first client with a unique UUID and REALITY shortId, add it to the server config, and write a VLESS share URI:

```bash
sudo ./add-client.sh phone
```

Create a client config that connects to the server's saved public IPv6 endpoint:

```bash
sudo ./add-client.sh --ipv6-endpoint phone
```

Remove a generated client from the server config and delete its generated files:

```bash
sudo ./remove-client.sh phone
```

Remove Xray data created by this script bundle:

```bash
sudo ./uninstall.sh
```

`uninstall.sh` stops and disables `xray`, removes the generated config, removes generated client files while keeping `clients/.gitkeep`, removes script state files and `install-backups`, removes the Xray BBR sysctl file, and tries to remove the saved UFW TCP allow rule. It does not uninstall Xray packages or binaries.

## Client Setup

Generated client files are written to `clients/<name>/`:

```text
<name>.uuid
<name>.short-id
vless-<name>.txt
```

Import `vless-<name>.txt` into a VLESS-capable client.

The generated share link uses:

```text
type=raw
security=reality
encryption=none
flow=xtls-rprx-vision
fp=firefox
```

## Notes

Client names may contain only letters, numbers, dot, underscore, and dash.

The scripts keep generated endpoint, IPv6 endpoint, port, server shortId, SNI, and REALITY key state in files next to the scripts. The server config remains the source of truth for active clients.

References:

- https://xtls.github.io/en/config/inbounds/vless.html
- https://xtls.github.io/en/config/transports/reality.html
- https://xtls.github.io/en/config/transports/raw.html
- https://github.com/XTLS/Xray-install
- https://github.com/XTLS/Xray-examples/tree/main/VLESS-TCP-XTLS-Vision-REALITY
