# Release and update runbook

> **Status:** Partial. `scripts/package.sh` builds and verifies the three
> macOS artifacts; CI runs it with ad-hoc signing. Developer ID signing and
> notarisation are supported and need the release credentials. The
> clean-machine checklist below is manual, and the signed update feed is
> documented but not hosted yet.
> **Owner:** release engineering.
> **Issue:** [#113](https://github.com/devstroop/ros/issues/113).

## The three artifacts

Each app is its own Native SDK app, with its own manifest, bundle id,
icon, install and update cadence.

| App | Bundle id | Executable | Install artifact | App data |
|---|---|---|---|---|
| Admin | `com.devstroop.ros.admin` | `ros-admin` | `dist/ros-admin-<version>-macos.dmg` | `~/Library/Application Support/com.devstroop.ros.admin` |
| Service | `com.devstroop.ros.service` | `ros-service` | `dist/ros-service-<version>-macos.dmg` | `~/Library/Application Support/com.devstroop.ros.service` |
| Kiosk | `com.devstroop.ros.kiosk` | `ros-kiosk` | `dist/ros-kiosk-<version>-macos.dmg` | `~/Library/Application Support/com.devstroop.ros.kiosk` |

The DMG contains one app: `Restaurant OS Admin.app`, `Restaurant OS
Service.app` or `Restaurant OS Kiosk.app`. `dist/checksums.txt` carries
the SHA-256 of every DMG.

**The ids are stable.** They are the key for the app-data directory, the
Local Network grant and the update feed. The phase-9 design sketched
`dev.eatery.v2.*`; the implementation keeps `com.devstroop.ros.*`, which
the manifests and the data directories already use. Renaming an id is a
migration, not a cosmetic change.

## Build and package

Requirements: macOS with Xcode command line tools, the pinned Zig 0.16,
Node 24 and the Native SDK CLI from `scripts/setup.sh` (or `source
scripts/env.sh`). The packaging commands need `hdiutil`, `codesign` and
`plutil`, so they are macOS only.

```sh
# CI shape: ad-hoc signing, no notarisation, all three apps.
scripts/package.sh --ci

# Release shape: Developer ID + notarisation from the environment.
ROS_SIGNING_IDENTITY="Developer ID Application: Devstroop (TEAMID)" \
ROS_NOTARY_PROFILE="ros-notary" \
scripts/package.sh

# Verify what is in dist/ without rebuilding.
scripts/package.sh --check
```

A full run clears the previous artifacts from `dist/` first, builds each
app in ReleaseFast, packages it with
`native package --target macos --signing none`, injects the Local
Network usage description, signs the bundle, optionally notarises it,
builds the DMG, verifies the DMG checksum, mounts it read-only, checks the
bundle inside it and writes `dist/checksums.txt`. `--app kiosk` rebuilds
one app for development; it does not remove the other artifacts.

The script owns the final signature because the plist is edited after
`native package` has run. Do not add `--signing` by hand.

## Signing and notarisation

### Ad-hoc (CI and local testing)

With `ROS_SIGNING_IDENTITY` unset, the script signs each bundle with
`codesign --force --deep --sign -`. This proves the bundle structure, the
plist and the signature seal, but Gatekeeper on another Mac will reject
it. The CI artifacts are for testing the packaging, not for handing to a
restaurant.

### Developer ID (release)

1. Install a **Developer ID Application** certificate in the login
   keychain.
2. Store a notarytool profile once:

   ```sh
   xcrun notarytool store-credentials ros-notary \
     --apple-id "release@example.com" \
     --team-id "TEAMID" \
     --password "app-specific-password"
   ```

3. Export `ROS_SIGNING_IDENTITY` (the certificate's common name) and
   `ROS_NOTARY_PROFILE=ros-notary`. If the app needs entitlements, export
   `ROS_ENTITLEMENTS=/path/to/entitlements.plist`.
4. Run `scripts/package.sh`.

The script signs with the hardened runtime and a secure timestamp, zips
the app for `notarytool submit --wait`, staples the ticket to the app,
runs `stapler validate` and `spctl --assess`, and only then builds the
DMG. The app inside the DMG is stapled; the DMG itself is not separately
notarised.

The three artifacts share the identity but not the bundle id. Signing is
per bundle, so a re-signed kiosk cannot impersonate the admin.

## The Local Network permission

macOS asks for Local Network access the first time an app opens a local
socket. The prompt shows `NSLocalNetworkUsageDescription` from the app's
`Info.plist`. The SDK does not generate that key, so `scripts/package.sh`
adds it after packaging and signs again. The three apps carry their own
words:

| App | `NSLocalNetworkUsageDescription` |
|---|---|
| Admin | Restaurant OS Admin uses the local network to sync orders, payments and reference data with the service and kiosk apps on this restaurant's network. |
| Service | Restaurant OS Service uses the local network to send orders to the kitchen and sync payments with the admin app on this restaurant's network. |
| Kiosk | Restaurant OS Kiosk uses the local network to receive orders from the service app and share order status with the admin app on this restaurant's kitchen network. |

The kiosk's text is the one the kitchen screen shows. **Grant it by
hand during the kiosk install:** the first launch or the first sync opens
the prompt; choose **Allow**. If it was denied, open **System Settings →
Privacy & Security → Local Network**, enable **Restaurant OS Kiosk**, quit
the app and open it again.

The permission is tied to the bundle id and the code signature. Keeping
`com.devstroop.ros.kiosk` and the same signing identity stable means an
update should not ask again; changing the bundle id would ask again and
would also strand the old app data.

Discovery uses UDP broadcast (`255.255.255.255`), not Bonjour, so
`NSBonjourServices` is not needed. A network that blocks broadcast can
use a manually configured peer address
([architecture/12](../architecture/12-three-apps-and-ipc.md)), but the
Local Network permission is still required for the socket.

Verify the packaged key:

```sh
plutil -extract NSLocalNetworkUsageDescription raw -o - \
  "dist/Restaurant OS Kiosk.app/Contents/Info.plist"
```

## Install on a clean machine

The three installs are the admin on the back-office Mac, the service on
the till and the kiosk on the kitchen screen. Do this once per machine,
with the release DMGs and `checksums.txt` on a USB stick or a local share.

1. Verify the artifact:

   ```sh
   cd dist
   shasum -a 256 -c checksums.txt
   ```

2. Open the DMG, drag the app to `/Applications`, and eject the volume.
3. Launch the app. A Developer ID + notarised build opens normally. An
   ad-hoc build needs **right-click → Open**. On a test machine only,
   you can remove the quarantine flag instead:

   ```sh
   xattr -d com.apple.quarantine "/Applications/Restaurant OS Kiosk.app"
   ```

   Do not disable Gatekeeper globally.
4. First run:
   - **Admin:** complete the setup walk-through (company, owner PIN,
     starter menu and tables).
   - **Service:** choose Waiter and sign in with a PIN the admin created.
     A service that starts before the admin waits for the admin's
     reference data.
   - **Kiosk:** choose Kitchen or Display. A kiosk that starts before the
     admin waits for the reference data.
5. **Local Network:** allow the prompt. On the kiosk, confirm the text
   names the kitchen, and confirm the switch in System Settings.
6. Pair the devices. They discover each other by beacon on the same
   subnet. If broadcast is blocked, enter one peer address by hand.
7. Smoke the restaurant: setup on the admin, a sale on the service, the
   ticket on the kiosk, the order and the payment on the admin. Quit and
   reopen one app and check the data survived.
8. Record the machine, macOS version, bundle id, version, SHA-256 and the
   Local Network decision in the release record.

CI proves the packaging on a macOS runner. The clean-machine step is a
manual sign-off; it needs the release hardware and, for Gatekeeper, a
Developer ID + notarised build.

## The update path per app

The three apps do not share a cadence. The admin is the back office, the
service is the till and the kiosk is a fixed kitchen screen.

| App | Cadence | Window | Order | Why |
|---|---|---|---|---|
| Admin | Every release, often | Closed hours | First | It owns the reference data and the schema. It can be closed while the service keeps selling. |
| Service | Deliberately, one till at a time | After close, after the admin | Second | It takes money. A failed update during service stops sales. |
| Kiosk | Rarely, by appointment | Scheduled maintenance, after close | Last | It is installed by hand on a wall or a shelf, and the kitchen cannot lose the board mid-service. |

The apps may run different versions during a rolling update: the op log
is the protocol. The wire has a major version (`ros/1`, with `/v1`
endpoints), and a peer refuses a different major version. A release that
changes the schema or the wire protocol still goes admin first, then
service, then kiosk, and the peers should not stay mixed for long. A
breaking wire change bumps the major version and needs a coordinated
update; the current `ros/1` peers will refuse a different major.

### Manual update (the current path)

1. Read the release notes and verify the new DMG against
   `checksums.txt`.
2. Quit the app.
3. Back up its data directory (see below).
4. Mount the new DMG, drag the app over the copy in `/Applications`, and
   eject. Keep the previous DMG.
5. Open the app. The bundle id did not change, so the data and the Local
   Network grant are still there; the permission should not ask again.
6. Sign in, check the data, and check that a peer sees the app. Run the
   smoke flow on the admin and the service.
7. Keep the previous DMG until the next service has run cleanly.

### Automatic update (supported by the SDK, not enabled)

The SDK can serve a signed update feed. It is not enabled in the
manifests because there is no hosted feed or release key yet. Do not put
a placeholder URL in `app.json`.

1. Generate a key once per feed, offline:

   ```sh
   native update keygen --private-key /secure/ros-admin-update.key
   ```

   Keep the private key out of the repository. Put the printed base64
   public key in the app's manifest.
2. Add the feed to the app's `app.json`:

   ```json
   "updates": {
       "feed_url": "https://updates.example.com/ros/admin/native-update.json",
       "public_key": "<base64 Ed25519 public key>",
       "check_on_start": false
   }
   ```

   `feed_url` must be HTTPS and `check_on_start` stays `false` until the
   feed is live. Use a separate feed, and preferably a separate key, for
   each app.
3. Build the update archive:

   ```sh
   native package --target macos --update-archive
   ```

   Run this from the app directory (`apps/admin`, `apps/service` or
   `apps/kiosk`); it reads that app's manifest and binary. This is a zip
   of the app, not the DMG. The manifest must already have the `updates`
   block.
4. Sign the feed entry:

   ```sh
   native update sign \
     --archive ros-admin-<version>-macos.zip \
     --url https://updates.example.com/ros/admin/ros-admin-<version>-macos.zip \
     --target macos-aarch64 \
     --manifest apps/admin/app.json \
     --private-key /secure/ros-admin-update.key \
     --output native-update.json
   ```

   Run this from the repository root and point `--archive` at the zip the
   package step produced. Build and sign `macos-aarch64` and
   `macos-x86_64` separately if both are supported; the target must match
   the machine.
5. Host the zip and `native-update.json` at the feed URL. The app
   verifies the Ed25519 signature and the bundle id before installing.
6. Publish in the cadence above: admin feed first, service after the
   admin is verified, kiosk in the maintenance window. A bad feed is
   rolled back by restoring the previous feed entry; the app keeps the
   installed version until it accepts a new one.

### Versioning

`version` in `app.json` is both `CFBundleShortVersionString` and
`CFBundleVersion`, and it is part of the artifact names. Bump it for
every release; do not reuse a version for a different build.

Schema migrations are forward-only. A newer app may migrate its own
database; an older app may not understand the result. Back up before an
update, and do not roll back across a schema change without restoring
the backup.

## Backup and rollback

The database is engine-owned and lives in the app-data directory. Back it
up with the app quit:

```sh
mkdir -p "$HOME/ros-backups"
cp -R "$HOME/Library/Application Support/com.devstroop.ros.admin" \
      "$HOME/ros-backups/admin-$(date +%Y%m%d-%H%M%S)"
```

To roll back:

1. Quit the app.
2. Replace `/Applications/Restaurant OS <App>.app` with the previous
   build.
3. If the update changed the schema, restore the matching data directory
   from the backup.
4. Open the app and run the smoke flow.

Keep at least the previous DMG and one data backup per machine until the
next service is clean. Test a restore on a spare machine before relying
on it in a service.

## Verification and evidence

`scripts/package.sh --check` verifies, for each app:

- the SHA-256 in `dist/checksums.txt`;
- the DMG checksum (`hdiutil verify`);
- the bundle id and version in the mounted app;
- the `NSLocalNetworkUsageDescription` (and, for the kiosk, that it names
  the kitchen);
- the executable and the code signature (`codesign --verify --deep
  --strict`).

The CI **Package (macOS)** job runs `scripts/package.sh --ci` and
`scripts/package.sh --check`, and uploads the three DMGs plus
`checksums.txt` as the `ros-macos-packages` artifact.

What this does not prove without the release credentials and hardware:
Developer ID signing, notarisation and Gatekeeper acceptance on a clean
Mac. The checklist above is the manual release sign-off for those. The
ad-hoc CI artifacts are not a distribution build.

## Related

- [Phase 8 — packaging, migration and cutover](../plan/phase-8-packaging-cutover.md)
- [Phase 9 — three apps over TCP/IP](../plan/phase-9-three-apps-and-ipc.md)
- [The three apps and IPC](../architecture/12-three-apps-and-ipc.md)
- [ADR-0021 — the counter POS is the service app](../decisions/0021-counter-pos-is-the-service-app.md)
- [`scripts/package.sh`](../../scripts/package.sh)
