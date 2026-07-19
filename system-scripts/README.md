# Resource-Constrained VPS Maintenance

This standalone bundle applies bounded housekeeping to Debian/Ubuntu VPS hosts that use APT and systemd. It limits systemd journals and core dumps, enables distro log rotation, schedules safe cleanup, and adds compressed zram swap when the host supports it.

It deliberately does not disable services, change broad networking or VM sysctls, remove packages, run `autoremove`, delete user or application data, or prune global Docker state.

## Setup

```bash
cd system-scripts
sudo ./install.sh
```

The installer derives limits from the host RAM and the filesystem containing `/var/log`, shows the exact values, and asks before making changes. It is safe to rerun. If an exact managed path contains a file not marked as owned by this bundle, setup stops instead of replacing it.

Zram is configured as half of RAM with a 1 GiB ceiling and priority 100, so it is normally preferred over default-priority disk swap. Existing swap is preserved. Existing zram configuration, container VPS environments, unsupported kernels, and repositories without `systemd-zram-generator` are left unchanged with an explanatory message.

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

## Uninstall

```bash
sudo ./uninstall.sh
```

The installer records the original `logrotate.timer` enabled/active state and whether `systemd-zram-generator` was already installed. Uninstall removes only marker-owned configuration and maintenance files, restores the recorded timer state, and removes `systemd-zram-generator` only when this bundle installed it. Shared base packages (`kmod`, `logrotate`, and `util-linux`) remain installed.

Active zram swap is never forced off because that can exhaust memory. If `/dev/zram0` is active, uninstall removes its future configuration and asks for a reboot so the running device is released safely. Logs, package archives, and temporary files deleted by earlier maintenance cannot be restored.

If setup predates the installer-state directory, uninstall still removes marker-owned files but leaves `logrotate.timer` and all packages unchanged because their original state cannot be proven.

## Managed host paths

```text
/etc/systemd/journald.conf.d/60-vpsfiles-limits.conf
/etc/systemd/coredump.conf.d/60-vpsfiles-limits.conf
/etc/systemd/zram-generator.conf.d/60-vpsfiles.conf  (only when configured)
/etc/systemd/system/vpsfiles-maintenance.service
/etc/systemd/system/vpsfiles-maintenance.timer
/usr/local/sbin/vpsfiles-maintenance
/var/lib/vpsfiles-system
```
