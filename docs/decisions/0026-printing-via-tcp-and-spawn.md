# ADR-0026 — Printing: TCP :9100 in-process, ESC/POS, spool on failure

**Status:** Accepted
**Date:** 2026-11-04

## Context

A POS must hand over a bill and send a kitchen ticket on paper. The
schema already carries `printer` and `auto_print`, and the read path
exists, but there is no encoder, queue or transport. The SDK gives no
BLE, USB or serial API, so a Bluetooth printer cannot be reached from
inside the app. TCP :9100 is reachable through `std.Io.net`, and `fx.spawn`
can drive `lp`/`lpr` for one-way jobs. `fx.writeFile` gives a spool file.

## Decision

- Printing runs **in process**, on the net thread, not in a sidecar.
- The only in-app transport is **TCP :9100** (raw socket). BLE/USB/serial
  printers are out of scope for the app; they are reached through an
  external helper or a system print queue invoked via `fx.spawn`.
- The encoder is **ESC/POS**, written once in `packages/ros-core`, shared
  by all three apps.
- Every print is a queued job with an idempotency key; a failed job is
  spooled to a file and retried; a sale is never blocked by a printer.
- `printer.paper_width_mm` is read and used by the encoder.

## Consequences

- No second program to package or sign for printing.
- Bluetooth printers need an external helper; the UI must say so.
- The print queue survives a crash via the spool file.

## Alternatives considered

- A printing sidecar: rejected, because the transport the SDK actually
  has (TCP) fits inside the app, and a sidecar doubles packaging work.
- BLE in-app: impossible today; the SDK exposes no API.
