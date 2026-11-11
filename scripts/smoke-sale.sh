#!/usr/bin/env bash
# Drive a real sale through the app, headlessly.
#
#   scripts/smoke-sale.sh [--keep]
#
# The CI smoke used to assert only that the canvas had pixels, so a
# blank role picker or a shell gate pointing at the wrong screen still
# passed. This script walks the path an operator walks:
#
#   walk-through -> sign out -> the pad -> PIN login -> the picker ->
#   POS -> add a dish -> Place order -> Orders -> theme -> Appearance
#   -> brand colour -> Team -> reset the sign-in to a password ->
#   the field -> KDS
#
# It then copies the database the admin wrote into the kiosk's data
# directory and asserts the same ticket is on the kitchen board, so the
# screen after the sale is exercised too, not just the till.
#
# Environment:
#   ROS_SMOKE_DATA       data directory to use (default: a temp dir)
#   ROS_SMOKE_KEEP=1     keep the data directory and screenshots
#   ROS_SMOKE_PRESS_MS   how long a press waits for its screen before
#                        it is repeated (default: 3000)
#
# Linux CI runs this under xvfb-run; a local session can use its own
# DISPLAY. When no DISPLAY is set, the script re-executes itself under
# xvfb-run if it is available.
set -euo pipefail

cd "$(dirname "$0")/.."

keep="${ROS_SMOKE_KEEP:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep)
      keep=1
      shift
      ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'smoke-sale: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
  ROS_SMOKE_KEEP="$keep" exec xvfb-run -a "$0"
fi

if ! command -v native >/dev/null 2>&1; then
  printf 'ros: the native CLI is not on PATH - run scripts/setup.sh\n' >&2
  exit 1
fi

data_dir="${ROS_SMOKE_DATA:-$(mktemp -d "${TMPDIR:-/tmp}/ros-sale-smoke.XXXXXX")}"
mkdir -p "$data_dir/logs" "$data_dir/screens"
admin_data="$data_dir/com.devstroop.ros.admin"
kiosk_data="$data_dir/com.devstroop.ros.kiosk"

app_pid=""
app_dir=""

stop_app() {
  if [ -n "$app_pid" ] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 100); do
      kill -0 "$app_pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -9 "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" 2>/dev/null || true
  fi
  app_pid=""
}

cleanup() {
  local status="$1"
  stop_app
  if [ "$keep" -eq 1 ] || [ "$status" -ne 0 ]; then
    printf 'smoke-sale: data kept at %s\n' "$data_dir"
  else
    rm -rf "$data_dir"
  fi
}

trap 'status=$?; cleanup "$status"' EXIT

fail() {
  printf 'smoke-sale: %s\n' "$*" >&2
  exit 1
}

start_app() {
  local app="$1" bin="$2"
  app_dir="apps/$app"
  rm -rf "$app_dir/.zig-cache/native-sdk-automation"
  # The automation server publishes `.zig-cache/native-sdk-automation`
  # relative to the process's working directory, and the CLI looks for
  # it there too. Launching from the repo root would leave the snapshot
  # somewhere `native automate` never looks.
  (cd "$app_dir" && exec env XDG_DATA_HOME="$data_dir" "./zig-out/bin/$bin") \
    >"$data_dir/logs/$app.log" 2>&1 &
  app_pid=$!
}

automate() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    if (cd "$app_dir" && native automate "$@"); then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# The id of a widget by its role and accessible name. Names are matched
# literally: a price with a $ in it is not a regex. The id must come
# from the widget header — a greedy `.*#` would pick up `parent=#…`
# later on the same line.
snapshot_id() {
  sed -n 's/.*widget @w1\/main-canvas#\([0-9]*\) role=.*/\1/p' | head -1
}

widget_id() {
  local role="$1" name="$2"
  automate snapshot | { grep -F "role=$role name=\"$name\"" || true; } | snapshot_id
}

