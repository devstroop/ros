#!/usr/bin/env bash
# Build and package the three macOS apps.
#
#   scripts/package.sh              # build all three; ad-hoc sign unless an identity is set
#   scripts/package.sh --ci         # ad-hoc signing, no notarisation (CI)
#   scripts/package.sh --check      # verify the artifacts in dist/ without rebuilding
#   scripts/package.sh --app kiosk  # package one app (dev convenience)
#   scripts/package.sh --output out # write elsewhere (default: dist)
#
# Environment:
#   ROS_SIGNING_IDENTITY  "Developer ID Application: ..." for a release; unset = ad-hoc
#   ROS_NOTARY_PROFILE    notarytool keychain profile; requires ROS_SIGNING_IDENTITY
#   ROS_ENTITLEMENTS      optional entitlements plist for identity signing
#   ROS_OUTPUT_DIR        default output directory (dist)
#
# The SDK's generated Info.plist has no Local Network usage description,
# so the script adds it after packaging and signs again. That is the key
# macOS shows in the Local Network prompt; each app carries its own words.
#
# macOS only: it uses hdiutil, codesign and plutil.
set -euo pipefail

cd "$(dirname "$0")/.."

mode="package"
only_app=""
output="${ROS_OUTPUT_DIR:-dist}"
ci=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

need_value() {
  if [ "$#" -lt 2 ]; then
    printf 'package: %s needs a value\n' "$1" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ci)
      ci=1
      shift
      ;;
    --check)
      mode="check"
      shift
      ;;
    --app)
      need_value "$@"
      only_app="$2"
      shift 2
      ;;
    --output)
      need_value "$@"
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'package: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'package: macOS only (hdiutil, codesign, plutil)\n' >&2
  exit 1
fi

if [ -n "$only_app" ]; then
  case "$only_app" in
    admin|service|kiosk) ;;
    *)
      printf 'package: --app must be admin, service or kiosk\n' >&2
      exit 2
      ;;
  esac
fi

# The app metadata is read from the manifest, so a version bump is one
# edit and the artifact names follow.
app_dir() { printf 'apps/%s' "$1"; }
app_id() { node -p "require('./apps/$1/app.json').id"; }
app_name() { node -p "require('./apps/$1/app.json').name"; }
app_display() { node -p "require('./apps/$1/app.json').display_name"; }
app_version() { node -p "require('./apps/$1/app.json').version"; }

# The Local Network prompt's reason, in each app's own words. The kiosk
# is the one installed by hand on a kitchen screen, so its text names the
# kitchen and the two peers it talks to.
local_network_text() {
  case "$1" in
    admin)
      printf '%s' "Restaurant OS Admin uses the local network to sync orders, payments and reference data with the service and kiosk apps on this restaurant's network."
      ;;
    service)
      printf '%s' "Restaurant OS Service uses the local network to send orders to the kitchen and sync payments with the admin app on this restaurant's network."
      ;;
    kiosk)
      printf '%s' "Restaurant OS Kiosk uses the local network to receive orders from the service app and share order status with the admin app on this restaurant's kitchen network."
      ;;
  esac
}

apps() {
  if [ -n "$only_app" ]; then
    printf '%s\n' "$only_app"
  else
    printf '%s\n' admin service kiosk
  fi
}

# The three ids must be distinct: the app-data directory, the update feed
# and the install are all keyed by the bundle id.
check_ids_distinct() {
  local count
  count="$(for app in admin service kiosk; do app_id "$app"; done | sort -u | wc -l | tr -d ' ')"
  if [ "$count" != "3" ]; then
    printf 'package: the three app ids are not distinct\n' >&2
    exit 1
  fi
}

