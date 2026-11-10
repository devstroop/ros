# Phase 8 — Packaging, migration and cutover

> **Status:** Partial. The three macOS artifacts package and verify in
> CI; migration, backup/restore, diagnostics and the pilot remain.
> **Estimate:** 5 engineer-days
> **Depends on:** Phases 0–7 as scoped
> **Exit criterion:** a signed app runs on a clean machine with imported
> data, and CI proves it.

## Goal

Ship it: a signed application, a supportable install, and a path from v1.

## What exists

- Three `app.json` manifests, each with its own id, display name, icon
  and window: `com.devstroop.ros.admin`, `com.devstroop.ros.service` and
  `com.devstroop.ros.kiosk`.
- `scripts/package.sh` builds all three in ReleaseFast, packages each as
  a macOS `.app`, injects its own `NSLocalNetworkUsageDescription`, signs
  it, builds a DMG, verifies the DMG and writes `dist/checksums.txt`.
  Ad-hoc signing is the default and the CI mode; a Developer ID identity
  and notarisation are supported through `ROS_SIGNING_IDENTITY` and
  `ROS_NOTARY_PROFILE`.
- A CI `Package (macOS)` job runs the script and uploads the three DMGs.
- The release/install/update runbook:
  [`docs/operations/release.md`](../operations/release.md).
- A 0.1.0 version. The version is read from each manifest, so an artifact
  name follows the app's own version.
- CI exists (`verify`, automation smoke and package); the automation
  smoke is still non-blank, not a sale.

## What is missing

| Item | Detail |
|---|---|
| Developer ID release | The script supports signing and notarisation, but no release credentials are configured in CI; CI produces ad-hoc artifacts |
| Clean-machine proof | The checklist is written; no signed release has been installed and signed off on the three target machines |
| Linux/Windows packaging | Untested |
| App icon set | The three apps have distinct 1024×1024 PNGs; Windows/Linux packaging and their icon requirements are still untested |
| Version policy | `0.1.0` only; bump per release. `CFBundleVersion` is the same string, with no separate build number |
| Update mechanism | The manual path is documented. The SDK's signed feed is supported but not hosted or enabled in the manifests |
| CI | The package job exists; there is no migration or clean-machine job |
| Automation smoke | Non-blank only; no sale flow (#42) |
| Legacy migration | None |
| Backup/restore | No UI, no schedule; the runbook has a manual copy/restore recipe |
| Diagnostics | No log export, no crash report path |
| Support mode | DB inspector exists as a screen name only |
| Documentation for operators | The release runbook exists; the setup/printer/backup operator runbook is still missing |
| Rollback plan | Documented and manual; not tested across a schema change |

## Tasks

1. **Package macOS first** and run the result on a clean machine.
   Three artifacts package and verify in CI; the clean-machine sign-off
   is still manual.
2. **Add the CI pipeline**: check, test, automation smoke, package.
   The package job exists; the sale smoke is still open.
3. **Add the automation smoke** (role picker → login → sale → KDS →
   screenshot, assert non-blank and node budget).
4. **Decide the legacy migration**:
   - in-place: transform a v1 database to the Restaurant OS schema; or
   - fresh install: export/import products, customers and open orders.
   Validate with a real database copy and a per-table row count.
5. **Build the setup flow** if a fresh install is the answer. It is a
   prerequisite, not optional. The admin's walk-through exists; the
   service and kiosk wait for its reference data.
6. **Add backup/restore** to a file and optionally to cloud storage via
   `fx.fetch` + `credentials`.
7. **Add diagnostics**: a log file, an export action, a support bundle.
8. **Write the operator runbook**: install, first-run setup, printer
   setup, device role, backup, upgrade, rollback. The release half is in
   [`docs/operations/release.md`](../operations/release.md).
9. **Define versioning and upgrade** (schema migration + app update).
   The manual version and update path is written down; the hosted feed
   is not enabled.
10. **Run a pilot service** in a real restaurant; record failures.

## Exit criterion

- A signed app installs on a clean machine.
- It creates a company and an admin through setup, or imports real data
  without loss.
- It prints a receipt and a KOT on the pilot hardware.
- Two devices converge.
- CI reproduces the build and the smoke test.
- A rollback is documented and tested.

## Risks

| Risk | Mitigation |
|---|---|
| Silent data loss in migration | Row counts, checksums, dry run, backup first |
| Notarisation/signing surprises | `scripts/package.sh` and the CI package job exercise the flow; Developer ID and notarisation still need the release credentials |
| Ad-hoc artifacts mistaken for a release | CI is explicitly ad-hoc; the runbook marks those artifacts as testing only and the release path as Developer ID + notarised |
| Pilot reveals a usability blocker | Pilot before declaring release, not after |
| No rollback | Keep the previous DMG and a data backup; the recipe is in the runbook, not yet tested across a schema change |
| Update mechanism absent | The manual update path and per-app cadence are written down; the signed feed is supported but not hosted |
| Operator setup is too complex | Observe a real operator doing it |

## Unknowns

- Is a fresh install acceptable, or is in-place migration mandatory?
- Which platforms ship first? macOS is packaged first; Linux and Windows
  are untested.
- Is there an update server or app-store distribution? No feed is hosted
  yet. The manual path is current; the SDK's signed feed is the chosen
  mechanism when there is a server.
- What does support need to diagnose a device?
- What is the rollback story if the Restaurant OS build is bad? The
  manual replace-and-restore recipe is written down; it is not tested
  across a schema change.

See [`../open-questions.md`](open-questions.md).
