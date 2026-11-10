#!/usr/bin/env bash
# Validate and test every app, and every package, in the repository.
#
#   scripts/verify-all.sh                 # everything, in parallel
#   scripts/verify-all.sh --only admin    # one target (comma-separate for more)
#
# Runs `native check` (manifest, markup, schema) and `native test`
# (headless update-logic and repository tests) for every app, and
# `zig build test` for every package - a dependency module's tests are
# not collected by the apps that depend on it, so the package has to
# prove itself. Reports a summary and exits non-zero if anything fails.
#
# The targets share nothing but a read-only source tree - each writes to
# its own cache and its own binary - so they run at once and each log is
# kept apart; a failure is read from its own file, not out of an
# interleaved stream.
set -u

cd "$(dirname "$0")/.." || exit 1

if ! command -v native >/dev/null 2>&1; then
  printf 'ros: the native CLI is not on PATH - run scripts/setup.sh\n' >&2
  exit 1
fi

only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      only="${2:-}"
      [ -n "$only" ] || { printf 'ros: --only wants a target list\n' >&2; exit 2; }
      shift 2
      ;;
    --only=*) only="${1#--only=}"; shift ;;
    *)
      printf 'ros: unknown argument %s - use --only <target[,target]>\n' "$1" >&2
      exit 2
      ;;
  esac
done

# The apps that carry copies of the shared screens, schema and shell
# chrome must agree before either is built: a drifted copy is a bug the
# tests cannot see.
if ! bash scripts/check-copies.sh; then
  exit 1
fi

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

targets=()

# One target: a job that writes its log and its verdict, and the shell
# keeps the pid so the wait can name it. A check that fails stops that
# target's test, not anybody else's.
run_target() {
  local name="$1"
  shift
  (
    if "$@" >"$logs/$name.log" 2>&1; then
      printf 'ok\n' >"$logs/$name.verdict"
    else
      printf 'FAILED\n' >"$logs/$name.verdict"
    fi
  ) &
  printf '%s %s\n' "$!" "$name" >>"$logs/jobs"
}

verify_package() {
  local name="$1"
  (cd "packages/$name" && zig build test)
}

verify_app() {
  local name="$1"
  native check "apps/$name" && native test "apps/$name" --yes
}

for package in packages/*/; do
  [ -f "$package/build.zig" ] || continue
  name="$(basename "$package")"
  if [ -z "$only" ] || [[ ",$only," == *",$name,"* ]]; then
    targets+=("$name:package")
  fi
done

for app in apps/*/; do
  name="$(basename "$app")"
  if [ -z "$only" ] || [[ ",$only," == *",$name,"* ]]; then
    targets+=("$name:app")
  fi
done

if [ "${#targets[@]}" -eq 0 ]; then
  printf 'ros: no target matched --only %s\n' "$only" >&2
  exit 2
fi

: >"$logs/jobs"
for spec in "${targets[@]}"; do
  name="${spec%%:*}"
  kind="${spec##*:}"
  if [ "$kind" = package ]; then
    run_target "$name" verify_package "$name"
  else
    run_target "$name" verify_app "$name"
  fi
done

wait

failed=0
for spec in "${targets[@]}"; do
  name="${spec%%:*}"
  verdict="$(cat "$logs/$name.verdict" 2>/dev/null || printf 'FAILED')"
  printf '==> %s: %s\n' "$name" "$verdict"
  if [ "$verdict" != ok ]; then
    sed 's/^/  | /' "$logs/$name.log" 2>/dev/null | tail -40
    failed=$((failed + 1))
  fi
done

if [ "$failed" -ne 0 ]; then
  printf '%d target(s) failed\n' "$failed" >&2
  exit 1
fi
printf 'all targets verified\n'
