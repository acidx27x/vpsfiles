#!/usr/bin/env python3
"""Manage the existing local REALITY fallback without reinstalling services."""

import base64
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
BEGIN = "# BEGIN vpsfiles Telemt WEB\n"
END = "# END vpsfiles Telemt WEB\n"


class CheckError(ValueError):
    """Operator-safe validation failure without configuration contents."""


def report(message: str) -> None:
    """Flush human-readable progress to stderr, preserving machine-readable stdout."""
    print(f"[WEB] {message}", file=sys.stderr, flush=True)


def require(condition: object, message: str) -> None:
    if not condition:
        raise CheckError(message)


def run(*args: str) -> str:
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True, timeout=20).strip()


def failure_summary(error: BaseException) -> str:
    """Describe failures without echoing arguments, response bodies or config values."""
    if isinstance(error, CheckError):
        return str(error)
    if isinstance(error, subprocess.CalledProcessError):
        program = Path(error.cmd[0]).name if isinstance(error.cmd, (list, tuple)) else "command"
        return f"{program} exited with code {error.returncode}"
    if isinstance(error, subprocess.TimeoutExpired):
        return "command timed out"
    if isinstance(error, urllib.error.HTTPError):
        return f"HTTP status {error.code}"
    if isinstance(error, OSError):
        return f"{type(error).__name__} (errno {error.errno})"
    return type(error).__name__


def state(bundle: str, name: str, default: str) -> str:
    path = ROOT / bundle / name
    return path.read_text().strip() if path.exists() else default


def config_path(bundle: str, name: str, default: str) -> Path:
    path = Path(state(bundle, name, default))
    require(path.is_absolute() and str(path) != "/" and not path.is_symlink(), "Unsafe config path")
    return path


def service(bundle: str, name: str, default: str) -> str:
    value = state(bundle, name, default)
    require(re.fullmatch(r"[A-Za-z0-9_.@-]+", value), "Invalid service name")
    return value


def load(path: Path) -> dict[str, Any]:
    return tomllib.loads(path.read_text())


def managed(text: str, block: str = "") -> str:
    require(text.count(BEGIN) == text.count(END) <= 1, "Invalid managed block")
    if BEGIN in text:
        start = text.index(BEGIN)
        stop = text.index(END, start) + len(END)
        text = text[:start] + text[stop:]
    return text.rstrip() + "\n" + (BEGIN + block + END if block else "")


def enabled(path: Path) -> bool:
    return path.exists() and load(path).get("web", {}).get("enabled", False)


def web_link(host: str, secret: str) -> str:
    require(re.fullmatch(r"[0-9a-fA-F]{32}", secret), "Invalid access secret")
    encoded = base64.urlsafe_b64encode(b"\x70\xdd" + bytes.fromhex(secret)).decode().rstrip("=")
    return "tg://webproxy?server=" + urllib.parse.quote(host, safe="") + "&secret=" + encoded


def web_block(config: dict[str, Any], host: str, address: str) -> str:
    users = config["access"]["users"]
    for name, secret in users.items():
        require(re.fullmatch(r"[A-Za-z0-9._-]+", name) and name not in (".", ".."), "Unsupported user name")
        web_link(host, secret)
    block = """[[server.listeners]]
ip = "127.0.0.1"
port = 18080
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[web]
enabled = true
carrier = "https"

[[web.vhosts]]
"""
    block += f'host = {json.dumps(host)}\nbase_path = "telegram/web"\npublic_addr = {json.dumps(address)}\n'
    block += '[web.vhosts.decoy]\nmode = "static_directory"\ndirectory = "/var/lib/telemt/public"\n'
    for name in users:
        block += "\n[[web.vhosts.profiles]]\nuser = " + json.dumps(name) + '\nsecret_mode = "dd"\n'
    return block


def refresh_profiles(text: str) -> str:
    config = tomllib.loads(text)
    if not config.get("web", {}).get("enabled"):
        return text
    require(BEGIN in text, "Refusing to edit unmanaged WEB configuration")
    (vhost,) = config["web"]["vhosts"]
    return managed(text, web_block(config, vhost["host"], vhost["public_addr"]))


