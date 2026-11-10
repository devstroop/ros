#!/usr/bin/env bash
# Copy the shared files from their source app into the apps that carry
# copies of them.
#
#   scripts/sync-copies.sh
#
# The SDK resolves an app's schema from `<app>/src/schema` and its markup
# imports from `<app>/src`, with no override, so the three apps carry
# byte-identical copies of the shared screens and of the whole schema.
# `apps/admin` is the source; `scripts/check-copies.sh` is the drift
# detector. This is the repair: edit the source, run this, and the check
# that verify-all runs is already agreed.
#
# Only files the destination already carries are synced - an app mounts
# only its role's screens, so a screen admin has and service does not is
# a choice, not drift. Adding one to an app's set stays a manual act (the
# checklist in AGENTS.md §7). The shell chrome is deliberately not
# copied: app.native holds the role's own pane between shared regions,
# and that half must not move.
set -u

cd "$(dirname "$0")/.." || exit 1

source_app="apps/admin"
copies="apps/service apps/kiosk"
synced=0

# --------------------------------------------------------------- screens

for app in $copies; do
  [ -d "$app/src/screens" ] || continue
  for file in "$app"/src/screens/*.native; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    source_file="$source_app/src/screens/$name"
    if [ ! -f "$source_file" ]; then
      printf 'copy: %s has no source in %s - check-copies will fail it\n' "$file" "$source_app" >&2
      continue
    fi
    if ! cmp -s "$source_file" "$file"; then
      cp "$source_file" "$file"
      printf 'screen: %s\n' "$file"
      synced=$((synced + 1))
    fi
  done
done

# ---------------------------------------------------------------- schema

# Every app carries the whole schema, so every file in the source lands
# in every copy - the list is synced too, not just the contents.
for app in $copies; do
  mkdir -p "$app/src/schema"
  for source_file in "$source_app"/src/schema/*; do
    [ -e "$source_file" ] || continue
    name="$(basename "$source_file")"
    if ! cmp -s "$source_file" "$app/src/schema/$name"; then
      cp "$source_file" "$app/src/schema/$name"
      printf 'schema: %s/src/schema/%s\n' "$app" "$name"
      synced=$((synced + 1))
    fi
  done
  for file in "$app"/src/schema/*; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    if [ ! -e "$source_app/src/schema/$name" ]; then
      rm "$file"
      printf 'schema: dropped %s - the source has no such file\n' "$file"
      synced=$((synced + 1))
    fi
  done
done

# ----------------------------------------------------------------- proof

# The sync is only honest if the checker agrees with it.
if bash scripts/check-copies.sh; then
  printf '%d file(s) synced\n' "$synced"
else
  printf 'sync-copies: the checker still disagrees - look above\n' >&2
  exit 1
fi
