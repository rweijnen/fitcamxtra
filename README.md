# FitCamXtra

A focused, modern iOS companion app for the FitCamX wifi dashcam. It replaces the
multi-brand stock app with something clean, dark and one-handed, and adds the two
things the stock app lacks: a painless connection flow (no more fighting wireless
CarPlay for the phone's wifi) and **station mode**, so the camera joins your home
network instead of forcing your phone onto its access point.

> Status: early. Repository scaffold and CI only; the app itself is being designed.

## Planned features

- **Connect** - discovers the camera on your LAN (station mode) or offers to join its
  own access point. Remembers the camera; no hardcoded credentials.
- **Live** - full-bleed RTSP preview, record / snapshot, battery and SD chips.
- **Events** - the clips your button (or the G-sensor) locked, shown as incident
  bundles with the surrounding loop segments, saved to Photos in one tap.
- **Network** - switch between AP mode and station mode, see the current SSID / IP.
- **Settings** - every camera setting the firmware exposes, cleaned up, plus a
  bitrate control the stock app does not offer.

Everything talks plain HTTP and RTSP to the camera on the local network. No cloud,
no account, no telemetry.

## Building

The app is built and signed with GitHub Actions on macOS runners. Signing material
lives exclusively in repository secrets; see [docs/SIGNING.md](docs/SIGNING.md) for
the list of secrets and how to produce them. Nothing secret is ever committed.

Local builds need Xcode 16 or newer once the project lands.

## License

[MIT](LICENSE)
