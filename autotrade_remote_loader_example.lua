_G.AutoTradeSettings = {
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

    Users = {},
    BlockedPlayers = {},

    TradeMessage = "cadeau!",
    AllowPartialAmountByDefault = false,

    Items = {
        { Class = "Misc", Item = "Pinata", Amount = 100, Match = "contains", AllowPartial = true, Required = false },
        { Class = "Misc", Item = "Coin Jar", Amount = 100, Match = "contains", AllowPartial = true, Required = false },
        { Class = "Misc", Item = "Comet", Amount = 250, AllowPartial = true, Required = false },
        { Class = "Misc", Item = "Lucky Block", Amount = 100, Match = "contains", AllowPartial = true, Required = false },
        { Class = "Pet", Item = "Blooming Axolotl", Amount = 100, Variant = "rainbow", AllowPartial = true, Required = false },
        { Class = "Enchant", Item = "Coins", Amount = 1, Tier = 7, AllowPartial = true, Required = false },
        { Class = "Enchant", Item = "Tap Power", Amount = 1, Tier = 7, AllowPartial = true, Required = false },
        { Class = "Enchant", Item = "Fortune", Amount = 1, AllowPartial = true, Required = false },
        { Class = "Potion", Item = "Coins", Amount = 100, Tier = 7, AllowPartial = true, Required = false },
        { Class = "Potion", Item = "Damage", Amount = 100, Tier = 7, AllowPartial = true, Required = false },
    },
}

loadstring(game:HttpGet("https://YOUR-RAW-URL-HERE/autotrade_all_in_one.lua"))()
