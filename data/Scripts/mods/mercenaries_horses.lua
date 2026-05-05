-- =======================================================================
-- HORSES MODULE
-- Centralized lifecycle management for mercenary mounts.
-- Called from the mercenary_follow Behavior Tree on stance change.
--
-- Cache:    mercenaries.ActiveHorses[npcEntityName] = { entRef, soulGuid, ownerWuid }
-- Pools:    mercenaries.HorseSouls.common / .elite (defined in mercenaries.lua)
-- Naming:   horse entity name = "MercenaryHorse_" .. npcEntityName
-- Persist:  SaveString tag "MercHorseMap" — "npcName=soulGuid|npcName2=soulGuid2"
-- =======================================================================

-- Internal: build entity name for the horse owned by a given NPC.
function mercenaries:HorseNameForMerc(npcName)
    if not npcName or npcName == "" then return nil end
    return 'MercenaryHorse_' .. tostring(npcName)
end

function mercenaries:ParseHorseMap(raw)
    local parsed = {}
    if not raw or raw == '__empty__' then return parsed end

    for entry in string.gmatch(raw, '([^|]+)') do
        local npcName, soulGuid = string.match(entry, '^(.-)=(.+)$')
        if npcName and soulGuid then
            parsed[npcName] = soulGuid
        end
    end

    return parsed
end

function mercenaries:GetSavedHorseSoul(npcName)
    if not npcName then return nil end
    if not self.SavedHorseSouls then
        self.SavedHorseSouls = self:ParseHorseMap(self:LoadString('MercHorseMap'))
    end
    return self.SavedHorseSouls[npcName]
end

function mercenaries:ResolveHorseEntityByMercName(npcName)
    local horseName = self:HorseNameForMerc(npcName)
    if not horseName then return nil end

    local horseEnt = System.GetEntityByName(horseName)
    if horseEnt and self.ActiveHorses[npcName] then
        self.ActiveHorses[npcName].entRef = horseEnt
    end

    return horseEnt
end

