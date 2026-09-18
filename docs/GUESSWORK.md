# What the app is guessing

Everything here is something the app does without hardware confirmation, or a
question whose answer would change what the app does. It is the companion to
[FIRMWARE_API.md](FIRMWARE_API.md), which records what a real CAR-WA7053
**did** answer; this file records what is still assumed.

The point of keeping it is that a session with the camera to hand — or a
session with the firmware image open in a disassembler — can work down it and
turn entries into confirmed behaviour. When an entry is settled, move it into
FIRMWARE_API.md as observed behaviour and delete it here.

The recovered command table in `FITCAMX_CGI_API.md`, kept with the firmware
image outside this repository, has already answered what each command *is*.
What remains below is almost entirely about what its values *mean*, which the
table does not say.

**How to confirm an entry:** the app logs every command and reply, so the
answer to most of these is one diagnostics export away. The "how to check"
column says what to do on the phone; the export then carries the reply.
Anything marked *firmware* needs the image rather than the camera.

---

## 1. Settings whose meaning is unverified

These four ship with a label and a control, and the command number is confirmed
from the dispatch table, but nothing has verified what the parameter means.
A fifth, 2011, was withdrawn: the table calls it `Config_Snapshot_SensorLevel`,
so shipping it as the driving G-sensor was telling people something about their
collision sensing that may have been about stills. The
code marks them `provisional: true`
(`FitCamXtra/Core/Settings/CameraSetting.swift`), and **no screen shows that
flag** — a guess is currently drawn exactly like a confirmed value.

| Setting | cmd | Reported | What is assumed | How to check |
| --- | ---: | ---: | --- | --- |
| Loop Record | 2003 | 1 | That the value is minutes (1/2/3), not an index | Set it to each value in the app, then look at the length of the clips the camera writes |
| Exposure Compensation | 2005 | 6 | An index 0–8 shown as −2.0…+2.0 in thirds | Set 0 and 8, film something evenly lit, compare brightness. If 6 is the middle the scale is wrong |
| Camera Language | 3008 | 6 | A table covering 0–3 only. **The camera reports 6, which is off the end of the table, so the row currently renders the literal text "value 6"** | Change the language on the camera itself and read 3008 back for each one |
| Parking Collision Detection | 3038 | 2 | That 3038 is parking sensitivity, which is what the firmware table calls it (`Config_Parking_Sensor`). 3038, 8005 and 8020 all report 2 and the table gives all three config index 0x5b and event 0x14020034, which cannot all be true | Change parking sensitivity on the camera, re-read all three, see which moves |

## 2. Commands the app sends without knowing the parameter form

| cmd | Used for | The guess | Risk if wrong | How to check |
| ---: | --- | --- | --- | --- |
| 4001 | Thumbnails | `str=<camera path>`, e.g. `A:\Novatek\MOVIE\x.MP4`, answering with image bytes. **4002 is the same handler and is untried** | Blank tiles. Harmless, and now logged: the app records the first 300 bytes of whatever comes back instead | Open the SD card screen and export the diagnostics. The log names what the camera sent. If 4001 keeps answering with something else, try 4002 |
| 4003 | Delete | Same `str` form, with the file server's `?del=1` as the fallback | A delete that silently does nothing, or deletes the wrong file | Delete one clip, re-read the listing, confirm that file and only that file is gone |
| 3015 | The card listing | Sent with `par: 0` for the full listing and without `par` for events. The doc records the reply in detail but never mentions a parameter, and the doc's own rule is that `par` means *set* | Unclear — it works, so `par: 0` is evidently harmless | Send it both ways and compare the replies. Then record which form is right in FIRMWARE_API.md |
| 3030 | Resolution options | A reply of `<item>` elements carrying `index`, `size` and `framerate`. The doc records the index→mode table but never the XML | The resolution row offers no choices at all | Export the diagnostics after opening Settings; the raw 3030 reply is logged |
| 2019 | Live stream URL | Reads `url`, `string` or `value` from the reply. Nothing in the doc covers 2019 | None — the nil case is handled honestly and the known path is kept | Open Live and export. The reply is logged either way |

## 3. Scales and units that are not known

| What | cmd | Answer seen | What is missing |
| --- | ---: | ---: | --- |
| SD card health | 3024 | `<Value>1</Value>` | What the scale is. The app treats anything other than 1 as a problem and shows no percentage. Whether 1 means "healthy" is an assumption |
| Battery | 3019 | `<Value>5</Value>` | Same. No percentage is shown. Whether 8005 carries a finer value is untested |
| Recording elapsed | 2016 | `<Value>9</Value>` | Whether this is seconds into the current clip, a clip index, or something else. The Live timer treats it as seconds |
| Wifi scan signal | 8050 | `RSSI 54 dBm` | Positive numbers with a dBm label. Treated as relative strength, so the ordering may be inverted |
| Locked-clip attribute | 3015 | `ATTR 32` | An ordinary clip is 32 (archive). The app treats bit 0, read-only, as the lock. **No clip locked by the button has been seen yet**, so the whole Events tab rests on this |

