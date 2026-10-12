#!/usr/bin/env bash
# Add or update a registry (Zot) user.
#   scripts/add-user.sh <username> [password]
# The user "admin" can overwrite and delete tags; everyone else can pull and push new tags.
set -euo pipefail
cd "$(dirname "$0")/.."

user="${1:?usage: $0 <username> [password]}"
pass="${2:-}"
if [[ -z "$pass" ]]; then
  read -rsp "Password for $user: " pass; echo
fi

touch zot/htpasswd
line=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass")
{ grep -v "^${user}:" zot/htpasswd || true; echo "$line"; } > zot/htpasswd.tmp
mv zot/htpasswd.tmp zot/htpasswd

# Restart only if the stack is running, so the new user is picked up
if docker compose ps --status running zot -q | grep -q .; then
  docker compose restart zot >/dev/null
fi
echo "User '$user' saved."