def edit_user(text: str, name: str, secret: str | None, limit: int | None) -> str:
    """Edit only the two existing access tables before regenerating profiles."""
    for table, value in (
        ("access.users", json.dumps(secret) if secret else None),
        ("access.user_max_unique_ips", str(limit) if secret else None),
    ):
        pattern = r"(?m)^\[" + re.escape(table) + r"\][ \t]*(?:#[^\n]*)?\n"
        match = re.search(pattern, text)
        require(match is not None, "Missing access table")
        following = re.search(r"(?m)^\[", text[match.end() :])
        stop = match.end() + following.start() if following else len(text)
        body = text[match.end() : stop]
        key = r'(?m)^[ \t]*(?:"' + re.escape(name) + r'"|' + re.escape(name) + r")[ \t]*=.*\n?"
        body = re.sub(key, "", body)
        if value is not None:
            body = json.dumps(name) + " = " + value + "\n" + body
        text = text[: match.end()] + body + text[stop:]
    tomllib.loads(text)
    return text


def atomic(path: Path, data: bytes, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    old = path.stat() if path.exists() else None
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".telemt-")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode if mode is not None else (old.st_mode & 0o777 if old else 0o600))
        if old and os.geteuid() == 0:
            os.chown(temporary, old.st_uid, old.st_gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Installation:
    def __init__(self) -> None:
        self.telemt = config_path("telemt-scripts", "telemt-config-path.txt", "/etc/telemt/telemt.toml")
        self.xray = config_path("xray-scripts", "xray-config-path.txt", "/usr/local/etc/xray/config.json")
        self.nginx = config_path("nginx-scripts", "nginx-config-path.txt", "/etc/nginx/sites-available/xray-fallback")
        self.services = [
            service("telemt-scripts", "telemt-service.txt", "telemt"),
            "nginx",
            service("xray-scripts", "xray-service.txt", "xray"),
        ]
        self.binary = state("telemt-scripts", "telemt-bin-path.txt", "/bin/telemt")
        self.clients = ROOT / "telemt-scripts/clients"

    def report_summary(self, result: str) -> None:
        """Show endpoints and artifact locations without printing access links."""
        config = load(self.telemt)
        report(f"SUCCESS: {result}")
        report(f"Native MTProxy port: {config['server']['port']}")
        report(f"Access users: {len(config['access']['users'])}")
        if config.get("web", {}).get("enabled"):
            vhost = config["web"]["vhosts"][0]
            report(f"WEB endpoint: https://{vhost['host']}/{vhost['base_path']}/")
            report(f"WEB profiles: {len(vhost['profiles'])}; private listener: 127.0.0.1:18080")
        else:
            report("WEB is disabled")
        report(f"Client links: {self.clients}/<client>/telemt-<client>-links.txt")
        if config.get("web", {}).get("enabled"):
            report("Import the web: link from your client's file to test Telegram")

    def ready(self) -> None:
        run(self.binary, "healthcheck", "--mode", "ready", str(self.telemt))
        if enabled(self.telemt):
            config = load(self.telemt)
            api = config["server"]["api"]
            request = urllib.request.Request("http://" + api["listen"] + "/v1/runtime/web/status")
            if api.get("auth_header"):
                request.add_header("Authorization", api["auth_header"])
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=5) as response:
                payload = json.loads(response.read(1024 * 1024))
            data = payload.get("data", payload)
            require(
                data.get("ingress", {}).get("accepting_connections") is True, "WEB runtime is not accepting connections"
            )
            with socket.create_connection(("127.0.0.1", 18080), timeout=3):
                pass

    def artifacts(self) -> dict[Path, bytes]:
        config = load(self.telemt)
        api = config["server"]["api"]
        request = urllib.request.Request("http://" + api["listen"] + "/v1/users")
        if api.get("auth_header"):
            request.add_header("Authorization", api["auth_header"])
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=5) as response:
            users = {item["username"]: item for item in json.load(response)["data"]}
        changes = {}
        for name, secret in config["access"]["users"].items():
            require(re.fullmatch(r"[A-Za-z0-9._-]+", name) and name not in (".", ".."), "Unsupported user name")
            lines = []
            for mode in ("tls", "secure", "classic"):
                for uri in users[name]["links"].get(mode, []):
                    lines.append(f"{mode}: {uri}")
            if config.get("web", {}).get("enabled"):
                host = config["web"]["vhosts"][0]["host"] + "/telegram/web"
                lines.append("web: " + web_link(host, secret))
            changes[self.clients / name / f"telemt-{name}-links.txt"] = ("\n".join(lines) + "\n").encode()
        return changes

    def transaction(self, changes: dict[Path, bytes | None], services: list[str], public_probe: bool = False) -> None:
        """Restore the current operation, never the original enable snapshot."""
        report(f"Preparing backup for {len(changes)} file changes")
        backup = Path(tempfile.mkdtemp(prefix="web-", dir=self.backup_root()))
        report(f"Backup directory: {backup}")
        original = {}
        ownership = {}
        new_directories = set()
        active = {
            unit: subprocess.run(["systemctl", "is-active", "--quiet", unit], capture_output=True).returncode == 0
            for unit in services
        }

        def save(path):
            require(not path.is_symlink() and not path.parent.is_symlink(), "Refusing to replace a symlink")
            if path not in original:
                original[path] = path.read_bytes() if path.exists() else None
                if path.exists():
                    info = path.stat()
                    ownership[path] = (info.st_uid, info.st_gid)
                    shutil.copy2(path, backup / str(len(original)))
                (backup / "manifest.json").write_text(json.dumps({str(p): i for i, p in enumerate(original, 1)}))
                (backup / "ownership.json").write_text(json.dumps({str(p): owner for p, owner in ownership.items()}))

        for path in changes:
            require(not path.is_symlink(), "Refusing to replace a symlink")
            save(path)
        (backup / "manifest.json").write_text(json.dumps({str(p): i for i, p in enumerate(original, 1)}))
        (backup / "services.json").write_text(json.dumps(active))
        stage = "writing prepared files"
        try:
            report(f"{stage[0].upper()}{stage[1:]}...")
            for path, value in changes.items():
                report(f"{'Removing' if value is None else 'Updating'} {path}")
                if not path.parent.exists():
                    new_directories.add(path.parent)
                    path.parent.mkdir(
                        parents=True, mode=0o755 if str(path).startswith("/var/lib/telemt/public/") else 0o700
                    )
                if value is None:
                    path.unlink(missing_ok=True)
                    continue
                atomic(path, value, 0o644 if str(path).startswith("/var/lib/telemt/public/") else None)
            if self.nginx in changes:
                stage = "validating Nginx configuration"
                report(f"{stage[0].upper()}{stage[1:]}...")
                run("nginx", "-t")
                report("Nginx configuration: OK")
            for unit in services:
                stage = f"activating service {unit}"
                report(f"{'Reloading' if unit == 'nginx' else 'Restarting'} {unit}...")
                run("systemctl", "reload" if unit == "nginx" else "restart", unit)
                stage = f"checking service {unit} readiness"
                report(f"{stage[0].upper()}{stage[1:]}...")
                self.wait_ready() if unit == self.services[0] else run("systemctl", "is-active", "--quiet", unit)
                report(f"Service {unit}: OK")
            if public_probe:
                stage = "checking public HTTPS and WEB routes"
                report(f"{stage[0].upper()}{stage[1:]}...")
                self.wait_public_ready()
            stage = "fetching client links from Telemt API"
            report(f"{stage[0].upper()}{stage[1:]}...")
            artifacts = self.artifacts()
            for path, value in artifacts.items():
                stage = "writing client link files"
                report(f"Writing client links: {path}")
                save(path)
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                atomic(path, value, 0o600)
            (backup / "manifest.json").write_text(json.dumps({str(p): i for i, p in enumerate(original, 1)}))
            report(f"Completed {len(changes)} file changes; wrote {len(artifacts)} client link files")
            report(f"Backup retained at: {backup}")
        except BaseException as error:
            failed = False
            detail = failure_summary(error)
            report(f"FAILED at {stage}: {detail}")
            try:
                atomic(backup / "failure.json", json.dumps({"stage": stage, "error": detail}).encode(), 0o600)
                report(f"Safe failure report: {backup / 'failure.json'}")
                output = getattr(error, "output", None)
                if output:
                    atomic(
                        backup / "command-output.log",
                        output.encode() if isinstance(output, str) else output,
                        0o600,
                    )
                    report(f"Private command output: {backup / 'command-output.log'} (review before sharing)")
            except OSError as diagnostic_error:
                # Diagnostic storage must never prevent restoration.
                report(f"Could not save diagnostics: {failure_summary(diagnostic_error)}")
            report("Rolling back files and services...")
            if self.telemt in changes and self.services[0] in services:
                try:
                    # Listener inventory belongs to the process. Do not let its
                    # watcher consume a restored config with incompatible vhosts.
                    report(f"Stopping {self.services[0]} before restoring its listener configuration")
                    run("systemctl", "stop", self.services[0])
                except (OSError, subprocess.SubprocessError) as recovery_error:
                    report(f"Could not stop {self.services[0]}: {failure_summary(recovery_error)}")
                    failed = True
            for index, (path, value) in enumerate(original.items(), 1):
                try:
                    report(f"Restoring {path}")
                    if value is None:
                        path.unlink(missing_ok=True)
                    else:
                        shutil.copy2(backup / str(index), path)
                        if os.geteuid() == 0:
                            os.chown(path, *ownership[path])
                except OSError as recovery_error:
                    report(f"Could not restore {path}: {failure_summary(recovery_error)}")
                    failed = True
            for directory in new_directories:
                try:
                    directory.rmdir()
                except OSError:
                    pass
            for unit in reversed(services):
                try:
                    report(f"Restoring service {unit} to {'active' if active[unit] else 'stopped'}")
                    run("systemctl", ("reload" if unit == "nginx" else "restart") if active[unit] else "stop", unit)
                    if active[unit]:
                        run("systemctl", "is-active", "--quiet", unit)
                except (OSError, subprocess.SubprocessError) as recovery_error:
                    report(f"Could not restore service {unit}: {failure_summary(recovery_error)}")
                    failed = True
            if not failed:
                try:
                    report("Verifying restored services and endpoints...")
                    if self.services[0] in active and active[self.services[0]]:
                        self.wait_ready()
                    if public_probe:
                        self.wait_public_ready()
                except (OSError, ValueError, subprocess.SubprocessError) as recovery_error:
                    report(f"Restored configuration verification failed: {failure_summary(recovery_error)}")
                    failed = True
            if failed:
                report(f"ROLLBACK INCOMPLETE: inspect services and backup {backup}")
                raise RuntimeError(
                    f"Operation AND rollback failed at {stage}: {detail}; inspect services. Backup: {backup}"
                ) from None
            report("Rollback verified: previous files and service state restored")
            raise RuntimeError(
                f"Operation failed at {stage}: {detail}; previous files and services restored. Backup: {backup}"
            ) from None

    def wait_public_ready(self) -> None:
        """Allow a simple systemd service to bind before probing its TLS endpoint."""
        for attempt in range(10):
            report(f"Public HTTPS probe: attempt {attempt + 1}/10")
            try:
                self.probe_public()
                return
            except subprocess.CalledProcessError as error:
                # curl: refused connection, TLS startup failure, empty reply, reset.
                # HTTP/decoy validation failures remain immediate failures.
                if error.returncode not in (7, 35, 52, 56) or attempt == 9:
                    raise
                report(f"Public HTTPS is not ready: {failure_summary(error)}; retrying in 1 second")
                time.sleep(1)

    def probe_public(self) -> None:
        host, address = self.endpoint()
        options = [
            "curl",
            "--silent",
            "--show-error",
            "--noproxy",
            "*",
            "--max-time",
            "10",
            "--resolve",
            f"{host}:443:{address}",
        ]
        code = run(*options, "--fail", "--output", "/dev/null", "--write-out", "%{http_code}", f"https://{host}/")
        report(f"HTTPS {host}/: HTTP {code}")
        if enabled(self.telemt):
            for path in ("/telegram/web", "/telegram/web/", "/telegram/web/unknown", "/telegram/web/?bridge=invalid"):
                code = run(*options, "--output", "/dev/null", "--write-out", "%{http_code}", f"https://{host}{path}")
                report(f"HTTPS {path}: HTTP {code}")
                require(
                    code in ("200", "404") and (path != "/telegram/web" or code == "404"),
                    f"Unexpected WEB decoy response for {path}: HTTP {code}",
                )

    def backup_root(self) -> Path:
        directory = ROOT / "telemt-scripts/install-backups"
        directory.mkdir(mode=0o700, exist_ok=True)
        directory.chmod(0o700)
        return directory

    def wait_ready(self) -> None:
        last_error = None
        for attempt in range(10):
            report(f"Telemt readiness: attempt {attempt + 1}/10")
            try:
                self.ready()
                report("Telemt readiness: OK")
                return
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                last_error = error
                report(f"Telemt is not ready: {failure_summary(error)}")
                time.sleep(1)
        raise CheckError(f"Telemt did not become ready: {failure_summary(last_error)}") from None

    def endpoint(self) -> tuple[str, str]:
        text = self.nginx.read_text()
        hosts = set(re.findall(r"^\s*server_name\s+([a-zA-Z0-9.-]+);", text, re.M))
        require(len(hosts) == 1, "Ambiguous managed Nginx hostname")
        host = hosts.pop()
        address = state("xray-scripts", "server-endpoint.txt", "")
        ipaddress.ip_address(address)
        return host, address

    def prepare(self, test_candidate: bool = True) -> dict[Path, bytes]:
        report("Checking installed configuration and prerequisites...")
        report(f"Configs: Telemt={self.telemt}; Nginx={self.nginx}; Xray={self.xray}")
        config = load(self.telemt)
        version = re.search(r"(\d+)\.(\d+)\.(\d+)", run(self.binary, "--version"))
        require(
            version and tuple(map(int, version.groups())) >= (3, 5, 16),
            "Update Telemt manually to 3.5.16 or later first",
        )
        report(f"Telemt version: {version[0]}")
        for unit in self.services:
            run("systemctl", "is-active", "--quiet", unit)
            report(f"Service {unit}: active")
        require(config["server"]["api"]["enabled"], "Telemt API must be enabled")
        require(
            re.fullmatch(r"(127\.0\.0\.1|\[::1\]):[0-9]+", config["server"]["api"]["listen"]),
            "Telemt API must bind loopback",
        )
        upstreams = [u for u in config.get("upstreams", []) if u.get("enabled", True)]
        require(
            len(upstreams) == 1 and upstreams[0]["type"] == "socks5" and not upstreams[0].get("scopes"),
            "Require one unscoped SOCKS5 upstream; direct fallback is forbidden",
        )
        require(config["general"].get("use_middle_proxy") is False, "Middle proxy must be disabled")
        self.ready()
        xray = json.loads(self.xray.read_text())
        (inbound,) = [i for i in xray["inbounds"] if i.get("tag") == "local-socks"]
        require(inbound.get("listen") == "127.0.0.1" and inbound["protocol"] == "socks", "SOCKS must bind loopback")
        port = inbound["port"]
        require(upstreams[0]["address"] == f"127.0.0.1:{port}", "SOCKS port mismatch")
        with socket.create_connection(("127.0.0.1", port), timeout=3):
            pass
        found = False
        for rule in xray.get("routing", {}).get("rules", []):
            if rule.get("inboundTag") and "local-socks" not in rule["inboundTag"]:
                continue
            if rule.get("outboundTag") == "block":
                continue
            require(
                rule.get("outboundTag") == "next-hop" and set(rule) <= {"ruleTag", "type", "inboundTag", "outboundTag"},
                "Cannot prove local-socks routes exclusively through next-hop",
            )
            found = True
            break
        require(
            found and any(o.get("tag") == "next-hop" and o["protocol"] == "vless" for o in xray["outbounds"]),
            "Missing next-hop route",
        )
        require(not xray.get("routing", {}).get("balancers"), "Unsupported balancer configuration")
        report(f"SOCKS5 route verified: 127.0.0.1:{port} -> next-hop")
        host, address = self.endpoint()
        (reality,) = [
            i
            for i in xray["inbounds"]
            if i.get("port") == 443 and i.get("streamSettings", {}).get("security") == "reality"
        ]
        settings = reality["streamSettings"]["realitySettings"]
        target = settings.get("target", settings.get("dest", ""))
        target_match = re.fullmatch(r"127\.0\.0\.1:(\d+)", target)
        require(
            target_match and host in settings["serverNames"],
            "Prepare a matching local Nginx fallback first; external target migration is unsupported",
        )
        internal_port = int(target_match[1])
        require(0 < internal_port < 65536 and internal_port not in (80, 443, 18080), "Invalid fallback port")
        for bundle, name, expected in (
            ("nginx-scripts", "fallback-domain.txt", host),
            ("xray-scripts", "reality-server-name.txt", host),
            ("xray-scripts", "reality-target.txt", target),
            ("telemt-scripts", "server-port.txt", str(config["server"]["port"])),
        ):
            value = state(bundle, name, "")
            require(not value or value == expected, "Installer state conflicts with installed configuration: " + name)
        require(
            address in {a[4][0] for a in socket.getaddrinfo(host, 443)}, "DNS does not point to the public endpoint"
        )
        require("--with-http_realip_module" in run("nginx", "-V"), "Nginx realip module required")
        site = self.nginx.read_text()
        (certificate,) = re.findall(r"^\s*ssl_certificate\s+([^;\s]+);", site, re.M)
        run("openssl", "x509", "-in", certificate, "-noout", "-checkend", "0")
        require(
            "does match certificate" in run("openssl", "x509", "-in", certificate, "-noout", "-checkhost", host),
            "Certificate hostname mismatch",
        )
        report(f"Fallback verified: {host} -> {target}; certificate hostname and expiry: OK")
        require(
            BEGIN in self.telemt.read_text()
            or (not config.get("web") and not any(i.get("transport") == "web" for i in config["server"]["listeners"])),
            "Unmanaged WEB configuration",
        )
        if not enabled(self.telemt):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 18080))
        listener = f"listen 127.0.0.1:{internal_port} ssl http2"
        require(
            site.count(listener) == 1 and (listener + ";" in site or listener + " proxy_protocol;" in site),
            "Unsupported Nginx layout",
        )
        require(len(re.findall(r"(?m)^\s*server\s*\{", site)) == 2, "Ambiguous Nginx server blocks")
        require(site.rfind("server {") < site.index(listener), "TLS must be the last managed server")
        require(not config.get("web", {}).get("limits") or BEGIN in self.telemt.read_text(), "Unmanaged WEB limits")
        require(
            config.get("web", {}).get("limits", {}).get("max_body_bytes", 2 * 1024 * 1024) <= 2 * 1024 * 1024,
            "WEB body limit exceeds the managed Nginx limit",
        )
        settings["xver"] = 1
        site = site.replace(listener + ";", listener + " proxy_protocol;")
        tls_start = site.index(listener)
        tls_site = site[tls_start:]
        require(
            all(value == "127.0.0.1" for value in re.findall(r"set_real_ip_from\s+([^;]+);", tls_site)),
            "Nginx must trust only loopback",
        )
        require(
            all(value == "proxy_protocol" for value in re.findall(r"real_ip_header\s+([^;]+);", tls_site)),
            "Conflicting Nginx real-IP policy",
        )
        if "real_ip_header proxy_protocol;" not in site[tls_start:]:
            site = site[:tls_start] + site[tls_start:].replace(
                "\n", "\n    set_real_ip_from 127.0.0.1;\n    real_ip_header proxy_protocol;\n", 1
            )
        # This bundle owns the whole site; reject unexpected WEB locations.
        clean = managed(site)
        require("/telegram/web" not in clean, "Unmanaged WEB location")
        clean = clean.replace(
            '# vpsfiles WEB map\nmap $http_upgrade $telemt_web_upgrade { default upgrade; "" ""; }\n', ""
        )
        position = clean.rfind("}")
        require(position >= 0, "Invalid Nginx site")
        location = """    location = /telegram/web { access_log off; return 404; }
    location ^~ /telegram/web/ {
        access_log off;
        client_max_body_size 2m;
        proxy_pass http://127.0.0.1:18080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $telemt_web_upgrade;
        proxy_connect_timeout 5s;
        proxy_send_timeout 65s;
        proxy_read_timeout 65s;
        client_body_timeout 65s;
        send_timeout 65s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_next_upstream off;
    }
"""
        location = location.replace(
            "        access_log off;", f"        if ($host != {host}) {{ return 404; }}\n        access_log off;"
        )
        site = (
            '# vpsfiles WEB map\nmap $http_upgrade $telemt_web_upgrade { default upgrade; "" ""; }\n'
            + clean[:position]
            + BEGIN
            + location
            + END
            + clean[position:]
        )
        text = managed(self.telemt.read_text(), web_block(config, host, address + ":443"))
        tomllib.loads(text)
        if test_candidate:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as candidate:
                json.dump(xray, candidate)
                candidate.flush()
                run("xray", "run", "-test", "-config", candidate.name)
                report("Xray candidate configuration: OK")
        return {
            self.telemt: text.encode(),
            self.xray: (json.dumps(xray, indent=2) + "\n").encode(),
            self.nginx: site.encode(),
            ROOT / "nginx-scripts/nginx-proxy-protocol.txt": b"1\n",
        }


