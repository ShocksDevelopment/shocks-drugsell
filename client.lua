-- SHOCKS Drug Selling - client
-- Supports ox_target, qb-target, qtarget, or the configured E-key fallback.
-- Sale completion, inventory removal, payments, reputation and eligibility
-- must always be validated by the server.

local QBCore = exports['qb-core']:GetCoreObject()

local selling = false
local saleWaitingForServer = false
local saleRequestToken = 0
local soldToNPCs = {} -- ped handle => expiry game timer
local activeTargetPed = nil
local usingTarget = false
local targetProvider = nil
local textUiVisible = false
local helpTextMode = nil
local zoneBlips = {}

local INTERACTION_NAME = 'shocks_drugsell_sell_drugs'
local INTERACTION_LABEL = 'Sell Drugs'

local function DebugPrint(message)
    if Config.Setup and Config.Setup.debug then
        print(('[SHOCKS Drug Selling] %s'):format(tostring(message)))
    end
end

local function HasRecentlySoldTo(ped)
    local expiresAt = soldToNPCs[ped]
    if not expiresAt then return false end

    if GetGameTimer() >= expiresAt then
        soldToNPCs[ped] = nil
        return false
    end

    return true
end

local function RestoreCustomer(ped, clearTasks)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    if clearTasks then
        ClearPedTasks(ped)
        ClearPedSecondaryTask(ped)
    end

    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedKeepTask(ped, false)
end

local function Notify(message, kind)
    kind = kind or 'inform'

    if Config.Setup and Config.Setup.notify == 'ox_lib' and lib and type(lib.notify) == 'function' then
        local ok = pcall(function()
            lib.notify({
                title = 'Drug Selling',
                description = tostring(message),
                type = kind,
            })
        end)
        if ok then return end
    end

    local qbType = kind == 'inform' and 'primary' or kind
    if QBCore and QBCore.Functions and QBCore.Functions.Notify then
        QBCore.Functions.Notify(tostring(message), qbType)
    else
        print(('[SHOCKS Drug Selling] %s'):format(tostring(message)))
    end
end

-- TextUI prefers ox_lib, then QBCore draw text, then GTA's native help prompt.
-- The native help prompt is rendered every frame by DrawNativeHelpText().
local function ShowHelpText()
    if textUiVisible then return end

    if lib and type(lib.showTextUI) == 'function' then
        local ok = pcall(function()
            lib.showTextUI(('[E] %s'):format(INTERACTION_LABEL), {
                position = 'right-center',
                icon = 'cannabis',
            })
        end)

        if ok then
            textUiVisible = true
            helpTextMode = 'ox_lib'
            return
        end
    end

    if QBCore and QBCore.Functions and type(QBCore.Functions.DrawText) == 'function' then
        local ok = pcall(function()
            QBCore.Functions.DrawText(('[E] %s'):format(INTERACTION_LABEL), 'left')
        end)

        if ok then
            textUiVisible = true
            helpTextMode = 'qb'
            return
        end
    end

    textUiVisible = true
    helpTextMode = 'native'
end

local function HideHelpText()
    if not textUiVisible then return end

    local previousMode = helpTextMode
    textUiVisible = false
    helpTextMode = nil

    if previousMode == 'ox_lib' and lib and type(lib.hideTextUI) == 'function' then
        pcall(function() lib.hideTextUI() end)
    elseif previousMode == 'qb' and QBCore and QBCore.Functions
        and type(QBCore.Functions.HideText) == 'function' then
        pcall(function() QBCore.Functions.HideText() end)
    end
end

local function DrawNativeHelpText()
    if not textUiVisible or helpTextMode ~= 'native' then return end

    BeginTextCommandDisplayHelp('STRING')
    if (tonumber(Config.Setup and Config.Setup.interactKey) or 38) == 38 then
        AddTextComponentSubstringPlayerName('Press ~INPUT_CONTEXT~ to sell drugs')
    else
        AddTextComponentSubstringPlayerName(('Press interaction key (%s) to sell drugs'):
            format(tostring(Config.Setup.interactKey)))
    end
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function GetPlayerJobName()
    if not QBCore or not QBCore.Functions or not QBCore.Functions.GetPlayerData then
        return nil
    end

    local playerData = QBCore.Functions.GetPlayerData()
    local jobName = playerData and playerData.job and playerData.job.name
    return jobName and string.lower(tostring(jobName)) or nil
end

local function IsBlacklistedJob()
    local jobName = GetPlayerJobName()
    if not jobName then return false end

    local jobs = {}
    for _, name in ipairs((Config.Setup and Config.Setup.blacklistJobs) or {}) do
        if type(name) == 'string' then jobs[string.lower(name)] = true end
    end
    for _, name in ipairs(Config.BlacklistJobs or {}) do
        if type(name) == 'string' then jobs[string.lower(name)] = true end
    end

    return jobs[jobName] == true
end

local function BuildPedModelSet(models)
    local result = {}
    for _, model in ipairs(models or {}) do
        if type(model) == 'string' then
            result[GetHashKey(model)] = true
        elseif type(model) == 'number' then
            result[model] = true
        end
    end
    return result
end

local allowedPedModels = BuildPedModelSet(Config.PedModels)
local ignoredPedModels = BuildPedModelSet(Config.IgnoredPedModels)

