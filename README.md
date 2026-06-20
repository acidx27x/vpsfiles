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

Shared implementation lives in `lib/`. When changing repeated behavior such as validation, state-file reads, endpoint formatting, safe removal, UFW/service handling, WireGuard-family peer editing, Xray JSON mutation, or Telemt TOML mutation, update the shared helper first instead of copying changes between protocol folders.
