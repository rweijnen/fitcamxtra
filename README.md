# FitCamXtra

A focused, modern iOS companion app for the FitCamX wifi dashcam. It replaces the
multi-brand stock app with something clean, dark and one-handed, and adds the two
things the stock app lacks: a painless connection flow (no more fighting wireless
CarPlay for the phone's wifi) and **station mode**, so the camera joins your home
network instead of forcing your phone onto its access point.

> Status: early. The design is done and the foundation is in place: design system,
> camera command layer, discovery, and the app shell with a working Live and Connect
> screen. Events, the SD card browser, Settings and the Network mode switch are next.

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

The Xcode project is **generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen)**
rather than committed, so the project can be maintained from a machine without Xcode.
Generate it before opening the app locally:

```sh
brew install xcodegen
xcodegen generate
open FitCamXtra.xcodeproj
```

CI does the same on every push, then archives and signs. Signing material lives
exclusively in repository secrets; see [docs/SIGNING.md](docs/SIGNING.md) for the list
and how to produce them. Nothing secret is ever committed. A build without access to
those secrets, such as a pull request from a fork, still compiles the app unsigned.

Requires Xcode 16 and iOS 17 or newer.

## Layout

| Path | What lives there |
| --- | --- |
| `FitCamXtra/Core` | Camera commands, XML replies, discovery, domain models. Deliberately free of Apple-only types so an Android port can reuse the logic. |
| `FitCamXtra/Platform` | The Apple edge: URLSession transport and reading the phone's own subnet. |
| `FitCamXtra/Design` | Design tokens and shared chrome. |
| `FitCamXtra/Features` | One folder per screen. |

### Finding the camera

The camera announces itself on nothing: its firmware has no mDNS responder, no SSDP
and no UDP beacon, so the phone has to look. Discovery tries the remembered address
first, which resolves most reconnects in a single request, then derives the range from
the phone's own interface and sweeps that subnet with every probe in flight at once.
A `/24` resolves in a second or two. Identity comes from the camera's version reply,
because iOS sandboxing rules out matching on MAC address.

## License

[MIT](LICENSE)
