-- SHOCKS Drug Selling - server
-- QBCore/Qbox via qb-core compatibility, ox_inventory preferred.
-- All sales are decided and validated server-side. Client outcome claims are ignored.

local QBCore = exports['qb-core']:GetCoreObject()

local processing = {}
local lastRequestAt = {}
local zoneCooldowns = {}
local zoneSaleWindows = {}
local playerSales = {}
local reputationCache = {}

local REPUTATION_TABLE = 'shocks_drugsell_reputation'
local databaseReady = false
local databaseInitDone = false
local DEFAULT_LIMIT_WINDOW_MS = 60 * 60 * 1000

local function DebugPrint(message)
    if Config.Setup and Config.Setup.debug then
        print(('[SHOCKS Drug Selling] %s'):format(tostring(message)))
    end
end

local function InitializeDatabase()
    if not MySQL or not MySQL.query or not MySQL.query.await then
        databaseInitDone = true
        print('[SHOCKS Drug Selling] ERROR: oxmysql is unavailable; SQL reputation persistence is disabled.')
        return false
    end

    local ok, err = pcall(function()
        MySQL.query.await(([=[
            CREATE TABLE IF NOT EXISTS `%s` (
                `citizenid` VARCHAR(64) NOT NULL,
                `xp` INT UNSIGNED NOT NULL DEFAULT 0,
                `level` TINYINT UNSIGNED NOT NULL DEFAULT 1,
                `sales` INT UNSIGNED NOT NULL DEFAULT 0,
                `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`citizenid`),
                KEY `idx_drugsell_level` (`level`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]=]):format(REPUTATION_TABLE))
    end)

    databaseInitDone = true
    if ok then
        databaseReady = true
        print(('[SHOCKS Drug Selling] SQL table `%s` is ready. Player XP, level and sales will persist automatically.'):format(REPUTATION_TABLE))
        return true
    end

    print(('[SHOCKS Drug Selling] ERROR: could not auto-create `%s`: %s'):format(REPUTATION_TABLE, tostring(err)))
    print('[SHOCKS Drug Selling] Check oxmysql, database permissions and server.cfg startup order.')
    return false
end

CreateThread(function()
    -- fxmanifest loads @oxmysql/lib/MySQL.lua before this server script.
    -- The short wait also covers startup races during a full server boot.
    local deadline = GetGameTimer() + 15000
    while (not MySQL or not MySQL.query or not MySQL.query.await) and GetGameTimer() < deadline do
        Wait(100)
    end
    InitializeDatabase()
end)

local function WaitForDatabaseReady(timeoutMs)
    local deadline = GetGameTimer() + (tonumber(timeoutMs) or 10000)
    while not databaseReady and not databaseInitDone and GetGameTimer() < deadline do
        Wait(25)
    end
    return databaseReady
end

local function Notify(src, message, kind)
    kind = kind or 'inform'
    if Config.Setup and Config.Setup.notify == 'ox_lib' and GetResourceState('ox_lib') == 'started' then
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Drug Selling',
            description = message,
            type = kind,
        })
        return
    end

    local qbKind = kind == 'inform' and 'primary' or kind
    TriggerClientEvent('QBCore:Notify', src, message, qbKind)
end

local function SendSaleResult(src, outcome, message, kind, extra)
    Notify(src, message, kind)
    TriggerClientEvent('shocks-drugsell:client:saleResult', src, {
        outcome = outcome,
        message = message,
        type = kind or 'inform',
        extra = extra,
    })
end

local function GetPlayer(src)
    return QBCore.Functions.GetPlayer(src)
end

local function GetPlayerJobName(Player)
    local job = Player and Player.PlayerData and Player.PlayerData.job
    return job and job.name and string.lower(job.name) or nil
end

local function IsBlacklistedJob(Player)
    local jobName = GetPlayerJobName(Player)
    if not jobName then return false end

    local blacklist = {}
    for _, name in ipairs((Config.Setup and Config.Setup.blacklistJobs) or {}) do
        blacklist[string.lower(tostring(name))] = true
    end
    for _, name in ipairs(Config.BlacklistJobs or {}) do
        blacklist[string.lower(tostring(name))] = true
    end

    return blacklist[jobName] == true
end

local function GetSellingZone(coords)
    local selectedKey, selectedZone, selectedDistance
    for key, zone in pairs(Config.Zones or {}) do
        if zone and zone.coords and tonumber(zone.size) then
            local distance = #(coords - zone.coords)
            if distance <= tonumber(zone.size) and (not selectedDistance or distance < selectedDistance) then
                selectedKey, selectedZone, selectedDistance = key, zone, distance
            end
        end
    end
    return selectedKey, selectedZone
end

-- Server builds differ in how game time is exposed. Prefer a provider explicitly
-- supplied in config or shared state; if unavailable, client-side daylight gating
-- remains active and server validation continues for all other zone constraints.
local function GetServerGameHour()
    local configured = tonumber(Config.ServerGameHour)
    if configured then return configured end

    if GlobalState then
        local sharedHour = tonumber(GlobalState.gameHour or GlobalState.weatherHour or GlobalState.clockHour)
        if sharedHour then return sharedHour end
    end

    if type(GetClockHours) == 'function' then
        local ok, hour = pcall(GetClockHours)
        if ok and tonumber(hour) then return tonumber(hour) end
    end

    return nil
end

local function IsZoneOpen(zone)
    if not zone or zone.daytime == nil then return true end

    local hour = GetServerGameHour()
    if hour == nil then
        return true
    end

    local startHour = tonumber(Config.DaytimeStart) or 6
    local endHour = tonumber(Config.DaytimeEnd) or 20
    local isDay

    if startHour == endHour then
        isDay = true
    elseif startHour < endHour then
        isDay = hour >= startHour and hour < endHour
    else
        isDay = hour >= startHour or hour < endHour
    end

    if zone.daytime then return isDay end
    return not isDay
end

local function GetOnlinePoliceCount()
    local policeConfig = Config.Police or {}
    local configuredJobs = policeConfig.jobs or { 'police' }
    local allowedJobs = {}
    for _, jobName in ipairs(configuredJobs) do
        allowedJobs[string.lower(tostring(jobName))] = true
    end

    local count = 0
    local players = QBCore.Functions.GetQBPlayers and QBCore.Functions.GetQBPlayers() or nil
    if players then
        for _, Player in pairs(players) do
            local job = Player and Player.PlayerData and Player.PlayerData.job
            if job and job.name and allowedJobs[string.lower(job.name)] then
                if not policeConfig.onDutyOnly or job.onduty == true then
                    count = count + 1
                end
            end
        end
    else
        for _, playerId in ipairs(QBCore.Functions.GetPlayers()) do
            local Player = GetPlayer(playerId)
            local job = Player and Player.PlayerData and Player.PlayerData.job
            if job and job.name and allowedJobs[string.lower(job.name)] then
                if not policeConfig.onDutyOnly or job.onduty == true then
                    count = count + 1
                end
            end
        end
    end

    return count
end

local function GetMaxReputationLevel()
    local levels = (Config.Reputation and Config.Reputation.levels) or {}
    local maxLevel = 1
    for level in pairs(levels) do
        local numericLevel = tonumber(level)
        if numericLevel and numericLevel > maxLevel then maxLevel = numericLevel end
    end
    return maxLevel
end

local function GetLevelForXP(xp)
    local perLevel = math.max(1, tonumber(Config.Reputation and Config.Reputation.levelUp) or 25000)
    return math.min(GetMaxReputationLevel(), math.floor(math.max(0, tonumber(xp) or 0) / perLevel) + 1)
end

local function SyncRepMetadata(Player, state)
    if Player and Player.Functions and Player.Functions.SetMetaData then
        Player.Functions.SetMetaData('drugSellingRep', {
            xp = math.max(0, math.floor(tonumber(state.xp) or 0)),
            level = GetLevelForXP(state.xp),
            sales = math.max(0, math.floor(tonumber(state.sales) or 0)),
        })
    end
end

local function PersistReputationRow(state, warnOnFailure)
    if not databaseReady or not state or not state.citizenid then return false end

    local level = GetLevelForXP(state.xp)
    local ok, err = pcall(function()
        MySQL.query.await(([=[
            INSERT INTO `%s` (`citizenid`, `xp`, `level`, `sales`)
            VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                `xp` = VALUES(`xp`),
                `level` = VALUES(`level`),
                `sales` = VALUES(`sales`),
                `updated_at` = CURRENT_TIMESTAMP
        ]=]):format(REPUTATION_TABLE), {
            state.citizenid,
            math.max(0, math.floor(tonumber(state.xp) or 0)),
            level,
            math.max(0, math.floor(tonumber(state.sales) or 0)),
        })
    end)

    if not ok and warnOnFailure then
        print(('[SHOCKS Drug Selling] WARNING: failed to save reputation for %s: %s'):format(tostring(state.citizenid), tostring(err)))
    end

    return ok
end

-- If a character was served while the SQL connection was still coming up,
-- flush its cached reputation as soon as the schema initialization finishes.
CreateThread(function()
    while not databaseInitDone do Wait(250) end
    if not databaseReady then return end

    for src, state in pairs(reputationCache) do
        local Player = GetPlayer(src)
        if Player and Player.PlayerData and Player.PlayerData.citizenid == state.citizenid then
            PersistReputationRow(state, true)
        end
    end
end)

local function LoadRepState(src, Player)
    local playerData = Player and Player.PlayerData
    local citizenid = playerData and playerData.citizenid
    if not citizenid or citizenid == '' then
        return { citizenid = nil, xp = 0, sales = 0, level = 1 }
    end

    local cached = reputationCache[src]
    if cached and cached.citizenid == citizenid then
        return cached
    end

    local metadata = playerData.metadata or {}
    local metadataRep = metadata.drugSellingRep
    local state = {
        citizenid = citizenid,
        xp = math.max(0, math.floor(tonumber(type(metadataRep) == 'table' and metadataRep.xp) or 0)),
        sales = math.max(0, math.floor(tonumber(type(metadataRep) == 'table' and metadataRep.sales) or 0)),
    }

    if WaitForDatabaseReady(10000) then
        local queryOk, row = pcall(function()
            return MySQL.single.await(
                ('SELECT `xp`, `level`, `sales` FROM `%s` WHERE `citizenid` = ? LIMIT 1'):format(REPUTATION_TABLE),
                { citizenid }
            )
        end)

        if queryOk and row then
            -- SQL is authoritative; QBCore metadata remains a fallback/mirror.
            state.xp = math.max(0, math.floor(tonumber(row.xp) or 0))
            state.sales = math.max(0, math.floor(tonumber(row.sales) or 0))
        elseif not queryOk then
            print(('[SHOCKS Drug Selling] WARNING: could not load saved reputation for %s: %s'):format(tostring(citizenid), tostring(row)))
        end
    end

    state.level = GetLevelForXP(state.xp)
    reputationCache[src] = state
    SyncRepMetadata(Player, state)

    -- If there is no SQL row yet, create it from existing QBCore metadata.
    -- This also keeps the stored level aligned with the current level config.
    PersistReputationRow(state, true)
    return state
end

local function GetReputation(src, Player)
    local state = LoadRepState(src, Player)
    state.level = GetLevelForXP(state.xp)
    local levels = (Config.Reputation and Config.Reputation.levels) or {}
    state.levelData = levels[state.level] or levels[tostring(state.level)] or {}
    return state
end

local function SaveReputation(src, Player, rep)
    local playerData = Player and Player.PlayerData
    local citizenid = playerData and playerData.citizenid
    local state = {
        citizenid = citizenid,
        xp = math.max(0, math.floor(tonumber(rep.xp) or 0)),
        sales = math.max(0, math.floor(tonumber(rep.sales) or 0)),
    }
    state.level = GetLevelForXP(state.xp)
    reputationCache[src] = state
    SyncRepMetadata(Player, state)
    PersistReputationRow(state, true)
    return state
end

local function AwardReputation(Player, zone, src)
    local rep = GetReputation(src, Player)
    local xpConfig = zone and zone.xp or { min = 5, max = 15 }
    local minXP = math.max(0, math.floor(tonumber(xpConfig.min) or 5))
    local maxXP = math.max(minXP, math.floor(tonumber(xpConfig.max) or minXP))
    local xp = math.random(minXP, maxXP)
    local previousLevel = rep.level

    rep.xp = rep.xp + xp
    rep.sales = rep.sales + 1
    SaveReputation(src, Player, rep)

    local updated = GetReputation(src, Player)
    if updated.level > previousLevel then
        local levelData = updated.levelData or {}
        Notify(src, ('Drug-dealing reputation increased to level %s%s.'):format(
            updated.level,
            levelData.label and (' - ' .. levelData.label) or ''
        ), 'success')
    end

    return updated, xp
end

local function GetInventoryCount(src, Player, itemName)
    if GetResourceState('ox_inventory') == 'started' then
        local ok, count = pcall(function()
            return exports.ox_inventory:Search(src, 'count', itemName)
        end)
        if ok and tonumber(count) then return tonumber(count) end
    end

    if Player and Player.Functions and Player.Functions.GetItemByName then
        local item = Player.Functions.GetItemByName(itemName)
        if item then return tonumber(item.amount or item.count) or 0 end
    end

    local count = 0
    for _, item in pairs((Player and Player.PlayerData and Player.PlayerData.items) or {}) do
        if item and item.name == itemName then
            count = count + (tonumber(item.amount or item.count) or 0)
        end
    end
    return count
end

local function IsMetadataPriceEnabled(drugName, zone)
    local metadataConfig = Config.Metadata or {}
    local drugConfig = Config.Drugs and Config.Drugs[drugName]
    if not metadataConfig.enabled or not (zone and zone.metadataPricing ~= false) then return false end
    if metadataConfig.items and metadataConfig.items[drugName] ~= nil then
        return metadataConfig.items[drugName] == true
    end
    return drugConfig and drugConfig.useMetadataPrice == true or false
end

local function CalculateMetadataUnitPrice(drugName, slotMetadata, drugConfig)
    local metadataConfig = Config.Metadata or {}
    local key = metadataConfig.key or 'purity'
    local purity = type(slotMetadata) == 'table' and tonumber(slotMetadata[key]) or nil

    if purity == nil then
        return math.random(tonumber(drugConfig.minPrice) or 1, math.max(tonumber(drugConfig.minPrice) or 1, tonumber(drugConfig.maxPrice) or 1))
    end

    purity = math.max(0, purity)
    local price = purity * (tonumber(metadataConfig.pricePerPurity) or 2.5)
    if purity >= 100 then
        price = price + (tonumber(metadataConfig.perfectBonus) or 0)
    end
    return math.max(1, math.floor(price + 0.5))
end

local function MakeRemovalPlan(src, Player, drugName, amount, zone)
    local drugConfig = Config.Drugs[drugName]
    local metadataPricing = IsMetadataPriceEnabled(drugName, zone)
    local remaining = amount
    local plan = {}
    local totalBasePrice = 0

    if GetResourceState('ox_inventory') == 'started' then
        local ok, slots = pcall(function()
            return exports.ox_inventory:GetSlotsWithItem(src, drugName)
        end)

        if ok and type(slots) == 'table' and #slots > 0 then
            for _, slotData in ipairs(slots) do
                if remaining <= 0 then break end
                local slotCount = tonumber(slotData.count) or 0
                local take = math.min(remaining, slotCount)
                if take > 0 then
                    local unitPrice
                    if metadataPricing then
                        unitPrice = CalculateMetadataUnitPrice(drugName, slotData.metadata, drugConfig)
                    else
                        unitPrice = math.random(
                            tonumber(drugConfig.minPrice) or 1,
                            math.max(tonumber(drugConfig.minPrice) or 1, tonumber(drugConfig.maxPrice) or 1)
                        )
                    end

                    plan[#plan + 1] = {
                        item = drugName,
                        count = take,
                        slot = slotData.slot,
                        metadata = slotData.metadata,
                    }
                    totalBasePrice = totalBasePrice + (unitPrice * take)
                    remaining = remaining - take
                end
            end

            if remaining > 0 then return nil, 0, 'not_enough_items' end
            return plan, totalBasePrice
        elseif amount > 0 then
            -- If slot enumeration is unavailable, generic removal remains supported.
            local unitPrice
            if metadataPricing then
                unitPrice = CalculateMetadataUnitPrice(drugName, nil, drugConfig)
            else
                unitPrice = math.random(
                    tonumber(drugConfig.minPrice) or 1,
                    math.max(tonumber(drugConfig.minPrice) or 1, tonumber(drugConfig.maxPrice) or 1)
                )
            end
            return { { item = drugName, count = amount } }, unitPrice * amount
        end
    end

    local minPrice = math.max(1, math.floor(tonumber(drugConfig.minPrice) or 1))
    local maxPrice = math.max(minPrice, math.floor(tonumber(drugConfig.maxPrice) or minPrice))
    local unitPrice = math.random(minPrice, maxPrice)
    return { { item = drugName, count = amount } }, unitPrice * amount
end

local function AddItemBack(src, Player, itemName, count, slotMetadata)
    if count <= 0 then return true end

    if GetResourceState('ox_inventory') == 'started' then
        local ok, result = pcall(function()
            return exports.ox_inventory:AddItem(src, itemName, count, slotMetadata)
        end)
        if ok and result == true then return true end
    end

    if Player and Player.Functions and Player.Functions.AddItem then
        local ok, result = pcall(function()
            return Player.Functions.AddItem(itemName, count)
        end)
        return ok and result == true
    end

    return false
end

local function RemovePlan(src, Player, plan)
    local removed = {}

    for _, entry in ipairs(plan) do
        local ok, result
        if GetResourceState('ox_inventory') == 'started' then
            ok, result = pcall(function()
                return exports.ox_inventory:RemoveItem(
                    src,
                    entry.item,
                    entry.count,
                    entry.metadata,
                    entry.slot,
                    false
                )
            end)
        elseif Player and Player.Functions and Player.Functions.RemoveItem then
            ok, result = pcall(function()
                return Player.Functions.RemoveItem(entry.item, entry.count)
            end)
        end

        if not ok or result == false or result == nil then
            -- Roll back earlier removals if a multi-slot removal partially failed.
            for _, old in ipairs(removed) do
                AddItemBack(src, Player, old.item, old.count, old.metadata)
            end
            return false
        end

        removed[#removed + 1] = entry
    end

    return true, removed
end

local function RestorePlan(src, Player, removed)
    for _, entry in ipairs(removed or {}) do
        AddItemBack(src, Player, entry.item, entry.count, entry.metadata)
    end
end

local function PayPlayer(Player, src, account, amount)
    account = tostring(account or 'cash'):lower()
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return false end

    local playerData = Player and Player.PlayerData
    local money = playerData and playerData.money or {}

    -- Standard QBCore accounts, plus any custom account registered in PlayerData.money.
    if Player and Player.Functions and Player.Functions.AddMoney and money[account] ~= nil then
        local ok, result = pcall(function()
            return Player.Functions.AddMoney(account, amount, 'drug-selling')
        end)
        if ok and result == true then return true end
    end

    -- black_money is commonly configured as an inventory item rather than a QBCore account.
    if GetResourceState('ox_inventory') == 'started' then
        local ok, result = pcall(function()
            return exports.ox_inventory:AddItem(src, account, amount)
        end)
        if ok and result == true then return true end
    end

    if Player and Player.Functions and Player.Functions.AddItem then
        local ok, result = pcall(function()
            return Player.Functions.AddItem(account, amount)
        end)
        if ok and result == true then return true end
    end

    return false
end

local function GetZoneSaleWindow(src, zoneKey)
    zoneSaleWindows[src] = zoneSaleWindows[src] or {}
    local now = GetGameTimer()
    local window = zoneSaleWindows[src][zoneKey]

    if not window or now >= window.resetAt then
        window = {
            count = 0,
            resetAt = now + (tonumber(Config.ZoneLimitWindowMinutes) or 60) * 60 * 1000,
        }
        zoneSaleWindows[src][zoneKey] = window
    end

    return window
end

local function CheckZoneRestrictions(src, zoneKey, zone)
    if not zone then return false, 'This is not a configured drug-selling area.' end
    if not IsZoneOpen(zone) then
        return false, 'Drug selling is not available at this time in this area.'
    end

    local policeRequired = math.max(0, math.floor(tonumber(zone.policeRequired) or 0))
    local policeCount = GetOnlinePoliceCount()
    if policeCount < policeRequired then
        return false, ('You need at least %s police on duty to sell here.'):format(policeRequired)
    end

    local cooldown = math.max(0, tonumber(zone.cooldown) or 0)
    if cooldown > 0 then
        zoneCooldowns[src] = zoneCooldowns[src] or {}
        local nextSale = zoneCooldowns[src][zoneKey] or 0
        local now = GetGameTimer()
        if now < nextSale then
            local seconds = math.ceil((nextSale - now) / 1000)
            return false, ('Wait %s seconds before selling in this area again.'):format(seconds)
        end
    end

    local limit = math.max(0, math.floor(tonumber(zone.limit) or 0))
    if limit > 0 then
        local window = GetZoneSaleWindow(src, zoneKey)
        if window.count >= limit then
            return false, 'You have reached the selling limit for this area. Try another location later.'
        end
    end

    return true, nil, policeCount
end

local function TryDispatch(src, zone, title, message, sprite, colour)
    if not (Config.DispatchTriggerDirect == true) then
        DebugPrint('Direct core_dispatch integration is disabled; no fallback dispatch adapter is configured.')
        return false
    end

    if GetResourceState('core_dispatch') ~= 'started' then
        DebugPrint('core_dispatch is not started; dispatch alert was skipped.')
        return false
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local coords = GetEntityCoords(ped)
    local callerInfo = zone and zone.anonymousCalls and 'Anonymous caller reported suspicious drug activity.' or message

    local ok, err = pcall(function()
        TriggerEvent('core_dispatch:addCall',
            '10-20',
            title or (Config.DispatchAlert and Config.DispatchAlert.title) or 'Suspicious Activity',
            {
                { icon = 'fa-cannabis', info = callerInfo or 'Suspicious drug activity reported.' }
            },
            { coords.x, coords.y, coords.z },
            'police',
            5000,
            tonumber(sprite) or 51,
            tonumber(colour) or 5
        )
    end)

    if not ok then
        DebugPrint(('Dispatch trigger failed: %s'):format(tostring(err)))
    end
    return ok
end

local function RollDispatchChance(src, zone, chance, title, message, sprite, colour)
    chance = math.max(0, math.min(100, tonumber(chance) or 0))
    local configuredChance = Config.DispatchAlert and tonumber(Config.DispatchAlert.alertChance)
    if configuredChance ~= nil then
        chance = chance * math.max(0, math.min(100, configuredChance)) / 100
    end

    if math.random(1, 100) <= chance then
        TryDispatch(src, zone, title, message, sprite, colour)
        return true
    end
    return false
end

local function GetGangMDTSettings()
    local settings = Config.GangMDT or {}
    return {
        enabled = settings.enabled ~= false,
        resource = tostring(settings.resource or 'SHOCKS-GangMDT'),
        activity = tostring(settings.activity or 'drug_sale'),
    }
end

local function ApplyTurfActivity(src)
    local settings = GetGangMDTSettings()
    if not settings.enabled then
        DebugPrint('SHOCKS Gang MDT integration is disabled in Config.GangMDT.')
        return
    end

    local resourceName = settings.resource
    if GetResourceState(resourceName) ~= 'started' then
        DebugPrint(('Gang MDT resource %s is not started; this sale will not award turf activity.'):format(resourceName))
        return
    end

    -- Call the supported V3 export exactly once. It performs its own turf,
    -- gang and peaceful-turf checks, applies configured influence and awards
    -- activity XP through Gang MDT. Do not also call AddTurfInfluenceByActivity
    -- or this drug sale would add influence twice.
    CreateThread(function()
        if not GetPlayer(src) then return end

        local hasTurfExport, turfId = pcall(function()
            return exports[resourceName]:GetPlayerCurrentTurf(src)
        end)

        if hasTurfExport and not turfId then
            DebugPrint(('Player %s is not inside a configured Gang MDT turf; no turf activity was applied.'):format(src))
            return
        end

        local callOk, activityResult, activityReason = pcall(function()
            return exports[resourceName]:HandleTurfActivity(src, settings.activity)
        end)

        if not callOk then
            print(('[SHOCKS Drug Selling] Gang MDT export error (%s:%s): %s'):format(
                resourceName, settings.activity, tostring(activityResult)
            ))
            return
        end

        if activityResult == true then
            DebugPrint(('Gang MDT activity "%s" returned success.'):format(settings.activity))
            return
        end

        local reason = tostring(activityReason or activityResult or 'unknown_result')
        if reason == 'peaceful_turf' then
            DebugPrint('Gang MDT skipped drug-sale influence because the turf is peaceful.')
        elseif reason == 'no_gang' then
            DebugPrint('Gang MDT skipped drug-sale influence because the player is not in a gang.')
        elseif reason == 'not_in_turf' or reason == 'no_turf' then
            DebugPrint('Player is not inside a configured Gang MDT turf; no turf activity was applied.')
        elseif activityResult == false and activityReason == nil and hasTurfExport and turfId then
            -- Gang MDT V3.4.0 can return false/nil after applying influence to
            -- an unowned turf because no owner gang is available for XP.
            local ownerOk, owner = pcall(function()
                return exports[resourceName]:GetTurfOwner(turfId)
            end)
            if ownerOk and (owner == nil or owner == false or owner == 'none' or owner == '') then
                DebugPrint(('Gang MDT activity "%s" was processed in unowned turf %s; influence may be applied, but no owner gang XP is available.'):format(
                    settings.activity, tostring(turfId)
                ))
            else
                DebugPrint(('Gang MDT activity "%s" returned false (%s). Check the MDT turf/peaceful/activity configuration.'):format(
                    settings.activity, reason
                ))
            end
        else
            DebugPrint(('Gang MDT activity "%s" was not fully applied: %s.'):format(settings.activity, reason))
        end
    end)
end

local function GetRepAdjustedSuccessChance(drugConfig, rep)
    local success = tonumber(drugConfig.successRate)
    if success == nil then success = 100 - (tonumber(drugConfig.failRate) or 0) end
    success = math.max(0, math.min(100, success))

    local rejectReduction = math.max(0, math.min(100, tonumber(rep.levelData and rep.levelData.reduceReject) or 0))
    local rejectionChance = (100 - success) * (1 - rejectReduction / 100)
    return math.max(0, math.min(100, 100 - rejectionChance))
end

local function GetAdjustedRobberyChance(zone, rep)
    local robbery = zone and zone.robbery
    if not robbery or robbery.enabled == false then return 0 end

    local chance = math.max(0, math.min(100, tonumber(robbery.chance) or 0))
    local reduction = math.max(0, math.min(100, tonumber(rep.levelData and rep.levelData.reduceRobbery) or 0))
    return chance * (1 - reduction / 100)
end

local function CompleteFailure(src, zone, drugName, rep, reason)
    local title = (Config.DispatchAlert and Config.DispatchAlert.title) or 'Suspicious Activity'
    local message = (Config.DispatchAlert and Config.DispatchAlert.message) or 'A person attempted to sell drugs and failed.'
    local callChance = zone and tonumber(zone.callChance)
    if callChance == nil then callChance = tonumber(Config.CallCopsChance) or 0 end

    RollDispatchChance(src, zone, callChance, title, message, 51, 5)
    SendSaleResult(src, 'failed', reason or 'The customer rejected the deal.', 'error')
end

local function ProcessSale(src, drugName, requestedAmount, requestedZoneKey)
    local Player = GetPlayer(src)
    if not Player then return end

    if processing[src] then
        SendSaleResult(src, 'rejected', 'A sale is already being processed.', 'error')
        return
    end

    local now = GetGameTimer()
    local minRequestDelay = math.max(750, (tonumber(Config.SellingDuration) or 2) * 1000 - 250)
    if lastRequestAt[src] and now - lastRequestAt[src] < minRequestDelay then
        SendSaleResult(src, 'rejected', 'Please wait before attempting another sale.', 'error')
        return
    end

    processing[src] = true
    lastRequestAt[src] = now

    local function finish()
        processing[src] = nil
    end

    if type(drugName) ~= 'string' or not (Config.Drugs and Config.Drugs[drugName]) then
        SendSaleResult(src, 'rejected', 'Invalid drug item.', 'error')
        finish()
        return
    end

    if IsBlacklistedJob(Player) then
        SendSaleResult(src, 'rejected', 'Your job does not allow you to sell drugs.', 'error')
        finish()
        return
    end

    -- IsEntityDead is not available in every server-side FiveM native set.
    -- Validate the ped handle first, then use GetEntityHealth when the server
    -- runtime exposes it. If health cannot be queried server-side, do not call
    -- an unavailable native or crash the sale handler; the client also blocks
    -- attempts while the player is dead, while all reward validation stays here.
    local playerPed = GetPlayerPed(src)
    if not playerPed or playerPed == 0 then
        SendSaleResult(src, 'rejected', 'You cannot sell drugs right now.', 'error')
        finish()
        return
    end

    if type(DoesEntityExist) == 'function' and not DoesEntityExist(playerPed) then
        SendSaleResult(src, 'rejected', 'You cannot sell drugs right now.', 'error')
        finish()
        return
    end

    if type(GetEntityHealth) == 'function' then
        local healthOk, health = pcall(GetEntityHealth, playerPed)
        if healthOk and tonumber(health) and tonumber(health) <= 0 then
            SendSaleResult(src, 'rejected', 'You cannot sell drugs while dead.', 'error')
            finish()
            return
        end
    end

    local coords = GetEntityCoords(playerPed)
    local zoneKey, zone = GetSellingZone(coords)
    if not zone then
        SendSaleResult(src, 'rejected', 'You are not inside a configured drug-selling area.', 'error')
        finish()
        return
    end

    if requestedZoneKey ~= nil and tostring(requestedZoneKey) ~= tostring(zoneKey) then
        SendSaleResult(src, 'rejected', 'Your selling area could not be verified. Move into the zone and try again.', 'error')
        finish()
        return
    end

    if not IsZoneOpen(zone) then
        SendSaleResult(src, 'rejected', 'Drug selling is not available at this time in this area.', 'error')
        finish()
        return
    end

    local restrictionsPass, restrictionMessage, policeCount = CheckZoneRestrictions(src, zoneKey, zone)
    if not restrictionsPass then
        SendSaleResult(src, 'rejected', restrictionMessage or 'You cannot sell drugs in this area right now.', 'error')
        finish()
        return
    end

    -- Enforce the zone's allowed item list on the server, not just in the UI.
    if type(zone.drugs) == 'table' then
        local allowedInZone = false
        for _, allowedDrug in ipairs(zone.drugs) do
            if allowedDrug == drugName then
                allowedInZone = true
                break
            end
        end
        if not allowedInZone then
            SendSaleResult(src, 'rejected', 'This drug cannot be sold in this area.', 'error')
            finish()
            return
        end
    end

    local drugConfig = Config.Drugs[drugName]

    -- Enforce personal progression before reading a removal plan or touching the
    -- inventory. Locked drugs are rejected cleanly; all items remain untouched.
    local rep = GetReputation(src, Player)
    local requiredLevel = math.max(1, math.floor(tonumber(drugConfig.minLevel) or 1))
    if (tonumber(rep.level) or 1) < requiredLevel then
        local drugLabel = tostring(drugConfig.label or drugName)
        SendSaleResult(src, 'rejected', ('You need Drug Selling Level %d to sell %s. Your current level is %d; your items have not been changed.'):format(
            requiredLevel, drugLabel, tonumber(rep.level) or 1
        ), 'error', { requiredLevel = requiredLevel, currentLevel = tonumber(rep.level) or 1, drug = drugName })
        finish()
        return
    end

    local minAmount = math.max(1, math.floor(tonumber(drugConfig.minAmount) or 1))
    local maxAmount = math.max(minAmount, math.floor(tonumber(drugConfig.maxAmount) or minAmount))
    local available = GetInventoryCount(src, Player, drugName)
    if available < minAmount then
        SendSaleResult(src, 'rejected', ('You do not have enough %s to sell.'):format(drugName), 'error')
        finish()
        return
    end

    local amount = tonumber(requestedAmount)
    if amount then
        amount = math.floor(amount)
        if amount < minAmount or amount > maxAmount then
            SendSaleResult(src, 'rejected', 'Invalid sale quantity.', 'error')
            finish()
            return
        end
        if amount > available then
            SendSaleResult(src, 'rejected', ('You only have %s x %s.'):format(available, drugName), 'error')
            finish()
            return
        end
    else
        amount = math.random(minAmount, math.min(maxAmount, available))
    end

    local currentWindow = GetZoneSaleWindow(src, zoneKey)
    if (tonumber(zone.limit) or 0) > 0 and currentWindow.count >= tonumber(zone.limit) then
        SendSaleResult(src, 'rejected', 'You have reached the selling limit for this area.', 'error')
        finish()
        return
    end

    local successChance = GetRepAdjustedSuccessChance(drugConfig, rep)
    local succeeded = math.random(1, 100) <= successChance

    -- This counts requests handled by the server, not a client-supplied success claim.
    currentWindow.count = currentWindow.count + 1
    if zoneCooldowns[src] == nil then zoneCooldowns[src] = {} end
    zoneCooldowns[src][zoneKey] = GetGameTimer() + math.max(0, tonumber(zone.cooldown) or 0) * 1000

    if not succeeded then
        CompleteFailure(src, zone, drugName, rep, 'The customer rejected your offer. No drugs were removed.')
        finish()
        return
    end

    local robberyChance = GetAdjustedRobberyChance(zone, rep)
    local robbed = robberyChance > 0 and math.random(1, 100) <= robberyChance

    local removalPlan, basePrice, planError = MakeRemovalPlan(src, Player, drugName, amount, zone)
    if not removalPlan then
        SendSaleResult(src, 'rejected', planError == 'not_enough_items' and 'Your inventory changed before the sale completed.' or 'Could not prepare this sale.', 'error')
        finish()
        return
    end

    local removedOk, removedPlan = RemovePlan(src, Player, removalPlan)
    if not removedOk then
        SendSaleResult(src, 'rejected', 'The items could not be removed from your inventory. No payment was made.', 'error')
        finish()
        return
    end

    if robbed then
        local callChance = tonumber(zone.callChance)
        if callChance == nil then callChance = tonumber(Config.CallCopsChance) or 0 end
        RollDispatchChance(src, zone, callChance, 'Suspicious Activity', 'A suspected drug robbery was reported.', 51, 5)
        SendSaleResult(src, 'robbed', ('The customer robbed you and took %sx %s. You received no payment.'):format(amount, drugName), 'error')
        finish()
        return
    end

    local priceMultiplier = math.max(0, tonumber(zone.priceMultiplier) or 1.0)
    local repBoost = math.max(0, tonumber(rep.levelData and rep.levelData.priceBoost) or 0)
    local policeBoost = 0
    if Config.Police and Config.Police.risk then
        policeBoost = math.max(0, tonumber(Config.Police.percent) or 0) * (tonumber(policeCount) or 0)
    end

    local totalPrice = math.floor(basePrice * priceMultiplier * (1 + repBoost / 100) * (1 + policeBoost / 100) + 0.5)
    totalPrice = math.max(1, totalPrice)
    local account = zone.account or Config.SaleAccount or 'cash'

    if not PayPlayer(Player, src, account, totalPrice) then
        RestorePlan(src, Player, removedPlan)
        SendSaleResult(src, 'rejected', ('Payment failed for account/item "%s". The drugs were returned. Check your currency setup.'):format(tostring(account)), 'error')
        finish()
        return
    end

    AwardReputation(Player, zone, src)
    playerSales[src] = (playerSales[src] or 0) + 1

    SendSaleResult(src, 'success', ('You sold %sx %s for $%s.'):format(amount, drugName, totalPrice), 'success', {
        amount = amount,
        drug = drugName,
        total = totalPrice,
        account = account,
        zone = zoneKey,
    })

    -- An NPC may alert police after either a successful deal or a rejected one.
    local successCallChance = tonumber(zone.callChance)
    if successCallChance == nil then successCallChance = tonumber(Config.CallCopsChance) or 0 end
    RollDispatchChance(src, zone, successCallChance, 'Suspicious Drug Sale Activity', 'A citizen reported suspected drug dealing.', 140, 5)

    -- Preserve the original alert-after-multiple-sales behavior as well as zone call chances.
    local everySales = math.max(0, math.floor(tonumber(Config.PoliceAlertEverySales) or 3))
    if everySales > 0 and playerSales[src] >= everySales then
        playerSales[src] = 0
        TryDispatch(src, zone, 'Suspicious Drug Sale Activity', 'Suspicious individual involved in multiple drug sales.', 140, 5)
    end

    ApplyTurfActivity(src)
    finish()
end

-- Preferred entry point: the server decides whether the sale succeeds or fails.
RegisterNetEvent('shocks-drugsell:attemptSale', function(drugName, requestedAmount, zoneKey)
    ProcessSale(source, drugName, requestedAmount, zoneKey)
end)

-- Compatibility aliases for older client builds. The event name does not dictate
-- the result; both paths are independently rolled and validated server-side.
RegisterNetEvent('shocks-drugsell:completeSale', function(drugName, requestedAmount, zoneKey)
    ProcessSale(source, drugName, requestedAmount, zoneKey)
end)

RegisterNetEvent('shocks-drugsell:failSale', function(drugName, requestedAmount, zoneKey)
    ProcessSale(source, drugName, requestedAmount, zoneKey)
end)

-- Optional callback for a reputation display / future MDT panel.
QBCore.Functions.CreateCallback('shocks-drugsell:server:getReputation', function(src, cb)
    local Player = GetPlayer(src)
    if not Player then cb(nil) return end
    local rep = GetReputation(src, Player)
    cb({ xp = rep.xp, sales = rep.sales, level = rep.level, levelData = rep.levelData })
end)

-- /drugstats shows the caller's own persistent reputation. Admins can use
-- /drugstats <serverId> to inspect another online player's stats. The console
-- can use drugstats <serverId> and receives the result in the server console.
local function HasDrugStatsAdminPermission(src)
    if src == 0 then return true end
    if not QBCore.Functions or type(QBCore.Functions.HasPermission) ~= 'function' then
        return false
    end

    for _, permission in ipairs({ 'admin', 'god' }) do
        local ok, allowed = pcall(QBCore.Functions.HasPermission, src, permission)
        if ok and allowed == true then return true end
    end
    return false
end

local function GetPlayerDisplayName(Player, playerId)
    local data = Player and Player.PlayerData or {}
    local charinfo = data.charinfo or {}
    local fullName = (tostring(charinfo.firstname or '') .. ' ' .. tostring(charinfo.lastname or '')):gsub('^%s*(.-)%s*$', '%1')
    if fullName ~= '' then return fullName end
    return data.name or GetPlayerName(playerId) or ('Player ' .. tostring(playerId))
end

local function BuildDrugStats(Player, playerId)
    local rep = GetReputation(playerId, Player)
    local maxLevel = GetMaxReputationLevel()
    local level = tonumber(rep.level) or GetLevelForXP(rep.xp)
    local levelUp = math.max(1, tonumber(Config.Reputation and Config.Reputation.levelUp) or 25000)
    local xp = math.max(0, math.floor(tonumber(rep.xp) or 0))
    local progress = xp % levelUp
    local levelData = rep.levelData or {}

    return {
        playerName = GetPlayerDisplayName(Player, playerId),
        level = level,
        maxLevel = maxLevel,
        levelLabel = tostring(levelData.label or ('Level ' .. tostring(level))),
        description = tostring(levelData.description or ''),
        xp = xp,
        sales = math.max(0, math.floor(tonumber(rep.sales) or 0)),
        xpPerLevel = levelUp,
        progress = level >= maxLevel and levelUp or progress,
        maxLevelReached = level >= maxLevel,
        priceBoost = math.max(0, tonumber(levelData.priceBoost) or 0),
        reduceReject = math.max(0, tonumber(levelData.reduceReject) or 0),
        reduceRobbery = math.max(0, tonumber(levelData.reduceRobbery) or 0),
    }
end

local statsCommand = Config.Commands and Config.Commands.DrugStats or 'drugstats'
if type(statsCommand) ~= 'string' or statsCommand == '' then statsCommand = 'drugstats' end

RegisterCommand(statsCommand, function(src, args)
    local targetId = src
    local requestedId = args and tonumber(args[1])

    if src == 0 then
        if not requestedId then
            print(('[SHOCKS Drug Selling] Usage: %s <serverId>'):format(statsCommand))
            return
        end
        targetId = math.floor(requestedId)
    elseif requestedId then
        if not HasDrugStatsAdminPermission(src) then
            Notify(src, ('Use /%s to view your own stats. Only admins can inspect another player.'):format(statsCommand), 'error')
            return
        end
        targetId = math.floor(requestedId)
    end

    if targetId < 1 then
        if src ~= 0 then Notify(src, 'Invalid player ID.', 'error') end
        return
    end

    local Target = GetPlayer(targetId)
    if not Target then
        local message = ('Player %s is not online.'):format(targetId)
        if src == 0 then print('[SHOCKS Drug Selling] ' .. message) else Notify(src, message, 'error') end
        return
    end

    local stats = BuildDrugStats(Target, targetId)
    if src == 0 then
        print(('[SHOCKS Drug Selling] %s (ID %s): Level %s - %s | XP %s | Successful sales %s | Price bonus +%s%% | Rejection reduction %s%% | Robbery reduction %s%%'):format(
            stats.playerName, targetId, stats.level, stats.levelLabel, stats.xp, stats.sales,
            stats.priceBoost, stats.reduceReject, stats.reduceRobbery
        ))
        return
    end

    TriggerClientEvent('shocks-drugsell:client:showStats', src, stats)
end, false)

AddEventHandler('playerDropped', function()
    local src = source
    processing[src] = nil
    lastRequestAt[src] = nil
    zoneCooldowns[src] = nil
    zoneSaleWindows[src] = nil
    playerSales[src] = nil
    reputationCache[src] = nil
end)

CreateThread(function()
    Wait(1000)
    local settings = GetGangMDTSettings()
    if not settings.enabled then
        print('[SHOCKS Drug Selling] Gang MDT integration is disabled by configuration.')
    elseif GetResourceState(settings.resource) == 'started' then
        print(('[SHOCKS Drug Selling] Gang MDT integration ready: %s / activity "%s".'):format(settings.resource, settings.activity))
    else
        print(('[SHOCKS Drug Selling] WARNING: %s is not started. Sales continue; turf influence/XP will be skipped until it is running.'):format(settings.resource))
    end
end)
