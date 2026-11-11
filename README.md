# ISDT Air Control

A native macOS (SwiftUI, Liquid Glass) app for ISDT **A8 Air**, **A4 Air** and **C4 Air** battery chargers, talking to them directly over Bluetooth LE. It replaces the manufacturer's phone app for everyday use:

- **Live view of every slot** as compact battery columns side by side, in the charger's physical order, with voltage, current and chemistry drawn inside each battery. Hover a slot for charged mAh and elapsed time.
- **Several chargers at once**, any mix of the supported models, each in its own window.
- **Per-slot settings** (battery type, charge current, cut-off voltage / delta-peak, capacity limit) in a popover, with **Apply to All Slots** to send one slot's settings to every slot of that charger.
- **System notification when a slot finishes charging** (and, optionally, when a slot errors). With several chargers the notification says which one. Slots finishing together are grouped.
- Lives in the **menu bar** too: closing windows doesn't quit, so you still get notified.

| Charger | Slots | Status |
| --- | --- | --- |
| A8 Air | 8 | Tested on real hardware |
| A4 Air | 4 | **Not tested on hardware** |
| C4 Air | 6 channels, 4 or 2 shown | Tested on real hardware |

The C4 Air has two alternative bay layouts (slots 1–4, or the two large bays 5/6); the app shows whichever layout holds batteries, and keeps the last one when both are empty.

## Build & run

```bash
./build_app.sh            # builds "ISDT Air Control.app" (ad-hoc signed)
open "ISDT Air Control.app"
```

It must be run as the `.app` (not `swift run`): Bluetooth permission and notifications only work for a real app bundle. macOS asks for Bluetooth and Notification permission on first launch.

**First connection:** a charger accepts one app at a time, so close ISD Link on your phone first. A new client has to be approved once: the charger beeps, press any button on it. After that this Mac is remembered.

### If macOS won't open the app (Gatekeeper)

The build is **ad-hoc signed, not notarized** (that needs a paid Apple Developer account). What happens depends on where the app came from:

- **Built on this Mac with `./build_app.sh`:** it opens normally. Nothing downloaded, so nothing is quarantined.
- **Downloaded, AirDropped, or copied from another Mac:** macOS quarantines it, and Gatekeeper refuses with *"ISDT Air Control can't be opened because Apple cannot check it for malicious software"* (or, sometimes, *"… is damaged and can't be opened"*). The app isn't actually damaged. Pick one:

  1. **Open Anyway** (no Terminal): double-click the app once and dismiss the warning, then open **System Settings → Privacy & Security**, scroll to *Security*, click **Open Anyway** next to "ISDT Air Control was blocked", and authenticate. On macOS 15 (Sequoia) and later this is the only GUI route; the old Control-click → Open shortcut no longer bypasses Gatekeeper.
  2. **Remove the quarantine flag** (Terminal):

     ```bash
     xattr -dr com.apple.quarantine "/Applications/ISDT Air Control.app"
     ```

     Adjust the path to wherever you put the app. This also cures the "is damaged" variant.

Only do this for a copy you built yourself or got from someone you trust. There's no need to turn Gatekeeper off globally (`spctl --master-disable`).

After the first launch macOS asks for **Bluetooth** and **Notifications** permission; the app needs both (Bluetooth to talk to the chargers, Notifications to tell you when a slot is done). If you declined one, the app shows how to fix it.

