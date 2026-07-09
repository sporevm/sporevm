#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/spore-build-copy-oracle.sh --context DIR --docker-tag TAG --spore-tag REF [--spore-arg ARG ...] [--path-prefix PATH ...]

Manual COPY oracle harness. It runs docker build and spore build on the same
Dockerfile context, then diffs sorted file metadata collected from both images.
Pass --path-prefix to restrict the diff to fixture-owned paths when the base
image has known Docker runtime metadata mounts.

Example:
  scripts/spore-build-copy-oracle.sh \
    --context /tmp/copy-fixture \
    --docker-tag spore-copy-oracle:docker \
    --spore-tag local/spore-copy-oracle:dev \
    --spore-arg --build-context --spore-arg base=oci-layout:///tmp/base-oci
USAGE
}

context=""
docker_tag=""
spore_tag=""
spore_args=()
path_prefixes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context="${2:?missing --context value}"
      shift 2
      ;;
    --docker-tag)
      docker_tag="${2:?missing --docker-tag value}"
      shift 2
      ;;
    --spore-tag)
      spore_tag="${2:?missing --spore-tag value}"
      shift 2
      ;;
    --spore-arg)
      spore_args+=("${2:?missing --spore-arg value}")
      shift 2
      ;;
    --path-prefix)
      path_prefixes+=("${2:?missing --path-prefix value}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$context" || -z "$docker_tag" || -z "$spore_tag" ]]; then
  usage
  exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/spore-build-copy-oracle.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

metadata_cmd='find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o -printf "%y %m %p -> %l\n" | sort'

docker build -t "$docker_tag" "$context" >/dev/null
spore_build=(zig build run -- build -t "$spore_tag")
if ((${#spore_args[@]} != 0)); then
  spore_build+=("${spore_args[@]}")
fi
spore_build+=("$context")
"${spore_build[@]}" >/dev/null

docker run --rm "$docker_tag" /bin/sh -c "$metadata_cmd" >"$tmp/docker.txt"
zig build run -- run --image "$spore_tag" -- /bin/sh -c "$metadata_cmd" >"$tmp/spore.txt"

if ((${#path_prefixes[@]} != 0)); then
  printf '%s\n' "${path_prefixes[@]}" >"$tmp/prefixes.txt"
  awk '
    NR == FNR { prefixes[++n] = $0; next }
    {
      path = $3
      for (i = 1; i <= n; i++) {
        prefix = prefixes[i]
        if (path == prefix || index(path, prefix "/") == 1) {
          print
          next
        }
      }
    }
  ' "$tmp/prefixes.txt" "$tmp/docker.txt" >"$tmp/docker.filtered.txt"
  awk '
    NR == FNR { prefixes[++n] = $0; next }
    {
      path = $3
      for (i = 1; i <= n; i++) {
        prefix = prefixes[i]
        if (path == prefix || index(path, prefix "/") == 1) {
          print
          next
        }
      }
    }
  ' "$tmp/prefixes.txt" "$tmp/spore.txt" >"$tmp/spore.filtered.txt"
  mv "$tmp/docker.filtered.txt" "$tmp/docker.txt"
  mv "$tmp/spore.filtered.txt" "$tmp/spore.txt"
fi

diff -u "$tmp/docker.txt" "$tmp/spore.txt"