## 4. Commands the app never sends

Confirmed present in the dispatch table, wired into `CameraCommand`, and called
from nowhere. Each is either a missing feature or a decision worth recording.

| cmd | Name | Why it is unused |
| ---: | --- | --- |
| 3005 / 3006 | Set date / set time | **Nothing sets the camera's clock.** Clip timestamps are the evidentiary value of a dashcam and these cameras drift. The most valuable unused pair here |
| 3004 | Set the camera's own wifi password | The factory passphrase is `12345678` and the app knows it. Changing it is not offered |
| 3028 | Switch front/rear channel | Deliberately hidden: there is no way yet to detect whether a unit has a rear channel |
| 3002 | Supported commands | `Basic_Device_GetSupportCmd`, a direct handler in the table. Would answer the rear-channel question and most of section 1 for a given unit. **The single most valuable unused command in this file** |
| 3017 | Base info | The remaining candidate for a firmware version string, which 3012 does not carry |
| 3013 | Apply firmware | No update flow |
| 2014 | Live view bitrate | Live quality is whatever the camera chooses |
| 1002 / 2017 | Snapshot size / simple snapshot | Snapshots use 1001 only |
| 3009 | Display mode | `Config_Video_DisplayMode`, config field 0x45. Unknown what it switches |
| 3031 | All capability | Correctly unused: the doc records it answering `Status -21` on this unit |
| 8005 / 8020 | Parking-adjacent values | See the 3038 question in section 1 |
| 4005 | Movie file info | Per-clip duration and resolution come from the listing instead, when present |

## 4b. Commands the app does not know about

Present in the recovered table, absent from `CameraCommand`. Listed so a later
session does not have to rediscover them.

| cmd | Table name | Worth a look because |
| ---: | --- | --- |
| 3023 | `Basic_Auth_Logon` | There is an authentication concept in this firmware. The app assumes an open CGI, which is what this unit does |
| 3017 | `Basic_Device_GetBaseinfo` | The remaining candidate for a firmware version string |
| 3016 | `Basic_Msg_MailBox` | Unknown. A message channel of some kind |
| 3022 / 3037 | (query, cnt mode status) | Unknown queries, direct handlers |
| 3025 / 3026 | `DEV_QUERY_UPDATE_SOURCE`, `DEV_QUERY_UPDATE_UPLOAD_URL` | The on-device update path, with 3013 |
| 3034 | `AutoTest` | A factory routine. Best left alone |
| 2009 / 2018 / 2025 | video cfg, raw encoded JPEG, trigger raw encode | 2018 and 2025 look like a stills path that is not 1001 |
| 1003 | (snapshot end) | Pairs with 1001 |
| 4004 | (file op) | An unidentified file operation next to delete |
| 5001 | `UploadFile` | The file server already accepts multipart POST |

## 5. Assumptions in the app's own logic

| Assumption | Where | Why it might be wrong |
| --- | --- | --- |
| Loop clips are 60 seconds | `Core/Model/CameraEvent.swift` — incident bundles look for neighbours ±60s with 30s tolerance | Loop Record is a setting offering 1/2/3 minutes. At 3 minutes neighbour matching silently never matches, and the screen blames the loop for overwriting clips that are still there |
| A clip's identity is its path | `Core/Files/MediaLibrary.swift` — unread events are tracked by id | Loop recording overwrites, so the remembered last-seen clip routinely no longer exists, and then every locked clip is marked new |
| The stream is at `/xxx.mov` | `Platform/RTSPClient.swift` default path | Only used when 2019 reports nothing. Confirmed working on this unit |
| RTP arrives on interleaved channel 0 | `Platform/RTSPClient.swift` | The SETUP reply is authoritative and is not read. LIVE555 honours the request, so this holds here and would fail silently elsewhere |
| Any device answering 3012 with XML is the camera | `Core/Camera/CameraClient.swift` — `looksLikeFitCamX` | A loose fingerprint. It would adopt another Novatek device on the same subnet |

## 6. Questions for the firmware image

Everything above that is marked *firmware*, plus:

- **Which of 3038, 8005, 8020 owns config index 0x5b**, since all three cannot.
- **The language table for 3008**, which reports 6 against a guessed table of 0–3.
- **Whether 2020 (50), 2021 (0) and 2024 (0)** — config indices 0x32, 0x33, 0x36, sitting either side of the record bitrate at 0x34 — are the Time Stamp and Motion Detection settings the app currently leaves out rather than guess at.
