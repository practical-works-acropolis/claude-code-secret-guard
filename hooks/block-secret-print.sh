#!/usr/bin/env bash
# block-secret-print.sh
#
# A guard for Claude Code. It runs BEFORE every Bash command Claude wants to run.
# If the command would PRINT a secret value to the screen (and so into the chat
# transcript), it blocks the command and tells Claude a safer way to do it.
#
# What it blocks:
#   - dumping all environment variables: env, printenv, export, export -p, bare
#     "set", declare -p, also inside a container (docker exec app env)
#   - printing one secret-looking variable: echo $STRIPE_SECRET_KEY, printenv API_KEY
#   - showing secret files: cat .env, head .env.local, less key.pem, cat ~/.aws/credentials,
#     git show HEAD:.env, while read ... done < .env, echo "$(< .env)"
#   - grep/sed/awk over a secret file that would print the matching lines
#   - one-line scripts that print a secret file or the environment:
#     python3 -c "print(open('.env').read())", node -e "console.log(process.env)"
#   - tools that print resolved secrets: docker compose config, docker inspect,
#     kubectl get secret -o yaml, heroku config, gh auth token, cloud secret readers
#
# Known gaps (it is a seatbelt): copying a secret file somewhere else and then
# printing the copy, recursive grep over the whole project, and scripts saved to
# a file and then run.
#
# What it allows:
#   - anything that does not print values: wc -c .env, grep -c KEY .env, grep -q KEY .env
#   - copying or editing secret files: cp .env .env.backup, sed -i
#   - output sent to a file instead of the screen: cat .env > /tmp/check.txt
#   - template files: cat .env.example, .env.sample, .env.template
#
# How Claude Code talks to it:
#   Claude Code sends the planned command as JSON on stdin.
#   Exit 0 = allow. Exit 2 = block (the message on stderr is shown to Claude).
#   If anything inside this script goes wrong, it allows the command. A bug in a
#   guard should never lock you out of your own terminal.
#
# This is a seatbelt, not a lock. It catches the common accidents. It cannot
# stop every possible way to print a value, so keep real secrets out of the repo.
#
# Works on macOS bash 3.2 and Linux bash. Uses jq if installed, then python3,
# then a plain-text fallback.

set -u

input="$(cat 2>/dev/null)" || exit 0
[ -z "${input:-}" ] && exit 0

# ---- 1. Pull the command string out of the JSON -----------------------------
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || cmd=""
fi
if [ -z "$cmd" ] && command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print((d.get("tool_input") or {}).get("command") or "")
except Exception:
    pass' 2>/dev/null)" || cmd=""
fi
if [ -z "$cmd" ]; then
  # Plain-text fallback: grab the text after "command":" and undo simple escapes.
  cmd="$(printf '%s' "$input" | tr '\n' ' ' \
    | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' \
    | sed 's/\\"/"/g; s/\\\\/\\/g')"
fi
[ -z "${cmd:-}" ] && exit 0

low="$(printf '%s' "$cmd" | tr 'A-Z' 'a-z')"

block() {
  printf 'BLOCKED by secret-print guard: %s\n' "$1" >&2
  exit 2
}

# Word start, written out so it works the same in GNU and BSD grep.
W='(^|[^a-z0-9_])'

# Files whose CONTENTS are secret.
#   .env, .env.local, .env.production (but not process.env in code)
#   .envrc .npmrc .netrc .pgpass, *.tfvars, *.pem *.key *.p12 *.pfx *.jks
#   credentials, secrets.yaml, client_secret.json, token.txt
#   service-account*.json, ssh keys, ~/.aws/ ~/.ssh/ docker and kube config
#   A bare word like "token" or "password" is NOT a file (so grep -rn token src
#   stays allowed). It needs a file extension, or a path like /credentials.
SECRET_FILE='((^|[[:space:]/"'"'"'=<:])\.env([./][a-z0-9._-]+)?([^a-z0-9._-]|$)|\.envrc|\.npmrc|\.netrc|\.pgpass|\.dev\.vars|[a-z0-9._/-]*\.tfvars|[a-z0-9._/-]*\.(pem|key|p12|pfx|jks|keystore)([^a-z0-9]|$)|[a-z0-9._/-]*(secret|credential|passwd|password|token)s?\.(json|txt|ya?ml|env|ini|conf|cfg|toml|csv)([^a-z0-9._/-]|$)|/credentials([^a-z0-9._-]|$)|/run/secrets/|[a-z0-9._/-]*service[-_]?account[a-z0-9._/-]*\.json|id_(rsa|ed25519|ecdsa|dsa)([^.a-z]|$)|/proc/[^[:space:]]*/environ|\.aws/|\.ssh/|\.docker/config\.json|\.kube/config)'

# Variable names that look secret.
SECRET_VAR='(secret|token|passw|signing|api[_-]?key|[_-]key([^a-z0-9]|$)|cred|private|database_url|db_url|dsn|auth|webhook)'

