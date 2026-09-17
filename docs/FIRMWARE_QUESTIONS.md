# Open questions for the firmware

What the app still has to guess about the camera's CGI. The transport is known
and working:

```
GET http://<cam>/?custom=1&cmd=<N>[&par=<int>][&str=<string>]  ->  XML
```

A command sent without `par` is assumed to report its current value, and with
`par` to set it. **That assumption is itself unconfirmed** and is question 1.

Almost nothing below is a missing command *number*. The numbers come from the
firmware's own dispatch table. What is missing is the meaning of `par` and the
shape of the reply, which cannot be read off the table.

---

## 1. The conventions, which affect every row

| Question | Why it matters |
| --- | --- |
| Does a command sent **without** `par` return the current value, or is there a separate getter? | Every settings row reads this way. If wrong, all rows show "no value in the reply". |
| Which XML element carries the value in a reply? The app tries `Value`, `Val`, `Status`, `Cur`, `Current`, `String`. | Wrong element name means a row reads as unavailable. |
| What does `Status` mean on a **set**? Is `0` success? Which values are errors besides `-256`? | The app treats non-zero as failure and rolls the row back. |
| Is there a range or enumeration report per command, or only the bulk `3031`? | Would let the UI build option lists from the camera instead of hardcoding. |

Dumps of `cmd=3031` (Config_All_Capability), `cmd=3014` (Config_All_Items_Value)
and `cmd=3030` (resolution capability) would answer most of this at once.

---

## 2. Settings rows the app ships with guessed values

These are live in the app and marked `provisional: true` in
`Core/Settings/CameraSetting.swift`. The command is right; the numbers are
guesses.

| Row | cmd | cfg idx | What is needed |
| --- | ---: | ---: | --- |
| Video Resolution | 2002 | 0x1b | The `par` value for each mode. App currently guesses `0`=3840x2160, `1`=2560x1440, `2`=1920x1080. |
| Loop Record | 2003 | 0x23 | Is `par` the minute count (1/2/3) or an index (0/1/2)? Any other durations? |
| Exposure Compensation | 2005 | 0x6 | Range and step. App guesses an index `0…8` mapping to −2.0…+2.0 EV. Is it signed instead? |
| Driving Collision Sensing | 2011 | 0x4f | The name is `Config_Snapshot_SensorLevel`. **Is this actually the G-sensor**, or a snapshot exposure/ISO level? If it is the G-sensor, what are the sensitivity values and is `0` off? |
| Camera Language | 3008 | 0x43 | The language index table. |
| Parking Collision Detection | 3038 | 0x5b | Sensitivity values, and whether `0` is off. Note 3038, 8005 and 8020 all map to cfg 0x5b in the table, which looks wrong; which one really drives parking sensitivity? |
| Parking Duration Limit | 8050 | - | Units: hours, minutes, or an index? Valid range? |

Also worth confirming, though not marked provisional:

| Row | cmd | Question |
| --- | ---: | --- |
| Record Bitrate | 2013 | Confirmed default 8000, ceiling 32000 from `Validate_UI_configuration`. Are the units really kbps, so 8000 = 8 Mbps? Does a read-back return the same scale? |
| Sound Recording | 2007 | Is `1` on and `0` off, or inverted (mute flag)? |
| Image Flip | 2023 | `Config_Video_Vertical_FLIP` is a vertical flip. Is there a separate 180° rotate for upside-down mounting, or does this cover it? |

---

## 3. Rows in the design with no command identified

These are **absent from the app** because guessing would be worse than omitting
them.

| Row | Candidates in the table | What is needed |
| --- | --- | --- |
| **Time Stamp** (date/time burned into the frame, distinct from the brand watermark on 2008) | 2020 (cfg 0x32), 2021 (cfg 0x33), 2024 (cfg 0x36) are unnamed config setters | Which one, and its `par`. |
| **Motion Detection** | 2022 is `Config_Video_AntiProtect`, which does not sound like motion | The real command, or confirmation the unit has no such setting. |
| **Speed / GPS overlay** | none seen | Confirmation this unit has no GPS module, so the row stays out for good. |

---

## 4. Reply shapes the app parses by guesswork

| Command | Purpose | What is needed |
| --- | ---: | --- |
| **3015** Album_Event_FileList | Backs both Events and the card browser | The full XML shape: the record element name, and the fields for name, full path, size, timestamp and the lock/protect attribute. **Does `par` select events versus all files?** The app sends no `par` for events and `par=0` for everything, which is a guess. Is there paging for a full card? |
| **3012** DEV_GET_VERSION | Identity and the discovery fingerprint | Element names for model and firmware version. |
| **3019** Battery status | Live chip | Element name and units: percent, millivolts, or a level index? |
| **3024** SD card status | Live chip and the card screen | Element names. Percent used, or free and total bytes? How is "no card" reported? |
| **3029** Basic_Device_GetWifi_info | Network screen | Elements for current mode, SSID, IP address and signal strength. |
| **3003** Manage_Wifi_Name | The Wi-Fi name row | Which element holds the SSID on a read? |
| **2016** Record status and duration | The REC timer | Elements for recording state and elapsed seconds. |
| **2019** Media_Video_GetStreamUrl | Live view | Which element holds the URL. The app falls back to `rtsp://<cam>/xxx.mov`, which works but is assumed. |
| **4005** GetMovieFileInfo | File detail | Available fields, especially duration and resolution. |

---

## 5. File operations

| Command | Question |
| --- | --- |
| **4001 / 4002** GetThumbnail | How is the file identified: `str=<full path>`, `str=<name>`, or an index? What comes back, a raw JPEG body or XML wrapping one? The app currently sends `str=<path>` and expects JPEG bytes. |
| **4003** Album_Event_DeleteFile | Parameter form: `str=<path>`? Does it clear the protect bit on a locked clip, or refuse? |
| HTTP file server | Confirm files are served at the DOS path with the drive stripped, so `A:\DCIM\100MEDIA\FILE.MOV` becomes `GET /DCIM/100MEDIA/FILE.MOV`. Confirm `?del=1` deletes, and whether it works on locked files. |
| Lock / unlock | Is there a command to protect or unprotect a clip from the app? The design wants a "Keep locked" action. |

---

## 6. Live video

| Question | Why |
| --- | --- |
| Does this unit stream **H.264 or H.265** by default, and can it be forced to H.264? | The app decodes H.264 only. H.265 uses a different RTP payload format (RFC 7798) and is detected and reported rather than mis-decoded. |
| Is there a **rear channel**? How would the app detect one? (`cmd=3002` supported-command list, or `3031`?) | The front/rear switch (`cmd=3028`) is only meant to appear when a rear channel exists. |
| Does `cmd=2015` need `par=1`, and does the stream stop on its own? | The app sends `par=1` and issues TEARDOWN. |

---

## How to answer

The fastest route is dumps rather than prose. With the camera reachable:

```sh
for c in 3012 3014 3030 3031 3029 3024 3019 2016 3003 3015; do
  echo "=== cmd=$c ==="
  curl -s "http://<cam>/?custom=1&cmd=$c"
done
```

The app also captures all of this by itself: connect, open **Settings ▸ General ▸
Diagnostics**, and share. The export includes the capability reports, the raw file
listing, the RTSP negotiation and every command with its reply.
