# VPS Script Bundles

This repository contains standalone Debian/Ubuntu VPS script bundles for:

- `wireguard-scripts`
- `amnezia-scripts`
- `xray-scripts`
- `telemt-scripts`

Each bundle keeps its existing public commands, for example:

```bash
cd wireguard-scripts
sudo ./install.sh
sudo ./add-client.sh phone
sudo ./remove-client.sh phone
```

Protocol-neutral implementation lives in `core/`. Protocol behavior lives beside each executable bundle: WireGuard helpers are shared from `wireguard-scripts/`, and AmneziaWG adds its obfuscation-specific behavior from `amnezia-scripts/`. Xray and Telemt helpers stay in their own script directories.

## Runtime Updates

Each installed bundle can update its own runtime without rerunning `install.sh`:

```bash
cd wireguard-scripts && sudo ./update.sh
cd amnezia-scripts && sudo ./update.sh
cd xray-scripts && sudo ./update.sh
cd telemt-scripts && sudo ./update.sh
```

Updates upgrade only packages required by the selected bundle, preserve server configuration, keys, clients, endpoints, firewall rules, and sysctl state, and restart the service only when it was already active. Xray and Telemt restore their previous binary if the updated binary cannot validate or restart. Set `TELEMT_VERSION=<version>` before Telemt's updater to use a specific release; the default is `latest`.

New client creation keeps only the artifacts required for use and management. Existing client directories are never removed or compacted automatically.

## Verification

```bash
make test
```
