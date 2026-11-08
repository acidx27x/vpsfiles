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

## WEB through an existing REALITY fallback

WEB is opt-in. It adds HTTPS ingress under `/telegram/web/` while preserving the
native MTProxy port, access secrets and per-user unique-IP limits. No Xray
installer is rerun and no REALITY client credentials are regenerated.

Prerequisites: Python 3.11+, Linux `flock` (util-linux), Telemt 3.5.16 or later,
active Telemt/Xray/Nginx services, and this bundle's existing two-server Nginx
fallback site. The HTTPS server must be last in the managed site. REALITY must
already target its loopback HTTPS listener and use the matching certificate
hostname. The public IPv4 in Xray installer state must resolve from that hostname.
External target/SNI migration is deliberately unsupported. A single unscoped,
enabled SOCKS5 upstream must point to Xray's loopback `local-socks` inbound, whose
route must lead exclusively to the VLESS `next-hop`. Rules that block traffic are
allowed before that route; possible direct or ambiguous routing is rejected.

First update Telemt separately, and verify the existing native connection:

```bash
# Run as root on the VPS, from this repository.
TELEMT_VERSION=3.5.16 ./telemt-scripts/update.sh
./telemt-scripts/web.sh status
./telemt-scripts/web.sh enable
./telemt-scripts/web.sh status
```

These are operator deployment commands: `enable` changes service configurations
and restarts services. Expect a brief interruption during activation. `status`
only inspects settings and health; it does not create backups or change services.
`enable` reads installed configs and state, checks DNS and the certificate, and
refuses conflicting settings. Running it again on a healthy matching installation
does not restart services.

The defaults are private HTTP `127.0.0.1:18080`, fixed carrier `https`, base path
`telegram/web`, and one `dd` profile for every access user. The public address is
the installed Xray endpoint with port 443. The decoy is a bounded copy of the
fallback's regular `index.html` in `/var/lib/telemt/public`; other site assets,
configuration and symlink targets are not copied.

Activation enables PROXY protocol on the REALITY fallback and Nginx listener.
Nginx trusts only loopback for PROXY headers and overwrites X-Forwarded-For with
one resolved client IP. The WEB listener trusts only its immediate loopback
proxy. The whole subtree is forwarded without a URI rewrite; the exact no-slash
path returns 404 without a redirect. WEB access logs, proxy buffering, cache and
upstream retries are disabled. The normal site and ACME remain in place.

New clients automatically receive WEB profiles and `web:` links in the existing
link files. Removal updates access and profiles together. Path links encode the
host/path and the binary secret according to Telemt's WEB contract; users API
links continue to supply the native variants.

```bash
./telemt-scripts/web.sh disable
```

Disable removes the managed WEB listener, profiles, Nginx locations and WEB links
from the current installation. It preserves later client additions, HTTPS, and
the synchronized REALITY/Nginx PROXY protocol settings. Nginx reinstall preserves
the PROXY protocol state. Telemt uninstall disables managed WEB first; dependent
Nginx or Xray removal requires WEB to be disabled. Fresh Telemt installation can
opt into the same command with `TELEMT_ENABLE_WEB=1`, after preparing the other
services.

Each mutation keeps a private numbered backup under `install-backups/web-*`, with
a path manifest and previous service state. Failures restore that operation's
files and verify services, Telemt readiness and HTTPS where applicable. If recovery
also fails, the command explicitly reports both failures and the backup directory.
Failure messages identify the activation stage and a credential-free error
summary, also saved in `failure.json`. Captured subprocess output, when available,
is saved separately in private `command-output.log`; review it locally and do not
share it unredacted. Rollback stops Telemt before restoring a configuration with
different WEB listener inventory. Public HTTPS checks tolerate a bounded startup
delay after Xray's systemd unit becomes active; invalid HTTP/decoy responses still
fail immediately.
APT package changes during a separate binary update are outside this rollback.
WEB-aware binary updates check runtime readiness before accepting the update.

Before distributing links, verify with a compatible Telegram build: native and
WEB connections, normal HTTPS, `/telegram/web`, `/telegram/web/`, unknown paths,
and an invalid bridge query. Test two external client IPs and a forged XFF header.
Verify the observed exit is the NL server. Test an unavailable next hop in an
isolated Linux environment: Telegram traffic must fail, never exit directly from
Russia. A listening SOCKS port and unit tests alone do not establish this.
