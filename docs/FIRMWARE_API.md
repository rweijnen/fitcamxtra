# The camera's CGI, as observed

Confirmed against a CAR-WA7053 on 17 September 2026, from a diagnostics export.
Where this disagrees with the names in the firmware's dispatch table, the
observed behaviour wins and the disagreement is noted.

```
GET http://<cam>/?custom=1&cmd=<N>[&par=<int>][&str=<string>]  ->  XML
```

## The one that matters most

**A config command sent without `par` does not report its value.** It answers
`<Status>0</Status>`, meaning the command was accepted, and nothing else.
Reading rows one at a time therefore returns a wall of zeroes that looks like
every setting is switched off. This cost the app a release.

**`cmd=3014` is the getter.** It returns alternating `Cmd` and `Status`
elements, where `Status` carries that command's current value:

```xml
<Function>
  <Cmd>2002</Cmd><Status>10</Status>    <!-- resolution, index 10 -->
  <Cmd>2022</Cmd><Status>8000</Status>  <!-- record bitrate, kbps -->
  <Cmd>3033</Cmd><Status>0</Status>     <!-- network mode, 0 = AP -->
</Function>
```

Observed on this unit: 1002=0, 2016=1, 2001=1, 2002=10, 2003=1, 2004=1, 2005=6,
2020=50, 2021=0, 2022=8000, 2023=0, 2024=0, 2007=1, 2008=1, 2011=0, 2012=1,
3008=6, 3009=0, 3028=0, 3033=0, 3038=2, 8005=2, 8020=2.

`cmd=3031` (Config_All_Capability) answers `Status -21` and is unusable here.

## Where the dispatch table is wrong

| cmd | Table says | Actually |
| ---: | --- | --- |
| **2022** | Config_Video_AntiProtect | **Record bitrate in kbps.** It holds config index 0x34, the field `Validate_UI_configuration` checks against its 8000 default and 32000 ceiling. Reported as 8000. |
| **2013** | Media_Video_SetRecordBitrate | Reports nothing, holds nothing, absent from `3014`. Whatever it does, it is not where the bitrate lives. |
| **8050** | Config_Parking_DurationLimit | **A scan of the wifi networks the camera can see.** Takes about 2.4 seconds. Valuable: the phone cannot enumerate wifi, the camera can. |
| **3015** | Album_Event_FileList | Returns **the whole card**, not an event list. Locked clips have to be filtered out of it. |
| **3003** | Manage_Wifi_Name (AP SSID) | Answers `Status 0` with no value. The SSID is in `3029`. |

## Confirmed reply shapes

**3029** carries the access point's own credentials, not mode or address:

```xml
<LIST><SSID>CAR-WA7053-</SSID><PASSPHRASE>12345678</PASSPHRASE></LIST>
```

**3030** lists the resolutions this unit offers. **The indices are not
contiguous and cannot be guessed:**

| Index | Mode |
| ---: | --- |
| 1 | 3840x2160 @30 (upscaled; the sensor is 4 MP) |
| 7 | 2560x1440 @30 |
| 10 | 1920x1080 @60 |

**3015** returns one `File` per clip inside repeated `ALLFile` wrappers:

```xml
<File>
  <NAME>20260917174742_000001.MP4</NAME>
  <FPATH>A:\Novatek\MOVIE\20260917174742_000001.MP4</FPATH>
  <SIZE>83398596</SIZE>
  <TIMECODE>1563528725</TIMECODE>
  <TIME>2026/09/17 17:48:42</TIME>
  <ATTR>32</ATTR>
</File>
```

- `FPATH` maps to the HTTP file server by dropping the drive: `/Novatek/MOVIE/...`
- `TIME` is the usable timestamp. **`TIMECODE` is not a Unix time** and did not
  match `TIME`; it is ignored.
- `ATTR` is the DOS attribute byte. An ordinary clip is 32, archive alone, so
  the app treats bit 0, read-only, as the lock. **Still to confirm against a
  clip locked with the button.**

**8050**, the wifi scan:

```xml
<List><AP_index><SSID>WiFi-IoT</SSID><Auth_type>6</Auth_type><RSSI>54 dBm</RSSI></AP_index>…</List>
```

RSSI is positive despite the dBm label, so it is treated as relative strength.

**`3012` does report a model.** This unit answers `car-cam-cx7053DW`, which
is also what its access point is called. The earlier note here said the
command returned nothing usable; it returned no *firmware* string, and the
model was being read and stored all along. The name on the Settings screen
comes from this and is not invented.

**3032 takes station credentials as `<ssid>:<passphrase>`.** Confirmed by
driving the camera directly:

```
cmd=3032&str=WiFi-IoT-24:zeergeheimwachtwoord
cmd=3033&par=1      # station mode
cmd=3021            # save
cmd=3018            # restart the wifi
```

The separator is a colon, sent literally rather than percent-encoded. An SSID
containing a colon has no representation here.

**The camera answers ICMP echo.** Confirmed on hardware. Discovery pings the
range first and asks only the addresses that reply for `cmd=3012`, which turns
253 connection attempts into a handful. The full HTTP sweep still runs when the
ping pass produces no camera, because an access point may filter echo between
its clients and a reply can be lost; it is no longer there to cover the camera
itself.

**Live video is H.265**, not H.264:

```
a=rtpmap:96 H265/90000
a=fmtp:96 …sprop-vps=…;sprop-sps=…;sprop-pps=…
a=control:track1
```

The stream is LIVE555 at `rtsp://<cam>:554/xxx.mov`, and RTP interleaves over
the same TCP connection.

## Still open

| Question | Why it matters |
| --- | --- |
| **ATTR value for a locked clip.** Expected 33, read-only plus archive. | The whole Events tab depends on telling locked clips from loop clips. |
| **3024 SD status** answers `1`. Scale unknown. | Shown as a warning only when it is not 1; no percentage is displayed because none is known. |
| **3019 battery** answers `5`. Scale unknown. Is `8005` the numeric value? | The battery chip is hidden rather than showing an invented percentage. |
| **2020 = 50, 2021 = 0, 2024 = 0.** Config indices 0x32, 0x33, 0x36, next to the bitrate at 0x34. | These are the likely homes of **Time Stamp** and **Motion Detection**, which the app leaves out rather than guess. 50 does not look boolean. |
| **2011** is named Config_Snapshot_SensorLevel. Is it the G-sensor or a snapshot setting? | Shipped as Driving Collision Sensing, still provisional. |
| **3038 = 2, 8005 = 2, 8020 = 2**, all mapped to config index 0x5b in the table. | Three commands cannot share one field. Which one is parking sensitivity? |
| **2003 loop** reports 1. Minutes, or an index? | Shipped as minutes, still provisional. |
| **2005 exposure** reports 6. Range and step? | Shipped as an index 0 to 8, still provisional. |
| **3008 language** reports 6. Which language is 6? | Shipped with a guessed table, still provisional. |
| **4001 thumbnails and 4003 delete**: parameter form and response type. | Both are implemented with `str=<path>` and untested. |
| **Writing the bitrate**: does 2022 alone apply it, or does 2013 have to be sent too? | The app writes 2022 only and re-reads to confirm. |
| **Rear channel**: how to detect one? `3002` GetSupportCmd? | The front/rear switch stays hidden until it can be detected. |
| **Firmware version**: `3012` carries a model but no firmware string. Does `3017` GetBaseinfo carry one? | The app shows "unreported" rather than inventing a version. |
