.PHONY: test test-nojq lint

test:
	./tests/run.sh

# Every case again, with a PATH that has no jq and no python3.
test-nojq:
	FORCE_NOJQ=1 ./tests/run.sh

lint:
	bash -n hooks/block-secret-print.sh tests/run.sh
	shellcheck -S warning hooks/block-secret-print.sh tests/run.sh