# Output goes to a file, not the screen. (2>&1 and >/dev/null do not count.)
is_redirected() {
  printf '%s' "$cmd" | sed -E 's/[0-9]?>&[0-9]//g; s/[0-9]?>[[:space:]]*\/dev\/null//g' \
    | grep -Eq '>>?[[:space:]]*[^&[:space:]]'
}

# Value is hidden or only its length is shown.
is_redacted() {
  printf '%s' "$low" | grep -Eq '<(hidden|redacted)>|s/=[.][*]|s#=[.][*]|s\|=[.][*]|-f1([^0-9]|$)|\$\{#'
}

# Template files are not secret. Strip them before checking.
touches_secret_file() {
  printf '%s' "$low" \
    | sed -E 's/[a-z0-9._/-]*\.(example|sample|template|dist|md)([[:space:]"'"'"']|$)/ /g' \
    | grep -Eq "$SECRET_FILE"
}

# Start of a command: the very start, or right after ; & | (but not inside $( ),
# so curl -H "Bearer $(gh auth token)" stays allowed: it uses the value, it does
# not print it).
SEG='(^[[:space:]]*|[;&|][[:space:]]*|sudo[[:space:]]+)'

# ---- 2. Whole-environment dumps ---------------------------------------------
ENVDUMP='(env|printenv|export|export[[:space:]]+-p|set|declare|declare[[:space:]]+-[a-z]*[px][a-z]*|typeset|typeset[[:space:]]+-[a-z]*[px][a-z]*)'
if printf '%s' "$low" | grep -Eq "(^|[;&|(\`][[:space:]]*)${ENVDUMP}([[:space:]]*\$|[[:space:]]*[;&)\`])"; then
  block "this dumps every environment variable, including secrets. Refer to variables by NAME. To check one is set: [ -n \"\$MY_VAR\" ] && echo set"
fi

# The same dump inside a container or pod: docker exec app env, kubectl exec pod -- printenv
if printf '%s' "$low" | grep -Eq "${W}exec[[:space:]][^;&|]*[[:space:]](env|printenv)([[:space:]]*\$|[[:space:]]*[;&|)])"; then
  is_redirected || block "this dumps the container's environment, including secrets. Check one name instead: docker exec app sh -c '[ -n \"\$NAME\" ] && echo set'"
fi

# printenv with a name prints that value.
if printf '%s' "$low" | grep -Eq "${W}printenv[[:space:]]+[a-z_]"; then
  is_redirected || block "printenv NAME prints the value. To check it is set without showing it: [ -n \"\$NAME\" ] && echo set"
fi

# env | grep KEY prints matching values.
if printf '%s' "$low" | grep -Eq "${W}(env|printenv|set|export|declare[[:space:]]+-p|typeset[[:space:]]+-p)[[:space:]]*\|"; then
  if printf '%s' "$low" | grep -Eq '\|[[:space:]]*grep[^|;]*[[:space:]]-[a-z]*[cql]'; then :
  elif printf '%s' "$low" | grep -Eq '\|[[:space:]]*wc([[:space:]]|$)'; then :
  elif is_redacted; then :
  else block "piping the environment into another command prints the values. Use grep -c to count, or cut -d= -f1 to show names only."
  fi
fi

# ---- 3. echo / printf of a secret-looking variable ---------------------------
if printf '%s' "$low" | grep -Eq "${W}(echo|printf|print)${W}[^>]*\\\$\\{?[a-z0-9_]*${SECRET_VAR}"; then
  is_redacted || is_redirected || block "this prints a secret-looking variable. Show only its length instead: echo \"length \${#MY_VAR}\""
fi

# ---- 4. Pagers and dumpers on a secret file ---------------------------------
if printf '%s' "$low" | grep -Eq "${W}(cat|bat|less|more|head|tail|xxd|od|hexdump|strings|nl|tac|rev|column|jq|yq|base64|dd)${W}" && touches_secret_file; then
  is_redirected || block "this shows the contents of a secret file. Safe options: wc -c FILE (size), grep -c NAME FILE (count), grep -q NAME FILE (exists), cut -d= -f1 FILE (names only)."
fi

# git show HEAD:.env, git diff .env, git log -p -- .env print old secret values.
if printf '%s' "$low" | grep -Eq "${W}git[[:space:]]([^|;&]*[[:space:]])?(show|diff|blame|cat-file|log[^|;&]*[[:space:]]-p)([[:space:]]|\$)" && touches_secret_file; then
  is_redirected || block "this prints a secret file from git. To see whether it was ever committed: git log --all --oneline -- .env (names and commits only)."
fi

# Reading a secret file through input redirection: done < .env, "$(< .env)"
redir_in="$(printf '%s' "$low" | grep -oE '(^|[^<])<[[:space:]]*[^[:space:]<(;&|)]+' | tr '\n' ' ')"
if [ -n "$redir_in" ] && printf ' %s' "$redir_in" | grep -Eq "$SECRET_FILE"; then
  if printf '%s' "$low" | grep -Eq "${W}wc${W}|${W}(grep|egrep|fgrep|rg)[[:space:]]([^|;]*[[:space:]])?-[a-z]*[cql]"; then :
  elif is_redacted || is_redirected; then :
  else block "this reads a secret file into a command that can print it. Safe options: wc -c FILE, grep -c NAME FILE, cut -d= -f1 FILE."
  fi
