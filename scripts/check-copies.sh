#!/usr/bin/env bash
# Check the files the three apps share by copy.
#
#   scripts/check-copies.sh
#
# The Native SDK resolves an app's schema from `<app>/src/schema` and its
# markup imports from `<app>/src`, and it has no option to point either at
# a shared directory. So the apps carry copies, and a copy that drifts is
# a bug that only shows up on one device.
#
# `apps/admin` is the source: it is the superset app, and every copy in
# `apps/service` and `apps/kiosk` must be byte-identical to it.
#
# Exits non-zero if a copy differs or is missing.
set -u

cd "$(dirname "$0")/.." || exit 1

source_app="apps/admin"
copies="apps/service apps/kiosk"
failed=0

# --------------------------------------------------------------- screens

for app in $copies; do
  for file in "$app"/src/screens/*.native; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    source_file="$source_app/src/screens/$name"
    if [ ! -f "$source_file" ]; then
      printf 'copy: %s has no source in %s\n' "$file" "$source_app" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! cmp -s "$source_file" "$file"; then
      printf 'copy: %s drifted from %s\n' "$file" "$source_file" >&2
      failed=$((failed + 1))
    fi
  done
done

# ---------------------------------------------------------------- schema

# Every app carries the whole schema: the SDK opens a database per app,
# and a device that has one migration fewer cannot read the rows another
# device wrote.
for app in $copies; do
  source_list="$(cd "$source_app/src/schema" && ls)"
  copy_list="$(cd "$app/src/schema" && ls)"
  if [ "$source_list" != "$copy_list" ]; then
    printf 'schema: %s/src/schema does not list the same files as %s\n' "$app" "$source_app" >&2
    failed=$((failed + 1))
    continue
  fi
  for name in $source_list; do
    if ! cmp -s "$source_app/src/schema/$name" "$app/src/schema/$name"; then
      printf 'schema: %s/src/schema/%s drifted\n' "$app" "$name" >&2
      failed=$((failed + 1))
    fi
  done
done

# ---------------------------------------------------------------- chrome

# The shell - the title bar, the banners, the session gates, the rail and
# the status bar - is shared by the three apps too, but the apps cannot
# share `app.native` itself: the content pane inside it mounts only the
# screens that app's role may open. So the chrome is compared as the
# region between the shell's opening element and the pane, plus the status
# bar line, and the pane's own `screen_index` gates are left out.
#
# Everything up to the pane is byte-identical in the three files today;
# this is what keeps a chrome fix from landing in one app only.
chrome() {
  awk '/^<column grow="1" background="background">$/ { f = 1 }
       f { print }
       /<column grow="1">$/ { if (f) exit }' "$1"
  sed -n 's|.*\(<status-bar>.*</status-bar>\).*|\1|p' "$1"
}

for app in $copies; do
  if ! diff -q <(chrome "$source_app/src/app.native") <(chrome "$app/src/app.native") >/dev/null; then
    printf 'chrome: %s/src/app.native drifted from %s\n' "$app" "$source_app" >&2
    diff -u <(chrome "$source_app/src/app.native") <(chrome "$app/src/app.native") >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -ne 0 ]; then
  printf '%d shared file(s) drifted - edit %s and run scripts/sync-copies.sh\n' "$failed" "$source_app" >&2
  exit 1
fi
printf 'shared files agree\n'
