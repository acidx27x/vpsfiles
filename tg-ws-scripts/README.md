# TG WS Proxy server bundle

This bundle runs [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) on a Debian or Ubuntu VPS using the upstream Dockerfile. Although upstream presents tg-ws-proxy mainly as a local desktop proxy, its console listener can bind to public VPS addresses. Telegram clients then use the VPS address, port, and generated MTProto secret.

The setup is suitable for a company VPS in Russia when the provider permits it and the host can reach Telegram, GitHub, Docker's apt repository, and Docker Hub. Docker changes packaging and lifecycle management; it does not itself bypass provider filtering or change applicable policy or law.

## Architecture

The installer creates one Compose project with an IPv4 container and, when configured, an IPv6 container:

```text
Telegram clients (secure `dd` or optional FakeTLS `ee`)
  ├─ IPv4 VPS:1443 -> tg-ws proxy IPv4 container ─┐
  └─ optional IPv6 VPS:1443 -> IPv6 container ────┴─ WSS -> Telegram DC
                                                        ├─ optional restricted Cloudflare Worker
                                                        └─ direct TCP fallback
```

The configured containers use the same 32-hex secret and upstream DC configuration. They use host networking so UFW remains responsible for the public port; Docker bridge-published ports can otherwise bypass ordinary UFW rules. The upstream public CfProxy pool is explicitly disabled with `--no-cfproxy`.

FakeTLS is terminated directly by tg-ws-proxy on its configured public port. It does not make Nginx share that port: for example, tg-ws-proxy can use `example.com:1443` while Xray remains on `example.com:443`. When FakeTLS is enabled, tg-ws-proxy forwards unrecognized TLS handshakes to the masking domain on port `443`; an existing Xray-to-Nginx fallback can handle that traffic without being modified by this bundle.

## Requirements

- Debian or Ubuntu with systemd.
- Root access.
- Public IPv4; a global IPv6 address assigned to the VPS is optional.
- TCP port `1443` available on each configured address family.
- For optional FakeTLS, a DNS-only FQDN whose `A` record points directly to the VPS. Publish an `AAAA` record only when the IPv6 listener is working.
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
- Optional FakeTLS/SNI masking domain. Leave it blank to generate a `dd` link, or enter the VPS domain to generate an `ee` link.
- Optional `*.workers.dev` Cloudflare Worker domain.

For unattended values, pass `TG_WS_PROXY_PUBLIC_IPV4`, `TG_WS_PROXY_PUBLIC_HOST`, `TG_WS_PROXY_PORT`, and optionally `TG_WS_PROXY_IPV6`, `TG_WS_PROXY_FAKE_TLS_DOMAIN`, and `TG_WS_PROXY_CF_WORKER` through `sudo`. Use `sudo TG_WS_PROXY_VERSION=v1.8.1 ./install.sh` to install a specific stable release instead of resolving `latest`.

Installation builds the selected immutable release locally as `vpsfiles/tg-ws-proxy:<version>`. It does not run an image published by an unrelated registry account. The generated client link is printed and stored with mode `0600` in `/etc/tg-ws-proxy/client.txt` and `tg-ws-scripts/tg-ws-link.txt`.

## Use and inspect

Enter the printed `tg://proxy` link in Telegram, use `tg-ws-link.txt`, or add an MTProto proxy manually with the configured server, port, and the secret from `/etc/tg-ws-proxy/.env`.

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

## Optional FakeTLS

Use the same DNS-only domain for the public Telegram endpoint and the FakeTLS masking domain to keep Xray on public port `443` while tg-ws-proxy listens separately on `1443`:

```text
Telegram -> example.com:1443 -> tg-ws-proxy FakeTLS (ee)
Probe    -> example.com:1443 -> example.com:443 -> existing Xray/Nginx fallback
```

The installer hex-encodes the lowercase masking domain into the generated `ee` secret. Cloudflare orange-cloud proxying does not forward this arbitrary TCP service; use a DNS-only record. A stale or unreachable `AAAA` record can make LTE clients wait for IPv6 to fail before trying IPv4.

FakeTLS mode does not accept the old `dd` link on the same listener. This bundle supports selecting the mode during a fresh installation; uninstall and reinstall tg-ws-proxy to switch modes, then replace the old Telegram link with the newly exported one. Xray, Nginx, and their port `443` configuration remain untouched.

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

Validate the deployed Worker from the VPS. The request must originate from the configured VPS address because the generated Worker rejects every other source:

```bash
worker_domain="$(sed -n 's/^TG_WS_PROXY_CF_WORKER=//p' /etc/tg-ws-proxy/.env)"
test -n "${worker_domain}"
curl -4 -i "https://${worker_domain}/"
```

A correctly deployed Worker returns HTTP `426` with `Expected websocket`. HTTP `403` means the Worker does not recognize the VPS source address; a Cloudflare `404` usually means the hostname or deployment is wrong.

Confirm that tg-ws-proxy loaded the Worker domain:

```bash
sudo docker compose \
  --project-directory /etc/tg-ws-proxy \
  --project-name tg-ws-proxy \
  logs --tail 100 \
  | grep -F 'CF worker: enabled'
```

The Worker is a fallback after the normal Telegram WebSocket route, so a working proxy may not contact it during every connection. To observe actual fallback use, follow the logs while reconnecting Telegram:

```bash
sudo docker compose \
  --project-directory /etc/tg-ws-proxy \
  --project-name tg-ws-proxy \
  logs -f \
  | grep --line-buffered -E 'trying CF worker|CF worker pool hit|CF worker .* failed|stats:'
```

`trying CF worker` or `CF worker pool hit` confirms that a Telegram connection selected the Worker path. A later `stats:` line with `cf=` greater than zero confirms a successful Worker WebSocket connection; this bundle disables the separate shared CF-proxy path, so only the configured Worker contributes to that counter. `CF worker ... failed` reports a failed Worker WebSocket connection. No Worker line and `cf=0` mean the preferred direct WebSocket route remained healthy; they do not mean the Worker deployment is broken.

The Worker is optional. Without it, tg-ws-proxy first attempts its normal Telegram WebSocket path and ultimately uses direct TCP fallback. `CfProxy.md` setup is not required because this bundle disables the shared CfProxy path.

If the VPS egress IP changes, rerun installation after uninstalling so the rendered Worker's source allowlist is regenerated.

## Update

```bash
cd tg-ws-scripts
sudo ./update.sh
```

The updater resolves the latest stable release, builds and validates a new image, and preserves the endpoint, secret, FakeTLS domain, Worker domain, firewall, and running/stopped state. A failed running update restores the previous environment and containers. Use `sudo TG_WS_PROXY_VERSION=v1.8.1 ./update.sh` to request an explicit release.

Old versioned images are retained for rollback and removed by this bundle's uninstaller unless another container is using them.

## Uninstall

```bash
cd tg-ws-scripts
sudo ./uninstall.sh
```

After confirmation this removes only the `tg-ws-proxy` Compose project, generated configuration and client credentials, its saved UFW rule, update backups, and images labeled by this bundle. Docker Engine, Docker's apt repository, build cache, daemon configuration, and unrelated containers/images remain.
