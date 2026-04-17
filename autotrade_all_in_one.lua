--[[
    AutoTrade - all in one
    Expected environment: Roblox client / executor with access to ReplicatedStorage modules.

    Main flow:
    1. Poll incoming trade requests via TradingCmds.HasRequestFromPlayer(player)
    2. Pre-build the trade plan from Save.Inventory
    3. Accept the request by re-sending TradingCmds.Request(player)
    4. Add configured items to the active trade
    5. Set ready
    6. Wait for the other player to be ready
    7. Confirm

    Safety defaults:
    - Does not accept if ItemList is empty
    - Does not accept if a required item is missing
    - Remembers already processed players for the current session

    Remote loader support:
    - You can inject config via _G.AutoTradeSettings before loadstring(...)
]]

local injectedEnv = type(getgenv) == "function" and getgenv() or nil
local globalEnv = injectedEnv or _G
local REMOTE_CONFIG_KEYS = {
    "AutoTradeSettings",
    "AUTOTRADE_REMOTE_CONFIG",
    "AUTOTRADE_CONFIG",
}

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, nestedValue in pairs(value) do
        copy[key] = deepCopy(nestedValue)
    end
    return copy
end

local function mergeConfig(base, override)
    if type(override) ~= "table" then
        return base
    end

    for key, value in pairs(override) do
        if type(value) == "table" and type(base[key]) == "table" then
            base[key] = mergeConfig(deepCopy(base[key]), value)
        else
            base[key] = deepCopy(value)
        end
    end

    return base
end

local function getInjectedConfig()
    for _, key in ipairs(REMOTE_CONFIG_KEYS) do
        local value = type(injectedEnv) == "table" and rawget(injectedEnv, key) or nil
        if type(value) == "table" then
            return value, key
        end

        value = rawget(_G, key)
        if type(value) == "table" then
            return value, key
        end
    end

    return nil, nil
end

local function normalizeInjectedItemSpec(spec)
    if type(spec) ~= "table" then
        return spec
    end

    local normalized = deepCopy(spec)

    if normalized.name == nil then
        normalized.name = spec.Name or spec.Item or spec.item
    end

    if normalized.class == nil then
        normalized.class = spec.Class or spec.class
    end

    if normalized.amount == nil then
        normalized.amount = spec.Amount or spec.amount or spec.MinimumAmount or spec.minimumAmount
    end

    if normalized.tier == nil then
        normalized.tier = spec.Tier or spec.tier
    end

    if normalized.variant == nil then
        normalized.variant = spec.Variant or spec.variant
    end

    if normalized.match == nil then
        normalized.match = spec.Match or spec.match
    end

    if normalized.required == nil then
        normalized.required = spec.Required
    end

    if normalized.allowPartial == nil then
        normalized.allowPartial = spec.AllowPartial
    end

    if normalized.enabled == nil then
        normalized.enabled = spec.Enabled
    end

    return normalized
end

local function normalizeInjectedConfig(config)
    if type(config) ~= "table" then
        return nil
    end

    local normalized = deepCopy(config)

    if normalized.AllowedPlayers == nil and type(normalized.Users) == "table" then
        normalized.AllowedPlayers = deepCopy(normalized.Users)
    end

    if normalized.BlockedPlayers == nil then
        if type(normalized.BlockList) == "table" then
            normalized.BlockedPlayers = deepCopy(normalized.BlockList)
        elseif type(normalized.BlockedUsers) == "table" then
            normalized.BlockedPlayers = deepCopy(normalized.BlockedUsers)
        end
    end

    if normalized.TradeMessage == nil then
        normalized.TradeMessage = normalized.Message or normalized.MailMessage
    end

    if normalized.ItemList == nil and type(normalized.Items) == "table" then
        normalized.ItemList = {}
        for _, spec in ipairs(normalized.Items) do
            table.insert(normalized.ItemList, normalizeInjectedItemSpec(spec))
        end
    elseif type(normalized.ItemList) == "table" then
        local mappedItemList = {}
        for _, spec in ipairs(normalized.ItemList) do
            table.insert(mappedItemList, normalizeInjectedItemSpec(spec))
        end
        normalized.ItemList = mappedItemList
    end

    return normalized
end

local DEFAULT_CONFIG = {
    Enabled = true,
    Debug = true,

    LoopInterval = 0.25,
    BetweenSetItemDelay = 0.12,
    AcceptDelay = 0.10,
    ReadyDelay = 0.20,
    ConfirmDelay = 0.20,
    ReadyResendInterval = 1.00,
    PostOtherReadyConfirmDelay = 0.50,
    ConfirmRetryInterval = 0.75,

    SaveLoadTimeout = 15,
    AcceptTimeout = 15,
    OtherReadyTimeout = 60,
    ConfirmTimeout = 20,
    TradeCloseTimeout = 20,

    ProcessExistingActiveTrade = true,
    KeepReadySynced = true,
    KeepConfirmSynced = true,
    UseDirectReadyRemoteFallback = true,
    UseDirectConfirmRemoteFallback = false,
    DebugTradeStateAtConfirm = true,
    ConfirmWithoutOtherReadyDetection = true,

    RejectIfItemListEmpty = true,
    RejectSkippedRequests = true,
    DeclineIfPlanFails = true,
    DeclineIfApplyFails = true,
    DeclineIfConfirmFails = true,
    DeclineIfOtherNeverReady = true,
    MarkPlayerAsTradedAfterConfirmFlow = true,

    SkipAlreadyTradedPlayers = true,
    RememberPlayersThisSession = true,
    PersistAlreadyTradedPlayers = false,
    PersistenceFile = "autotrade_processed_players.json",

    AllowedPlayers = {
        -- Empty = everyone allowed
        -- "SomePlayerName",
        -- 123456789,
    },

    BlockedPlayers = {
        -- "BadPlayerName",
        -- 987654321,
    },

    TradeMessage = "cadeau!",

    AllowPartialAmountByDefault = false,

    -- Each entry supports:
    -- name        = required string
    -- amount      = required number or "all"
    -- class       = optional, example "Currency", "Pet", "Misc"
    -- match       = optional, "exact" (default) or "contains"
    -- tier        = optional, useful for Enchant/Potion stacks when the raw item data stores a tier
    -- variant     = optional, useful for pets, example "rainbow" or "golden"
    -- required    = optional, default true
    -- allowPartial= optional, default CONFIG.AllowPartialAmountByDefault
    -- enabled     = optional, default true
    ItemList = {
        { name = "Pinata", amount = 100, class = "Misc", match = "contains", allowPartial = true, required = false },
        { name = "Coin Jar", amount = 100, class = "Misc", match = "contains", allowPartial = true, required = false },
        { name = "Comet", amount = 250, class = "Misc", allowPartial = true, required = false },
        { name = "Lucky Block", amount = 100, class = "Misc", match = "contains", allowPartial = true, required = false },
        { name = "Blooming Axolotl", amount = 100, class = "Pet", variant = "rainbow", allowPartial = true, required = false },
        { name = "Coins", amount = 1, class = "Enchant", tier = 7, allowPartial = true, required = false },
        { name = "Tap Power", amount = 1, class = "Enchant", tier = 7, allowPartial = true, required = false },
        { name = "Fortune", amount = 1, class = "Enchant", allowPartial = true, required = false },
        { name = "Coins", amount = 100, class = "Potion", tier = 7, allowPartial = true, required = false },
        { name = "Damage", amount = 100, class = "Potion", tier = 7, allowPartial = true, required = false },
    },
}

