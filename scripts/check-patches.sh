#!/usr/bin/env bash
#
# Verify that every patch under patches/ still applies to the revisions that
# frida/frida currently pins in its submodules.
#
# This mirrors what the build workflow does (clone -> git am in order), but
# without building anything, so drift is caught in seconds instead of after
# a full Android build.
#
# Usage: ./scripts/check-patches.sh [frida-ref]   (default: main)

set -euo pipefail
export LC_ALL=C

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PATCH_ROOT="$REPO_ROOT/patches"
FRIDA_REF=${1:-${FRIDA_REF:-main}}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '%s\n' "$*"; }
error() { printf '::error::%s\n' "$*" >&2; }

log "Resolving submodule revisions from frida/frida@$FRIDA_REF"

if ! git clone --quiet --depth 1 --filter=blob:none --no-checkout \
        --branch "$FRIDA_REF" https://github.com/frida/frida.git "$WORKDIR/frida"; then
  error "Unable to clone frida/frida@$FRIDA_REF"
  exit 1
fi

resolve_pin() {
  local name=$1 entry

  entry=$(git -C "$WORKDIR/frida" ls-tree HEAD "subprojects/$name")
  if [ -z "$entry" ]; then
    error "subprojects/$name is missing in frida@$FRIDA_REF"
    return 1
  fi

  printf '%s\n' "$entry" | awk '{ print $3 }'
}

check_repo() {
  local name=$1 sha=$2
  local dest="$WORKDIR/$name"
  local patch count=0

  log ""
  log "== $name@$sha"

  if ! git clone --quiet --filter=blob:none "https://github.com/frida/$name.git" "$dest"; then
    error "Unable to clone frida/$name"
    return 1
  fi

  if ! git -C "$dest" cat-file -e "$sha^{commit}" 2>/dev/null; then
    if ! git -C "$dest" fetch --quiet --depth 1 origin "$sha"; then
      error "Unable to fetch $sha from frida/$name"
      return 1
    fi
  fi

  if ! git -C "$dest" checkout --quiet --detach "$sha"; then
    error "Unable to check out $sha in frida/$name"
    return 1
  fi

  git -C "$dest" config user.name "Florida CI"
  git -C "$dest" config user.email "florida-ci@localhost"

  for patch in "$PATCH_ROOT/$name"/*.patch; do
    [ -e "$patch" ] || continue
    count=$((count + 1))

    if git -C "$dest" am --quiet "$patch" >"$WORKDIR/am.log" 2>&1; then
      log "  ok      $(basename "$patch")"
    else
      error "$(basename "$patch") does not apply to $name@$sha"
      sed 's/^/    /' "$WORKDIR/am.log" >&2
      git -C "$dest" am --abort >/dev/null 2>&1 || true
      return 1
    fi
  done

  if [ "$count" -eq 0 ]; then
    error "No patches found under patches/$name"
    return 1
  fi

  log "  $count patch(es) applied"
}

status=0

core_sha=$(resolve_pin frida-core) || status=1
gum_sha=$(resolve_pin frida-gum) || status=1

if [ "$status" -ne 0 ]; then
  exit 1
fi

check_repo frida-core "$core_sha" || status=1
check_repo frida-gum "$gum_sha" || status=1

if [ "$status" -ne 0 ]; then
  log ""
  log "Patch drift detected; update the failing patch(es) against the revisions above."
  exit 1
fi

log ""
log "All patches apply cleanly."
