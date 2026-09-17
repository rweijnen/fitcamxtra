# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A SwiftUI iOS app (iOS 17+) that talks to a FitCamX CAR-WA7053 wifi dashcam over plain
HTTP (Novatek CGI) and RTSP on the local network. No cloud, no account, no stored
credentials.

## Build

The Xcode project is **generated from `project.yml` by XcodeGen and is not committed**.
There is no `.xcodeproj` in the tree; generate it before any local build:

```sh
brew install xcodegen
xcodegen generate            # or: xcodegen generate --spec project.yml
xcodebuild build -project FitCamXtra.xcodeproj -scheme FitCamXtra \
  -configuration Release -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO
```

The primary development machine is Windows, where none of this can run. Compilation is
verified by `.github/workflows/ios-build.yml` on a `macos-26` runner, which picks the
newest installed Xcode (App Store Connect rejects an SDK older than iOS 26), generates
the project, archives, exports and uploads to TestFlight. Signing material comes only
from repository secrets (`docs/SIGNING.md`); without them CI still builds unsigned.

Adding a source file needs no project edit — `project.yml` globs the `FitCamXtra`
directory. Adding a dependency, capability or Info.plist key does mean editing
`project.yml`.

There is no test target and no linter configured. "Verified" here means a change was
built by CI and, for anything touching the camera protocol, confirmed against hardware
via a diagnostics export.

## Architecture

Four layers, and the split is deliberate: `Core` stays free of Apple-only types so the
logic can be reused by an Android port. Keep it that way — `Foundation` value types and
protocols only, no `UIKit`/`SwiftUI`/`Network`/`URLSession`.

- `FitCamXtra/Core` — `CameraCommand`/`CameraRequest` (the CGI surface), XML reply
  parsing, discovery, settings model, file listing, and the RTSP/RTP/H.264/H.265
  protocol handling.
- `FitCamXtra/Platform` — the Apple edge, reached through protocols defined in Core:
  `CameraTransport` → `URLSessionTransport`, `NetworkInterfaceProviding` →
  `NetworkInterfaceProvider`, plus `RTSPClient` (NWConnection), `VideoRenderer`,
  `MediaDownloader`, `NetworkPathMonitor`.
- `FitCamXtra/Design` — `Theme.swift`, the only place colors and spacing are defined.
- `FitCamXtra/Features` — one folder per screen (Connect, Live, Events, SDCard,
  Network, Settings, Diagnostics).
- `FitCamXtra/App` — `AppState`, an `@Observable @MainActor` object that owns the
  connection state machine, the `CameraClient` actor, and the child stores
  (`SettingsStore`, `LiveStream`, `MediaLibrary`, `MediaDownloader`, `DiagnosticsLog`).
  Views read `AppState`; they do not build requests themselves.

Concurrency: `CameraClient` and `RTSPClient` are actors; everything observable by the UI
is `@MainActor`. `SWIFT_STRICT_CONCURRENCY` is `minimal`.

`DiagnosticsLog` is not decoration. For a local-network app the interesting failures are
silent, so every probe, command and reply is logged through a `LogSink` handed down from
`AppState`; the user can export it as a text file. When adding a code path that talks to
the camera, log it the same way — a hardware bug report is a diagnostics export.

## The camera protocol

`docs/FIRMWARE_API.md` records what a real CAR-WA7053 actually answered, including where
the firmware's own dispatch table names are wrong. **Read it before touching anything
command-related, and trust it over the command names.** Key consequences already baked
into the code:

- Reading settings is a single `cmd=3014`. A config command sent *without* `par` does
  **not** report its value — it answers `<Status>0</Status>` meaning "accepted", which
  reads back as the value zero and makes every setting look switched off. This has
  already cost one release.
- The record bitrate lives at `2022` (named AntiProtect), not `2013`. `8050` (named
  Parking_DurationLimit) is a wifi scan. `3015` (named Event_FileList) returns the whole
  card and locked clips must be filtered out of it.
- Resolution indices from `3030` are non-contiguous and cannot be guessed.
- The stream is H.265, not H.264.

Unverified mappings are marked provisional in code and listed under "Still open" in the
firmware doc. Do not promote a guess to a shipped label, and do not invent a value the
camera did not report: the app deliberately shows "unreported" or hides a chip rather
than display an invented percentage (SD status and battery scales are unknown). New
findings from a diagnostics export belong in `docs/FIRMWARE_API.md` in the same
observed-behaviour-wins style.

Discovery: the camera announces itself on nothing — no mDNS, SSDP or UDP beacon. The app
tries the remembered address, then derives the subnet from the phone's own interface and
sweeps it with all probes in flight. Identity comes from the `cmd=3012` version reply,
because iOS sandboxing rules out MAC matching. A network wider than a `/24` is offered to
the user rather than swept silently.

## Conventions

Commit subjects are written as what the change does to the product, in plain sentences
("Correct the settings layer against a real camera"), not conventional-commit prefixes.

Comments in this codebase explain *why* a non-obvious decision was made — usually a
firmware quirk or an Apple constraint. Match that; do not strip them.
