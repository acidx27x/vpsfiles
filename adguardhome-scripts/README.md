# AdGuard Home VPS Installer

Bash scripts to install and manage a native AdGuard Home DNS server with a local recursive Unbound backend on a
Debian/Ubuntu VPS:

```text
VPN/Xray -> AdGuard Home 127.0.0.1:53 -> Unbound 127.0.0.1:5335 -> authoritative DNS servers
```

This bundle is standalone: it does not modify WireGuard, AmneziaWG, Xray, UFW, or the VPS's own DNS resolver.

## Install

Run on a Debian/Ubuntu VPS:

```bash
cd adguardhome-scripts
sudo ./install.sh
```

The installer downloads the latest stable official AdGuard Home release by default, verifies the release asset's
SHA-256 digest, installs it under `/opt/AdGuardHome`, and registers the upstream native `AdGuardHome` systemd service.
It also installs the distro packages `unbound`, `dns-root-data`, and `dnsutils`, and configures Unbound to listen only
on `127.0.0.1:5335`. Unbound performs IPv4 recursion directly from the DNS root and validates DNSSEC; there is no
Cloudflare, Google, Quad9, or other forwarding fallback.

Installation stops before making changes if TCP or UDP port `5335` conflicts on loopback, or if an active or custom
Unbound installation already exists. An inactive package-default Unbound installation is accepted. The installer
records the prior Unbound and `unbound-resolvconf` unit states, masks the resolver helper, and temporarily deactivates
its `/etc/resolvconf.conf` integration so it cannot inject a forwarding zone. It never changes `/etc/resolv.conf` or
`systemd-resolved`.
The installation directory and binary are owned by `root` and are not writable by regular users.

To install a specific stable release:

```bash
sudo ADGUARD_HOME_VERSION=v0.107.79 ./install.sh
```

Only exact stable tags in `vX.Y.Z` form are accepted. Beta, edge, branch, and mutable tag names are rejected.

The admin interface is always overridden to listen on `127.0.0.1:3000`; the installer does not open that port.
From your workstation, create an SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 user@your-server
```

Then open <http://127.0.0.1:3000> and complete the AdGuard Home wizard.

After the wizard, open **Settings → DNS settings** and configure the recursive backend:

- **Upstream DNS servers:** remove every existing entry and enter only `127.0.0.1:5335`.
- **Fallback DNS servers:** leave empty.
- **Bootstrap DNS servers:** leave empty; the upstream is already a literal IP address.
- **Private reverse DNS servers:** enter `127.0.0.1:5335`, or disable private reverse DNS resolution.
- Keep AdGuard Home's cache enabled.

Select **Test upstreams**, apply the settings, and then verify resolution through AdGuard Home on port `53`:

```bash
dig @127.0.0.1 -p 53 example.org
```

Do not add a public resolver as a fallback. If recursive resolution fails, inspect Unbound instead:

```bash
sudo unbound-checkconf
sudo systemctl status unbound
dig @127.0.0.1 -p 5335 example.org
dig @127.0.0.1 -p 5335 example.org +tcp
```

## DNS Listener and Clients

This bundle deliberately does not choose DNS listener addresses or firewall policy. In the wizard, select only the
loopback or private VPN address that should accept DNS queries. Do not select **All interfaces** unless you have
separately secured the public resolver.

If AdGuard Home needs to listen on several private addresses, stop it, update `dns.bind_hosts` in
`/opt/AdGuardHome/AdGuardHome.yaml`, and start it again. For example, addresses might include:

```yaml
dns:
  bind_hosts:
    - 127.0.0.1
    - 10.8.0.1
    - fd42:42:42::1
```

Do not edit `AdGuardHome.yaml` while the service is running; AdGuard Home can overwrite live configuration changes.

Point each consumer at one of the configured addresses yourself. For example, set `DNS = 10.8.0.1` in a WireGuard
or AmneziaWG client configuration, or use `127.0.0.1:53` for a same-host service such as Xray after enabling the
loopback DNS listener. Existing client files and templates are never changed by these scripts.

The bundle does not edit `/etc/resolv.conf` or `/etc/systemd/resolved.conf*`. If the wizard offers a
`DNSStubListener` autofix, do not use it when you want the VPS resolver to remain unchanged; choose a non-conflicting
private address instead.

## Use with the Other Bundles

AdGuard Home must listen on the address that a client uses. Keep DNS on loopback
or a private VPN address; do not expose an unrestricted resolver on the VPS's
public address.

| Bundle | AdGuard Home address | Current support |
| --- | --- | --- |
| WireGuard | `10.8.0.1` (default) | Set the client `DNS` field |
| AmneziaWG | `10.9.0.1` (default) | Set the client `DNS` field |
| Xray | `127.0.0.1` | Server-side Xray lookups only |
| Telemt | None | No custom DNS-server setting in this bundle |
| TG WS | None | Telegram DCs are configured as IP addresses |

### WireGuard and AmneziaWG

Add the relevant VPN server address to `dns.bind_hosts` in
`/opt/AdGuardHome/AdGuardHome.yaml`, then restart AdGuard Home. The defaults in
this repository are:

- WireGuard: `10.8.0.1` and `fd42:42:42::1`
- AmneziaWG: `10.9.0.1` and `fd52:52:52::1`

If different addresses were selected during VPN installation, use those values
instead. Then replace the public resolvers in the appropriate client template:

```ini
# wireguard-scripts/wg0-client.example.conf
DNS = 10.8.0.1

