# VPS Script Bundles

This repository contains standalone Debian/Ubuntu VPS script bundles for:

- `wireguard-scripts`
- `amnezia-scripts`
- `xray-scripts`
- `telemt-scripts`
- `nginx-scripts` (standalone HTTPS fallback site for Xray REALITY)
- `tg-ws-scripts` (Docker-based TG WS Proxy with IPv4/IPv6 listeners)
- `system-scripts` (bounded logs, safe cleanup, zram, and host package updates)

Each bundle keeps its existing public commands, for example:

```bash
cd wireguard-scripts
sudo ./install.sh
sudo ./add-client.sh phone
sudo ./remove-client.sh phone
```

The standalone Nginx fallback installer is run separately from Xray:

```bash
cd nginx-scripts
sudo ./install.sh
sudo ./uninstall.sh
```

It creates a real HTTPS site on an internal listener and prints the target and SNI values to enter in `xray-scripts/install.sh`. Its standalone uninstaller removes the fallback and safely handles the dedicated certificate without coupling cleanup to Xray.

The standalone host maintenance installer is also independent of the protocol bundles:

```bash
cd system-scripts
sudo ./install.sh
```

It derives bounded journal and coredump limits from the VPS resources, schedules safe daily cleanup, enables log rotation, and configures compressed zram swap when supported. See `system-scripts/README.md` for managed paths and behavior.

When Xray is installed with an optional next-hop URI, routing is selected per client:

```bash
cd xray-scripts
sudo ./add-client.sh phone
sudo ./add-client.sh --next-hop tablet
sudo ./set-client-route.sh --next-hop phone
```

Direct routing remains the default. See `xray-scripts/README.md` for mixed direct and next-hop setup details.

The entry VPS can optionally route Russian IPs, Russian TLDs, and known Russian government domains directly while sending the remaining traffic from next-hop clients through the exit VPS. Its geodata refreshes every Friday at 04:30 in the entry VPS's local timezone.

Xray can also expose an optional SOCKS5 listener on `127.0.0.1` and route it through its VLESS next hop. Telemt on the same entry VPS can use that listener to build `Telegram -> Telemt/Xray entry VPS -> Xray exit VPS -> Telegram DC`. See the Xray and Telemt bundle READMEs for the VPS2-first workflow.

Protocol-neutral implementation lives in `core/`. Protocol behavior lives beside each executable bundle: WireGuard helpers are shared from `wireguard-scripts/`, and AmneziaWG adds its obfuscation-specific behavior from `amnezia-scripts/`. Xray and Telemt helpers stay in their own script directories.

Shared Docker Engine and Compose installation helpers live in `core/docker.sh`. See `core/README.md` for the reusable contract, security rules, and an example for future container-based bundles. The tg-ws bundle uses this layer without converting any existing service to Docker:

```bash
cd tg-ws-scripts
sudo ./install.sh
```

It builds a pinned upstream tg-ws-proxy release locally and runs separate host-network IPv4 and IPv6 containers on port `1443` by default. See `tg-ws-scripts/README.md` for prerequisites, Telegram connection details, optional restricted Cloudflare Worker setup, and the reasons FakeTLS/CfProxy/Xray are not combined in this deployment.

## Runtime Updates

Each installed bundle can update its own runtime without rerunning `install.sh`:

```bash
cd wireguard-scripts && sudo ./update.sh
cd amnezia-scripts && sudo ./update.sh
cd xray-scripts && sudo ./update.sh
cd telemt-scripts && sudo ./update.sh
cd tg-ws-scripts && sudo ./update.sh
cd system-scripts && sudo ./update.sh
```

Protocol updates change only runtime components required by the selected bundle, preserve server configuration, keys, clients, endpoints, firewall rules, and sysctl state, and restart a service only when it was already active. Xray and Telemt automatically restore their previous runtime artifacts after a failed update and report successful rollback only after an originally active service is healthy again. TG WS Proxy builds a versioned image and automatically restores the previous Compose environment, image, and running/stopped container state if cutover fails. Set `TELEMT_VERSION=<version>` or `TG_WS_PROXY_VERSION=<version>` before the corresponding updater to request a specific release; the default is `latest`.

WireGuard and AmneziaWG updates are APT-managed, and their current configuration is validated before and after the package update. All APT package versions and dependency changes—including prerequisite packages upgraded by Xray or Telemt—remain installed after a later failure and cannot be automatically downgraded. The system updater has the same rollback boundary: it uses APT's non-removing upgrade mode, clears downloaded package archives, reports held packages and required reboots, and never reboots automatically. Create a provider snapshot before any APT update when full VPS rollback is required.

New client creation keeps only the artifacts required for use and management. Existing client directories are never removed or compacted automatically.

## Verification

```bash
make test
```