# A view that refreshes on a timer rebuilds its tree, and a widget id
# read from one snapshot can be retired before the command carrying it
# arrives: the app rejects the stale id and nothing happens. So every
# interaction is repeated until the screen says it landed.
press_window_ms="${ROS_SMOKE_PRESS_MS:-3000}"

# Press a control, and press it again if what was asked of the screen
# did not follow. The app's own guards - a sale still being saved, an
# order already moving - make a repeated press safe rather than a second
# sale, and a toggle is pressed only until its state really moves, so an
# extra press is undone by the next one rather than doubled.
tap() {
  local role="$1" name="$2"
  shift 2
  local attempt id
  for attempt in 1 2 3 4 5 6 7 8; do
    id="$(widget_id "$role" "$name")"
    [ -n "$id" ] || fail "\"$name\" left the screen and \"$*\" never held"
    automate widget-click main-canvas "$id" >/dev/null 2>&1 || true
    if automate assert --timeout-ms "$press_window_ms" "$@" >/dev/null 2>&1; then
      return 0
    fi
  done
  fail "pressing \"$name\" never held: $*"
}

# The text a field holds is published back as a `text="…"` attribute; a
# field that holds nothing carries no such attribute, so an empty reading
# means empty rather than unread.
box_text() {
  automate snapshot |
    { grep -F "main-canvas#$1 " || true; } |
    sed -n 's/.* text="\([^"]*\)".*/\1/p' |
    head -1
}

# Type into a field, and type again until the field says it holds the
# value. A press can be verified by what the screen does, but a keystroke
# leaves no screen behind to read: the host answers a stale id with
# "delivered", drops the command, and the walk-through continues with an
# empty field that every later step assumes is filled.
# Read only after a pause. The snapshot is what the screen has painted,
# so a field read the moment after the keystroke is usually still empty
# even though the app took it. Waiting costs one poll, not a type: the
# buffer keeps whatever already landed, so typing again on a false
# negative appends the value a second time.
type_into() {
  local name="$1" value="$2" id attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    id="$(widget_id textbox "$name")"
    [ -n "$id" ] || fail "no textbox named \"$name\" on screen"
    automate widget-action main-canvas "$id" set_text "$value" >/dev/null 2>&1 || true
    sleep 0.25
    if [ "$(box_text "$id")" = "$value" ]; then
      return 0
    fi
  done
  fail "typing \"$value\" into \"$name\" never landed - the field reads \"$(box_text "${id:-}")\""
}

assert_visible() {
  automate assert "$@"
}