# amnezia-scripts/awg0-client.example.conf
DNS = 10.9.0.1
```

New clients generated by `add-client.sh` inherit the template. For an existing
client, change `DNS` in its generated configuration and re-import or restart the
profile. The `DNS` field takes an address without `:53`.

The full-tunnel client templates already route these addresses. For a custom
split-tunnel profile, include the selected DNS address in `AllowedIPs`.

When UFW is active, allow DNS only on the VPN interface. Run the pair matching
the installed bundle:

```bash
sudo ufw allow in on wg0 to 10.8.0.1 port 53 proto udp
sudo ufw allow in on wg0 to 10.8.0.1 port 53 proto tcp

sudo ufw allow in on awg0 to 10.9.0.1 port 53 proto udp
sudo ufw allow in on awg0 to 10.9.0.1 port 53 proto tcp
```

These are manual UFW rules and are not removed by the AdGuard Home uninstaller.
If using the IPv6 DNS address, replace the destination with its IPv6 counterpart
and confirm that IPv6 is enabled in UFW. Do not replace the private destination
with the VPS's public address.

From a connected client, verify the applicable address:

```bash
dig @10.8.0.1 example.org
dig @10.9.0.1 example.org
```

### Xray

The repository's default Xray config uses its
[built-in DNS module](https://xtls.github.io/en/config/dns) when routing or the
[direct outbound](https://xtls.github.io/en/config/outbounds/freedom.html) needs
to resolve a domain. To make those server-side
lookups use AdGuard Home, first make AdGuard Home listen on `127.0.0.1:53`, then
add this top-level object to `/usr/local/etc/xray/config.json`:

```json
"dns": {
  "servers": ["tcp+local://127.0.0.1:53"]
}
```

The local TCP form bypasses Xray routing for this query. That matters because
the generated server config blocks private destinations, including loopback,
for ordinary proxied traffic.

Validate the complete JSON before restarting Xray:

```bash
sudo xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl restart xray
```

If the config already has the optional Russian split-routing DNS object, replace
its Cloudflare and Google DoH servers with the same local TCP resolver, remove
the obsolete `dns-next-hop` tag and its routing rule, and retain
`routing.domainStrategy`, the Russian direct rules, and the geodata settings:

```bash
tmp="$(mktemp)"
trap 'rm -f -- "${tmp}"' EXIT
sudo jq '
  .dns.servers = ["tcp+local://127.0.0.1:53"]
  | .dns |= del(.tag)
  | .routing.rules |= map(select(.ruleTag != "dns-next-hop"))
