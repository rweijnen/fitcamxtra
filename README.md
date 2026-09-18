# FitCamXtra

![AI assisted](https://img.shields.io/badge/AI-assisted-blue)

A focused iOS companion app for the FitCamX wifi dashcam: clean, dark and
one-handed. It finds the camera by itself and reconnects when the network
changes, and it can put the camera into **station mode**, so it joins your home
network rather than needing your phone on its access point.

Not affiliated with or endorsed by FitCamX.

> Status: all five surfaces are built and running on TestFlight. Some camera setting
> mappings are marked provisional in code, meaning the command number is confirmed from
> the firmware but the meaning of its parameter is not yet verified on hardware.

## Features

- **Connect** - finds the camera by itself and reconnects when the network changes or
  the app returns to the foreground. Remembers the address; no stored credentials.
- **Live** - full-bleed RTSP video, record and snapshot, battery and SD chips.
- **Events** - the clips your button or the G-sensor locked, opened as incident
  bundles with the surrounding loop segments, saved to Photos in one tap.
- **SD card** - the whole card, grouped by day, with filters, multi-select, saving
  and deleting.
- **Network** - switch the camera between its own access point and your home wifi.
- **Settings** - the camera's settings, including a record-bitrate control.
- **Diagnostics** - an in-app log of every probe, command and reply, shareable as
  text. For a local-network app the interesting failures are silent ones.

Everything talks plain HTTP and RTSP to the camera on the local network. No cloud,
no account, no telemetry.

### Live video

iOS has no RTSP support and AVPlayer cannot open it, so the app speaks the protocol
itself rather than taking on a large dependency. RTP is interleaved on the same TCP
connection, which needs no second socket and behaves the same on the camera's access
point as on a home LAN. The protocol work is portable; only the socket and the
display layer are Apple-specific. H.265 is detected and reported rather than
mis-decoded, since it uses a different payload format.

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