**Stale icon after replacing the app** (e.g. notifications still show an older icon): macOS caches icons per bundle. Re-register the app and restart the caching agents:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R -trusted "/Applications/ISDT Air Control.app"
killall iconservicesagent usernoted NotificationCenter
```

## Languages

The app follows your macOS language and is localized into the same 18 languages as the sibling instrument apps: English, German, Spanish, Catalan, French, Portuguese (Portugal and Brazil), Dutch, Italian, Polish, Czech, Danish, Swedish, Norwegian Bokmål, Finnish, Simplified Chinese, Japanese and Korean. Strings live in `Localization/<code>.lproj/Localizable.strings` and are copied into the app bundle by `build_app.sh`. To try another language without changing your system language: `open -n "ISDT Air Control.app" --args -AppleLanguages "(ja)"`.

## Using it

| Action | How |
| --- | --- |
| Add / remove chargers | **Chargers…** in the menu bar item, the File menu, or Window → Chargers. Each charger opens in its own window; a charger found for the first time is added automatically if it's the only one in range |
| Edit a slot | Click its column; its settings open in a popover |
| Apply | **Apply** (⌘↩) writes to that slot |
| Same settings everywhere | **Apply to All Slots…** in the popover (asks for confirmation; all slots of that charger) |
| Undo edits | **Revert** returns the draft to what the charger has stored |

After every apply the app reads the settings back from the charger and tells you per slot whether they were **confirmed**, **adjusted** (the charger kept different values), or **unconfirmed**.

Edits you haven't applied are never overwritten by the background refresh (an orange dot marks those slots).

> ⚠️ **Applying settings (re)starts charging** on slots with a battery in them: that's how the charger's own protocol works (`WorkTasksReq` is the "start a charge" command). Check the chemistry before applying: wrong chemistry or cut-off can damage batteries or start a fire. You use this at your own risk.

## Notifications

Settings (⌘,) → Notifications: toggle "slot finished", "slot error" and sound. If macOS notification permission is missing, a row with a button to grant it (or open System Settings) appears there. A charge counts as finished when a slot goes from *charging* to *done*; a slot that's already done when the app starts doesn't notify. The app remembers slot states across Bluetooth reconnects (the A8 drops the link every couple of minutes), so a charge that finishes during a dropout is still reported.

## Protocol sources

The chargers speak a reverse-engineered BLE protocol (service `0000af00-…`, characteristics AF01/AF02):

- Reading + bind handshake: [mtheli/isdt_air_ble](https://github.com/mtheli/isdt_air_ble) (`PROTOCOL.md`)
- Writing slot settings (`WorkTasksReq`), the A8's settings query, and the A4/C4 per-channel details: [DittelHome/ISDT-Charge-Utility](https://github.com/DittelHome/ISDT-Charge-Utility)
- Per-chemistry value ranges are the ones that project documents from the ISD Link app.

The A8 reports all slots in one 203-byte packet. The A4 and C4 are polled one channel at a time (a WorkState and an Electric request per channel), and report each slot's stored settings inside every WorkState reply. The A4 numbers its channels in the opposite direction to its physical slots, which the app reverses. The C4 allows up to 2 A per slot (A8/A4: 1 A).

## Caveats: please read

**A4 Air and C4 Air support has not been run against real hardware.** It's built from the two documents above and unit-tested (frame parsing, slot/channel mapping, bay-layout switching), but nobody has connected an A4 or C4 to it yet. The likeliest things to need a tweak: whether the A4/C4 reply with the layouts the docs describe, the A4's slot order, which of the C4's channels answer in each bay layout, and the meaning of the reply's "max output power" field, which the Charge Utility uses as the capacity limit.

**Verified on a real A8 Air:** discovery and model detection, the bind handshake (with `BindReq` last byte `0x01`, no `0xE2` stream-start needed), hardware info (HW 1.0 / FW 2.2 on the test unit), the 203-byte status mega-packet, the settings query, and input voltage/current; stable polling. The internal-resistance field is in 0.01 mΩ, as the Charge Utility documents (values like 15–22 mΩ on the test cells).

**Writing settings** was verified on an emptied A8 slot (acknowledged, read back, restored). What a write does to a slot that has a battery in it (it should restart charging) is untested. Other things to know:

- **Stored current reads 0.** The charger reports a stored current of 0 for every slot while charging at about 500 mA, so the app treats 0 as "charger default" (there's a toggle for it). Whether a non-zero current is honoured by the A8 is unconfirmed.
- **Odd stored cut-offs.** Some slots report leftovers (e.g. a NiMH slot with a 1900 mV cut-off); the editor flags out-of-range values until you change them.
- **"Empty slot"** isn't a distinct state on the A8; the app treats *idle with < 0.5 V* as no battery.
- The capacity percentage the A8 reports looked coarse (10% → 90% jumps), so treat it as indicative.

If something misbehaves, run the **hardware probe** (below): it records the raw bytes in both directions, which is exactly what's needed to fix a protocol detail.

## Development

```text
Sources/ISDTCore/        protocol layer: frame parsing/reassembly, command bytes, models,
                         completion detector, notification wording. No CoreBluetooth/SwiftUI.
Sources/A8AirControl/    app (slot columns, settings popover, menu bar): BLECentral (one shared CoreBluetooth
                         central) → BLETransport (link per charger) → ChargerSession (handshake,
                         request/response) → Charger (@Observable per charger: connection + poll
                         loops, drafts/apply) ← ChargerHub (all chargers, discovery, windows) → SwiftUI views
Localization/            Localizable.strings for 18 languages (English is the source)
Tests/ISDTCoreTests/     Swift Testing suite (44 tests)
Tools/make_icon.swift    renders the app icon
```

Architecture mirrors the sibling instrument apps: one `@MainActor @Observable` model owns all UI state, a fast poll loop (every 1–10 s, default 3 s) reads live status, and a slower tier (every 20 s) re-reads stored settings while skipping slots with unapplied edits. Connection failures reconnect automatically with backoff.

```bash
swift test      # on a machine with Xcode
# With only the Command Line Tools, Swift Testing needs its framework path:
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
```

**Hardware probe:** `open -n "ISDT Air Control.app" --args --probe /tmp/probe.txt` connects read-only and writes link state, slot data and raw traffic to that file every 2 s.

**Demo mode:** `open -n "ISDT Air Control.app" --args --demo` runs with three simulated chargers (A8, A4, and a C4 using its large bays) and no Bluetooth. Six seconds in, a slot on each "finishes charging", which exercises the real completion detector and notification path. Useful for looking at the UI, or testing notifications, without a charger.

Not affiliated with ISDT. MIT licensed.
