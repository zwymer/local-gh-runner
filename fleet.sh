#!/usr/bin/env bash
# Run a docker compose command against exactly one runner fleet.
#
# Every fleet lives in this one directory and shares compose.base.yml, so the
# project name and the -f list have to be right or you act on the wrong fleet.
# This wrapper supplies both, so they cannot be wrong.
#
#   ./fleet.sh edtok up -d
#   ./fleet.sh edtok ps
#   ./fleet.sh leetspeak down
set -euo pipefail

usage() {
  echo "usage: $0 <edtok|leetspeak> <docker compose args...>" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
fleet=$1
shift

case "$fleet" in
  edtok)     project=local-gh-runner ;;
  leetspeak) project=leetspeak-gh-runner ;;
  *)         usage ;;
esac

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# docker-credential-wincred lives in Docker's bin directory and is not on PATH
# by default; without it every build dies during "load metadata" with an opaque
# "error getting credentials" failure.
docker_bin="/c/Program Files/Docker/Docker/resources/bin"
if [[ -d "$docker_bin" && ":$PATH:" != *":$docker_bin:"* ]]; then
  PATH="$PATH:$docker_bin"
  export PATH
fi

base="$root/compose.base.yml"
overlay="$root/compose.$fleet.yml"
for f in "$base" "$overlay"; do
  [[ -f "$f" ]] || { echo "missing compose file: $f" >&2; exit 1; }
done

echo "fleet=$fleet project=$project -> docker compose $*"
exec docker compose -p "$project" -f "$base" -f "$overlay" "$@"