fi

# ---- 5. grep / sed / awk over a secret file ---------------------------------
if printf '%s' "$low" | grep -Eq "${W}(grep|egrep|fgrep|rg|ag|ack|sed|awk|perl|cut|sort|uniq|diff)${W}" && touches_secret_file; then
  if printf '%s' "$low" | grep -Eq "${W}(grep|egrep|fgrep|rg)[[:space:]]([^|;]*[[:space:]])?-[a-z]*[cql]"; then : # count / quiet / file names only
  elif printf '%s' "$low" | grep -Eq "${W}sed[[:space:]]+-i"; then :                                       # edit in place, prints nothing
  elif is_redacted; then :                                                                                  # values hidden
  elif is_redirected; then :                                                                                # written to a file
  else block "this would print lines from a secret file. Use grep -c (count), grep -q (exists), cut -d= -f1 (names only), or sed 's/=.*/=<hidden>/'."
  fi
fi

# ---- 6. One-line scripts: python -c, node -e, ruby -e, perl -e, php -r ------
if printf '%s' "$low" | grep -Eq "${W}(python[0-9.]*|node|nodejs|ruby|perl|php|bun|deno)[[:space:]]([^|;&]*[[:space:]])?(-[a-z]*[cepr][a-z]*|eval)([[:space:]]|\$)"; then
  hit=""
  touches_secret_file && hit=1
  # the whole environment: process.env on its own, os.environ on its own, ENV in ruby
  printf '%s' "$low" | grep -Eq 'process\.env([^.a-z0-9_[]|$)|os\.environ([^.a-z0-9_[]|$)|os\.environ\.(items|copy|keys|values)|(^|[^a-z0-9_])env\.(to_h|each|inspect)' && hit=1
  # one secret-looking variable
  printf '%s' "$low" | grep -Eq "(process\\.env\\.|process\\.env\\[|environ\\[|environ\\.get\\(|getenv\\(|env\\[)[\"' ]*[a-z0-9_]*${SECRET_VAR}" && hit=1
  if [ -n "$hit" ]; then
    is_redacted || is_redirected || block "this script prints a secret file or secret environment values. Print names or lengths only, for example: python3 -c \"import os; print(len(os.environ.get('NAME','')))\""
  fi
fi

# ---- 7. Tools that print resolved secrets -------------------------------------
# docker compose config fills in every value from .env. Listing names is fine.
if printf '%s' "$low" | grep -Eq "${W}docker([[:space:]]+|-)compose[[:space:]]([^|;&]*[[:space:]])?config([[:space:]]|\$)" \
  && ! printf '%s' "$low" | grep -Eq -- '--(services|volumes|images|profiles|hash|quiet)|[[:space:]]-q([[:space:]]|$)'; then
  is_redirected || block "docker compose config prints every resolved value, including secrets. Use docker compose config --services, or docker compose config -q to only validate."
fi
# docker inspect prints the container's environment unless --format picks a field.
if printf '%s' "$low" | grep -Eq "${W}docker[[:space:]]+(container[[:space:]]+|image[[:space:]]+)?inspect([[:space:]]|\$)" \
  && ! printf '%s' "$low" | grep -Eq -- '--format|[[:space:]]-f[[:space:]]'; then
  is_redirected || block "docker inspect prints the container's environment, including secrets. Pick one field: docker inspect --format '{{.State.Status}}' NAME"
fi
# kubectl get secret -o yaml/json shows the (only base64-encoded) values.
if printf '%s' "$low" | grep -Eq "${W}kubectl[[:space:]]([^|;&]*[[:space:]])?get[[:space:]]+secrets?([[:space:]]|/)" \
  && printf '%s' "$low" | grep -Eq -- '(-o|--output)[[:space:]=]*(yaml|json|jsonpath|go-template)'; then
  is_redirected || block "this prints Kubernetes secret values (base64 is not encryption). Use kubectl describe secret NAME to see key names and sizes."
fi
# Secret managers and hosting CLIs that print a value, when run on their own.
# Inside $( ) they only pass the value along, so they are allowed there.
if printf '%s' "$low" | grep -Eq "${SEG}(heroku[[:space:]]+config([[:space:]]*\$|[[:space:]]*[;&|]|:get)|railway[[:space:]]+variables|gcloud[[:space:]]+secrets[[:space:]]+versions[[:space:]]+access|gcloud[[:space:]]+auth[[:space:]]+print-(access|identity)-token|aws[[:space:]]+secretsmanager[[:space:]]+get-secret-value|aws[[:space:]]+ssm[[:space:]]+get-parameters?[^|;&]*with-decryption|gh[[:space:]]+auth[[:space:]]+token|op[[:space:]]+read|vault[[:space:]]+(kv[[:space:]]+)?(get|read)|doppler[[:space:]]+secrets|infisical[[:space:]]+secrets)"; then
  is_redirected || block "this prints a secret value from a secret manager or host. Use it inside a command instead (for example curl -H \"Authorization: Bearer \$(gh auth token)\" ...), or list names only."
fi

exit 0