local injectedConfig, injectedConfigKey = getInjectedConfig()
local CONFIG = mergeConfig(deepCopy(DEFAULT_CONFIG), normalizeInjectedConfig(injectedConfig))

local GLOBAL_KEY = "AUTOTRADE_ALL_IN_ONE_V1"
local SESSION_KEY = GLOBAL_KEY .. "_SESSION"
local existingController = rawget(globalEnv, GLOBAL_KEY)

if type(existingController) == "table" and type(existingController.Stop) == "function" then
    pcall(existingController.Stop, "replaced by new instance")
end

local currentSessionValue = tonumber(rawget(globalEnv, SESSION_KEY)) or 0
local mySessionId = currentSessionValue + 1
globalEnv[SESSION_KEY] = mySessionId

local Controller = {
    Running = true,
    Version = "1.0.4",
    SessionId = mySessionId,
    StopReason = nil,
    ConfigSource = injectedConfigKey or "defaults",
}

globalEnv[GLOBAL_KEY] = Controller

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local NetworkFolder = ReplicatedStorage:FindFirstChild("Network") or ReplicatedStorage:WaitForChild("Network", 10)

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end
local ClientFolder = ReplicatedStorage:WaitForChild("Library"):WaitForChild("Client")

local function requireModule(moduleScript, label)
    local ok, result = pcall(require, moduleScript)
    if not ok then
        error(string.format("[AutoTrade] Failed to require %s: %s", label, tostring(result)))
    end
    return result
end

local TradingCmds = requireModule(ClientFolder:WaitForChild("TradingCmds"), "TradingCmds")
local Save = requireModule(ClientFolder:WaitForChild("Save"), "Save")

local function log(message)
    if CONFIG.Debug then
        print("[AutoTrade] " .. tostring(message))
    end
end

local function warnLog(message)
    warn("[AutoTrade] " .. tostring(message))
end

local function trim(value)
    return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeString(value)
    return trim(value):lower():gsub("%s+", " ")
end

local CLASS_ALIASES = {
    booth = "booth",
    booths = "booth",
    box = "box",
    boxes = "box",
    charm = "charm",
    charms = "charm",
    currency = "currency",
    currencies = "currency",
    enchant = "enchant",
    enchants = "enchant",
    fruit = "fruit",
    fruits = "fruit",
    hoverboard = "hoverboard",
    hoverboards = "hoverboard",
    lootbox = "lootbox",
    lootboxes = "lootbox",
    misc = "misc",
    miscitems = "misc",
    pet = "pet",
    pets = "pet",
    potion = "potion",
    potions = "potion",
    seed = "seed",
    seeds = "seed",
    ultimate = "ultimate",
    ultimates = "ultimate",
}

local function normalizeClass(value)
    local normalized = normalizeString(value or "")
    return CLASS_ALIASES[normalized] or normalized
end

local function toBoolean(value)
    if value == true then
        return true
    end
    if value == false or value == nil then
        return false
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        local normalized = normalizeString(value)
        return normalized == "true" or normalized == "1" or normalized == "yes"
    end
    return false
end

local function isHex32(value)
    return type(value) == "string" and value:match("^[%x]+$") ~= nil and #value == 32
end

local function safeRawGet(tbl, key)
    if type(tbl) ~= "table" then
        return nil
    end
    local ok, result = pcall(rawget, tbl, key)
    if ok then
        return result
    end
    return nil
end

local function firstStringField(tbl, keys)
    for _, key in ipairs(keys) do
        local value = safeRawGet(tbl, key)
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function firstNumberField(tbl, keys)
    for _, key in ipairs(keys) do
        local value = safeRawGet(tbl, key)
        local numeric = tonumber(value)
        if numeric and numeric >= 0 then
            return numeric
        end
    end
    return nil
end

local function coerceWantedAmount(value, fallback)
    if value == "all" then
        return "all"
    end
    local numeric = tonumber(value)
    if not numeric or numeric <= 0 then
        return fallback or 1
    end
    return math.max(1, math.floor(numeric))
end

local function formatAmount(value)
    if type(value) ~= "number" then
        return tostring(value)
    end
    if math.abs(value - math.floor(value)) < 0.000001 then
        return tostring(math.floor(value))
    end
    return tostring(value)
end