local function IsMarkedAsScriptPed(ped)
    if not (Config.Setup and Config.Setup.excludeScriptPeds) then
        return false
    end

    -- FiveM has no universal native for identifying every resource-created ped.
    -- Respect common state-bag markers when another resource exposes them.
    local ok, state = pcall(function()
        return Entity(ped).state
    end)
    if not ok or not state then return false end

    return state.isScriptPed == true
        or state.scriptedPed == true
        or state.spawnedByResource ~= nil
        or state.scripted == true
end

local function GetSellingZone(coords)
    if not Config.Zones then return nil, nil end

    local closestKey, closestZone, closestDistance = nil, nil, nil
    for key, zone in pairs(Config.Zones) do
        if zone and zone.coords and tonumber(zone.size) then
            local distance = #(coords - zone.coords)
            if distance <= tonumber(zone.size) and (not closestDistance or distance < closestDistance) then
                closestKey = key
                closestZone = zone
                closestDistance = distance
            end
        end
    end

    return closestKey, closestZone
end

local function IsDaytime()
    local hour = GetClockHours()
    local startHour = tonumber(Config.DaytimeStart) or 6
    local endHour = tonumber(Config.DaytimeEnd) or 20

    if startHour == endHour then return true end
    if startHour < endHour then
        return hour >= startHour and hour < endHour
    end

    -- Supports a time window crossing midnight (for example, 20 -> 6).
    return hour >= startHour or hour < endHour
end

local function IsZoneOpen(zone)
    if not zone or zone.daytime == nil then return true end
    local isDay = IsDaytime()
    return zone.daytime and isDay or (not zone.daytime and not isDay)
end

local function IsIgnoredPedModel(ped, zone)
    local model = GetEntityModel(ped)
    if ignoredPedModels[model] then return true end

    for _, name in ipairs((zone and zone.ignoredPedModels) or {}) do
        if type(name) == 'string' and model == GetHashKey(name) then
            return true
        end
    end

    return false
end

-- Interaction previews may allow a closed zone to show its interaction.
-- The actual StartSale call uses allowClosedZone=false, enforcing zone hours.
-- The model whitelist is opt-in: missing models were the principal reason
-- ambient pedestrians could be rejected by both ox_target and the E fallback.
local function IsValidSalePed(ped, requireZone, allowClosedZone)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end
    if GetEntityType(ped) ~= 1 or IsPedAPlayer(ped) then return false end
    if IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) then return false end
    if selling or HasRecentlySoldTo(ped) then return false end

    local model = GetEntityModel(ped)
    if Config.Setup and Config.Setup.requirePedModelList == true and not allowedPedModels[model] then
        return false
    end
    if IsMarkedAsScriptPed(ped) then return false end

    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local zoneKey, zone = GetSellingZone(playerCoords)

    if requireZone and not zone then return false end
    if zone and IsIgnoredPedModel(ped, zone) then return false end
    if zone and not allowClosedZone and not IsZoneOpen(zone) then return false end

    local distance = #(GetEntityCoords(ped) - playerCoords)
    if distance > ((tonumber(Config.InteractionDistance) or 2.0) + 0.25) then
        return false
    end

    return true, zoneKey, zone
end

local function GetInventoryCount(itemName)
    if GetResourceState('ox_inventory') == 'started' then
        local ok, count = pcall(function()
            return exports.ox_inventory:Search('count', itemName)
        end)
        if ok and type(count) == 'number' then return count end
    end

    -- Fallback for servers using QBCore inventory rather than ox_inventory.
    local playerData = QBCore.Functions.GetPlayerData()
    for _, item in pairs((playerData and playerData.items) or {}) do
        if item and item.name == itemName then
            return tonumber(item.amount or item.count) or 0
        end
    end

    return 0
end

