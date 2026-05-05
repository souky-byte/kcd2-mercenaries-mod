#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLLOW_XML="$ROOT/data/AI/mercenary_follow.xml"
HORSES_LUA="$ROOT/data/Scripts/mods/mercenaries_horses.lua"
MAIN_QUEST_LUA="$ROOT/data/Scripts/mods/mercenaries_main_quest_handler.lua"

if rg -n "DespawnHorseFor" "$FOLLOW_XML"; then
  echo "mercenary_follow.xml must not despawn merc horses when the player dismounts" >&2
  exit 1
fi

rg -n "function mercenaries:EnsureHorseForMerc" "$HORSES_LUA" >/dev/null
rg -n "function mercenaries:TeleportHorseNearMercIfFar" "$HORSES_LUA" >/dev/null
rg -n "MercHorseMapV2" "$HORSES_LUA" >/dev/null
rg -n "MercHorseMap'" "$HORSES_LUA" >/dev/null

if rg -n "DespawnAllHorses\\(" "$MAIN_QUEST_LUA"; then
  echo "fast-travel handling must not clear persistent merc horse assignments" >&2
  exit 1
fi