verify_bundle() {
  local app="$1"
  local bundle="$2"
  local expected_id="$3"
  local expected_version="$4"
  local plist="$bundle/Contents/Info.plist"
  local actual_id actual_version executable text lower

  if [ ! -f "$plist" ]; then
    printf 'package: %s has no Info.plist\n' "$bundle" >&2
    return 1
  fi
  plutil -lint "$plist" >/dev/null

  actual_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist")"
  if [ "$actual_id" != "$expected_id" ]; then
    printf 'package: %s has bundle id %s, expected %s\n' "$bundle" "$actual_id" "$expected_id" >&2
    return 1
  fi

  actual_version="$(plutil -extract CFBundleVersion raw -o - "$plist")"
  if [ "$actual_version" != "$expected_version" ]; then
    printf 'package: %s has version %s, expected %s\n' "$bundle" "$actual_version" "$expected_version" >&2
    return 1
  fi

  text="$(plutil -extract NSLocalNetworkUsageDescription raw -o - "$plist")"
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *"local network"*) ;;
    *)
      printf 'package: %s has no Local Network usage description\n' "$bundle" >&2
      return 1
      ;;
  esac
  if [ "$app" = "kiosk" ]; then
    case "$lower" in
      *kitchen*) ;;
      *)
        printf 'package: the kiosk Local Network description does not name the kitchen\n' >&2
        return 1
        ;;
    esac
  fi

  executable="$(plutil -extract CFBundleExecutable raw -o - "$plist")"
  if [ ! -x "$bundle/Contents/MacOS/$executable" ]; then
    printf 'package: %s has no executable at Contents/MacOS/%s\n' "$bundle" "$executable" >&2
    return 1
  fi
}

# Mount the DMG read-only and check the app it carries. This proves the
# install artifact, not just the bundle that happened to sit in dist/.
verify_dmg() {
  local app="$1"
  local dmg="$2"
  local expected_id="$3"
  local expected_version="$4"
  local display="$5"
  local mount mounted_app ok

  if [ ! -f "$dmg" ]; then
    printf 'package: missing %s - run scripts/package.sh first\n' "$dmg" >&2
    return 1
  fi
  if ! hdiutil verify "$dmg" >/dev/null; then
    printf 'package: %s is not a valid disk image\n' "$dmg" >&2
    return 1
  fi

  mount="$(mktemp -d "${TMPDIR:-/tmp}/ros-dmg.XXXXXX")"
  if ! hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$dmg" >/dev/null 2>&1; then
    printf 'package: could not mount %s\n' "$dmg" >&2
    rmdir "$mount" 2>/dev/null || true
    return 1
  fi

  mounted_app="$mount/$display.app"
  ok=1
  if [ ! -d "$mounted_app" ]; then
    printf 'package: %s does not contain %s.app\n' "$dmg" "$display" >&2
    ok=0
  else
    verify_bundle "$app" "$mounted_app" "$expected_id" "$expected_version" || ok=0
    codesign --verify --deep --strict "$mounted_app" || ok=0
  fi

  hdiutil detach "$mount" >/dev/null 2>&1 || hdiutil detach -force "$mount" >/dev/null 2>&1 || true
  rmdir "$mount" 2>/dev/null || true
  [ "$ok" -eq 1 ]
}

package_app() {
  local app="$1"
  local dir id name display version bundle dmg plist text
  dir="$(app_dir "$app")"
  id="$(app_id "$app")"
  name="$(app_name "$app")"
  display="$(app_display "$app")"
  version="$(app_version "$app")"
  bundle="$output/$display.app"
  dmg="$output/$name-$version-macos.dmg"
  plist="$bundle/Contents/Info.plist"

  printf '==> %s (%s)\n' "$display" "$id"

  native build "$dir" --yes

  # Package unsigned first: the plist is edited below, so any signature
  # the package step applied would be stale.
  rm -rf "$bundle"
  (
    cd "$dir"
    native package --target macos --signing none --output "$bundle"
  )

  text="$(local_network_text "$app")"
  if plutil -extract NSLocalNetworkUsageDescription raw -o - "$plist" >/dev/null 2>&1; then
    plutil -replace NSLocalNetworkUsageDescription -string "$text" "$plist"
  else
    plutil -insert NSLocalNetworkUsageDescription -string "$text" "$plist"
  fi

  # The SDK's signing plan was generated for the unsigned package step.
  # Rewrite it before signing so the bundle describes the final signature.
  local signing_plan="$bundle/Contents/Resources/signing-plan.txt"
  if [ -n "${ROS_SIGNING_IDENTITY:-}" ]; then
    {
      printf 'signing=identity\n'
      printf 'identity=%s\n' "$ROS_SIGNING_IDENTITY"
      if [ -n "${ROS_NOTARY_PROFILE:-}" ]; then
        printf 'notarization=requested profile=%s\n' "$ROS_NOTARY_PROFILE"
      else
        printf 'notarization=none\n'
      fi
    } > "$signing_plan"
  else
    printf 'signing=adhoc\nad-hoc local package; not for distribution\n' > "$signing_plan"
  fi

  # Sign after the plist is final. Ad-hoc is the CI default; a release
  # sets ROS_SIGNING_IDENTITY and gets the hardened runtime + timestamp.
  if [ -n "${ROS_SIGNING_IDENTITY:-}" ]; then
    local sign_args=(--force --deep --options runtime --timestamp --sign "$ROS_SIGNING_IDENTITY")
    if [ -n "${ROS_ENTITLEMENTS:-}" ]; then
      sign_args+=(--entitlements "$ROS_ENTITLEMENTS")
    fi
    codesign "${sign_args[@]}" "$bundle"
  else
    codesign --force --deep --sign - "$bundle"
  fi
  codesign --verify --deep --strict --verbose=2 "$bundle"
  verify_bundle "$app" "$bundle" "$id" "$version"

  # Notarise the app, staple it, and only then build the DMG. The
  # temporary zip is what notarytool accepts; it is not a release artifact.
  if [ -n "${ROS_NOTARY_PROFILE:-}" ]; then
    if [ -z "${ROS_SIGNING_IDENTITY:-}" ]; then
      printf 'package: ROS_NOTARY_PROFILE needs ROS_SIGNING_IDENTITY\n' >&2
      return 1
    fi
    local notarize_zip="$output/.notarize-$name.zip"
    rm -f "$notarize_zip"
    ditto -c -k --keepParent "$bundle" "$notarize_zip"
    xcrun notarytool submit "$notarize_zip" --keychain-profile "$ROS_NOTARY_PROFILE" --wait
    rm -f "$notarize_zip"
    xcrun stapler staple "$bundle"
    xcrun stapler validate "$bundle"
    spctl --assess --type execute --verbose=2 "$bundle"
  fi

  rm -f "$dmg"
  hdiutil create -volname "$display" -srcfolder "$bundle" -ov -format UDZO "$dmg" >/dev/null
  verify_dmg "$app" "$dmg" "$id" "$version" "$display"
  printf '  artifact: %s\n' "$dmg"
}