# A secret is typed by what it covers up.
#
# The field's own text is one bullet per character while the eye is
# shut, so the reading `type_into` checks - the text the field reports -
# is not the text that was typed. Here the dots are the proof: the
# app holds the secret and the screen shows only its length.
type_secret() {
  local name="$1" value="$2" id attempt bullets
  bullets="$(printf '•%.0s' $(seq 1 "${#value}"))"
  for attempt in 1 2 3 4 5 6 7 8; do
    id="$(widget_id textbox "$name")"
    [ -n "$id" ] || fail "no textbox named \"$name\" on screen"
    automate widget-action main-canvas "$id" set_text "$value" >/dev/null 2>&1 || true
    sleep 0.25
    if [ "$(box_text "$id")" = "$bullets" ]; then
      return 0
    fi
  done
  fail "typing \"$value\" into \"$name\" never drew $bullets - the field reads \"$(box_text "${id:-}")\""
}

# Tap a PIN out on the pad, and take the dots as the proof of each key.
# A tapped code has no caret and no keyboard, so nothing else on the
# screen moves to show that the tap landed.
tap_pin() {
  local digits="$1" dots="" index digit
  for index in $(seq 1 "${#digits}"); do
    digit="${digits:$((index - 1)):1}"
    dots="${dots}•"
    tap button "$digit" "$dots"
  done
}

screenshot() {
  local name="$1"
  automate screenshot main-canvas >/dev/null
  cp "$app_dir/.zig-cache/native-sdk-automation/screenshot-main-canvas.png" \
    "$data_dir/screens/$name.png"
}

# The host samples the canvas's centre pixel on every present and
# publishes it in the snapshot. It is a colour rather than a widget, so
# it says what the page paints - which is how a control that is drawn
# somewhere the operator cannot reach is caught: the widgets are in the
# tree, the presses are delivered, and the picture never moves.
centre_pixel() {
  automate snapshot | sed -n 's/.*gpu_sample=0x\([0-9a-f]*\).*/\1/p' | head -1
}

# The canvas repaints on its own clock, so the new pixel is not always
# published in the first snapshot after the press.
repainted() {
  local before="$1" screen="$2" after attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    after="$(centre_pixel)"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      return 0
    fi
    sleep 0.25
  done
  fail "$screen still paints 0x$before after the press - the palette never reached the canvas"
}

build_app() {
  local app="$1"
  printf '==> building %s with automation\n' "$app"
  # Debug keeps the smoke's build step short. The release build is
  # `scripts/build.sh`'s job, and one smoke run should not wait for two
  # ReleaseFast compiles before it tests anything.
  (cd "apps/$app" && native build -Dautomation=true -Doptimize=Debug --yes >/dev/null)
}

# ---------------------------------------------------------------- admin

build_app admin
build_app kiosk

rm -rf "$admin_data" "$kiosk_data"

printf '==> booting admin on a fresh database\n'
start_app admin ros-admin
automate wait >/dev/null
assert_visible 'Set up your restaurant' 'Restaurant name'

printf '==> walking through setup\n'
type_into "Restaurant name" "Smoke Restaurant"
type_into "Address" "1 Test Lane"
type_into "Phone" "555 0100"
type_into "Tax number" "TEST123"
type_into "Currency code" "USD"
type_into "Symbol" "\$"
tap button "Next" 'Who is the owner?' 'Your name' 'Sign in with' 'Confirm PIN'
type_into "Your name" "Smoke Owner"
type_secret "PIN" "123456"
type_secret "Confirm" "123456"
tap button "Create my restaurant" 'Dashboard' 'New order'
screenshot admin-dashboard

printf '==> signing out leaves the gate on the person who left\n'
# The till does not go blank on them. It asks the person who was just
# using it to prove themselves again, and it asks on the surface their
# row says they use - so the picker is a choice, not a chore.
tap button "Sign out" 'Smoke Owner - enter your PIN'
screenshot login-by-pin
tap button "Change person" 'Who is using this device?' 'Smoke Owner'
tap button "Sign in" 'Smoke Owner - enter your PIN'
tap_pin "123456"
tap button "Sign in" 'Dashboard' 'New order'

printf '==> selling a dish\n'
tap listitem "POS" 'Place order' 'Search the menu'
tap group "Paneer Tikka" '245.00'
tap button "Place order" 'Order 000001' 'TAKE THE PAYMENT'
screenshot admin-order

printf '==> the order is on the list\n'
tap listitem "Orders" '000001' 'New' '1 open'
screenshot admin-orders

# The title bar's palette control draws a glyph and no word, so the name
# the snapshot carries is the one the accessibility label gives it. That
# label reads the same in both halves of the day, so what proves the
# press landed is the page's own colour rather than a string on it.
printf '==> the theme control is named, and the dark palette paints\n'
assert_visible 'Switch theme'
page="$(centre_pixel)"
tap button "Switch theme" 'Switch theme'
repainted "$page" admin-dark
screenshot admin-dark

# Settings is where the other registers live. The title bar only knows
# the two halves of the day; the four registers and the contrast are the
# Appearance card's, and a palette that only exists in the model is a
# palette no operator can reach. Each register button carries its chosen
# state in the snapshot, so the assertion is that the model moved rather
# than that a word is on the card - and the centre pixel is that the
# canvas followed it.
printf '==> Appearance offers every register, and each one repaints\n'
tap listitem "Settings" 'Appearance' 'High contrast'
for register in Light Dark Warm Night; do
  page="$(centre_pixel)"
  tap button "$register" "name=\"$register\".*selected"
  repainted "$page" "settings-$register"
  screenshot "settings-$register"
done

printf '==> high contrast sits beside the registers, on any of them\n'
tap button "High contrast" 'name="High contrast".*selected'
screenshot settings-night-contrast

# Back to the plain look before the database goes to the kiosk: the
# stored look travels with the file the smoke copies, and the board
# below is easier to read as the register it is meant to show.
printf '==> the choice switches back, and the device is left plain\n'
tap button "High contrast" --absent 'name="High contrast".*selected'
tap button "Light" 'name="Light".*selected'

# The restaurant's own colour is not a device setting: the owner types it
# into the company form once, and every screen on every device draws with
# it. Two things are worth proving from the operator's side - a colour
# the theme cannot read is refused on the screen it was typed on, and a
# colour that can be read comes back out of the database when the form is
# opened again.
# The settings rows are cards: the press lives on the card, which the
# snapshot publishes as an unnamed group, and the word that names it is
# the title inside. Pressing the title is how the operator presses the
# row, and the pointer lands inside the card either way.
printf '==> the company form takes the restaurant colour, and keeps it\n'
tap text "Company" 'Restaurant name' 'Brand colour'
type_into "Brand colour" "#1F7A"
tap button "Save" 'a hash and six digits'
type_into "Brand colour" "#B4141E"
tap button "Save" --absent 'a hash and six digits'

# Opening the form again seeds it from the database, so the colour that
# comes back is the colour that was saved rather than the text still in
# the widget.
tap listitem "Settings" 'Appearance'
tap text "Company" 'Brand colour'
assert_visible '#B4141E'
screenshot settings-brand

# How a person proves who they are is theirs, not the device's, and it
# is a choice with two answers. The reset screen is where an owner
# changes it, and the change is proved from both sides: the secret stays
# covered until the eye is pressed, and the till that opens afterwards
# offers the field rather than the pad - because the row says so, not
# because the screen remembered what it was showing a minute ago.
printf '==> the owner changes to a password, and the till offers the field\n'
tap listitem "Team" 'Smoke Owner' 'Reset sign-in'
tap button "Reset sign-in" 'Sign in with' 'Their old sign-in stops working'
tap button "Password" 'name="Password".*selected'
type_secret "New credential" "smoke-table-one"
type_secret "Confirm credential" "smoke-table-one"
tap button "Show" 'smoke-table-one'
tap button "Hide" --absent 'smoke-table-one'
screenshot reset-credential
tap button "Save the new sign-in" 'Smoke Owner' 'Password'
screenshot team-password

printf '==> the dashboard is where the device signs out\n'
tap listitem "Dashboard" 'New order' 'Sign out'

printf '==> and signs back in by typing it\n'
# The gate is the one the row now says: the field rather than the pad
# this person left behind, still asking them by name.
tap button "Sign out" 'Smoke Owner - enter your password'
type_secret "Password" "smoke-table-one"
screenshot login-by-password
tap button "Sign in" 'Dashboard' 'New order'

# ---------------------------------------------------------------- kiosk

printf '==> handing the database to the kiosk\n'
stop_app
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$admin_data/app.db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
fi
mkdir -p "$kiosk_data"
rm -f "$kiosk_data"/app.db*
cp "$admin_data"/app.db* "$kiosk_data"/

printf '==> the kitchen sees the ticket\n'
start_app kiosk ros-kiosk
automate wait >/dev/null
assert_visible 'Kitchen' 'Display' 'Smoke Restaurant'
tap button "Kitchen" 'Kitchen' '000001' 'New'
screenshot kiosk-kitchen

printf '==> the kitchen works the ticket along\n'
tap button "Start cooking" 'Cooking'
screenshot kiosk-cooking
tap button "Mark ready" 'Ready'
screenshot kiosk-ready

printf 'smoke-sale: PASS - setup, role picker, the pad, the field, sale, orders, the look and KDS\n'
