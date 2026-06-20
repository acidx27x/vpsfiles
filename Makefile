.PHONY: test

test:
	find . -maxdepth 2 -name '*.sh' -print | sort | xargs bash -n
	shellcheck -x lib/*.sh ./*-scripts/*.sh tests/*.bats tests/test_helper.bash
	bats tests/*.bats