' /usr/local/etc/xray/config.json | sudo tee "${tmp}" >/dev/null
sudo xray run -test -config "${tmp}"
sudo install -m 600 -o root -g root "${tmp}" /usr/local/etc/xray/config.json
rm -f -- "${tmp}"
trap - EXIT
sudo systemctl restart xray
```

This preserves `IPOnDemand`, `russian-domain-direct`, `russian-ip-direct`, and
the scheduled geodata routing while moving only the DNS queries to the local
stack. The Xray updater preserves the current config, but reinstalling Xray can
regenerate its public-DoH DNS object; reapply this local-DNS change afterward.

This is server-side resolution only. A VLESS share link cannot push a DNS server
to the client, and client applications that resolve names locally will continue
to use their own DNS configuration.

### Telemt and TG WS

The current Telemt bundle does not expose a custom DNS-server setting. Its
optional Xray SOCKS5 upstream is the literal loopback address
`127.0.0.1:<port>`, so it does not need DNS. Telemt may still use the host
resolver for hostname-based features such as its TLS masking domain; this
AdGuard Home bundle intentionally does not change the host resolver.

The current TG WS bundle passes Telegram data-center destinations as fixed IP
addresses through `TG_WS_PROXY_DC_IPS`, and its Compose file has no custom DNS
setting. AdGuard Home therefore does not participate in its normal Telegram-DC
path. Optional hostnames such as the Cloudflare Worker still use the container's
default resolver. Manual Compose edits are not documented as a supported setup
because a bundle reinstall can replace them.

### Other Services

For another service on the same VPS, prefer `127.0.0.1:53` and configure only
that service to use it. For a VPN client, use an AdGuard Home address assigned to
the VPN interface and keep the firewall rule scoped to that interface. A
container's `127.0.0.1` is normally the container itself unless it uses host
networking, so use a host address reachable from that container instead.

## Update

Update to the latest stable release:

```bash
sudo ./update.sh
```

Or request a specific stable release:

```bash
sudo ADGUARD_HOME_VERSION=v0.107.79 ./update.sh
```

The updater ensures `unbound`, `dns-root-data`, and `dnsutils` are installed and current, rewrites the exact managed
Unbound drop-in atomically, validates it with `unbound-checkconf`, and validates UDP and TCP recursion when Unbound was
already active. It also validates the current AdGuard Home configuration, downloads and verifies the requested release,
and saves the current binary and configuration under `/opt/AdGuardHome/backup/vpsfiles-<timestamp>-<suffix>`. Each of
AdGuard Home and Unbound is restarted only when that service was active before the update; an inactive service remains
stopped.

If the new binary, configuration check, or restarted service fails, the updater restores the previous binary and
configuration. It reports a separate error if automatic rollback also fails. Required apt package upgrades are not
rolled back. APT package upgrades are outside binary rollback and are not downgraded or removed.

## Uninstall

Remove the service and binary:

```bash
sudo ./uninstall.sh
```

The uninstaller retains the following application data for a later reinstall:

- `/opt/AdGuardHome/AdGuardHome.yaml`
- `/opt/AdGuardHome/data/`
- `/opt/AdGuardHome/backup/`

Retained data can include DNS query history and other private information. The script prints these paths before its
confirmation prompt. It does not uninstall apt packages or modify UFW, the host resolver, or any other bundle.
The managed Unbound drop-in and bundle state are removed. The recorded pre-install Unbound and
`unbound-resolvconf` unit states, `/etc/resolvconf.conf` integration, and any explained generated resolver file are
restored. The `unbound`, `dns-root-data`, and `dnsutils` packages remain installed.

Running `install.sh` again restores the binary and native service around the retained configuration. If you want to
discard the retained application data permanently, inspect it and remove `/opt/AdGuardHome` manually; no automatic
purge command is provided.

## Unbound Verification

On a Debian/Ubuntu host, these checks confirm syntax, loopback-only binding, UDP/TCP recursion, and DNSSEC rejection:

```bash
sudo unbound-checkconf
sudo ss -lntup 'sport = :5335'
dig @127.0.0.1 -p 5335 example.org
dig @127.0.0.1 -p 5335 example.org +tcp
dig @127.0.0.1 -p 5335 dnssec-failed.org A +comments
```

The `ss` output must show only `127.0.0.1:5335` for Unbound. The last query must report `SERVFAIL`; an address answer
would mean DNSSEC validation is not working. After completing AdGuard's UI settings, repeat a normal query against
AdGuard on `127.0.0.1:53`.

## Recursive DNS Limits

Unbound must be able to make outbound UDP and TCP connections on port `53` to root, TLD, and authoritative DNS
servers. No inbound firewall rule is needed for port `5335`, and this bundle does not add one. DNSSEC validation
protects authenticated DNS data only for zones that are correctly signed; it does not make unsigned zones trustworthy.

Local recursive DNS can avoid dependence on a public forwarding resolver, but it does not bypass destination-IP,
TLS/SNI, or DPI blocking. It can return both A and AAAA records even though this Unbound configuration uses IPv4 only
for its own authoritative-server connections.

## Service Commands

```bash
sudo systemctl status AdGuardHome
sudo systemctl stop AdGuardHome
sudo systemctl start AdGuardHome
sudo journalctl -u AdGuardHome -n 100 --no-pager
sudo systemctl status unbound
sudo journalctl -u unbound -n 100 --no-pager
```

References:

- <https://github.com/AdguardTeam/AdGuardHome>
- <https://adguard-dns.io/kb/adguard-home/getting-started/>
- <https://adguard-dns.io/kb/adguard-home/running-securely/>
- <https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration>
- <https://unbound.docs.nlnetlabs.nl/en/latest/getting-started/configuration.html>
- <https://sources.debian.org/src/unbound/1.17.1-2%2Bdeb12u4/debian/changelog/>
