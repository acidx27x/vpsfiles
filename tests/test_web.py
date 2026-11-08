"""WEB configuration preservation and transaction failure tests; no real services."""

import importlib.util
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
import json
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "web_config", Path(__file__).resolve().parents[1] / "telemt-scripts/web-config.py"
)
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)

BASE = """# existing installation
[general]
use_middle_proxy = false
[server]
port = 2443
[server.api]
enabled = true
listen = "127.0.0.1:9091"
[[server.listeners]]
ip = "0.0.0.0"
[access.users]
main = "000102030405060708090a0b0c0d0e0f"
phone = "00112233445566778899aabbccddeeff"
[access.user_max_unique_ips]
main = 2
phone = 3
[[upstreams]]
type = "socks5"
address = "127.0.0.1:1080"
enabled = true
"""
SITE = """server {
    listen 80;
    server_name xbubax.ru;
}
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name xbubax.ru;
    ssl_certificate /public/fullchain.pem;
    location / { try_files $uri $uri/ =404; }
}
"""


class WebTests(unittest.TestCase):
    def test_success_reports_stages_endpoints_backup_and_link_locations_without_secrets(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            install.telemt = Path(directory) / "telemt.toml"
            install.nginx = Path(directory) / "nginx.conf"
            install.clients = Path(directory) / "clients"
            install.telemt.write_text(
                web.managed(BASE, web.web_block(tomllib.loads(BASE), "xbubax.ru", "45.87.246.142:443"))
            )
            install.nginx.write_text(SITE)
            link_path = install.clients / "main" / "telemt-main-links.txt"
            private_link = b"web: tg://webproxy?server=example&secret=private-client-secret\n"
            console, stdout = StringIO(), StringIO()
            with (
                redirect_stderr(console),
                redirect_stdout(stdout),
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(install, "artifacts", return_value={link_path: private_link}),
                patch.object(install, "wait_ready"),
                patch.object(install, "wait_public_ready"),
                patch.object(web, "run"),
                patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)),
            ):
                install.transaction({install.nginx: SITE.encode()}, install.services, True)
                install.report_summary("WEB enabled; activation checks passed")
            output = console.getvalue()
            for text in (
                "Backup directory:",
                "Nginx configuration: OK",
                "Restarting telemt",
                "Reloading nginx",
                "Restarting xray",
                "Checking public HTTPS",
                "Fetching client links",
                str(link_path),
                "SUCCESS: WEB enabled",
                "Native MTProxy port: 2443",
                "https://xbubax.ru/telegram/web/",
                "WEB profiles: 2",
                "Backup retained at:",
            ):
                self.assertIn(text, output)
            self.assertLess(output.index("Restarting telemt"), output.index("Reloading nginx"))
            self.assertNotIn("private-client-secret", output)
            self.assertNotIn("000102030405060708090a0b0c0d0e0f", output)
            self.assertNotIn("tg://", output)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(link_path.read_bytes(), private_link)

    def test_status_keeps_stdout_machine_readable_when_checks_report_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            install.telemt = Path(directory) / "telemt.toml"
            install.telemt.write_text(
                web.managed(BASE, web.web_block(tomllib.loads(BASE), "xbubax.ru", "45.87.246.142:443"))
            )
            stdout, console = StringIO(), StringIO()

            def check(test_candidate):
                self.assertFalse(test_candidate)
                web.report("Checking installed configuration")
                return {}

            with (
                redirect_stdout(stdout),
                redirect_stderr(console),
                patch.object(web.sys, "argv", ["web-config.py", "status"]),
                patch.object(web, "Installation", return_value=install),
                patch.object(web, "run", return_value="telemt 3.5.16"),
                patch.object(install, "prepare", side_effect=check),
                patch.object(install, "ready"),
            ):
                web.main()
            self.assertTrue(json.loads(stdout.getvalue())["enabled"])
            self.assertIn("Checking installed configuration", console.getvalue())

    def test_public_probe_waits_for_xray_socket_after_systemd_reports_active(self):
        install = web.Installation()
        with (
            patch.object(
                install,
                "probe_public",
                side_effect=[subprocess.CalledProcessError(7, ["curl"]), None],
            ) as probe,
            patch.object(web.time, "sleep") as sleep,
        ):
            install.wait_public_ready()
        self.assertEqual(probe.call_count, 2)
        sleep.assert_called_once_with(1)

    def test_public_probe_does_not_retry_permanent_http_or_decoy_failures(self):
        install = web.Installation()
        for error in (subprocess.CalledProcessError(22, ["curl"]), web.CheckError("HTTP 404")):
            with (
                patch.object(install, "probe_public", side_effect=error) as probe,
                patch.object(web.time, "sleep") as sleep,
            ):
                with self.assertRaises(type(error)):
                    install.wait_public_ready()
                probe.assert_called_once()
                sleep.assert_not_called()

    def test_public_probe_preserves_final_startup_error_after_bounded_retries(self):
        install = web.Installation()
        error = subprocess.CalledProcessError(35, ["curl"], output="private diagnostic")
        with (
            patch.object(install, "probe_public", side_effect=error) as probe,
            patch.object(web.time, "sleep") as sleep,
        ):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                install.wait_public_ready()
            self.assertIs(caught.exception, error)
            self.assertEqual(probe.call_count, 10)
            self.assertEqual(sleep.call_count, 9)

    def test_transaction_reports_stage_and_keeps_subprocess_output_private(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            target = Path(directory) / "nginx.conf"
            target.write_bytes(b"original")
            install.nginx = target
            secret_output = "invalid configuration with secret=do-not-print"
            console = StringIO()
            with (
                redirect_stderr(console),
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(web, "run", side_effect=subprocess.CalledProcessError(1, ["nginx", "-t"], secret_output)),
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "validating Nginx configuration: nginx exited with code 1"
                ) as caught:
                    install.transaction({target: b"candidate"}, [])
            self.assertNotIn("do-not-print", str(caught.exception))
            self.assertNotIn("do-not-print", console.getvalue())
            self.assertIn("FAILED at validating Nginx configuration", console.getvalue())
            self.assertIn("Rolling back files and services", console.getvalue())
            self.assertIn("Rollback verified", console.getvalue())
            self.assertIn("Safe failure report:", console.getvalue())
            self.assertIn("Private command output:", console.getvalue())
            (backup,) = Path(directory).glob("web-*")
            failure = json.loads((backup / "failure.json").read_text())
            self.assertEqual(failure["stage"], "validating Nginx configuration")
            self.assertNotIn("do-not-print", json.dumps(failure))
            self.assertEqual((backup / "command-output.log").read_text(), secret_output)
            self.assertEqual((backup / "command-output.log").stat().st_mode & 0o777, 0o600)
            self.assertEqual(target.read_bytes(), b"original")

    def test_failure_diagnostic_write_error_does_not_prevent_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            target = Path(directory) / "config"
            target.write_bytes(b"original")
            write = web.atomic

            def write_without_diagnostics(path, data, mode=None):
                if path.name == "failure.json":
                    raise PermissionError("diagnostic write failed")
                write(path, data, mode)

            with (
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(install, "artifacts", side_effect=ValueError("API failure")),
                patch.object(web, "atomic", side_effect=write_without_diagnostics),
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "fetching client links.*previous files and services restored"
                ):
                    install.transaction({target: b"candidate"}, [])
            self.assertEqual(target.read_bytes(), b"original")

    def test_rollback_stops_web_process_before_restoring_native_only_config(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            target = Path(directory) / "telemt.toml"
            target.write_text(BASE)
            install.telemt = target
            candidate = web.managed(BASE, web.web_block(tomllib.loads(BASE), "xbubax.ru", "45.87.246.142:443"))
            events = []

            def command(*args):
                events.append(args)
                if args == ("systemctl", "stop", "telemt"):
                    self.assertEqual(target.read_text(), candidate)
                if args == ("systemctl", "restart", "telemt") and len(events) > 1:
                    self.assertEqual(target.read_text(), BASE)
                return ""

            with (
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(install, "wait_ready", side_effect=[web.CheckError("failed"), None]),
                patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)),
                patch.object(web, "run", side_effect=command),
            ):
                with self.assertRaisesRegex(RuntimeError, "checking service telemt readiness"):
                    install.transaction({target: candidate.encode()}, ["telemt"])
            self.assertEqual(
                events,
                [
                    ("systemctl", "restart", "telemt"),
                    ("systemctl", "stop", "telemt"),
                    ("systemctl", "restart", "telemt"),
                    ("systemctl", "is-active", "--quiet", "telemt"),
                ],
            )

    def test_path_link_upstream_vector(self):
        self.assertEqual(
            web.web_link("xbubax.ru/telegram/web", "000102030405060708090a0b0c0d0e0f"),
            "tg://webproxy?server=xbubax.ru%2Ftelegram%2Fweb&secret=cN0AAQIDBAUGBwgJCgsMDQ4P",
        )

    def test_profiles_idempotent_preserve_native(self):
        first = web.managed(BASE, web.web_block(tomllib.loads(BASE), "xbubax.ru", "45.87.246.142:443"))
        self.assertEqual(web.refresh_profiles(first), first)
        self.assertEqual(tomllib.loads(first)["server"]["port"], 2443)
        self.assertEqual(len(tomllib.loads(first)["server"]["listeners"]), 2)
        self.assertEqual(web.managed(first), BASE)
        self.assertEqual(tomllib.loads(first)["access"], tomllib.loads(BASE)["access"])

    def test_client_edits_and_disable_keep_new_clients(self):
        text = web.managed(BASE, web.web_block(tomllib.loads(BASE), "xbubax.ru", "45.87.246.142:443"))
        text = web.refresh_profiles(web.edit_user(text, "new.user", "f" * 32, 4))
        self.assertEqual(len(tomllib.loads(text)["web"]["vhosts"][0]["profiles"]), 3)
        text = web.refresh_profiles(web.edit_user(text, "phone", None, None))
        self.assertNotIn("phone", tomllib.loads(text)["access"]["users"])
        self.assertIn("new.user", tomllib.loads(web.managed(text))["access"]["users"])

    def test_ambiguous_managed_block_rejected(self):
        with self.assertRaises(ValueError):
            web.managed(BASE + web.BEGIN)
        with self.assertRaises(ValueError):
            web.web_link("host", "not-a-secret")

    def test_prepare_routes_and_preserves_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            install.telemt = Path(directory) / "telemt.toml"
            install.xray = Path(directory) / "xray.json"
            install.nginx = Path(directory) / "nginx.conf"
            install.telemt.write_text(BASE)
            install.nginx.write_text(SITE)
            config = {
                "inbounds": [
                    {"tag": "local-socks", "listen": "127.0.0.1", "port": 1080, "protocol": "socks"},
                    {
                        "port": 443,
                        "settings": {"clients": [{"id": str(i)} for i in range(10)]},
                        "streamSettings": {
                            "security": "reality",
                            "realitySettings": {
                                "target": "127.0.0.1:8443",
                                "serverNames": ["xbubax.ru"],
                                "privateKey": "existing",
                                "shortIds": ["same"],
                                "xver": 0,
                            },
                        },
                    },
                ],
                "outbounds": [{"tag": "next-hop", "protocol": "vless"}],
                "routing": {"rules": [{"type": "field", "inboundTag": ["local-socks"], "outboundTag": "next-hop"}]},
            }
            install.xray.write_text(json.dumps(config))

            def command(*args):
                if "--version" in args:
                    return "telemt 3.5.16"
                if "-V" in args:
                    return "--with-http_realip_module"
                if "-checkhost" in args:
                    return "Hostname xbubax.ru does match certificate"
                return ""

            with (
                patch.object(web, "run", side_effect=command),
                patch.object(install, "ready"),
                patch.object(
                    web,
                    "state",
                    side_effect=lambda bundle, name, default: (
                        "45.87.246.142" if name == "server-endpoint.txt" else default
                    ),
                ),
                patch.object(
                    web.socket, "getaddrinfo", return_value=[(None, None, None, None, ("45.87.246.142", 443))]
                ),
                patch.object(web.socket, "create_connection"),
                patch.object(web.socket, "socket"),
            ):
                # Every rejected preflight must leave the installed files intact.
                original = {p: p.read_bytes() for p in (install.telemt, install.xray, install.nginx)}
                with patch.object(web, "run", return_value="telemt 3.4.25"):
                    with self.assertRaisesRegex(ValueError, "Update Telemt"):
                        install.prepare()
                with patch.object(web.socket, "getaddrinfo", return_value=[]):
                    with self.assertRaisesRegex(ValueError, "DNS"):
                        install.prepare()
                for broken in (
                    BASE.replace("127.0.0.1:1080", "127.0.0.1:1081"),
                    BASE + '\n[[upstreams]]\ntype = "direct"\nenabled = true\n',
                ):
                    install.telemt.write_text(broken)
                    with self.assertRaises(ValueError):
                        install.prepare()
                install.telemt.write_text(BASE)
                config["inbounds"][1]["streamSettings"]["realitySettings"]["target"] = "external.example:443"
                install.xray.write_text(json.dumps(config))
                with self.assertRaisesRegex(ValueError, "external target migration"):
                    install.prepare()
                for path, contents in original.items():
                    path.write_bytes(contents)
                config["inbounds"][1]["streamSettings"]["realitySettings"]["target"] = "127.0.0.1:8443"
                changes = install.prepare()
                after = json.loads(changes[install.xray])
                self.assertEqual(after["inbounds"][1]["settings"], config["inbounds"][1]["settings"])
                self.assertEqual(after["routing"], config["routing"])
                self.assertIn(b"proxy_protocol;", changes[install.nginx])
                self.assertIn(b"proxy_next_upstream off;", changes[install.nginx])
                for path in (install.telemt, install.xray, install.nginx):
                    path.write_bytes(changes[path])
                self.assertEqual(install.prepare()[install.nginx], changes[install.nginx])
                config["routing"]["rules"].insert(0, {"type": "field", "outboundTag": "direct"})
                install.xray.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    install.prepare()

    def test_failed_activation_restores_files_and_inactive_service(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            target = Path(directory) / "telemt.toml"
            target.write_text(BASE)
            added = Path(directory) / "new.secret"
            install.telemt = target
            install.nginx = Path(directory) / "nginx"
            install.services = ["telemt", "nginx", "xray"]
            with (
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(install, "wait_ready", side_effect=ValueError("failed")),
                patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)),
                patch.object(web, "run") as command,
            ):
                with self.assertRaisesRegex(RuntimeError, "previous files and services restored"):
                    install.transaction({target: b"new", added: b"secret"}, ["telemt"])
                self.assertEqual(target.read_text(), BASE)
                self.assertFalse(added.exists())
                command.assert_any_call("systemctl", "stop", "telemt")

    def test_rollback_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            path = Path(directory) / "config"
            path.write_bytes(b"original")
            with (
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)),
                patch.object(web, "run", side_effect=subprocess.CalledProcessError(1, "systemctl")),
            ):
                with self.assertRaisesRegex(RuntimeError, "AND rollback failed"):
                    install.transaction({path: b"candidate"}, ["xray"])
                self.assertEqual(path.read_bytes(), b"original")

    def test_artifact_failure_restores_deleted_and_updated_files(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            config = Path(directory) / "config"
            removed = Path(directory) / "removed-links"
            config.write_bytes(b"original")
            config.chmod(0o640)
            removed.write_bytes(b"old link")
            with (
                patch.object(install, "backup_root", return_value=Path(directory)),
                patch.object(install, "artifacts", side_effect=ValueError("API unavailable")),
            ):
                with self.assertRaisesRegex(RuntimeError, "previous files and services restored"):
                    install.transaction({config: b"candidate", removed: None}, [])
                self.assertEqual(config.read_bytes(), b"original")
                self.assertEqual(config.stat().st_mode & 0o777, 0o640)
                self.assertEqual(removed.read_bytes(), b"old link")

    def test_web_health_checks_actual_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            install = web.Installation()
            install.telemt = Path(directory) / "telemt.toml"
            install.telemt.write_text(
                web.managed(BASE, web.web_block(tomllib.loads(BASE), "xbubax.ru", "45.87.246.142:443"))
            )
            from io import BytesIO
            from contextlib import closing

            with (
                patch.object(web, "run"),
                patch.object(web.socket, "create_connection"),
                patch.object(web.urllib.request, "build_opener") as opener,
            ):
                opener.return_value.open.return_value = closing(
                    BytesIO(b'{"data":{"ingress":{"accepting_connections":false}}}')
                )
                with self.assertRaisesRegex(ValueError, "not accepting"):
                    install.ready()
                opener.return_value.open.return_value = closing(
                    BytesIO(b'{"data":{"ingress":{"accepting_connections":true}}}')
                )
                install.ready()


if __name__ == "__main__":
    unittest.main()