-- Internal: pick an appropriate horse soul GUID for a given NPC entity.
-- Priority:
--   1. Custom companion with dedicated horse → CustomCompanionHorses[ccID]
--   2. Custom companion without dedicated horse → round-robin elite pool
--   3. Generic merc → round-robin common pool
function mercenaries:PickHorseSoul(npcEnt)
    if not npcEnt then return nil end
    local name = npcEnt:GetName() or ''

    -- Custom companion path
    if string.find(name, 'MercenaryCustomCompanion') then
        -- Reverse lookup by soul GUID embedded in entity name:
        -- format: MercenaryCustomCompanion_<soulGuid>_<random>
        for ccID, data in pairs(self.CustomCompanionsData) do
            if data and data.guid and string.find(name, data.guid, 1, true) then
                local dedicated = self.CustomCompanionHorses[ccID]
                if dedicated then return dedicated end
                break
            end
        end
        -- Fallback: elite pool round-robin
        local pool = self.HorseSouls.elite
        if pool and #pool > 0 then
            local idx = self.HorseSoulIndex.elite
            local soul = pool[idx]
            self.HorseSoulIndex.elite = (idx % #pool) + 1
            return soul
        end
    end

    -- Generic merc path: common pool round-robin
    local pool = self.HorseSouls.common
    if not pool or #pool == 0 then return nil end
    local idx = self.HorseSoulIndex.common
    local soul = pool[idx]
    self.HorseSoulIndex.common = (idx % #pool) + 1
    return soul
end

-- Internal: register a spawned horse in the cache and persist the mapping.
function mercenaries:RegisterHorse(npcName, horseEnt, soulGuid, ownerWuid)
    if not npcName or not horseEnt then return end
    soulGuid = soulGuid or self:GetSavedHorseSoul(npcName)
    self.ActiveHorses[npcName] = {
        entRef    = horseEnt,
        soulGuid  = soulGuid,
        ownerWuid = ownerWuid,
    }
    if soulGuid then
        self.SavedHorseSouls = self.SavedHorseSouls or {}
        self.SavedHorseSouls[npcName] = soulGuid
        self:SaveHorseMap()
    end
end

-- Internal: drop a horse from the cache and persist the mapping.
function mercenaries:UnregisterHorse(npcName)
    if not npcName then return end
    if self.ActiveHorses[npcName] then
        self.ActiveHorses[npcName] = nil
        if self.SavedHorseSouls then
            self.SavedHorseSouls[npcName] = nil
        end
        self:SaveHorseMap()
    end
end

-- =======================================================================
-- PUBLIC API — called from mercenary_follow.xml ExecuteLua nodes
-- =======================================================================

-- Spawn a horse for the given NPC entity. Returns the horse entity (or nil on failure).
-- Idempotent: if the merc already has a live horse cached, it is reused.
function mercenaries:SpawnHorseFor(npcEnt)
    if not npcEnt then return nil end
    local npcName = npcEnt:GetName() or ''
    if npcName == '' then return nil end

    local horseName = self:HorseNameForMerc(npcName)
    if not horseName then return nil end

    -- If already spawned and alive, reuse
    local existing = System.GetEntityByName(horseName)
    if existing then
        local soulGuid = self.ActiveHorses[npcName] and self.ActiveHorses[npcName].soulGuid
            or self:GetSavedHorseSoul(npcName)
        local ownerWuid = npcEnt.this and npcEnt.this.id or npcEnt.id
        self:RegisterHorse(npcName, existing, soulGuid, ownerWuid)
        return existing
    end

    local soulGuid = self:PickHorseSoul(npcEnt)
    if not soulGuid then
        System.LogAlways('[MercHorse] No horse soul available for ' .. npcName)
        return nil
    end

    local pos = npcEnt:GetPos()
    if not pos then return nil end

    local horsePos = {
        x = pos.x + (math.random() - 0.5) * 2.0,
        y = pos.y + (math.random() - 0.5) * 2.0,
        z = pos.z,
    }

    local ok, err = pcall(function()
        System.SpawnEntity({
            class = 'Horse',
            name = horseName,
            position = horsePos,
            orientation = { x = 0, y = 0, z = 0 },
            properties = { guidSharedSoulId = soulGuid },
        })
    end)
    if not ok then
        System.LogAlways('[MercHorse] Spawn EXCEPTION for ' .. npcName .. ': ' .. tostring(err))
        return nil
    end

    local horseEnt = System.GetEntityByName(horseName)
    if not horseEnt then
        System.LogAlways('[MercHorse] Spawn returned no entity for ' .. npcName)
        return nil
    end

    local ownerWuid = npcEnt.this and npcEnt.this.id or npcEnt.id
    self:RegisterHorse(npcName, horseEnt, soulGuid, ownerWuid)
    System.LogAlways('[MercHorse] Spawned horse for ' .. npcName .. ' (soul=' .. tostring(soulGuid) .. ')')
    return horseEnt
end

-- Despawn the horse owned by the given NPC entity (if any).
function mercenaries:DespawnHorseFor(npcEnt)
    if not npcEnt then return end
    local npcName = npcEnt:GetName() or ''
    if npcName == '' then return end
    self:DespawnHorseByMercName(npcName)
end

-- Despawn by NPC name directly — useful when the NPC entity is already gone
-- (e.g. cleanup after merc death/despawn).
function mercenaries:DespawnHorseByMercName(npcName)
    if not npcName then return end
    local horseName = self:HorseNameForMerc(npcName)
    if not horseName then return end

    local horseEnt = System.GetEntityByName(horseName)
    if horseEnt then
        local ok, err = pcall(function() System.RemoveEntity(horseEnt.id) end)
        if not ok then
            System.LogAlways('[MercHorse] Despawn EXCEPTION for ' .. npcName .. ': ' .. tostring(err))
        end
    end
    self:UnregisterHorse(npcName)
end

-- Returns the WUID of the horse owned by the given NPC, or nil.
function mercenaries:GetHorseForMerc(npcEnt)
    if not npcEnt then return nil end
    local npcName = npcEnt:GetName() or ''
    local ent = self:ResolveHorseEntityByMercName(npcName)
    if ent and ent.this then return ent.this.id end
    return nil
end

-- True when at least one tracked merc currently owns a live horse.
function mercenaries:IsAnyMercMounted()
    for _, data in pairs(self.ActiveHorses) do
        if data and data.entRef then
            return true
        end
    end
    return false
end

-- =======================================================================
-- PERSISTENCE — piggyback on the SaveString/LoadString BasicEntity system.
-- Format: "npcName=soulGuid|npcName2=soulGuid2|..."
-- =======================================================================

function mercenaries:SaveHorseMap()
    local parts = {}
    self.SavedHorseSouls = self.SavedHorseSouls or self:ParseHorseMap(self:LoadString('MercHorseMap'))

    for npcName, data in pairs(self.ActiveHorses) do
        if data then
            local soulGuid = data.soulGuid or self.SavedHorseSouls[npcName]
            -- Sanitize: skip names with our delimiters to prevent corruption
            if soulGuid and not string.find(npcName, '|') and not string.find(npcName, '=') then
                data.soulGuid = soulGuid
                self.SavedHorseSouls[npcName] = soulGuid
                table.insert(parts, npcName .. '=' .. soulGuid)
            end
        end
    end
    if #parts == 0 then
        -- Encode "empty" as a sentinel because SaveString refuses empty payloads
        self:SaveString('MercHorseMap', '__empty__')
    else
        self:SaveString('MercHorseMap', table.concat(parts, '|'))
    end
end

-- Parse the persisted map and re-register live horses found in the world.
-- Orphan entries (NPC despawned, horse missing) are dropped silently.
function mercenaries:LoadHorseMap()
    local raw = self:LoadString('MercHorseMap')
    if not raw or raw == '__empty__' then
        self.ActiveHorses = {}
        self.SavedHorseSouls = {}
        return
    end

    self.ActiveHorses = {}
    self.SavedHorseSouls = self:ParseHorseMap(raw)

    for npcName, soulGuid in pairs(self.SavedHorseSouls) do
        local horseEnt = self:ResolveHorseEntityByMercName(npcName)
        if horseEnt then
            self.ActiveHorses[npcName] = {
                entRef   = horseEnt,
                soulGuid = soulGuid,
                ownerWuid = nil, -- not persisted; resolved on next BT tick
            }
        end
        -- If horse is missing, skip - BT will respawn naturally on next mount tick.
    end
end

-- Called via Script.SetTimerForFunction on game load, after RebuildMercCache.
function mercenaries.RebuildHorseCacheDelayed()
    mercenaries:LoadHorseMap()
    mercenaries:PruneOrphanHorses()
    System.LogAlways('[MercHorse] Horse cache rebuilt. Active horses: '
        .. tostring(mercenaries:_TableCount(mercenaries.ActiveHorses)))
end

-- Drop horses whose owner NPC is no longer in ActiveMercs (despawned/dead).
function mercenaries:PruneOrphanHorses()
    for npcName, data in pairs(self.ActiveHorses) do
        local owner = self.ActiveMercs[npcName]
        if not owner then
            -- Owner is gone — clean up the dangling horse entity if any
            local horseName = self:HorseNameForMerc(npcName)
            local horseEnt = horseName and System.GetEntityByName(horseName) or nil
            if horseEnt then
                pcall(function() System.RemoveEntity(horseEnt.id) end)
            end
            self.ActiveHorses[npcName] = nil
            if self.SavedHorseSouls then
                self.SavedHorseSouls[npcName] = nil
            end
        end
    end
    self:SaveHorseMap()
end

-- Periodic health check, called from MonitorLoop. Removes dead-horse entries
-- so the BT can respawn them next time the player mounts.
function mercenaries:PruneDeadHorses()
    local changed = false
    for npcName, data in pairs(self.ActiveHorses) do
        if data then
            local ent = self:ResolveHorseEntityByMercName(npcName)
            local alive = false
            if ent then
                pcall(function()
                    if ent.soul then
                        local hp = ent.soul:GetState('health')
                        alive = (hp ~= nil and hp > 0)
                    end
                end)
            end
            if not alive then
                self.ActiveHorses[npcName] = nil
                if self.SavedHorseSouls then
                    self.SavedHorseSouls[npcName] = nil
                end
                changed = true
            end
        end
    end
    if changed then self:SaveHorseMap() end
end

-- Force-cleanup all horses (used by dismiss / fast-travel paths).
function mercenaries:DespawnAllHorses()
    for npcName, _ in pairs(self.ActiveHorses) do
        local horseName = self:HorseNameForMerc(npcName)
        local horseEnt = horseName and System.GetEntityByName(horseName) or nil
        if horseEnt then
            pcall(function() System.RemoveEntity(horseEnt.id) end)
        end
    end
    self.ActiveHorses = {}
    self.SavedHorseSouls = {}
    self:SaveHorseMap()
end

function mercenaries:TeleportHorseForMercName(npcName, targetPos)
    if not npcName or not targetPos then return nil end

    local horseEnt = self:ResolveHorseEntityByMercName(npcName)
    if not horseEnt then return nil end

    local horsePos = {
        x = targetPos.x + 1.5,
        y = targetPos.y + 1.5,
        z = targetPos.z,
    }
    local ok, err = pcall(function() horseEnt:SetPos(horsePos) end)
    if not ok then
        System.LogAlways('[MercHorse] Teleport EXCEPTION for ' .. tostring(npcName) .. ': ' .. tostring(err))
        return nil
    end

    return horseEnt
end
