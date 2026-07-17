# Shared VPS helpers

Scripts in `core/` are sourced by the standalone Debian/Ubuntu bundles. They are libraries, not commands to run directly.

## Docker Engine and Compose

`docker.sh` provides the shared Docker setup used by container-based bundles. Source it after the base and installation helpers:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=core/core.sh
. "${REPO_ROOT}/core/core.sh"
# shellcheck source=core/install.sh
. "${REPO_ROOT}/core/install.sh"
# shellcheck source=core/docker.sh
. "${REPO_ROOT}/core/docker.sh"

vps_require_root "sudo ./install.sh"
vps_docker_ensure_ready
vps_docker_compose /etc/example-proxy example-proxy config
vps_docker_compose /etc/example-proxy example-proxy up -d
```

`vps_docker_ensure_ready` reuses Docker when the daemon responds and the Compose v2 plugin works. When Docker is completely absent, it configures Docker's signed official Debian/Ubuntu apt repository and installs Docker CE, the CLI, containerd, Buildx, and Compose. It deliberately stops on partial or broken installations instead of replacing packages or deleting existing Docker data.

The helper enables `docker.service`, but it does not add users to the privileged `docker` group. Application uninstallers must not remove Docker packages, Docker's apt repository, daemon configuration, global build cache, or resources belonging to other Compose projects.

### Networking and firewall ownership

Docker bridge port publishing and UFW do not share the same packet path: published container traffic can be diverted before UFW's normal rules. See [Docker's packet-filtering documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw). A bundle must either use host networking so its existing host firewall rules remain authoritative, or explicitly own the required Docker firewall-chain rules.

Each bundle must use a fixed, unique Compose project name and labels for resources it creates. Cleanup must target only that project and those labels; never use global `docker system prune` or broad image/container deletion.

### Lifecycle and secrets

Prefer a Docker restart policy such as `unless-stopped`. Do not combine a container restart policy with a competing systemd unit that independently starts and stops the same container; Docker documents that these approaches can conflict in its [restart-policy guidance](https://docs.docker.com/engine/containers/start-containers-automatically/).

Environment files should be root-owned with mode `0600`. Their values remain visible to root and anyone with access to the Docker daemon, so membership in the `docker` group must be treated as root-equivalent access.
