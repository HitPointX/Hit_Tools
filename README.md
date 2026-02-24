# Hit-Tools

Hit-Tools is a World of Warcraft TBC Anniversary addon focused on dungeon pace, group utility, and quality-of-life tools.

- Interface: `20505`
- Current version: `0.1.0`
- Addon folder: `Hit_Tools`

## Current Feature Set

### XPRate + Dungeon Tracking
- Session and rolling XP/hour tracking.
- Time-to-level estimate.
- Movable mini UI frame with live stats.
- Automatic dungeon run tracking for 5-player instances.
- End-of-run summary with XP, mobs, deaths, items by quality, reputation gains, gold, and estimated footsteps.
- Smart run finalization logic to avoid bad finalizes during corpse runs, quick re-entry, or zone churn.
- Optional party/raid chat output for run summaries.

### Alerts
- Top-screen healer OOM alert with animated text.
- Sound alert support (`assets/meow.ogg`) with volume control.

### AMark (Auto Target Marking)
- Auto-marks hostile packs around your target.
- Healer/caster/support keyword prioritization.
- Skull priority for healer targets (configurable threshold behavior).
- Kill-order and CC-priority modes.
- Party/raid/solo toggles and tank-gated behavior.
- Zone-in kill-order announcement with dedupe to prevent spam during roster churn.

### Social Heatmap
- Local-only run analytics for players you group with.
- Tracks run outcomes, wipes, deaths, role tendencies, and pair synergy.
- Optional sentiment tracking from group chat (opt-in).
- Friend and Battle.net helper workflow.
- Built-in retention limits and automatic compaction.

### Social Heatmap UI
- Dedicated UI with tabs for:
  - Players
  - Pairings
  - Runs
  - Settings
- Filtering, sorting, and drill-down views for run history and player metrics.

### Baggy
- Unified bag UI replacement ("one big bag").
- Search and multiple sort modes (`default`, `rarity`, `alphabetical`, `type`, `newest`).
- Rare/epic loot rainbow border effect.
- Bank integration and keyring panel support.
- Per-character and account-total gold display.

### Scrapya
- Auto-sells poor-quality (grey) items when a vendor opens.
- Uses repeated sell passes for reliable bulk selling.
- Shift override support (hold Shift while opening vendor to skip once).
- Optional caution mode (disabled by default): can sell soulbound white/blue armor that is not your class primary armor type.
- Caution mode safeguards: never sells BoE items and never sells jewelry/weapons through that mode.

### CursorGrow
- Cursor growth/visibility aid based on high-speed cursor movement.
- Optional glow effects and debug/test controls.
- Optional easter egg particle effects.

### Catfish
- Double-left-click world cast helper for Fishing using a secure click-binding approach.
- Bobber bite alert with transparent pulsing circular glow plus meow sound (`assets/meow.ogg`).
- Hover-assisted bobber tracking with soft-target CVar tuning for better bobber detection fidelity.
- Adaptive timing model that learns cast-to-catch timing from recent successful catches.
- Adaptive predictor includes EMA smoothing and anti-early bias tuning to reduce premature alerts.
- Glow anchor prefers confirmed bobber-hover cursor position, then cursor fallback if needed.
- On clients without direct pre-bite combat events, best results come from hovering the bobber.
- Alert stops on click/loot and uses timeout safeguards to avoid stale screen effects.

### MountTracker
- Detects tracked mount boss pulls (raid + dungeon + target/combat fallback logic).
- Per-boss kill counts.
- Dynamic drop chance estimate using configured base chance plus progression scaling.

## Slash Commands

Primary:
- `/hittools`
- `/hit`
- `/xprate` (alias)

Core:
- `/hit config` - Open addon options.
- `/hit stats` - Show dungeon averages.
- `/hit ui` - Toggle mini UI.
- `/hit lock` - Lock/unlock mini UI.
- `/hit reset` - Reset dungeon stats.
- `/hit verbose` - Toggle verbose loading logs.

CursorGrow:
- `/hit cursor ...`
- `/hit cursor on|off`
- `/hit cursor max <1.0-5.0>`
- `/hit cursor debug [on|off]`
- `/hit cursor test`

Catfish:
- `/hit catfish ...`
- `/hit catfish on|off|test`
- `/hit catfish debug on|off`
- `/hit catfish adaptive on|off`
- `/hit catfish adaptive reset`
- `/hit catfish delay <1-60>`
- `/hit catfish lead <0-3>`
- `/hit catfish min <2-40>`
- `/hit catfish max <3-45>`

Baggy:
- `/hit baggy debug [on|off]`
- `/hit baggy diag`
- `/hit baggy overlay`

Scrapya:
- `/hit scrapya on|off`
- `/hit scrapya status`
- `/hit scrapya summary on|off`
- `/hit scrapya shift on|off`
- `/hit scrapya soulbound on|off`

Social Heatmap:
- `/hit social stats`
- `/hit social perf`
- `/hit social compact`
- `/hit social diag`
- `/hit social debug on|off`
- `/hit social sentiment on|off`
- `/hit social addfriend <name>`
- `/hit social setbnet <name> <BattleTag>`
- `/hit social invite <name>`
- `/hit social friend <name>`
- `/hit social reset player <name>`
- `/hit social reset all`

## Installation

1. Place this addon at:
   - `World of Warcraft/_anniversary_/Interface/AddOns/Hit_Tools`
2. Reload UI in game:
   - `/reload`
3. Open settings:
   - `/hit config`

## Data Storage

This addon currently stores data in per-character SavedVariables:
- `HitToolsDB`
- `XPRateDB`

## Project Status

Active development. Feature polish and guardrail fixes are ongoing as TBC Anniversary behavior is validated in live runs.
