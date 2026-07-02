.PHONY: test

test:
	find . -maxdepth 2 -name '*.sh' -print | sort | xargs bash -n
	@missing="$$(find wireguard-scripts amnezia-scripts xray-scripts telemt-scripts -maxdepth 1 \( -name install.sh -o -name update.sh -o -name add-client.sh -o -name remove-client.sh -o -name uninstall.sh -o -name add-peer.sh -o -name remove-peer.sh \) ! -perm -111 -print)"; \
	if [ -n "$$missing" ]; then printf 'Public commands must be executable:\n%s\n' "$$missing"; exit 1; fi
	shellcheck -x core/*.sh ./*-scripts/*.sh tests/*.bats tests/test_helper.bash
	bats tests/*.bats
