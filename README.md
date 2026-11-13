# Claude Code secret guard

A Claude Code hook that stops Claude from printing your secret values.

It runs before every Bash command Claude wants to run. If the command would print a secret to the screen, the hook blocks it and tells Claude a safer way to get what it needs. That covers `.env` files, credential files, `printenv`, and tools that read tokens out of a secret manager.

## Why we built it

An AI session nearly printed real keys into a chat log. Claude wanted to check a config value, so it reached for `cat .env`. Once a value is on screen, it is in the transcript. It can end up in logs, in shared sessions, in screenshots. You have to rotate it.

A rule in a prompt is a request. A hook is a check that runs every time. So we wrote one.

## Install (2 minutes)

From the root of your project:

```
mkdir -p .claude/hooks
curl -fsSL -o .claude/hooks/block-secret-print.sh \
  https://raw.githubusercontent.com/practical-works-acropolis/claude-code-secret-guard/main/hooks/block-secret-print.sh
chmod +x .claude/hooks/block-secret-print.sh
```

Or copy `hooks/block-secret-print.sh` from this repo by hand.

Then wire it up in `.claude/settings.json`. If you have no settings file yet, copy [`examples/settings.json`](examples/settings.json). If you already have one, add this under `hooks`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/block-secret-print.sh\""
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code. Ask it to `cat .env`. It should be blocked.

To guard every project on your machine, put the hook in `~/.claude/hooks/` and the same block in `~/.claude/settings.json`, with the path changed to `$HOME/.claude/hooks/block-secret-print.sh`.

It needs only bash. It works on macOS bash 3.2 and Linux bash. It uses jq if you have it, then python3, then a plain-text fallback.

## Test it yourself

```
make test
```

or `./tests/run.sh`. Each line in `tests/cases/` is a command and the result we expect: block or allow. The runner sends each one to the hook the same way Claude Code does. No case is ever executed.

`make test-nojq` runs every case again with no jq and no python3 on the PATH.

See [`tests/README.md`](tests/README.md) for the case format.

## What it blocks

- Dumping the environment: `env`, `printenv`, `export -p`, bare `set`, `declare -p`. Also inside a container, like `docker exec app env`.
- Printing one secret-looking variable: `echo $STRIPE_SECRET_KEY`, `printenv API_KEY`.
- Showing secret files: `cat .env`, `head .env.local`, `less server.pem`, `cat ~/.aws/credentials`, `git show HEAD:.env`, `while read ... done < .env`.
- `grep`, `sed`, `awk` over a secret file when the matching lines would print.
- One-line scripts that print a secret file or the environment: `python3 -c`, `node -e`, `ruby -e`, `perl -e`.
- Tools that print resolved secrets: `docker compose config`, `docker inspect`, `kubectl get secret -o yaml`, `heroku config`, `gh auth token`, and secret manager readers for AWS, Google Cloud, 1Password, Vault, Doppler and Infisical.

## What it allows

- Commands that do not print values: `wc -c .env`, `grep -c KEY .env`, `grep -q KEY .env`, `cut -d= -f1 .env`.
- Copying and editing secret files: `cp .env .env.backup`, `sed -i`.
- Output sent to a file instead of the screen.
- Template files: `.env.example`, `.env.sample`, `.env.template`.
- Using a value without showing it: `curl -H "Authorization: Bearer $(gh auth token)" ...`
- Normal work: `grep -rn token src`, `cat src/auth/token.ts`, `npm test`, `git diff`.

## Known gaps

This is a seatbelt, not a lock. It catches the common accidents. It does not catch everything. Here is what we know gets through:

- **Copy, then print.** If Claude copies `.env` to `notes.txt` in one command and runs `cat notes.txt` in the next, the second command is allowed. Nothing in it looks secret.
- **Scripts saved to a file, then run.** The hook reads the command line. It does not read a script Claude wrote to disk and then runs.
- **Recursive grep over the whole project.** `grep -rn KEY .` searches `.env` too, but the command never names it, so the hook cannot tell.

Keep real secrets out of the repo, and treat any value that shows up in a transcript as leaked. Rotate it.

## Found a bypass?

Open a GitHub issue. Include the command and what it printed, with the secret replaced by a placeholder. Never paste a real value. A pull request that adds a failing case to `tests/cases/` is even better.

## The SHIP Kit

This hook is one piece of [The SHIP Kit](https://ship-kit.pages.dev), our production guardrails for Claude Code: skills that make "done" mean done, one task per worktree, clean pull requests, a pre-launch audit, a starter CLAUDE.md and a 30-minute walkthrough.

Built by [Practical Works](https://practical.works).

## License

MIT. See [LICENSE](LICENSE).