local function GetZoneDrugList(zone)
    local list = {}
    if zone and type(zone.drugs) == 'table' then
        for _, itemName in ipairs(zone.drugs) do
            if Config.Drugs and Config.Drugs[itemName] then
                list[#list + 1] = itemName
            end
        end
    else
        for itemName in pairs(Config.Drugs or {}) do
            list[#list + 1] = itemName
        end
    end
    return list
end

local function GetPlayerDrugSellingLevel()
    local playerData = QBCore.Functions.GetPlayerData()
    local metadata = playerData and playerData.metadata or {}
    local rep = type(metadata.drugSellingRep) == 'table' and metadata.drugSellingRep or {}

    local levelUp = math.max(1, tonumber(Config.Reputation and Config.Reputation.levelUp) or 25000)
    local maxLevel = 1
    for configuredLevel in pairs((Config.Reputation and Config.Reputation.levels) or {}) do
        maxLevel = math.max(maxLevel, tonumber(configuredLevel) or 1)
    end

    if rep.xp ~= nil then
        return math.min(maxLevel, math.floor(math.max(0, tonumber(rep.xp) or 0) / levelUp) + 1)
    end

    return math.max(1, math.min(maxLevel, math.floor(tonumber(rep.level) or 1)))
end

local function GetPlayerDrug(zone)
    local available = {}
    local hasAnyDrugs = false
    local lockedDrug = nil
    local currentLevel = GetPlayerDrugSellingLevel()

    for _, itemName in ipairs(GetZoneDrugList(zone)) do
        local drugConfig = Config.Drugs[itemName]
        if drugConfig then
            local count = GetInventoryCount(itemName)
            local minAmount = math.max(1, math.floor(tonumber(drugConfig.minAmount) or 1))
            local maxAmount = math.max(minAmount, math.floor(tonumber(drugConfig.maxAmount) or minAmount))
            local minLevel = math.max(1, math.floor(tonumber(drugConfig.minLevel) or 1))

            if count > 0 then hasAnyDrugs = true end

            if currentLevel < minLevel then
                if count >= minAmount and (not lockedDrug or minLevel < lockedDrug.minLevel) then
                    lockedDrug = {
                        name = itemName,
                        label = drugConfig.label or itemName,
                        minLevel = minLevel,
                        count = count,
                    }
                end
            elseif count >= minAmount then
                available[#available + 1] = {
                    name = itemName,
                    label = drugConfig.label or itemName,
                    count = count,
                    minAmount = minAmount,
                    maxAmount = math.min(maxAmount, count),
                }
            end
        end
    end

    if #available == 0 then
        return nil, 0, 0, hasAnyDrugs, lockedDrug, currentLevel
    end

    local chosen = available[math.random(1, #available)]
    local amount = math.random(chosen.minAmount, chosen.maxAmount)
    return chosen.name, chosen.count, amount, hasAnyDrugs, lockedDrug, currentLevel
end

local function RequestAnimationDictionary(dict)
    if not dict or dict == '' then return false end
    RequestAnimDict(dict)

    local timeout = GetGameTimer() + 5000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeout do
        Wait(10)
    end

    return HasAnimDictLoaded(dict)
end

local function AttachAnimationProp(ped, propName)
    if not propName or not ped or ped == 0 or not DoesEntityExist(ped) then return nil end

    local modelHash = type(propName) == 'number' and propName or GetHashKey(propName)
    if not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) then return nil end

    RequestModel(modelHash)
    local modelTimeout = GetGameTimer() + 3000
    while not HasModelLoaded(modelHash) and GetGameTimer() < modelTimeout do
        Wait(10)
    end

    if not HasModelLoaded(modelHash) then return nil end

    local coords = GetEntityCoords(ped)
    local prop = CreateObject(modelHash, coords.x, coords.y, coords.z + 0.2, false, false, false)
    SetModelAsNoLongerNeeded(modelHash)
    if not prop or prop == 0 then return nil end

    SetEntityAsMissionEntity(prop, true, true)
    SetEntityCollision(prop, false, false)
    AttachEntityToEntity(
        prop, ped, GetPedBoneIndex(ped, 57005),
        0.12, 0.02, -0.02, -90.0, 0.0, 0.0,
        false, false, false, false, 2, true
    )
    return prop
end

local function PlayPedAnimation(ped, animation)
    if not animation or not animation.dict or not animation.clip then return end
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end
    if not RequestAnimationDictionary(animation.dict) then return end

    local attachedProp = AttachAnimationProp(ped, animation.prop)
    local duration = math.max(400, tonumber(animation.duration) or 1000)
    local flag = math.floor(tonumber(animation.flag) or 49)

    TaskPlayAnim(ped, animation.dict, animation.clip, 8.0, -8.0, duration, flag, 0.0, false, false, false)
    local finishAt = GetGameTimer() + duration
    while DoesEntityExist(ped) and GetGameTimer() < finishAt do
        Wait(25)
    end

    if DoesEntityExist(ped) then ClearPedSecondaryTask(ped) end

    if attachedProp and DoesEntityExist(attachedProp) then
        DetachEntity(attachedProp, true, true)
        DeleteEntity(attachedProp)
    end

    RemoveAnimDict(animation.dict)
end

local function ApproachCustomer(targetPed, playerPed)
    local behavior = Config.NPCBehavior or {}
    if not DoesEntityExist(targetPed) or IsEntityDead(targetPed) then return false end

    SetBlockingOfNonTemporaryEvents(targetPed, true)
    SetPedKeepTask(targetPed, true)
    TaskTurnPedToFaceEntity(playerPed, targetPed, 750)
    TaskTurnPedToFaceEntity(targetPed, playerPed, 750)
    TaskLookAtEntity(targetPed, playerPed, tonumber(behavior.lookDuration) or 7000, 2048, 3)

    local desiredDistance = math.max(0.8, tonumber(behavior.approachDistance) or 1.15)
    local approachTimeout = math.max(0, tonumber(behavior.approachTimeout) or 2500)

    if behavior.approach ~= false then
        local currentDistance = #(GetEntityCoords(targetPed) - GetEntityCoords(playerPed))
        if currentDistance > desiredDistance + 0.15 then
            TaskGoToEntity(targetPed, playerPed, approachTimeout, desiredDistance, 1.0, 1073741824, 0)
            local deadline = GetGameTimer() + approachTimeout

            while DoesEntityExist(targetPed) and not IsEntityDead(targetPed) and GetGameTimer() < deadline do
                currentDistance = #(GetEntityCoords(targetPed) - GetEntityCoords(playerPed))
                if currentDistance <= desiredDistance + 0.2 then break end
                if currentDistance > (tonumber(behavior.maxSaleDistance) or 3.25) then break end
                Wait(50)
            end
        end
    end

    if not DoesEntityExist(targetPed) or IsEntityDead(targetPed) then
        RestoreCustomer(targetPed, true)
        return false
    end

    local distance = #(GetEntityCoords(targetPed) - GetEntityCoords(playerPed))
    if distance > (tonumber(behavior.maxSaleDistance) or 3.25) then
        RestoreCustomer(targetPed, true)
        return false
    end

    ClearPedTasks(targetPed)
    TaskTurnPedToFaceEntity(targetPed, playerPed, tonumber(behavior.faceDuration) or 350)
    TaskTurnPedToFaceEntity(playerPed, targetPed, tonumber(behavior.faceDuration) or 350)
    TaskLookAtEntity(targetPed, playerPed, tonumber(behavior.lookDuration) or 7000, 2048, 3)
    Wait(math.min(500, math.max(0, tonumber(behavior.faceDuration) or 350)))
    return true
end

local function HandleCustomerOutcome(targetPed, outcome)
    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed) then return end

    local animations = Config.Animations or {}
    if outcome == 'success' then
        PlayPedAnimation(targetPed, animations.npcAccepted or animations.accepted)
        RestoreCustomer(targetPed, false)
    elseif outcome == 'failed' then
        PlayPedAnimation(targetPed, animations.npcRejected or animations.rejected)
        RestoreCustomer(targetPed, false)
    elseif outcome == 'robbed' then
        local playerPed = PlayerPedId()
        TaskSmartFleePed(targetPed, playerPed, 65.0, 5000, false, false)
        SetBlockingOfNonTemporaryEvents(targetPed, false)
        SetPedKeepTask(targetPed, true)
    else
        RestoreCustomer(targetPed, true)
    end
end

local function RunSaleProgress(onFinish, onCancel)
    local duration = math.max(500, (tonumber(Config.SellingDuration) or 2) * 1000)

    if lib and type(lib.progressBar) == 'function' then
        local ok, completed = pcall(function()
            return lib.progressBar({
                duration = duration,
                label = 'Selling drugs...',
                useWhileDead = false,
                canCancel = true,
                disable = { move = true, car = true, combat = true },
            })
        end)

        if ok then
            if completed then onFinish() else onCancel() end
            return
        end
        DebugPrint(('ox_lib progress bar failed; trying QBCore fallback: %s'):format(tostring(completed)))
    end

    if QBCore.Functions.Progressbar then
        local ok = pcall(function()
            QBCore.Functions.Progressbar(
                'selling_drugs', 'Selling drugs...', duration, false, true,
                {
                    disableMovement = true,
                    disableCarMovement = true,
                    disableMouse = false,
                    disableCombat = true,
                },
                {}, {}, {}, onFinish, onCancel
            )
        end)
        if ok then return end
    end

    -- Last-resort fallback when no supported progress implementation is usable.
    Wait(duration)
    onFinish()
end

local function StartSale(targetPed)
    if selling or saleWaitingForServer then
        Notify('You are already selling drugs.', 'error')
        return
    end

    if IsBlacklistedJob() then
        Notify('Your job does not allow you to sell drugs.', 'error')
        return
    end

    local valid, zoneKey, zone = IsValidSalePed(targetPed, true, false)
    if not valid then
        local _, currentZone = GetSellingZone(GetEntityCoords(PlayerPedId()))
        if not currentZone then
            Notify('You cannot sell drugs in this area.', 'error')
        elseif not IsZoneOpen(currentZone) then
            Notify('Drug selling is not available at this time in this area.', 'error')
        else
            Notify('That pedestrian is not a valid customer.', 'error')
        end
        return
    end

    if not zone then
        Notify('You cannot sell drugs in this area.', 'error')
        return
    end

    local drugToSell, _, saleAmount, hasAnyDrugs, lockedDrug, currentLevel = GetPlayerDrug(zone)
    if not drugToSell then
        if lockedDrug then
            Notify(('You need Drug Selling Level %d to sell %s. You are Level %d; your items are safe.'):
                format(lockedDrug.minLevel, lockedDrug.label, currentLevel), 'error')
        elseif hasAnyDrugs then
            Notify('You have drugs, but not enough of an eligible item to make a sale.', 'error')
        else
            Notify('You do not have any configured drugs available to sell.', 'error')
        end
        return
    end

    if not Config.Drugs[drugToSell] then
        Notify('This drug is not configured correctly.', 'error')
        return
    end

    selling = true
    activeTargetPed = targetPed
    local playerPed = PlayerPedId()

    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed) then
        activeTargetPed = nil
        selling = false
        Notify('That pedestrian is no longer available.', 'error')
        return
    end

    if not ApproachCustomer(targetPed, playerPed) then
        RestoreCustomer(targetPed, true)
        activeTargetPed = nil
        selling = false
        Notify('The customer moved away before the deal could start.', 'error')
        return
    end

    local dealScenario = Config.NPCBehavior and Config.NPCBehavior.playerScenario
    if type(dealScenario) == 'string' and dealScenario ~= '' then
        TaskStartScenarioInPlace(playerPed, dealScenario, 0, true)
    end

    RunSaleProgress(function()
        if DoesEntityExist(playerPed) then ClearPedTasks(playerPed) end

        local behavior = Config.NPCBehavior or {}
        local maxDistance = tonumber(behavior.maxSaleDistance) or 3.25
        if not DoesEntityExist(targetPed) or IsEntityDead(targetPed)
            or #(GetEntityCoords(targetPed) - GetEntityCoords(playerPed)) > maxDistance then
            RestoreCustomer(targetPed, true)
            activeTargetPed = nil
            saleWaitingForServer = false
            selling = false
            Notify('The customer left before the sale could finish.', 'error')
            return
        end

        -- The client requests a sale only. Server validation must validate level,
        -- inventory, quantity, zone and payment before removing any items.
        saleWaitingForServer = true
        saleRequestToken = saleRequestToken + 1
        local requestToken = saleRequestToken
        TriggerServerEvent('shocks-drugsell:attemptSale', drugToSell, saleAmount, zoneKey)

        local timeout = math.max(tonumber(Config.Setup and Config.Setup.requestWait) or 10000, 3000)
        CreateThread(function()
            Wait(timeout)
            if saleWaitingForServer and saleRequestToken == requestToken then
                saleWaitingForServer = false
                RestoreCustomer(activeTargetPed, true)
                activeTargetPed = nil
                selling = false
                Notify('The server did not respond to the sale. Please try again.', 'error')
            end
        end)
    end, function()
        if DoesEntityExist(playerPed) then ClearPedTasks(playerPed) end
        RestoreCustomer(targetPed, true)
        activeTargetPed = nil
        saleWaitingForServer = false
        selling = false
        Notify('Drug sale cancelled.', 'error')
    end)
end

local function FormatNumber(value)
    local number = tostring(math.max(0, math.floor(tonumber(value) or 0)))
    local reversed = number:reverse():gsub('(%d%d%d)', '%1,')
    return reversed:reverse():gsub('^,', '')
end

local function BuildUnlockSummary(currentLevel)
    local unlocked, nextUnlocks = {}, {}
    local nextLevel = nil

    for itemName, drug in pairs(Config.Drugs or {}) do
        local requiredLevel = math.max(1, math.floor(tonumber(drug.minLevel) or 1))
        local label = tostring(drug.label or itemName)
        if requiredLevel <= currentLevel then
            unlocked[#unlocked + 1] = { label = label, level = requiredLevel }
        else
            if not nextLevel or requiredLevel < nextLevel then
                nextLevel = requiredLevel
                nextUnlocks = {}
            end
            if requiredLevel == nextLevel then nextUnlocks[#nextUnlocks + 1] = label end
        end
    end

    table.sort(unlocked, function(a, b)
        if a.level == b.level then return a.label < b.label end
        return a.level < b.level
    end)
    table.sort(nextUnlocks)

    local unlockedNames = {}
    for _, item in ipairs(unlocked) do unlockedNames[#unlockedNames + 1] = item.label end
    return #unlockedNames > 0 and table.concat(unlockedNames, ', ') or 'None configured',
        nextLevel, table.concat(nextUnlocks, ', ')
end

local function GetConfiguredMaxDrugLevel()
    local maxLevel = 1

    for configuredLevel in pairs((Config.Reputation and Config.Reputation.levels) or {}) do
        maxLevel = math.max(maxLevel, math.floor(tonumber(configuredLevel) or 1))
    end

    return maxLevel
end

local cachedDrugStats = nil
local lastRenderedDrugXP = nil

local function ShowDrugStats(stats)
    if type(stats) ~= 'table' then return end

    -- Keep a snapshot so an open stats menu can refresh when QBCore syncs new XP.
    local statsSnapshot = {}
    for key, value in pairs(stats) do
        statsSnapshot[key] = value
    end
    cachedDrugStats = statsSnapshot
    stats = cachedDrugStats

    local playerData = QBCore.Functions.GetPlayerData() or {}
    local metadata = playerData.metadata or {}
    local rep = type(metadata.drugSellingRep) == 'table' and metadata.drugSellingRep or {}

    -- XP is stored cumulatively. Derive the current-level progress from total XP
    -- rather than trusting a potentially stale `stats.progress` value.
    local rawXP = stats.xp
    if rawXP == nil then rawXP = stats.totalXp end
    if rawXP == nil then rawXP = rep.xp end

    local xp = math.max(0, math.floor(tonumber(rawXP) or 0))
    lastRenderedDrugXP = xp
    local goal = math.max(1, math.floor(
        tonumber(stats.xpPerLevel)
        or tonumber(Config.Reputation and Config.Reputation.levelUp)
        or 25000
    ))

    local configuredMaxLevel = GetConfiguredMaxDrugLevel()
    local maxLevel = math.max(1, math.floor(tonumber(stats.maxLevel) or configuredMaxLevel))
    maxLevel = math.max(maxLevel, configuredMaxLevel)

    -- Keep displayed level and percentage consistent with the cumulative XP.
    -- Fall back to the server's level only when no XP field is available at all.
    local level
    if rawXP ~= nil then
        level = math.min(maxLevel, math.floor(xp / goal) + 1)
    else
        level = math.floor(tonumber(stats.level or rep.level) or 1)
    end
    level = math.max(1, math.min(maxLevel, level))

    local levelConfig = (Config.Reputation and Config.Reputation.levels and Config.Reputation.levels[level]) or {}
    local levelLabel = tostring(levelConfig.label or stats.levelLabel or ('Level ' .. tostring(level)))
    local description = tostring(levelConfig.description or stats.description or 'Your reputation with local customers.')
    local sales = math.max(0, math.floor(tonumber(stats.sales) or 0))
    local priceBoost = math.max(0, tonumber(levelConfig.priceBoost) or tonumber(stats.priceBoost) or 0)
    local reduceReject = math.max(0, tonumber(levelConfig.reduceReject) or tonumber(stats.reduceReject) or 0)
    local reduceRobbery = math.max(0, tonumber(levelConfig.reduceRobbery) or tonumber(stats.reduceRobbery) or 0)

    local maxed = stats.maxLevelReached == true or level >= maxLevel
    local xpIntoLevel = xp % goal
    local progressXP = maxed and goal or xpIntoLevel
    local percent = maxed and 100 or math.floor((progressXP / goal) * 100 + 0.5)
    percent = math.max(0, math.min(100, percent))
    local xpToNext = maxed and 0 or math.max(0, goal - progressXP)

    local unlockedText, nextUnlockLevel, nextUnlockText = BuildUnlockSummary(level)
    local nextUnlockDescription

    if maxed then
        nextUnlockDescription = 'Maximum selling level reached. All configured drug tiers are unlocked.'
    elseif nextUnlockLevel then
        nextUnlockDescription = ('Next unlock — Level %s: %s'):format(nextUnlockLevel, nextUnlockText)
    else
        nextUnlockDescription = 'No additional drug tiers are configured.'
    end

    local titleName = tostring(stats.playerName or 'Your Profile')
    local contextOptions = {
        {
            title = ('Level %02d / %02d · %s'):format(level, maxLevel, levelLabel),
            description = description,
            icon = 'user',
            readOnly = true,
            metadata = {
                { label = 'Total XP', value = FormatNumber(xp) },
                { label = 'Successful paid sales', value = FormatNumber(sales) },
            },
        },
        {
            title = 'Reputation Progress',
            description = maxed
                and ('%s total XP · Maximum level reached'):format(FormatNumber(xp))
                or ('%s / %s XP this level · %s XP to next level · %d%%'):format(
                    FormatNumber(progressXP), FormatNumber(goal), FormatNumber(xpToNext), percent
                ),
            icon = 'chart-line',
            progress = percent,
            colorScheme = 'blue',
            readOnly = true,
            metadata = {
                { label = 'Total XP', value = FormatNumber(xp) },
                { label = 'Current level progress', value = ('%d%%'):format(percent), progress = percent, colorScheme = 'blue' },
                { label = 'XP to next level', value = maxed and 'Max level' or FormatNumber(xpToNext) },
            },
        },
        {
            title = 'Dealer Benefits',
            description = 'Bonuses earned from your personal drug-selling reputation.',
            icon = 'award',
            readOnly = true,
            metadata = {
                { label = 'Sale price bonus', value = ('+%s%%'):format(priceBoost) },
                { label = 'Reduced rejection chance', value = ('%s%%'):format(reduceReject) },
                { label = 'Reduced robbery chance', value = ('%s%%'):format(reduceRobbery) },
            },
        },
        {
            title = 'Career Record',
            description = ('Successful paid sales: %s'):format(FormatNumber(sales)),
            icon = 'handshake',
            readOnly = true,
        },
        {
            title = 'Drug Access',
            description = ('Unlocked at your level: %s\n%s'):format(unlockedText, nextUnlockDescription),
            icon = 'pills',
            readOnly = true,
        },
    }

    -- Use ox_lib's native context progress option for a real, readable progress
    -- bar. Re-registering the context on each stats response refreshes its value.
    if lib and type(lib.registerContext) == 'function' and type(lib.showContext) == 'function' then
        local ok = pcall(function()
            lib.registerContext({
                id = 'shocks_drugsell_stats',
                title = ('SHOCKS | Drug Dealer · %s'):format(titleName),
                position = 'top-right',
                options = contextOptions,
            })
            lib.showContext('shocks_drugsell_stats')
        end)

        if ok then return end
        DebugPrint('Could not display ox_lib stats context; trying the dialog fallback.')
    end

    -- Fallback for older ox_lib versions or servers without the context menu API.
    local fallbackContent = table.concat({
        ('LEVEL %02d / %02d — %s'):format(level, maxLevel, levelLabel),
        description,
        '',
        'REPUTATION PROGRESS',
        ('[%s%%] %s / %s XP this level'):format(percent, FormatNumber(progressXP), FormatNumber(goal)),
        maxed and 'Maximum selling level reached.' or ('%s XP to the next level.'):format(FormatNumber(xpToNext)),
        ('Total XP: %s'):format(FormatNumber(xp)),
        '',
        'DEALER BENEFITS',
        ('Sale price bonus: +%s%%'):format(priceBoost),
        ('Reduced rejection chance: %s%%'):format(reduceReject),
        ('Reduced robbery chance: %s%%'):format(reduceRobbery),
        '',
        'CAREER RECORD',
        ('Successful paid sales: %s'):format(FormatNumber(sales)),
        '',
        'DRUG ACCESS',
        ('Unlocked: %s'):format(unlockedText),
        nextUnlockDescription,
    }, '\n')

    if lib and type(lib.alertDialog) == 'function' then
        local ok = pcall(function()
            lib.alertDialog({
                header = ('SHOCKS | %s'):format(titleName),
                content = fallbackContent,
                centered = true,
                cancel = false,
            })
        end)
        if ok then return end
    end

    QBCore.Functions.Notify(
        ('Drug Dealer Level %s (%s) | %s XP | %s sales | %d%% level progress'):format(
            level, levelLabel, FormatNumber(xp), FormatNumber(sales), percent
        ),
        'primary',
        12000
    )
end

RegisterNetEvent('shocks-drugsell:client:showStats', function(stats)
    ShowDrugStats(stats)
end)

-- If the stats panel is already open, refresh its progress bar as soon as the
-- synced QBCore drug-selling XP changes. No client-side XP is awarded here;
-- this only displays the server-synced metadata value.
RegisterNetEvent('QBCore:Player:SetPlayerData', function(playerData)
    if type(playerData) ~= 'table' or type(cachedDrugStats) ~= 'table' then return end
    if not lib or type(lib.getOpenContextMenu) ~= 'function' then return end

    local openMenu
    local ok = pcall(function()
        openMenu = lib.getOpenContextMenu()
    end)
    if not ok or openMenu ~= 'shocks_drugsell_stats' then return end

    local metadata = playerData.metadata or {}
    local rep = type(metadata.drugSellingRep) == 'table' and metadata.drugSellingRep or nil
    local currentXP = rep and tonumber(rep.xp) or nil
    if not currentXP then return end

    currentXP = math.max(0, math.floor(currentXP))
    if currentXP == lastRenderedDrugXP then return end

    local refreshedStats = {}
    for key, value in pairs(cachedDrugStats) do
        refreshedStats[key] = value
    end
    refreshedStats.xp = currentXP

    ShowDrugStats(refreshedStats)
end)

RegisterNetEvent('shocks-drugsell:client:saleResult', function(result)
    local targetPed = activeTargetPed
    saleWaitingForServer = false

    if type(result) ~= 'table' then
        RestoreCustomer(targetPed, true)
        activeTargetPed = nil
        selling = false
        return
    end

    local outcome = tostring(result.outcome or 'rejected')

    -- Rejections from server validation do not consume the NPC cooldown and do
    -- not play fake hand-off/rejection animations.
    if outcome == 'rejected' then
        if targetPed then soldToNPCs[targetPed] = nil end
        RestoreCustomer(targetPed, true)
        activeTargetPed = nil
        selling = false
        if result.message then Notify(tostring(result.message), 'error') end
        return
    end

    local behavior = Config.NPCBehavior or {}
    if targetPed and DoesEntityExist(targetPed) then
        soldToNPCs[targetPed] = GetGameTimer() + math.max(1000, tonumber(behavior.customerCooldown) or 60000)
        CreateThread(function() HandleCustomerOutcome(targetPed, outcome) end)
    end

    local animations = Config.Animations or {}
    local playerAnimation
    if outcome == 'success' then
        playerAnimation = animations.accepted
    elseif outcome == 'failed' or outcome == 'robbed' then
        playerAnimation = animations.rejected
    end

    if playerAnimation then
        CreateThread(function()
            PlayPedAnimation(PlayerPedId(), playerAnimation)
            if activeTargetPed == targetPed then activeTargetPed = nil end
            selling = false
        end)
    else
        if activeTargetPed == targetPed then activeTargetPed = nil end
        selling = false
    end
end)

-- Preserve the event used by the resource's existing ox_target option or by
-- other resources that trigger a sale directly.
RegisterNetEvent('shocks-drugsell:sellDrugs', function(data)
    local entity = type(data) == 'table' and data.entity or data
    StartSale(entity)
end)

local function CanTargetPed(entity, distance)
    if selling or saleWaitingForServer then return false end
    if IsBlacklistedJob() then return false end
    if distance and distance > (tonumber(Config.InteractionDistance) or 2.0) then return false end

    -- Do not hide the interaction solely because a zone's configured time window
    -- is closed. StartSale rechecks the opening hours before a transaction.
    return IsValidSalePed(entity, true, true) == true
end

local function RegisterOxTarget()
    local ok, err = pcall(function()
        exports.ox_target:addGlobalPed({
            {
                name = INTERACTION_NAME,
                icon = 'fa-solid fa-cannabis',
                label = INTERACTION_LABEL,
                distance = tonumber(Config.InteractionDistance) or 2.0,
                canInteract = function(entity, distance)
                    return CanTargetPed(entity, distance)
                end,
                onSelect = function(data)
                    if data and data.entity then StartSale(data.entity) end
                end,
            }
        })
    end)

    if not ok then DebugPrint(('ox_target registration failed: %s'):format(tostring(err))) end
    return ok
end

local function RegisterQbTarget(resourceName)
    local ok, err = pcall(function()
        exports[resourceName]:AddGlobalPed({
            options = {
                {
                    icon = 'fas fa-cannabis',
                    label = INTERACTION_LABEL,
                    action = function(entity) StartSale(entity) end,
                    canInteract = function(entity, distance)
                        return CanTargetPed(entity, distance)
                    end,
                }
            },
            distance = tonumber(Config.InteractionDistance) or 2.0,
        })
    end)

    if not ok then DebugPrint(('%s registration failed: %s'):format(resourceName, tostring(err))) end
    return ok
end

local function RemoveTargetRegistration()
    if not usingTarget or not targetProvider then return end

    if targetProvider == 'ox_target' then
        pcall(function() exports.ox_target:removeGlobalPed({ INTERACTION_NAME }) end)
    elseif targetProvider == 'qb-target' then
        pcall(function() exports['qb-target']:RemoveGlobalPed({ INTERACTION_LABEL }) end)
    elseif targetProvider == 'qtarget' then
        pcall(function() exports.qtarget:RemoveGlobalPed({ INTERACTION_LABEL }) end)
    end

    usingTarget = false
    targetProvider = nil
end

local function TryRegisterConfiguredTarget()
    local configuredTarget = string.lower(tostring(Config.Setup and Config.Setup.target or 'none'))
    if configuredTarget == 'none' or configuredTarget == 'custom' then
        if configuredTarget == 'custom' then
            DebugPrint('target = custom has no custom bridge in this client; using E-key interaction.')
        end
        return false
    end

    if configuredTarget == 'ox_target' then
        if GetResourceState('ox_target') ~= 'started' then return false end
        if RegisterOxTarget() then
            usingTarget = true
            targetProvider = 'ox_target'
            DebugPrint('Registered Sell Drugs with ox_target.')
            return true
        end
    elseif configuredTarget == 'qb-target' then
        if GetResourceState('qb-target') ~= 'started' then return false end
        if RegisterQbTarget('qb-target') then
            usingTarget = true
            targetProvider = 'qb-target'
            DebugPrint('Registered Sell Drugs with qb-target.')
            return true
        end
    elseif configuredTarget == 'qtarget' then
        if GetResourceState('qtarget') ~= 'started' then return false end
        if RegisterQbTarget('qtarget') then
            usingTarget = true
            targetProvider = 'qtarget'
            DebugPrint('Registered Sell Drugs with qtarget.')
            return true
        end
    else
        DebugPrint(('Unknown target provider "%s"; using E-key interaction.'):format(configuredTarget))
        return false
    end

    return false
end

-- Retry target registration in case the target resource starts after this one.
-- Until registration succeeds, the E-key fallback remains usable.
CreateThread(function()
    Wait(1000)
    while true do
        if usingTarget and targetProvider and GetResourceState(targetProvider) ~= 'started' then
            DebugPrint(('Target provider %s stopped; E-key fallback re-enabled.'):format(targetProvider))
            RemoveTargetRegistration()
        end

        if not usingTarget then
            TryRegisterConfiguredTarget()
        end

        Wait(usingTarget and 3000 or 2000)
    end
end)

local function GetClosestValidPed(maxDistance)
    local playerPed = PlayerPedId()
    local playerCoords = GetEntityCoords(playerPed)
    local closestPed, closestDistance = nil, maxDistance or (tonumber(Config.InteractionDistance) or 2.0)

    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= playerPed then
            local valid = IsValidSalePed(ped, true, true)
            if valid then
                local distance = #(GetEntityCoords(ped) - playerCoords)
                if distance <= closestDistance then
                    closestPed = ped
                    closestDistance = distance
                end
            end
        end
    end

    return closestPed
end

-- The E-key fallback runs for target = 'none', missing target dependencies,
-- failed target registration, or the not-yet-registered startup period.
CreateThread(function()
    local closestPed = nil
    local nextScan = 0

    while true do
        if usingTarget then
            HideHelpText()
            Wait(500)
        elseif selling or saleWaitingForServer then
            HideHelpText()
            Wait(200)
        else
            local now = GetGameTimer()
            if now >= nextScan then
                closestPed = GetClosestValidPed(tonumber(Config.InteractionDistance) or 2.0)
                nextScan = now + 300
            end

            if closestPed and DoesEntityExist(closestPed) and not selling then
                ShowHelpText()
                DrawNativeHelpText()

                if IsControlJustReleased(0, tonumber(Config.Setup and Config.Setup.interactKey) or 38) then
                    local pedToSellTo = closestPed
                    closestPed = nil
                    nextScan = 0
                    StartSale(pedToSellTo)
                end
                Wait(0)
            else
                HideHelpText()
                closestPed = nil
                Wait(150)
            end
        end
    end
end)

-- Create map markers from the configured selling zones.
CreateThread(function()
    Wait(1000)

    for zoneKey, zone in pairs(Config.Zones or {}) do
        local blipConfig = zone and zone.blip
        if blipConfig and blipConfig.enabled and zone.coords then
            local coords = zone.coords
            local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
            SetBlipSprite(blip, tonumber(blipConfig.sprite) or 51)
            SetBlipDisplay(blip, 4)
            SetBlipScale(blip, tonumber(blipConfig.scale) or 0.8)
            SetBlipColour(blip, tonumber(blipConfig.color) or 1)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString(zone.name or zoneKey)
            EndTextCommandSetBlipName(blip)
            zoneBlips[#zoneBlips + 1] = blip

            if blipConfig.showRadius and tonumber(zone.size) and tonumber(zone.size) > 0 then
                local radiusBlip = AddBlipForRadius(coords.x, coords.y, coords.z, tonumber(zone.size) + 0.0)
                SetBlipColour(radiusBlip, tonumber(blipConfig.color) or 1)
                SetBlipAlpha(radiusBlip, 45)
                zoneBlips[#zoneBlips + 1] = radiusBlip
            end
        end
    end
end)

-- Entity handles can be reused after a ped despawns; periodically clear stale keys.
CreateThread(function()
    while true do
        Wait(30000)
        for ped in pairs(soldToNPCs) do
            if not DoesEntityExist(ped) then soldToNPCs[ped] = nil end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    HideHelpText()
    RemoveTargetRegistration()

    for _, blip in ipairs(zoneBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end

    if activeTargetPed and DoesEntityExist(activeTargetPed) then
        RestoreCustomer(activeTargetPed, true)
    end

    local playerPed = PlayerPedId()
    if playerPed and playerPed ~= 0 and DoesEntityExist(playerPed) then
        ClearPedSecondaryTask(playerPed)
        ClearPedTasks(playerPed)
    end
end)
