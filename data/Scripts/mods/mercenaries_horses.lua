-- =======================================================================
-- HORSES MODULE
-- Centralized lifecycle management for mercenary mounts.
-- Called from the mercenary_follow Behavior Tree on stance change.
--
-- Cache:    mercenaries.ActiveHorses[npcEntityName] = { entRef, soulGuid, ownerWuid }
-- Pools:    mercenaries.HorseSouls.common / .elite (defined in mercenaries.lua)
-- Naming:   horse entity name = "MercenaryHorse_" .. npcEntityName
-- Persist:  SaveString tag "MercHorseMapV2" — "npcName=soulGuid|npcName2=soulGuid2"
-- =======================================================================

local MERC_HORSE_MAP_TAG = 'MercHorseMapV2'
local MERC_HORSE_MAP_OLD_TAG = 'MercHorseMap'

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
        self.SavedHorseSouls = self:ParseHorseMap(self:LoadString(MERC_HORSE_MAP_TAG))
        if self:_TableCount(self.SavedHorseSouls) == 0 then
            self.SavedHorseSouls = self:ParseHorseMap(self:LoadString(MERC_HORSE_MAP_OLD_TAG))
            if self:_TableCount(self.SavedHorseSouls) > 0 then
                self:SaveHorseMap()
            end
        end
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

function mercenaries:GetHorseEntitySoulGuid(horseEnt)
    if not horseEnt or not horseEnt.soul then return nil end
    local ok, soulGuid = pcall(function()
        if horseEnt.soul.GetSharedSoulId then
            return horseEnt.soul:GetSharedSoulId()
        end
        return nil
    end)
    if ok and soulGuid then return tostring(soulGuid) end
    return nil
end

function mercenaries:IsHorseSoulAssigned(soulGuid, exceptNpcName)
    if not soulGuid then return false end
    self.SavedHorseSouls = self.SavedHorseSouls or {}

    for npcName, savedSoulGuid in pairs(self.SavedHorseSouls) do
        if npcName ~= exceptNpcName and savedSoulGuid == soulGuid then
            return true
        end
    end

    for npcName, data in pairs(self.ActiveHorses) do
        if npcName ~= exceptNpcName and data and data.soulGuid == soulGuid then
            return true
        end
    end

    return false
end

function mercenaries:PickFirstFreeHorseSoul(pool, exceptNpcName)
    if not pool or #pool == 0 then return nil end

    for _, soulGuid in ipairs(pool) do
        if not self:IsHorseSoulAssigned(soulGuid, exceptNpcName) then
            return soulGuid
        end
    end

    return pool[1]
end

function mercenaries:GetCustomCompanionHorseSoul(npcName)
    if not npcName or not string.find(npcName, 'MercenaryCustomCompanion') then return nil end

    -- Reverse lookup by soul GUID embedded in entity name:
    -- format: MercenaryCustomCompanion_<soulGuid>_<random>
    for ccID, data in pairs(self.CustomCompanionsData) do
        if data and data.guid and string.find(npcName, data.guid, 1, true) then
            return self.CustomCompanionHorses[ccID]
        end
    end

    return nil
end

-- Internal: pick a stable, unassigned horse soul for a given NPC entity.
function mercenaries:PickHorseSoul(npcEnt)
    if not npcEnt then return nil end
    local npcName = npcEnt:GetName() or ''
    local saved = self:GetSavedHorseSoul(npcName)
    if saved then return saved end

    local dedicated = self:GetCustomCompanionHorseSoul(npcName)
    if dedicated and not self:IsHorseSoulAssigned(dedicated, npcName) then
        return dedicated
    end

    if string.find(npcName, 'MercenaryCustomCompanion') then
        return self:PickFirstFreeHorseSoul(self.HorseSouls.elite, npcName)
    end

    return self:PickFirstFreeHorseSoul(self.HorseSouls.common, npcName)
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

-- Internal: drop a live horse from cache. Saved ownership is kept unless
-- clearSaved is explicitly true (dismiss/death cleanup).
function mercenaries:UnregisterHorse(npcName, clearSaved)
    if not npcName then return end
    if self.ActiveHorses[npcName] then
        self.ActiveHorses[npcName] = nil
    end
    if clearSaved then
        if self.SavedHorseSouls then
            self.SavedHorseSouls[npcName] = nil
        end
    end
    self:SaveHorseMap()
end

-- =======================================================================
-- PUBLIC API — called from mercenary_follow.xml ExecuteLua nodes
-- =======================================================================

function mercenaries:SpawnHorseEntityFor(npcEnt, soulGuid)
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
            or self:GetHorseEntitySoulGuid(existing)
        local ownerWuid = npcEnt.this and npcEnt.this.id or npcEnt.id
        self:RegisterHorse(npcName, existing, soulGuid, ownerWuid)
        return existing
    end

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

-- Ensure a merc has its own persistent horse. If the live entity disappeared,
-- respawn the same saved horse soul instead of assigning a different one.
function mercenaries:EnsureHorseForMerc(npcEnt)
    if not npcEnt then return nil end
    local npcName = npcEnt:GetName() or ''
    if npcName == '' then return nil end

    local existing = self:ResolveHorseEntityByMercName(npcName)
    if existing then
        local ownerWuid = npcEnt.this and npcEnt.this.id or npcEnt.id
        local soulGuid = self:GetSavedHorseSoul(npcName)
            or self:GetHorseEntitySoulGuid(existing)
            or self:PickHorseSoul(npcEnt)
        self:RegisterHorse(npcName, existing, soulGuid, ownerWuid)
        return existing
    end

    local soulGuid = self:GetSavedHorseSoul(npcName) or self:PickHorseSoul(npcEnt)
    if not soulGuid then return nil end

    return self:SpawnHorseEntityFor(npcEnt, soulGuid)
