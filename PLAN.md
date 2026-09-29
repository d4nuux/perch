# NotchApp plan

Our own notch app, written from scratch. Feature parity target: fluid transitions, live activities,
notifications, swipe gestures, custom HUDs, lock screen widgets, native performance.

## Architecture (owned by lead)
- `Core/NotchModel.swift` — UI state, `open/close`, `selectTab`, `present(LiveActivity)` / `dismissActivity`.
- `Core/LiveActivity.swift` — leading/trailing/below content around the closed notch.
- `Core/AppSettings.swift` — every toggle, persisted.
- `Core/Services.swift` — `NotchContext` handed to each service.
- `Core/NotchController.swift`, `UI/NotchView.swift` — panel, hover tracking, rendering.

## Workstreams (parallel, one owner each, own folder only)
| Agent | Folder | Scope |
|---|---|---|
| HUD | `HUD/` | Volume, brightness, keyboard backlight: intercept keys, change value, show notch HUD, suppress system OSD |
| Activities | `Activities/` | Charging / unplug, low battery, Bluetooth device connect (with battery %), track-change peek |
| Calendar | `Calendar/` | EventKit, Calendar tab, upcoming-meeting activity with Join button (notifications stand-in) |
| Settings | `Settings/` | Settings window, launch at login, trackpad swipe gestures |
| LockScreen | `LockScreen/` | Now-playing + clock/battery widget on the lock screen |

## Integration (lead)
Merge folders → build → fix → run → review pass.

## Wave 4 (parity gaps)
| Agent | Owns | Scope |
|---|---|---|
| media4 | `Media/` | Artwork styles (full / gradient / mono), artwork flip on track change, Explicit badge (iTunes Search lookup, cached), Lossless/Atmos only if a real signal exists |
| hud4 | `HUD/` | Glow + decibel bar styles, per-HUD rules (off on lock screen / during Focus), external display brightness (native DDC on Apple Silicon, BetterDisplay fallback) |
| act4 | `Activities/` | Animated 3D device visuals (SF Symbols + rotation3DEffect, per device type) for Bluetooth/charging |
| shell4 | `Core/`, `UI/`, `Display/`, `Settings/Gesture*` | Swipe to cycle activities (history queue), contrast outline, progressive blur, hide during Mission Control and games |

Out of scope: auto-update (no release host yet), Focus names without Full Disk Access (no public source).
