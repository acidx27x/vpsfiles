# Resource-Constrained VPS Maintenance

This standalone bundle applies bounded housekeeping and SSH brute-force protection to Debian/Ubuntu VPS hosts that use APT and systemd. It limits systemd journals and core dumps, enables distro log rotation, schedules safe cleanup, adds compressed zram swap when the host supports it, and enables one Fail2ban `sshd` jail.

It does not change SSH configuration or authentication policy, base firewall rules, broad networking or VM sysctls, remove unrelated packages, run `autoremove`, delete user or application data, or prune global Docker state. On Ubuntu only, setup can optionally disable automatic APT activity and kernel meta-package updates after a separate warning and confirmation.

## Setup

```bash
cd system-scripts
sudo ./install.sh
```

The installer derives limits from the host RAM and the filesystem containing `/var/log`, shows the exact values, and asks before making changes. It is safe to rerun. If an exact managed path contains a file not marked as owned by this bundle, setup stops instead of replacing it.

The installer explicitly installs `fail2ban` and `python3-systemd`, then writes a `.local` override for the stock `sshd` filter using Fail2ban's systemd journal backend. Five failed SSH attempts from one source within ten minutes trigger a one-hour ban. Configuration is tested before the service is enabled and restarted; setup also verifies the daemon, the `sshd` jail, and the effective thresholds. The package-owned Fail2ban configuration and other local jails remain untouched. This follows Fail2ban's [documented `.local` override model](https://manpages.debian.org/trixie/fail2ban/jail.conf.5.en.html).

The jail uses the distribution's `banaction_allports` setting instead of hardcoding a firewall backend. Consequently, an address banned for SSH failures is blocked from every host port for the ban duration, not only the SSH port. Existing global `ignoreip` and `ignoreself` settings are inherited. The installer does not automatically allowlist the current remote administrator address, so confirm that you retain a console or another recovery path before intentionally testing bans.

Zram is configured as half of RAM with a 1 GiB ceiling and priority 100, so it is normally preferred over default-priority disk swap. Existing swap is preserved. Existing zram configuration, container VPS environments, unsupported kernels, and repositories without `systemd-zram-generator` are left unchanged with an explanatory message.

On Ubuntu, the installer separately offers to disable automatic APT and kernel updates. The default answer is no. Accepting writes a marker-owned APT drop-in, masks the `unattended-upgrades` and `apt-daily` services and timers, and holds installed kernel meta-packages. This also stops automatic security patching, so use `sudo ./update.sh` regularly and review held kernel packages manually. A rerun preserves an earlier opt-in without prompting again.

## Fail2ban status and unban

Check the daemon and SSH jail:

```bash
sudo fail2ban-client ping
sudo fail2ban-client status sshd
sudo fail2ban-client get sshd bantime
sudo fail2ban-client get sshd findtime
sudo fail2ban-client get sshd maxretry
sudo journalctl -u fail2ban.service --no-pager
```

Remove one address from the SSH jail after verifying that it is the intended source:

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.10
```

Replace the example address with the exact address shown by `fail2ban-client status sshd`.

## Manual cleanup

Preview the bounded cleanup:

```bash
sudo ./cleanup.sh --dry-run
```

Run it immediately:

```bash
sudo ./cleanup.sh
```

Cleanup rotates the journal, removes archived journal entries older than seven days, clears downloaded APT package archives, and asks `systemd-tmpfiles` to remove only files expired under installed tmpfiles policies. The same cleanup runs daily through `vpsfiles-maintenance.timer` with a randomized delay.

## System updates

```bash
sudo ./update.sh
```

The updater runs `apt-get update` followed by `apt-get upgrade --with-new-pkgs`. It can install new dependencies but never removes packages, invokes `autoremove`, performs a distribution release upgrade, or reboots. A required reboot and held packages are reported for manual action.

System-wide APT package versions and dependency changes cannot be automatically downgraded after a failure. Create a provider snapshot before updating when full VPS rollback is required.

### Manual security updates

For a normal manual update, run:

```bash
sudo ./update.sh
```

This installs all eligible package updates, not only security updates. If you want to review and apply only the origins configured for `unattended-upgrades` (normally the Ubuntu security and ESM pockets), run it directly even while its automatic service and timer are disabled:

```bash
sudo apt-get update
sudo unattended-upgrade --dry-run --verbose
sudo unattended-upgrade --verbose
```

Review `/etc/apt/apt.conf.d/50unattended-upgrades` before relying on this as security-only behavior, because local configuration can enable additional origins. If the `unattended-upgrade` command is missing, install its package first:

```bash
sudo apt-get install unattended-upgrades
```

When the optional automatic-update lock is enabled, detected kernel meta packages remain held and are skipped by both methods. To include kernel security updates, first list the exact held package names:

```bash
apt-mark showhold | grep '^linux-'
```

Temporarily unhold only the kernel meta packages shown by that command, update, and then hold the same packages again. Package names vary by VPS image (`generic`, `virtual`, `aws`, `azure`, `gcp`, or HWE), so do not copy package names from another server. For example:

```bash
sudo apt-mark unhold linux-generic linux-image-generic linux-headers-generic
sudo ./update.sh
sudo apt-mark hold linux-generic linux-image-generic linux-headers-generic
```

Use the actual names from `apt-mark showhold`. If the updater reports that a reboot is required, schedule one so the updated kernel and libraries take effect.

## Uninstall

```bash
sudo ./uninstall.sh
```

The installer records the original `logrotate.timer` enabled/active state and whether `systemd-zram-generator` was already installed. When automatic updates were disabled, it also records the original unit masks/activity and only the kernel holds added by this bundle. Uninstall removes only marker-owned configuration and maintenance files, restores the recorded states, and removes `systemd-zram-generator` only when this bundle installed it. Pre-existing unit masks and package holds are preserved. Shared base packages (`kmod`, `logrotate`, and `util-linux`) remain installed.

Fail2ban has separate nested ownership state. Uninstall always removes only the marker-owned SSH jail fragment. It removes the `fail2ban` package only when the recorded first-run baseline proves this bundle introduced it; `python3-systemd` and other shared dependencies are retained, and `autoremove` is never used. If Fail2ban predated the bundle, uninstall validates the remaining Fail2ban configuration and restores the recorded enabled, active, and masked service states. If the Fail2ban baseline is unavailable, the package and service are preserved while only the owned jail fragment is removed.

Active zram swap is never forced off because that can exhaust memory. If `/dev/zram0` is active, uninstall removes its future configuration and asks for a reboot so the running device is released safely. Logs, package archives, and temporary files deleted by earlier maintenance cannot be restored.

If setup predates the installer-state directory, uninstall still removes marker-owned files but leaves `logrotate.timer` and all packages unchanged because their original state cannot be proven.

## Managed host paths

```text
/etc/systemd/journald.conf.d/60-vpsfiles-limits.conf
/etc/systemd/coredump.conf.d/60-vpsfiles-limits.conf
/etc/systemd/zram-generator.conf.d/60-vpsfiles.conf  (only when configured)
/etc/fail2ban/jail.d/60-vpsfiles.local
/etc/apt/apt.conf.d/99-vpsfiles-disable-auto-updates  (Ubuntu opt-in only)
/etc/systemd/system/vpsfiles-maintenance.service
/etc/systemd/system/vpsfiles-maintenance.timer
/usr/local/sbin/vpsfiles-maintenance
/var/lib/vpsfiles-system
/var/lib/vpsfiles-system/fail2ban
```
