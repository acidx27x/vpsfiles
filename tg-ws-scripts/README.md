# TG WS Proxy server bundle

This bundle runs [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) on a Debian or Ubuntu VPS using the upstream Dockerfile. Although upstream presents tg-ws-proxy mainly as a local desktop proxy, its console listener can bind to public VPS addresses. Telegram clients then use the VPS address, port, and generated MTProto secret.

The setup is suitable for a company VPS in Russia when the provider permits it and the host can reach Telegram, GitHub, Docker's apt repository, and Docker Hub. Docker changes packaging and lifecycle management; it does not itself bypass provider filtering or change applicable policy or law.

## Architecture

The installer creates one Compose project with an IPv4 container and, when configured, an IPv6 container:

```text
Telegram clients
  ├─ IPv4 VPS:1443 -> tg-ws proxy IPv4 container ─┐
  └─ optional IPv6 VPS:1443 -> IPv6 container ────┴─ WSS -> Telegram DC
                                                        ├─ optional restricted Cloudflare Worker
                                                        └─ direct TCP fallback
```

The configured containers use the same 32-hex secret and upstream DC configuration. They use host networking so UFW remains responsible for the public port; Docker bridge-published ports can otherwise bypass ordinary UFW rules. The upstream public CfProxy pool is explicitly disabled with `--no-cfproxy`.

FakeTLS, Nginx, Xray, and shared port `443` are not part of this setup. Your existing Xray proxy is left untouched. Adding FakeTLS later would require a separate port-443 routing design and is not needed for this standalone port `1443` deployment.

## Requirements

- Debian or Ubuntu with systemd.
- Root access.
- Public IPv4; a global IPv6 address assigned to the VPS is optional.
- TCP port `1443` available on each configured address family.
- Outbound HTTPS access to GitHub, `download.docker.com`, Docker Hub, Cloudflare when a Worker is used, and Telegram.

Docker Engine and Compose v2 are reused when already healthy. If Docker is completely absent, the shared [`core/docker.sh`](../core/docker.sh) helper installs Docker CE from Docker's official signed apt repository. Partial or broken Docker installations are not replaced automatically; repair them first using the guidance in [`core/README.md`](../core/README.md).

## Install

```bash
cd tg-ws-scripts
sudo ./install.sh
```

The installer asks for:

- Public IPv4 and optional IPv6 addresses. Leave IPv6 blank on an IPv4-only VPS.
- The domain or IP Telegram clients should use. The detected IPv4 is the default.
- Public TCP port, default `1443`.
- Optional `*.workers.dev` Cloudflare Worker domain.

For unattended values, pass `TG_WS_PROXY_PUBLIC_IPV4`, `TG_WS_PROXY_PUBLIC_HOST`, `TG_WS_PROXY_PORT`, and optionally `TG_WS_PROXY_IPV6` and `TG_WS_PROXY_CF_WORKER` through `sudo`. Use `sudo TG_WS_PROXY_VERSION=v1.8.1 ./install.sh` to install a specific stable release instead of resolving `latest`.

Installation builds the selected immutable release locally as `vpsfiles/tg-ws-proxy:<version>`. It does not run an image published by an unrelated registry account. The generated client link is printed and stored root-only in `/etc/tg-ws-proxy/client.txt`.

## Use and inspect

Enter the printed `tg://proxy` link in Telegram, or add an MTProto proxy manually with the configured server, port, and the secret from `/etc/tg-ws-proxy/.env`.

```bash
sudo docker compose \
  --project-directory /etc/tg-ws-proxy \
  --project-name tg-ws-proxy \
  ps

sudo docker compose \
  --project-directory /etc/tg-ws-proxy \
  --project-name tg-ws-proxy \
  logs -f
```

The containers use `restart: unless-stopped`, read-only filesystems, no Linux capabilities, `no-new-privileges`, and bounded Docker log rotation. Secrets in `/etc/tg-ws-proxy/.env` are readable by root and Docker administrators; the installer does not add users to the `docker` group.

## Optional Cloudflare Worker

The installer always writes `/etc/tg-ws-proxy/cf-worker.js`. It is based on upstream's Worker but closes its open-relay behavior by allowing only:

- Requests whose `CF-Connecting-IP` equals this VPS's public IPv4 or its configured IPv6.
- tg-ws-proxy's six fixed Telegram fallback DC addresses.
- TCP destination port `443`.

To use it:

1. In Cloudflare, create a Worker and replace its code with `/etc/tg-ws-proxy/cf-worker.js`.
2. Deploy it and copy its `*.workers.dev` hostname without `https://` or a path.
3. Put that hostname in `TG_WS_PROXY_CF_WORKER` in `/etc/tg-ws-proxy/.env`.
4. Validate and recreate the project:

```bash
sudo docker compose --project-directory /etc/tg-ws-proxy --project-name tg-ws-proxy config --quiet
sudo docker compose --project-directory /etc/tg-ws-proxy --project-name tg-ws-proxy up -d --force-recreate
```

The Worker is optional. Without it, tg-ws-proxy first attempts its normal Telegram WebSocket path and ultimately uses direct TCP fallback. `CfProxy.md` setup is not required because this bundle disables the shared CfProxy path.

If the VPS egress IP changes, rerun installation after uninstalling so the rendered Worker's source allowlist is regenerated.

## Update

```bash
cd tg-ws-scripts
sudo ./update.sh
```

The updater resolves the latest stable release, builds and validates a new image, and preserves the endpoint, secret, Worker domain, firewall, and running/stopped state. A failed running update restores the previous environment and containers. Use `sudo TG_WS_PROXY_VERSION=v1.8.1 ./update.sh` to request an explicit release.

Old versioned images are retained for rollback and removed by this bundle's uninstaller unless another container is using them.

## Uninstall

```bash
cd tg-ws-scripts
sudo ./uninstall.sh
```

After confirmation this removes only the `tg-ws-proxy` Compose project, generated configuration and client credentials, its saved UFW rule, update backups, and images labeled by this bundle. Docker Engine, Docker's apt repository, build cache, daemon configuration, and unrelated containers/images remain.