local function clearDictionary(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local function isCurrentSession()
    return rawget(globalEnv, SESSION_KEY) == mySessionId and rawget(globalEnv, GLOBAL_KEY) == Controller
end

local function shouldRun()
    return Controller.Running and isCurrentSession()
end

local RemoteCache = {}

local function getPlayerKey(player)
    if player and typeof(player) == "Instance" and player:IsA("Player") then
        if player.UserId and player.UserId > 0 then
            return tostring(player.UserId)
        end
        return player.Name
    end
    return tostring(player)
end

local function resolvePlayer(candidate)
    if candidate == nil then
        return nil
    end

    if typeof(candidate) == "Instance" and candidate:IsA("Player") then
        return candidate
    end

    if type(candidate) == "number" then
        local ok, result = pcall(function()
            return Players:GetPlayerByUserId(candidate)
        end)
        return ok and result or nil
    end

    if type(candidate) == "string" then
        local direct = Players:FindFirstChild(candidate)
        if direct and direct:IsA("Player") then
            return direct
        end

        local numeric = tonumber(candidate)
        if numeric then
            local ok, result = pcall(function()
                return Players:GetPlayerByUserId(numeric)
            end)
            if ok and result then
                return result
            end
        end
    end

    return nil
end

local function tableHasPlayerReference(tbl, player)
    if type(tbl) ~= "table" or not player then
        return false
    end

    if tbl[player] ~= nil then
        return true
    end

    if player.UserId and tbl[player.UserId] ~= nil then
        return true
    end

    if player.Name and tbl[player.Name] ~= nil then
        return true
    end

    for key, value in pairs(tbl) do
        if resolvePlayer(key) == player or resolvePlayer(value) == player then
            return true
        end
        if key == player.UserId or value == player.UserId then
            return true
        end
        if key == player.Name or value == player.Name then
            return true
        end
    end

    return false
end

local function getCurrentSave()
    local ok, saveData = pcall(function()
        return Save.Get(LocalPlayer)
    end)
    if ok then
        return saveData
    end
    return nil
end

local function waitForSave(timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds

    while shouldRun() and os.clock() <= deadline do
        local saveData = getCurrentSave()
        if type(saveData) == "table" and type(saveData.Inventory) == "table" then
            return saveData
        end

        pcall(TradingCmds.GetState)
        pcall(Save.FetchPlayer, LocalPlayer)
        task.wait(0.25)
    end

    return getCurrentSave()
end

local function getInventory()
    local saveData = getCurrentSave()
    if type(saveData) ~= "table" or type(saveData.Inventory) ~= "table" then
        saveData = waitForSave(CONFIG.SaveLoadTimeout)
    end
    if type(saveData) == "table" and type(saveData.Inventory) == "table" then
        return saveData.Inventory
    end
    return nil
end

local function resolveEntryUid(uidKey, entryData)
    if isHex32(uidKey) then
        return uidKey
    end

    if type(entryData) == "table" then
        for _, key in ipairs({ "uid", "UID", "_uid", "uuid", "UUID" }) do
            local value = safeRawGet(entryData, key)
            if isHex32(value) then
                return value
            end
        end
    end

    return nil
end

local function resolveEntryName(entryData)
    if type(entryData) ~= "table" then
        return nil
    end

    local direct = firstStringField(entryData, { "id", "_id", "name", "Name" })
    if direct then
        return direct
    end

    local nestedData = safeRawGet(entryData, "data")
    if type(nestedData) == "table" then
        return firstStringField(nestedData, { "id", "_id", "name", "Name" })
    end

    return nil
end

local function resolveEntryAmount(entryData)
    if type(entryData) ~= "table" then
        return nil
    end

    local amount = firstNumberField(entryData, { "_am", "am", "amount", "Amount", "_amount", "qty", "Qty" })
    if amount then
        return amount
    end

    local nestedData = safeRawGet(entryData, "data")
    if type(nestedData) == "table" then
        amount = firstNumberField(nestedData, { "_am", "am", "amount", "Amount", "_amount", "qty", "Qty" })
        if amount then
            return amount
        end
    end

    return 1
end

local function getCandidateTables(entryData)
    local tables = {}

    if type(entryData) == "table" then
        table.insert(tables, entryData)

        local nestedData = safeRawGet(entryData, "data")
        if type(nestedData) == "table" then
            table.insert(tables, nestedData)
        end
    end

    return tables
end

local function findFirstPresentValue(entryData, keys)
    for _, candidateTable in ipairs(getCandidateTables(entryData)) do
        for _, key in ipairs(keys) do
            local value = safeRawGet(candidateTable, key)
            if value ~= nil then
                return value
            end
        end
    end
    return nil
end

local function normalizeVariant(value)
    local normalized = normalizeString(value or "")
    if normalized == "rb" then
        return "rainbow"
    end
    if normalized == "gold" then
        return "golden"
    end
    return normalized
end

local function stackMatchesTier(stack, wantedTier)
    if wantedTier == nil then
        return true
    end

    local numericWantedTier = tonumber(wantedTier)
    if not numericWantedTier then
        return false
    end

    local value = findFirstPresentValue(stack.data, {
        "tn",
        "tier",
        "Tier",
        "t",
        "lvl",
        "Lvl",
        "level",
        "Level",
    })

    local numericValue = tonumber(value)
    return numericValue ~= nil and numericValue == numericWantedTier
end

local function stackMatchesVariant(stack, wantedVariant)
    if wantedVariant == nil then
        return true
    end

    local normalizedWantedVariant = normalizeVariant(wantedVariant)
    if normalizedWantedVariant == "" then
        return true
    end

    local directVariant = findFirstPresentValue(stack.data, {
        "variant",
        "Variant",
        "petType",
        "PetType",
        "ptype",
        "PType",
    })

    local normalizedDirectVariant = normalizeVariant(directVariant)
    if normalizedDirectVariant ~= "" and normalizedDirectVariant == normalizedWantedVariant then
        return true
    end

    local petTypeCode = tonumber(findFirstPresentValue(stack.data, { "pt", "PT" }))
    if petTypeCode ~= nil then
        if normalizedWantedVariant == "golden" and petTypeCode == 1 then
            return true
        end
        if normalizedWantedVariant == "rainbow" and petTypeCode == 2 then
            return true
        end
    end

    if normalizedWantedVariant == "rainbow" then
        local rainbowFlag = findFirstPresentValue(stack.data, { "rainbow", "Rainbow", "rb", "RB" })
        if toBoolean(rainbowFlag) then
            return true
        end
    end

    if normalizedWantedVariant == "golden" then
        local goldenFlag = findFirstPresentValue(stack.data, { "gold", "Gold", "golden", "Golden" })
        if toBoolean(goldenFlag) then
            return true
        end
    end

    if normalizedWantedVariant == "normal" then
        if normalizedDirectVariant == "normal" then
            return true
        end
        if petTypeCode == nil or petTypeCode == 0 then
            local rainbowFlag = findFirstPresentValue(stack.data, { "rainbow", "Rainbow", "rb", "RB" })
            local goldenFlag = findFirstPresentValue(stack.data, { "gold", "Gold", "golden", "Golden" })
            if not toBoolean(rainbowFlag) and not toBoolean(goldenFlag) then
                return true
            end
        end
    end

    return false
end

local function collectOwnedStacks()
    local inventory = getInventory()
    local stacks = {}

    if type(inventory) ~= "table" then
        return stacks
    end

    for className, bucket in pairs(inventory) do
        if type(bucket) == "table" then
            for uidKey, entryData in pairs(bucket) do
                local uid = resolveEntryUid(uidKey, entryData)
                local name = resolveEntryName(entryData)
                local amount = resolveEntryAmount(entryData)

                if uid and name and amount and amount > 0 then
                    table.insert(stacks, {
                        class = tostring(className),
                        normalizedClass = normalizeClass(className),
                        name = tostring(name),
                        normalizedName = normalizeString(name),
                        uid = uid,
                        amount = amount,
                        remaining = amount,
                        data = entryData,
                    })
                end
            end
        end
    end

    table.sort(stacks, function(a, b)
        if a.normalizedName == b.normalizedName then
            if a.normalizedClass == b.normalizedClass then
                if a.amount == b.amount then
                    return a.uid < b.uid
                end
                return a.amount > b.amount
            end
            return a.normalizedClass < b.normalizedClass
        end
        return a.normalizedName < b.normalizedName
    end)

    return stacks
end

local function isItemSpecEnabled(spec)
    if type(spec) ~= "table" then
        return false
    end
    if spec.enabled == nil then
        return true
    end
    return toBoolean(spec.enabled)
end

local function itemSpecMatchesStack(spec, stack)
    if type(spec) ~= "table" or type(stack) ~= "table" then
        return false
    end

    if spec.class and normalizeClass(spec.class) ~= stack.normalizedClass then
        return false
    end

    if not stackMatchesTier(stack, spec.tier) then
        return false
    end

    if not stackMatchesVariant(stack, spec.variant) then
        return false
    end

    local wantedName = normalizeString(spec.name or "")
    if wantedName == "" then
        return false
    end

    local matchMode = normalizeString(spec.match or "exact")
    if matchMode == "contains" then
        return stack.normalizedName:find(wantedName, 1, true) ~= nil
    end

    return stack.normalizedName == wantedName
end

local function buildTradePlan()
    local plan = {
        entries = {},
        errors = {},
    }

    if type(CONFIG.ItemList) ~= "table" or #CONFIG.ItemList == 0 then
        table.insert(plan.errors, "CONFIG.ItemList is empty.")
        return nil, plan.errors[1], plan
    end

    local stacks = collectOwnedStacks()

    for index, spec in ipairs(CONFIG.ItemList) do
        if isItemSpecEnabled(spec) then
            local name = trim(spec.name or "")
            if name == "" then
                table.insert(plan.errors, string.format("ItemList[%d] is missing a valid name.", index))
                return nil, plan.errors[#plan.errors], plan
            end

            local required = spec.required ~= false
            local allowPartial = spec.allowPartial
            if allowPartial == nil then
                allowPartial = CONFIG.AllowPartialAmountByDefault
            end
            allowPartial = toBoolean(allowPartial)

            local wantedAmount = coerceWantedAmount(spec.amount, 1)
            local matches = {}
            local totalAvailable = 0

            for _, stack in ipairs(stacks) do
                if stack.remaining > 0 and itemSpecMatchesStack(spec, stack) then
                    table.insert(matches, stack)
                    totalAvailable = totalAvailable + stack.remaining
                end
            end

            if totalAvailable <= 0 then
                if required then
                    local classSuffix = spec.class and (" in class " .. tostring(spec.class)) or ""
                    table.insert(plan.errors, string.format("Missing item: %s%s.", name, classSuffix))
                    return nil, plan.errors[#plan.errors], plan
                end
            else
                local targetAmount = wantedAmount == "all" and totalAvailable or wantedAmount
                if totalAvailable < targetAmount then
                    if not allowPartial then
                        table.insert(
                            plan.errors,
                            string.format(
                                "Not enough '%s' (wanted %s, have %s).",
                                name,
                                formatAmount(targetAmount),
                                formatAmount(totalAvailable)
                            )
                        )
                        return nil, plan.errors[#plan.errors], plan
                    end
                    targetAmount = totalAvailable
                end

                local remainingToTake = targetAmount
                local selections = {}

                for _, stack in ipairs(matches) do
                    if remainingToTake <= 0 then
                        break
                    end

                    local takeAmount = math.min(stack.remaining, remainingToTake)
                    if takeAmount > 0 then
                        table.insert(selections, {
                            class = stack.class,
                            uid = stack.uid,
                            amount = takeAmount,
                            name = stack.name,
                        })
                        stack.remaining = stack.remaining - takeAmount
                        remainingToTake = remainingToTake - takeAmount
                    end
                end

                if remainingToTake > 0 then
                    table.insert(
                        plan.errors,
                        string.format(
                            "Could not fully allocate '%s' (missing %s after planning).",
                            name,
                            formatAmount(remainingToTake)
                        )
                    )
                    return nil, plan.errors[#plan.errors], plan
                end

                table.insert(plan.entries, {
                    index = index,
                    name = name,
                    requestedAmount = targetAmount,
                    selections = selections,
                    class = spec.class,
                    match = spec.match or "exact",
                })
            end
        end
    end

    if #plan.entries == 0 then
        table.insert(plan.errors, "No enabled items produced a trade plan.")
        return nil, plan.errors[1], plan
    end

    return plan, nil, plan
end

local function getTradeState()
    local ok, state = pcall(TradingCmds.GetState)
    if ok then
        return state
    end
    return nil
end

local function getTradeId(state)
    if type(state) == "table" then
        return safeRawGet(state, "_id")
    end
    return nil
end

local function stateContainsPlayer(state, player)
    if type(state) ~= "table" or not player then
        return false
    end

    local playersField = safeRawGet(state, "_players")
    return tableHasPlayerReference(playersField, player)
end

local function getOtherPlayerFromState(state)
    if type(state) ~= "table" then
        return nil
    end

    local playersField = safeRawGet(state, "_players")
    if type(playersField) ~= "table" then
        return nil
    end

    local seen = {}

    local function remember(candidate)
        local player = resolvePlayer(candidate)
        if player and player ~= LocalPlayer then
            local key = getPlayerKey(player)
            if not seen[key] then
                seen[key] = true
                return player
            end
        end
        return nil
    end

    for key, value in pairs(playersField) do
        local playerFromValue = remember(value)
        if playerFromValue then
            return playerFromValue
        end

        local playerFromKey = remember(key)
        if playerFromKey then
            return playerFromKey
        end
    end

    return nil
end

local function getPlayerTradeIndex(state, player)
    if type(state) ~= "table" or not player then
        return nil
    end

    local playerIndexMethod = safeRawGet(state, "PlayerIndex")
    if type(playerIndexMethod) == "function" then
        local okIndex, result = pcall(playerIndexMethod, state, player)
        if okIndex and type(result) == "number" and result >= 1 then
            return result
        end
    end

    local playersField = safeRawGet(state, "_players")
    if type(playersField) ~= "table" then
        return nil
    end

    for index, candidate in ipairs(playersField) do
        if candidate == player then
            return index
        end

        local resolvedCandidate = resolvePlayer(candidate)
        if resolvedCandidate == player then
            return index
        end

        if typeof(candidate) == "Instance" and candidate:IsA("Player") then
            if player.UserId and candidate.UserId == player.UserId then
                return index
            end
            if player.Name and candidate.Name == player.Name then
                return index
            end
        end
    end

    return nil
end

local function getReadyValueForPlayer(state, player)
    if type(state) ~= "table" or not player then
        return false
    end

    local playerIndex = getPlayerTradeIndex(state, player)

    local function getPlayerFlagValue(fieldName)
        local field = safeRawGet(state, fieldName)
        if type(field) ~= "table" then
            return false
        end

        if playerIndex and field[playerIndex] ~= nil then
            return toBoolean(field[playerIndex])
        end

        if field[player] ~= nil then
            return toBoolean(field[player])
        end

        if player.UserId and field[player.UserId] ~= nil then
            return toBoolean(field[player.UserId])
        end

        if player.Name and field[player.Name] ~= nil then
            return toBoolean(field[player.Name])
        end

        for key, value in pairs(field) do
            if resolvePlayer(key) == player then
                return toBoolean(value)
            end

            if player.UserId and key == player.UserId then
                return toBoolean(value)
            end

            if player.Name and key == player.Name then
                return toBoolean(value)
            end

            if resolvePlayer(value) == player then
                return toBoolean(key)
            end

            if player.UserId and value == player.UserId then
                return toBoolean(key)
            end

            if player.Name and value == player.Name then
                return toBoolean(key)
            end
        end

        return false
    end

    return getPlayerFlagValue("_ready")
end

local function getConfirmedValueForPlayer(state, player)
    if type(state) ~= "table" or not player then
        return false
    end

    local confirmedField = safeRawGet(state, "_confirmed")
    if type(confirmedField) ~= "table" then
        return false
    end

    local playerIndex = getPlayerTradeIndex(state, player)
    if playerIndex and confirmedField[playerIndex] ~= nil then
        return toBoolean(confirmedField[playerIndex])
    end

    if confirmedField[player] ~= nil then
        return toBoolean(confirmedField[player])
    end

    if player.UserId and confirmedField[player.UserId] ~= nil then
        return toBoolean(confirmedField[player.UserId])
    end

    if player.Name and confirmedField[player.Name] ~= nil then
        return toBoolean(confirmedField[player.Name])
    end

    for key, value in pairs(confirmedField) do
        if resolvePlayer(key) == player then
            return toBoolean(value)
        end

        if player.UserId and key == player.UserId then
            return toBoolean(value)
        end

        if player.Name and key == player.Name then
            return toBoolean(value)
        end

        if resolvePlayer(value) == player then
            return toBoolean(key)
        end

        if player.UserId and value == player.UserId then
            return toBoolean(key)
        end

        if player.Name and value == player.Name then
            return toBoolean(key)
        end
    end

    return false
end

local function callTradingFunction(name, ...)
    local fn = TradingCmds[name]
    if type(fn) ~= "function" then
        return false, string.format("TradingCmds.%s is not available.", tostring(name))
    end

    local ok, result = pcall(fn, ...)
    if not ok then
        return false, tostring(result)
    end

    return true, result
end

local function getNetworkRemote(remoteName)
    if not NetworkFolder then
        return nil
    end

    if RemoteCache[remoteName] ~= nil then
        return RemoteCache[remoteName]
    end

    local remote = NetworkFolder:FindFirstChild(remoteName)
    RemoteCache[remoteName] = remote or false
    return remote
end

local function invokeDirectTradeRemote(remoteName, ...)
    local remote = getNetworkRemote(remoteName)
    if not remote or remote == false then
        return false, "remote not found: " .. tostring(remoteName)
    end

    local args = table.pack(...)
    local ok, result = pcall(function()
        return remote:InvokeServer(table.unpack(args, 1, args.n))
    end)

    if not ok then
        return false, tostring(result)
    end

    return true, result
end

local ProcessedPlayers = {}
local ProcessedTradeIds = {}

local function loadProcessedPlayers()
    if not CONFIG.PersistAlreadyTradedPlayers then
        return
    end

    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        warnLog("Persistence requested but isfile/readfile is unavailable. Falling back to session memory.")
        return
    end

    local exists = false
    local okExists, existsResult = pcall(isfile, CONFIG.PersistenceFile)
    if okExists then
        exists = existsResult
    end
    if not exists then
        return
    end

    local okRead, content = pcall(readfile, CONFIG.PersistenceFile)
    if not okRead or type(content) ~= "string" or content == "" then
        return
    end

    local okDecode, decoded = pcall(function()
        return HttpService:JSONDecode(content)
    end)

    if okDecode and type(decoded) == "table" then
        for key, value in pairs(decoded) do
            if value then
                ProcessedPlayers[tostring(key)] = true
            end
        end
        log("Loaded processed players from " .. CONFIG.PersistenceFile)
    else
        warnLog("Failed to decode persistence file: " .. CONFIG.PersistenceFile)
    end
end

local function saveProcessedPlayers()
    if not CONFIG.PersistAlreadyTradedPlayers then
        return
    end

    if type(writefile) ~= "function" then
        warnLog("Persistence requested but writefile is unavailable.")
        return
    end

    local okEncode, payload = pcall(function()
        return HttpService:JSONEncode(ProcessedPlayers)
    end)
    if not okEncode then
        warnLog("Failed to encode processed players payload.")
        return
    end

    local okWrite, err = pcall(writefile, CONFIG.PersistenceFile, payload)
    if not okWrite then
        warnLog("Failed to write persistence file: " .. tostring(err))
    end
end

local function markPlayerProcessed(player)
    if not CONFIG.RememberPlayersThisSession then
        return
    end

    local key = getPlayerKey(player)
    ProcessedPlayers[key] = true
    saveProcessedPlayers()
    log("Marked player as processed: " .. tostring(player and player.Name or player))
end

local function isPlayerProcessed(player)
    if not CONFIG.SkipAlreadyTradedPlayers then
        return false
    end

    local key = getPlayerKey(player)
    return ProcessedPlayers[key] == true
end

local function listContainsPlayer(list, player)
    if type(list) ~= "table" or #list == 0 or not player then
        return false
    end

    for _, entry in ipairs(list) do
        if type(entry) == "string" then
            if normalizeString(entry) == normalizeString(player.Name) then
                return true
            end
        elseif type(entry) == "number" then
            if player.UserId == entry then
                return true
            end
        end
    end

    return false
end

local function isPlayerAllowed(player)
    if not player or player == LocalPlayer then
        return false, "invalid player"
    end

    if listContainsPlayer(CONFIG.BlockedPlayers, player) then
        return false, "player is blocked"
    end

    if type(CONFIG.AllowedPlayers) == "table" and #CONFIG.AllowedPlayers > 0 and not listContainsPlayer(CONFIG.AllowedPlayers, player) then
        return false, "player is not whitelisted"
    end

    if isPlayerProcessed(player) then
        return false, "player already processed"
    end

    return true, nil
end

local function findIncomingRequestPlayer()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local okAllowed, reason = isPlayerAllowed(player)
            local hasIncoming = false

            local okHas, result = callTradingFunction("HasRequestFromPlayer", player)
            if okHas then
                hasIncoming = toBoolean(result)
            end

            if hasIncoming then
                if okAllowed then
                    return player
                end

                log(string.format("Ignoring request from %s (%s)", player.Name, tostring(reason)))
                if CONFIG.RejectSkippedRequests then
                    callTradingFunction("Reject", player)
                end
            end
        end
    end

    return nil
end

local function waitForTradeWithPlayer(player, timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds

    while shouldRun() and os.clock() <= deadline do
        local state = getTradeState()
        if state and (not player or stateContainsPlayer(state, player)) then
            return state
        end
        task.wait(0.10)
    end

    local finalState = getTradeState()
    if finalState and (not player or stateContainsPlayer(finalState, player)) then
        return finalState
    end
    return nil
end

local function waitForOtherReady(tradeId, otherPlayer)
    local deadline = os.clock() + CONFIG.OtherReadyTimeout
    local lastReadyResend = 0

    while shouldRun() and os.clock() <= deadline do
        local state = getTradeState()
        if not state or getTradeId(state) ~= tradeId then
            return false, "trade closed while waiting for other ready"
        end

        if otherPlayer and (getReadyValueForPlayer(state, otherPlayer) or getConfirmedValueForPlayer(state, otherPlayer)) then
            log("Other player is ready for confirm.")
            return true
        end

        if CONFIG.KeepReadySynced and not getReadyValueForPlayer(state, LocalPlayer) then
            if os.clock() - lastReadyResend >= CONFIG.ReadyResendInterval then
                lastReadyResend = os.clock()
                callTradingFunction("SetReady", true)
            end
        end

        task.wait(0.20)
    end

    return false, "other ready timeout"
end

local function waitForTradeClose(tradeId, timeoutSeconds)
    local deadline = os.clock() + timeoutSeconds

    while shouldRun() and os.clock() <= deadline do
        local state = getTradeState()
        if not state then
            return true
        end

        local currentTradeId = getTradeId(state)
        if currentTradeId ~= tradeId then
            return true
        end

        task.wait(0.15)
    end

    return false
end

local function sendReadySignal(state)
    local okReady, readyError = callTradingFunction("SetReady", true)
    if okReady then
        return true
    end

    if not CONFIG.UseDirectReadyRemoteFallback then
        return false, readyError
    end

    local currentTradeId = getTradeId(state)
    local currentCounter = state and safeRawGet(state, "_counter")
    local okRemote, remoteError = invokeDirectTradeRemote("Server: Trading: Set Ready", currentTradeId, true, currentCounter)
    if okRemote then
        log(string.format("Direct ready remote invoked. tradeId=%s counter=%s", tostring(currentTradeId), tostring(currentCounter)))
        return true
    end

    return false, string.format("wrapper=%s | direct=%s", tostring(readyError), tostring(remoteError))
end

local function sendConfirmSignal(state, otherPlayer)
    local currentState = getTradeState() or state
    local currentTradeId = getTradeId(currentState)
    local currentCounter = currentState and safeRawGet(currentState, "_counter")
    local localIndex = getPlayerTradeIndex(currentState, LocalPlayer)
    local otherIndex = getPlayerTradeIndex(currentState, otherPlayer)

    if CONFIG.DebugTradeStateAtConfirm then
        log(string.format(
            "Confirm snapshot: tradeId=%s counter=%s localIndex=%s otherIndex=%s localReady=%s otherReady=%s localConfirmed=%s otherConfirmed=%s",
            tostring(currentTradeId),
            tostring(currentCounter),
            tostring(localIndex),
            tostring(otherIndex),
            tostring(getReadyValueForPlayer(currentState, LocalPlayer)),
            tostring(otherPlayer and getReadyValueForPlayer(currentState, otherPlayer) or "n/a"),
            tostring(getConfirmedValueForPlayer(currentState, LocalPlayer)),
            tostring(otherPlayer and getConfirmedValueForPlayer(currentState, otherPlayer) or "n/a")
        ))
    end

    local okConfirm, confirmError = callTradingFunction("SetConfirmed", true)
    if okConfirm then
        log(string.format("Wrapper confirm succeeded. tradeId=%s counter=%s", tostring(currentTradeId), tostring(currentCounter)))
        return true
    end

    if CONFIG.UseDirectConfirmRemoteFallback then
        local okRemote, remoteResult = invokeDirectTradeRemote("Server: Trading: Set Confirmed", currentTradeId, true, currentCounter)
        if okRemote then
            log(string.format("Direct confirm remote invoked. tradeId=%s counter=%s", tostring(currentTradeId), tostring(currentCounter)))
            return true
        end

        if okConfirm then
            return false, "direct confirm remote failed: " .. tostring(remoteResult)
        end

        return false, string.format("wrapper=%s | direct=%s", tostring(confirmError), tostring(remoteResult))
    end

    return false, tostring(confirmError)
end

local function waitForLocalConfirm(tradeId, otherPlayer)
    local deadline = os.clock() + CONFIG.ConfirmTimeout
    local lastConfirmAttempt = -1000000
    local lastReadyResend = 0

    while shouldRun() and os.clock() <= deadline do
        local state = getTradeState()
        if not state or getTradeId(state) ~= tradeId then
            return true, "trade closed during confirm"
        end

        if getConfirmedValueForPlayer(state, LocalPlayer) then
            return true, "local confirm registered"
        end

        local otherReady =
            (not otherPlayer)
            or getReadyValueForPlayer(state, otherPlayer)
            or getConfirmedValueForPlayer(state, otherPlayer)

        if CONFIG.ConfirmWithoutOtherReadyDetection or otherReady then
            if CONFIG.KeepReadySynced and not getReadyValueForPlayer(state, LocalPlayer) then
                if os.clock() - lastReadyResend >= CONFIG.ReadyResendInterval then
                    lastReadyResend = os.clock()
                    local okReadySignal, readySignalError = sendReadySignal(state)
                    if not okReadySignal then
                        warnLog("Ready resend failed during confirm loop: " .. tostring(readySignalError))
                    end
                end
            end

            if not CONFIG.KeepConfirmSynced or os.clock() - lastConfirmAttempt >= CONFIG.ConfirmRetryInterval then
                lastConfirmAttempt = os.clock()
                log("Sending final confirm.")
                local okConfirm, confirmError = sendConfirmSignal(state, otherPlayer)
                if not okConfirm then
                    warnLog("SetConfirmed failed during retry loop: " .. tostring(confirmError))
                end
            end
        end

        task.wait(0.15)
    end

    return false, "confirm timeout"
end

local function applyTradePlan(plan)
    for _, entry in ipairs(plan.entries) do
        for _, selection in ipairs(entry.selections) do
            local state = getTradeState()
            if not state then
                return false, "trade is no longer active"
            end

            log(
                string.format(
                    "Setting item %s x%s [%s / %s]",
                    selection.name,
                    formatAmount(selection.amount),
                    selection.class,
                    selection.uid
                )
            )

            local okSet, err = callTradingFunction("SetItem", selection.class, selection.uid, selection.amount)
            if not okSet then
                return false, "SetItem failed: " .. tostring(err)
            end

            task.wait(CONFIG.BetweenSetItemDelay)
        end
    end

    return true
end

local function previewTradePlan(plan)
    local lines = {}
    for _, entry in ipairs(plan.entries) do
        table.insert(lines, string.format("- %s x%s", entry.name, formatAmount(entry.requestedAmount)))
    end
    return table.concat(lines, "\n")
end

local function processTradeState(state, fallbackPlayer)
    local tradeId = getTradeId(state)
    if not tradeId then
        return false, "active trade has no id"
    end

    if ProcessedTradeIds[tradeId] then
        return false, "trade already handled"
    end

    ProcessedTradeIds[tradeId] = true

    local otherPlayer = getOtherPlayerFromState(state) or fallbackPlayer
    if not otherPlayer then
        return false, "could not resolve other player"
    end

    local okAllowed, reason = isPlayerAllowed(otherPlayer)
    if not okAllowed then
        log(string.format("Declining active trade with %s (%s)", otherPlayer.Name, tostring(reason)))
        callTradingFunction("Decline")
        return false, reason
    end

    if CONFIG.RejectIfItemListEmpty and (#CONFIG.ItemList == 0) then
        callTradingFunction("Decline")
        return false, "item list is empty"
    end

    local plan, planError = buildTradePlan()
    if not plan then
        warnLog("Trade plan failed: " .. tostring(planError))
        if CONFIG.DeclineIfPlanFails then
            callTradingFunction("Decline")
        end
        return false, planError
    end

    log("Trade plan for " .. otherPlayer.Name .. ":\n" .. previewTradePlan(plan))

    local okApply, applyError = applyTradePlan(plan)
    if not okApply then
        warnLog("Trade apply failed: " .. tostring(applyError))
        if CONFIG.DeclineIfApplyFails then
            callTradingFunction("Decline")
        end
        return false, applyError
    end

    if CONFIG.TradeMessage ~= "" then
        callTradingFunction("Message", CONFIG.TradeMessage)
    end

    task.wait(CONFIG.ReadyDelay)

    local okReady, readyError = sendReadySignal(getTradeState() or state)
    if not okReady then
        if CONFIG.DeclineIfApplyFails then
            callTradingFunction("Decline")
        end
        return false, "SetReady failed: " .. tostring(readyError)
    end

    log("Ready sent.")

    if not CONFIG.ConfirmWithoutOtherReadyDetection then
        local otherReady, readyReason = waitForOtherReady(tradeId, otherPlayer)
        if not otherReady then
            warnLog("Other player did not become ready: " .. tostring(readyReason))
            if CONFIG.DeclineIfOtherNeverReady then
                callTradingFunction("Decline")
            end
            return false, readyReason
        end
    else
        log("Skipping explicit other-ready wait. Entering confirm loop immediately.")
    end

    task.wait(CONFIG.PostOtherReadyConfirmDelay)

    local confirmed, confirmReason = waitForLocalConfirm(tradeId, otherPlayer)
    if not confirmed then
        warnLog("Final confirm failed: " .. tostring(confirmReason))
        if CONFIG.DeclineIfConfirmFails then
            callTradingFunction("Decline")
        end
        return false, confirmReason
    end

    task.wait(CONFIG.ConfirmDelay)

    local closed = waitForTradeClose(tradeId, CONFIG.TradeCloseTimeout)
    if closed and CONFIG.MarkPlayerAsTradedAfterConfirmFlow then
        markPlayerProcessed(otherPlayer)
    end

    return true, closed and "trade flow completed" or "confirm sent, close timeout reached"
end

local function acceptIncomingRequest(player)
    if not player then
        return false, "missing player"
    end

    if CONFIG.RejectIfItemListEmpty and (#CONFIG.ItemList == 0) then
        if CONFIG.RejectSkippedRequests then
            callTradingFunction("Reject", player)
        end
        return false, "item list is empty"
    end

    local plan, planError = buildTradePlan()
    if not plan then
        warnLog("Refusing request from " .. player.Name .. " because plan failed: " .. tostring(planError))
        if CONFIG.RejectSkippedRequests then
            callTradingFunction("Reject", player)
        end
        return false, planError
    end

    log("Accepting request from " .. player.Name)
    log("Prebuilt plan:\n" .. previewTradePlan(plan))

    local stillPendingOk, stillPending = callTradingFunction("HasRequestFromPlayer", player)
    if stillPendingOk and not toBoolean(stillPending) then
        return false, "request disappeared before accept"
    end

    local okRequest, requestError = callTradingFunction("Request", player)
    if not okRequest then
        return false, "Request failed: " .. tostring(requestError)
    end

    task.wait(CONFIG.AcceptDelay)

    local state = waitForTradeWithPlayer(player, CONFIG.AcceptTimeout)
    if not state then
        return false, "trade did not open after accept"
    end

    return processTradeState(state, player)
end

loadProcessedPlayers()
waitForSave(CONFIG.SaveLoadTimeout)

function Controller.Stop(reason)
    Controller.Running = false
    Controller.StopReason = reason or Controller.StopReason or "manual stop"
    if rawget(globalEnv, GLOBAL_KEY) == Controller then
        globalEnv[GLOBAL_KEY] = nil
    end
    log("Controller stopped. reason=" .. tostring(Controller.StopReason))
end

function Controller.BuildTradePlan()
    return buildTradePlan()
end

function Controller.GetProcessedPlayers()
    return ProcessedPlayers
end

function Controller.ResetProcessedPlayers()
    clearDictionary(ProcessedPlayers)
    saveProcessedPlayers()
end

task.spawn(function()
    log("Controller started. Version " .. Controller.Version .. " session=" .. tostring(Controller.SessionId) .. " config=" .. tostring(Controller.ConfigSource))

    while shouldRun() and CONFIG.Enabled do
        local okLoop, loopError = pcall(function()
            local activeState = getTradeState()

            if CONFIG.ProcessExistingActiveTrade and activeState then
                local activeTradeId = getTradeId(activeState)
                if activeTradeId and not ProcessedTradeIds[activeTradeId] then
                    local okProcess, reason = processTradeState(activeState)
                    if not okProcess then
                        log("Active trade processing ended: " .. tostring(reason))
                    else
                        log("Active trade processed successfully.")
                    end
                    return
                end
            end

            if not activeState then
                local requester = findIncomingRequestPlayer()
                if requester then
                    local okAccept, reason = acceptIncomingRequest(requester)
                    if okAccept then
                        log("Trade with " .. requester.Name .. " processed.")
                    else
                        log("Trade request from " .. requester.Name .. " ended: " .. tostring(reason))
                    end
                    return
                end
            end
        end)

        if not okLoop then
            warnLog("Main loop error: " .. tostring(loopError))
        end

        task.wait(CONFIG.LoopInterval)
    end

    log("Main loop exited.")
end)

return Controller
