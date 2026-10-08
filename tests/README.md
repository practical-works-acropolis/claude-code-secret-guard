# Tests

Run every case:

```
make test
```

or, without make:

```
./tests/run.sh
```

The runner prints one line per case and a summary like `total=159 mismatches=0`.
It exits non-zero if any case does not match.

## Case files

Each file in `tests/cases/` holds one case per line:

```
EXPECTED_EXIT|MODE|COMMAND
```

- `EXPECTED_EXIT` is `2` when the hook should block the command and `0` when it should allow it.
- `MODE` is `jq` to run with your normal `PATH`, or `nojq` to run with a `PATH` that holds only `cat`, `tr`, `sed` and `grep`. The `nojq` mode tests the plain-text JSON fallback for machines with no jq and no python3.
- `COMMAND` is the Bash command Claude would try to run. The hook only reads it. Nothing in these files is ever executed.

Files:

- `core.txt`: the basic cases (show a secret file, dump the environment, print one secret variable).
- `extended.txt`: more ways to print a secret, plus everyday commands that must keep working.
- `false-positives.txt`: normal developer commands that look close to a secret read but are fine.

## Run one file, or a different hook

```
./tests/run.sh hooks/block-secret-print.sh tests/cases/core.txt
```

## Adding a case

Found a bypass? Add a line with `2` as the expected exit, run the suite, and watch it fail.
Then fix the hook until the whole suite passes again. Found a command that is blocked but should not be? Add it with `0`.