end

-- Compatibility wrapper for older BT/Lua call sites.
function mercenaries:SpawnHorseFor(npcEnt)
    return self:EnsureHorseForMerc(npcEnt)
end

-- Remove a live horse entity but keep the saved merc->horse ownership.
function mercenaries:ReleaseHorseFor(npcEnt)
    if not npcEnt then return end
    local npcName = npcEnt:GetName() or ''
    if npcName == '' then return end
    self:ReleaseHorseEntityByMercName(npcName)
end

function mercenaries:ReleaseHorseEntityByMercName(npcName)
    if not npcName then return end
    local horseName = self:HorseNameForMerc(npcName)
    if not horseName then return end

    local horseEnt = System.GetEntityByName(horseName)
    if horseEnt then
        local ok, err = pcall(function() System.RemoveEntity(horseEnt.id) end)
        if not ok then
            System.LogAlways('[MercHorse] Release EXCEPTION for ' .. npcName .. ': ' .. tostring(err))
        end
    end
    self:UnregisterHorse(npcName, false)
end

-- Despawn the horse owned by the given NPC entity (if any), but preserve the
-- saved assignment. Destructive cleanup should call DespawnHorseByMercName.
function mercenaries:DespawnHorseFor(npcEnt)
    self:ReleaseHorseFor(npcEnt)
end

-- Despawn by NPC name directly — useful when the NPC entity is already gone
-- (e.g. cleanup after merc death/despawn). This forgets the assignment.
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
    self:UnregisterHorse(npcName, true)
end

-- Returns the WUID of the horse owned by the given NPC, or nil.
function mercenaries:GetHorseForMerc(npcEnt)
    if not npcEnt then return nil end
    local npcName = npcEnt:GetName() or ''
    local ent = self:EnsureHorseForMerc(npcEnt)
    if ent and ent.this then return ent.this.id end
    return nil
end

-- True when at least one tracked merc currently owns a live horse.
function mercenaries:IsAnyMercMounted()
    local playerMounted = false
    pcall(function()
        if player and player.human then
            local horseWuid = player.human:GetHorse()
            if horseWuid and tostring(horseWuid) ~= "" and tostring(horseWuid) ~= "0" then
                playerMounted = true
            end
        end
    end)
    if not playerMounted then return false end

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
    self.SavedHorseSouls = self.SavedHorseSouls or {}

    for npcName, data in pairs(self.ActiveHorses) do
        if data and data.soulGuid then
            self.SavedHorseSouls[npcName] = data.soulGuid
        end
    end

    for npcName, soulGuid in pairs(self.SavedHorseSouls) do
        -- Sanitize: skip names with our delimiters to prevent corruption
        if soulGuid and not string.find(npcName, '|') and not string.find(npcName, '=') then
            table.insert(parts, npcName .. '=' .. soulGuid)
        end
    end
    if #parts == 0 then
        -- Encode "empty" as a sentinel because SaveString refuses empty payloads
        self:SaveString(MERC_HORSE_MAP_TAG, '__empty__')
    else
        self:SaveString(MERC_HORSE_MAP_TAG, table.concat(parts, '|'))
    end
end

-- Parse the persisted map and re-register live horses found in the world.
-- Orphan entries (NPC despawned, horse missing) are dropped silently.
function mercenaries:LoadHorseMap()
    local raw = self:LoadString(MERC_HORSE_MAP_TAG)
    if not raw or raw == '__empty__' then
        raw = self:LoadString(MERC_HORSE_MAP_OLD_TAG)
        if raw and raw ~= '__empty__' then
            System.LogAlways('[MercHorse] Migrating legacy horse map to V2.')
        end
    end

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
        -- If horse is missing, keep the saved soul - BT will respawn it.
    end
    self:SaveHorseMap()
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
    local orphanNames = {}
    for npcName, data in pairs(self.ActiveHorses) do
        local owner = self.ActiveMercs[npcName]
        if not owner then
            table.insert(orphanNames, npcName)
        end
    end
    for _, npcName in ipairs(orphanNames) do
        self:DespawnHorseByMercName(npcName)
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
                changed = true
            end
        end
    end
    if changed then self:SaveHorseMap() end
end

-- Release live horse entities but keep persistent assignments.
function mercenaries:ReleaseAllHorseEntities()
    local names = {}
    local seen = {}
    for npcName, _ in pairs(self.ActiveHorses) do
        table.insert(names, npcName)
        seen[npcName] = true
    end
    if self.SavedHorseSouls then
        for npcName, _ in pairs(self.SavedHorseSouls) do
            if not seen[npcName] then
                table.insert(names, npcName)
            end
        end
    end

    for _, npcName in ipairs(names) do
        self:ReleaseHorseEntityByMercName(npcName)
    end
    self.ActiveHorses = {}
    self:SaveHorseMap()
end

-- Force-cleanup all horses and forget assignments (used by dismiss paths).
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

function mercenaries:TeleportHorseNearMercIfFar(npcEnt, threshold)
    if not npcEnt then return nil end
    threshold = threshold or 20.0

    local npcName = npcEnt:GetName() or ''
    if npcName == '' then return nil end

    local horseEnt = self:EnsureHorseForMerc(npcEnt)
    if not horseEnt then return nil end

    local npcPos = npcEnt:GetPos()
    local horsePos = horseEnt:GetPos()
    if not npcPos or not horsePos then return horseEnt end

    local dx = npcPos.x - horsePos.x
    local dy = npcPos.y - horsePos.y
    local dz = npcPos.z - horsePos.z
    local distance = math.sqrt(dx*dx + dy*dy + dz*dz)
    if distance > threshold then
        return self:TeleportHorseForMercName(npcName, npcPos)
    end

    return horseEnt
end
