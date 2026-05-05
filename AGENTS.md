# Agent and contributor notes — KCD2 Mercenaries mod

This file orients humans and coding agents working on this repository. Deeper “how to mod KCD2” context lives in [`docs/`](docs/index.md) and [`docs/general/how-to-mod.md`](docs/general/how-to-mod.md).

## What this mod does

Companion-style mercenaries: hire, basic orders (follow / wait / dismiss), combat behavior via Behaviour Trees, persistence in save, localization. Some branches extend this (e.g. horses for mercenaries).

## Repository layout

| Path | Purpose |
|------|---------|
| `data/` | Lua (`data/Scripts/mods/`), Behaviour Trees, Skald/XML table patches under `data/libs/tables/` |
| `localization/` | UI and dialogue strings |
| `docs/` | Project wiki: Lua ↔ Skald, spawning, XML souls, BT guides |
| `tools/` | Utilities (e.g. voiceover batch scripts) |
| `PackageMod.bat` | Local packaging: copies the mod tree into the game `Mods` folder (paths are machine-specific; edit as needed) |

## Patch naming (XML / tables)

Follow Warhorse-style table patches: `originalfilename__yourmodid.xml` (note **two underscores** between base name and mod id). See `docs/general/how-to-mod.md`.

## Lua mod scripts

- Main logic is split across `mercenaries_*.lua` under `data/Scripts/mods/`.
- Prefer extending existing modules and patterns already in those files (logging style, entity name conventions).
- Base game Lua reference (when available locally): modding tools `docs/script_bind` — described in `docs/general/how-to-mod.md`.

## Mercenary visibility, LOD, and Skald (important)

Do **not** “fix” disappearing or low-detail mercenary meshes by forcing render distance or always-on rendering from Lua (e.g. patterns like aggressively toggling `SetViewDistRatio`, `RenderAlways`, or similar). That fights the engine’s LOD/culling and has caused **body meshes popping to wrong LOD or vanishing while weapons stayed visible**.

Preferred approach:

1. Keep **Skald character rows** aligned with how vanilla NPCs of the same archetype are configured. In particular, avoid unusual `streaming_string_name` (or equivalent) values copied from unrelated definitions unless you know they match the character’s intended streaming profile.
2. If mercenaries misbehave after spawn or equipment changes, debug **lifecycle and cache** (when entities are rebuilt, equipped, dismissed) rather than reintroducing render hacks.

### Optional lifecycle debug

In `mercenaries_util.lua`, setting `_G.MercDebugMercLifecycle = true` (game console) enables extra `[MercDebug]` log lines after cache rebuild / equip — useful when investigating battle or dismiss edge cases. See the comment at the top of that file.

## Packaging and testing

- Run `PackageMod.bat` after edits; confirm output path matches your Steam install (script may point at `...\KingdomComeDeliverance2\Mods\...`).
- The batch script may warn about missing localization files (e.g. Chinese) if those packs are absent; that is often expected for a partial checkout.
- Prefer testing in **retail** game builds when possible; modding-tools builds can differ (see `docs/general/how-to-mod.md`).

## Where to read next

- [docs/index.md](docs/index.md) — wiki map
- [docs/spawning-npcs.md](docs/spawning-npcs.md) — spawning from Lua
- [docs/xml/add-new-npc.md](docs/xml/add-new-npc.md) — soul / appearance / inventory
- [docs/general/lua-skald-communication.md](docs/general/lua-skald-communication.md) — Skald ↔ Lua

When adding behavior, mirror existing `mercenaries_*` naming and error handling; avoid drive-by refactors unrelated to the task.