def main() -> None:
    require(len(sys.argv) >= 2, "usage: web.sh enable|disable|status")
    action = sys.argv[1]
    if action in ("enable", "disable", "client-add", "client-remove"):
        report(f"Starting {action}")
    installation = Installation()
    if action == "link":
        config = load(Path(sys.argv[2]))
        if config.get("web", {}).get("enabled"):
            print("web: " + web_link(config["web"]["vhosts"][0]["host"] + "/telegram/web", sys.stdin.read().strip()))
        return
    if action == "guard":
        require(
            not enabled(installation.telemt),
            "Active WEB depends on this service; run telemt-scripts/web.sh disable first",
        )
        return
    if action == "health":
        if enabled(installation.telemt):
            installation.wait_ready()
        return
    if action == "status":
        config = load(installation.telemt)
        print(
            json.dumps(
                {
                    "enabled": enabled(installation.telemt),
                    "native_port": config["server"]["port"],
                    "version": run(installation.binary, "--version"),
                    "public_host": config.get("general", {}).get("links", {}).get("public_host"),
                    "upstreams": [
                        {key: item[key] for key in ("type", "address", "enabled", "weight") if key in item}
                        for item in config.get("upstreams", [])
                    ],
                    "listeners": [
                        {key: item[key] for key in ("ip", "port", "transport") if key in item}
                        for item in config.get("server", {}).get("listeners", [])
                    ],
                    "web_listen": "127.0.0.1:18080",
                    "vhosts": [
                        dict((k, v[k]) for k in ("host", "base_path", "public_addr"))
                        for v in config.get("web", {}).get("vhosts", [])
                    ],
                    "telemt_config": str(installation.telemt),
                    "nginx_config": str(installation.nginx),
                    "xray_config": str(installation.xray),
                }
            )
        )
        if enabled(installation.telemt):
            changes = installation.prepare(False)
            require(
                all(p.exists() and p.read_bytes() == v for p, v in changes.items()), "WEB configuration drift detected"
            )
            installation.ready()
        return
    require(os.geteuid() == 0, "Run as root")
    inherited = os.environ.get("VPS_TELEMT_LOCK_FD")
    report("Waiting for the Telemt configuration lock...")
    with os.fdopen(os.dup(int(inherited)), "a") if inherited else open("/run/lock/vpsfiles-telemt.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        report("Configuration lock acquired")
        if action == "enable":
            changes = installation.prepare()
            if all(p.exists() and p.read_bytes() == v for p, v in changes.items()):
                installation.ready()
                installation.report_summary("WEB already enabled and healthy; no changes applied")
                return
            public = Path("/var/lib/telemt/public")
            if public.exists():
                require(
                    not public.is_symlink()
                    and (public / "index.html").is_file()
                    and not (public / "index.html").is_symlink()
                    and public.stat().st_mode & 0o005 == 0o005
                    and (public / "index.html").stat().st_mode & 0o004,
                    "Decoy snapshot must be publicly readable",
                )
            else:
                source = (
                    Path(state("nginx-scripts", "nginx-web-root-path.txt", "/var/www/xray-fallback")) / "index.html"
                )
                require(
                    source.is_file() and not source.is_symlink() and source.stat().st_size <= 1024 * 1024,
                    "Require a small regular decoy index.html",
                )
                changes[public / "index.html"] = source.read_bytes()
            report("Enabling WEB at /telegram/web/; native port and credentials preserved")
            installation.transaction(changes, installation.services, True)
            installation.report_summary("WEB enabled; activation checks passed")
        elif action == "disable":
            if not enabled(installation.telemt):
                installation.report_summary("WEB already disabled; no changes applied")
                return
            require(BEGIN in installation.telemt.read_text(), "Unmanaged WEB configuration")
            site = managed(installation.nginx.read_text()).replace(
                '# vpsfiles WEB map\nmap $http_upgrade $telemt_web_upgrade { default upgrade; "" ""; }\n', ""
            )
            installation.transaction(
                {
                    installation.telemt: managed(installation.telemt.read_text()).encode(),
                    installation.nginx: site.encode(),
                },
                installation.services[:2],
                True,
            )
            installation.report_summary("WEB disabled; HTTPS fallback retained")
        elif action in ("client-add", "client-remove"):
            name = sys.argv[2]
            require(re.fullmatch(r"[A-Za-z0-9._-]+", name) and name not in (".", ".."), "Invalid user name")
            config = load(installation.telemt)
            users = config["access"]["users"]
            require(enabled(installation.telemt), "WEB must be enabled")
            text = installation.telemt.read_text()
            directory = installation.clients / name
            if action == "client-add":
                require(name not in users and not directory.exists(), "Client already exists")
                limit = int(sys.argv[3])
                require(limit > 0, "Invalid unique IP limit")
                secret = secrets.token_hex(16)
                text = edit_user(text, name, secret, limit)
            else:
                require(name in users and len(users) > 1, "Missing or last client")
                text = edit_user(text, name, None, None)
            text = refresh_profiles(text)
            installation.ready()
            changes = {installation.telemt: text.encode()}
            if action == "client-add":
                changes[directory / (name + ".secret")] = (secret + "\n").encode()
                changes[directory / (name + ".max-unique-ips")] = (str(limit) + "\n").encode()
            if action == "client-remove" and directory.exists():
                require(
                    not directory.is_symlink() and all(p.is_file() and not p.is_symlink() for p in directory.iterdir()),
                    "Unexpected client directory contents",
                )
                changes.update({p: None for p in directory.iterdir()})
            installation.transaction(changes, installation.services[:1])
            if action == "client-remove" and directory.exists():
                directory.rmdir()
            installation.report_summary(f"Client {name} {'added' if action == 'client-add' else 'removed'}")
        else:
            raise ValueError("usage: web.sh enable|disable|status")


def interrupted(signum: int, frame: object) -> None:
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (RuntimeError, CheckError) as error:
        report(f"ERROR: {error}")
        sys.exit(1)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Never print parser errors, subprocess stderr or HTTP payloads containing credentials.
        report(
            f"ERROR: WEB operation failed: {failure_summary(error)}; check the last reported stage and configuration"
        )
        sys.exit(1)