write_checksums() {
  (
    cd "$output"
    find . -maxdepth 1 -type f \( -name '*.dmg' -o -name '*.zip' \) -print |
      sort |
      while IFS= read -r file; do
        shasum -a 256 "$file"
      done > checksums.txt
  )
}

check_all() {
  local app dir id name display version dmg
  check_ids_distinct

  if [ ! -f "$output/checksums.txt" ]; then
    printf 'package: %s/checksums.txt is missing - run scripts/package.sh first\n' "$output" >&2
    exit 1
  fi
  ( cd "$output" && shasum -a 256 -c checksums.txt )

  for app in $(apps); do
    dir="$(app_dir "$app")"
    id="$(app_id "$app")"
    name="$(app_name "$app")"
    display="$(app_display "$app")"
    version="$(app_version "$app")"
    dmg="$output/$name-$version-macos.dmg"
    printf '==> %s (%s)\n' "$display" "$id"
    verify_dmg "$app" "$dmg" "$id" "$version" "$display"
    printf '  verified: %s\n' "$dmg"
  done
  printf 'all artifacts verified\n'
}

if [ "$mode" = "check" ]; then
  if ! command -v node >/dev/null 2>&1; then
    printf 'package: node is not on PATH - run scripts/setup.sh\n' >&2
    exit 1
  fi
  check_all
  exit 0
fi

if [ "$ci" -eq 1 ]; then
  ROS_SIGNING_IDENTITY=""
  ROS_NOTARY_PROFILE=""
  ROS_ENTITLEMENTS=""
fi

# A dev shell gets the pinned toolchain from env.sh. CI puts the SDK CLI
# and the pinned Zig on PATH itself, so do not shadow them with a
# Homebrew Zig that happens to be installed on the runner.
if ! command -v native >/dev/null 2>&1; then
  # shellcheck source=scripts/env.sh
  source scripts/env.sh
fi

for tool in native node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'package: %s is not on PATH - run scripts/setup.sh\n' "$tool" >&2
    exit 1
  fi
done

check_ids_distinct

mkdir -p "$output"
if [ -z "$only_app" ]; then
  # Clear the previous release artifacts, not the whole directory: the
  # output path is caller-supplied and may hold other files.
  rm -rf "$output"/*.app
  rm -f "$output"/*.dmg "$output"/.notarize-*.zip "$output/checksums.txt"
fi
output="$(cd "$output" && pwd)"

for app in $(apps); do
  name="$(app_name "$app")"
  version="$(app_version "$app")"
  rm -rf "$output/$(app_display "$app").app"
  rm -f "$output/$name-$version-macos.dmg"
  package_app "$app"
done

write_checksums
check_all
printf 'packaged %s\n' "$(apps | tr '\n' ' ')"
