# Commands worth watching the stock app send

Every command this app has sent to a CAR-WA7053, with what came back, and what
would settle the ones that did not behave. Compiled from the diagnostics
exports in hand (17–19 September 2026) and the recovered command table.

The point of the list: capture the stock app's HTTP traffic while it does the
same things, and compare. It is on the camera's own wifi, unauthenticated, over
plain HTTP, so a proxy on the phone or a packet capture on the AP sees
everything. **The parameter forms are what matter** — the command numbers are
already known from the firmware table.

Status codes seen so far: `0` accepted, `-13` and `-21` refused (the firmware
answers `-256` for a command that is not in its table at all, which we have
never seen).

---

## 1. Refused, and we do not know why

| cmd | What we send | Answer | What to watch for |
| ---: | --- | --- | --- |
| **4001** | `str=A:\Novatek\MOVIE\<name>.MP4`, percent-encoded | `Status -21` | **The highest-value one.** Does the stock app show clip thumbnails at all? If it does, capture the request: is the parameter the DOS path, the file-server path, a bare name, or an index? Is it `4001` or `4002`? The current build sends the path raw and falls back to 4002 — both untested |
| **2015** | `par=1` before opening RTSP | `Status -13` | Does the stock app send 2015 before live view, and what does it get? -13 may mean "already streaming", in which case it is the right command in the wrong order |

## 2. Accepted and ignored

| cmd | What we send | What happened | What to watch for |
| ---: | --- | --- | --- |
| **2002** | `par=7` for 2560×1440 | `Status 0`, and `3014` still reported `10` afterwards. The camera was recording at the time | Does the stock app stop recording (`2001&par=0`) before changing resolution, and start it again after? Does it send `3021` to save? That sequence is the obvious explanation and is untested |

## 3. Answers whose meaning is unknown

The command is confirmed; the number it returns is not understood. The stock
app's own screens are the fastest way to decode these — set a value there, then
read the command back.

| cmd | Reports | Question |
| ---: | ---: | --- |
| **3008** language | 6 | Which language is 6? Set each language on the camera and read it back |
| **2005** exposure | 6 | What is the range, and is 6 the middle? |
| **2003** loop length | 1 | Minutes, or an index? Compare against the length of the clips actually written |
| **3024** SD status | 1 | What else can it answer? Eject the card and read it again |
| **3019** battery | 5 | A level, a percentage, or a code? Compare against `8005` |
| **2016** record status | 9 from a direct read, 1 inside `3014` | Two different things under one number. Which is the elapsed time, if either? |
| **2020 / 2021 / 2024** | 50 / 0 / 0 | Config fields 0x32, 0x33, 0x36, either side of the record bitrate at 0x34. Time stamp and motion detection are the missing settings; do those switches move these? |
| **3038 / 8005 / 8020** | 2 / 2 / 2 | The table gives all three config field 0x5b, which cannot be true for all of them. Move parking sensitivity on the camera and see which one changes |

## 4. Never sent, and worth seeing once

Present in the firmware's table, never exercised here. A capture of the stock
app doing the corresponding thing gives us the parameter form for free.

| cmd | Table name | Why we want it |
| ---: | --- | --- |
| **3005 / 3006** | SetDate / SetTime | **Nothing sets the camera's clock.** Timestamps are the evidentiary value of a dashcam and these cameras drift. What format does the date take? |
| **3002** | GetSupportCmd | Would answer most of this page for any given unit, including whether a rear channel exists |
| **3017** | GetBaseinfo | The remaining candidate for a firmware version string, which `3012` does not carry |
| **4005** | GetMovieFileInfo | Per-clip duration and resolution without downloading the clip |
| **4002** | GetThumbnail | Shares 4001's handler. If the stock app uses this one, that settles section 1 |
| **3004** | Manage_Wifi_Password | Changing the camera's own AP password, which is `12345678` from the factory |
| **3028** | SwitchCamera | Front/rear. Does the stock app show this control on a single-channel unit? |
| **2014** | Liveview bitrate | Live quality is currently whatever the camera picks |
| **3009** | DisplayMode | Unknown what it switches |
| **3023** | Basic_Auth_Logon | There is an authentication concept in this firmware. Does the stock app ever log in? |
| **3016 / 3022 / 3037** | MailBox, two queries | Unidentified |
| **3025 / 3026** | Update source / upload URL | The on-device update path, with `3013` |
| **1002 / 2017 / 2018 / 2025** | Snapshot size, simple snapshot, raw JPEG, trigger raw | A stills path that is not `1001` |
| **4004** | (file op) | An unidentified file operation next to delete |

## 5. Confirmed here, contradicting the table

Recorded so nobody re-derives them: **2022** is the record bitrate although the
table calls it `Config_Video_AntiProtect`; **8050** is a wifi scan although the
table calls it `Config_Parking_DurationLimit`; **3015** returns the whole card
rather than an event list, and we send it with `par=0` for reasons nobody has
established; **3003** answers `Status 0` with no value, and the AP name is in
**3029**; **3012** carries the model in a `<String>` element and no firmware
string; **3031** answers `-21` and is unusable on this unit.

## 6. Not a CGI command

Live video is RTSP on 554 (`rtsp://<cam>/xxx.mov`, LIVE555, H.265). The `404
Stream Not Found` that broke Live for a day was the PLAY target, not a missing
start command: aggregate control belongs at the server's `Content-Base`. If the
stock app's live view behaves differently — particularly if it survives longer
than the ~33 seconds we see when a download is running at the same time — the
RTSP exchange is worth capturing too.
