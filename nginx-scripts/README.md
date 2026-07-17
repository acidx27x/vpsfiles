# Nginx HTTPS Fallback for Xray REALITY

This standalone installer creates a minimal real HTTPS site for Xray REALITY active-probing fallback. It is intentionally separate from `../xray-scripts`.

The generated Nginx configuration exposes TCP port 80 for Let's Encrypt HTTP-01 challenges and redirects. HTTPS listens only on `127.0.0.1:8443` by default, leaving public TCP port 443 for Xray.

Before running it, point the fallback domain's public DNS record at this VPS and make sure inbound TCP port 80 is reachable.

The installer adds an HTTP allow rule to UFW. If UFW is currently inactive, verify that your SSH port also has an allow rule before choosing to enable it.

```bash
cd nginx-scripts
sudo ./install.sh
```

The installer prints the local REALITY target and SNI values to enter when running `../xray-scripts/install.sh`.

Certbot checks renewal automatically through `certbot.timer`. After a successful renewal, the installed deploy hook validates the Nginx configuration and reloads Nginx so the renewed certificate becomes active.

Run this installer independently on every Xray VPS that should answer active probes with its own domain and certificate. It manages only:

```text
/etc/nginx/sites-available/xray-fallback
/etc/nginx/sites-enabled/xray-fallback
/var/www/xray-fallback
/etc/letsencrypt/renewal-hooks/deploy/reload-xray-fallback-nginx
```

It does not bind public TCP port 443, modify unrelated Nginx sites, or remove Nginx data when Xray is uninstalled.

## Uninstall

Remove the independently installed fallback with:

```bash
sudo ./uninstall.sh
```

The uninstaller removes the managed site, webroot, renewal hook, install backups, and an owned TCP/80 UFW rule when no remaining Nginx configuration needs that port. It deletes the fallback certificate through `certbot delete` only after confirming that no remaining Nginx, Apache/httpd, or Postfix configuration references it. An unknown or still-referenced certificate is retained and reported as partial cleanup.

Uninstall always stops and disables `nginx.service` and `certbot.timer`, and stops an active `certbot.service`. This can affect unrelated sites or certificates on the same VPS. Nginx and Certbot packages and the shared Certbot account remain installed. Xray uninstall does not invoke this command.

Installations created before ownership state was added derive the certificate name from the default managed Nginx config. Unknown firewall ownership is left unchanged. For legacy installations that used custom paths, pass the same `NGINX_CONFIG`, `NGINX_ENABLED_CONFIG`, `NGINX_WEB_ROOT`, and `NGINX_RENEWAL_HOOK` environment overrides when uninstalling.

After Xray is installed, verify the public fallback:

```bash
curl -v --resolve fallback.example.com:443:<VPS_IP> https://fallback.example.com/
```
