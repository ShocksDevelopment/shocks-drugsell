Config = {}

-- Player command for persistent drug-selling reputation/stats.
-- Players can run /drugstats; admins can run /drugstats <serverId>.
Config.Commands = {
    DrugStats = 'drugstats',
}

---------------------------------------------------------------------
-- SHOCKS Drug Selling - zone-based configuration
-- QBCore/Qbox resource configuration. Both client and server enforce these
-- zone, reputation, minimum-level, metadata-pricing and police settings.
---------------------------------------------------------------------

Config.Setup = {
    debug = false,

    -- 'ox_target', 'qb-target', 'qtarget', 'custom', or 'none'.
    target = 'ox_target',

    notify = 'ox_lib',
    menu = 'ox_lib',
    dispatch = 'custom',
    versionCheck = true,
    interactKey = 38, -- E
    requestWait = 10000,

    blacklistJobs = { 'police', 'ambulance' },

    dynamic = true,
    excludeScriptPeds = true,

    -- false = allow ambient human peds without requiring Config.PedModels membership.
    -- true = only allow peds listed in Config.PedModels.
    requirePedModelList = false,
}
---------------------------------------------------------------------
-- Drugs available for sale
-- Item names are preserved from your current config.
-- Amounts are the number of items the NPC transaction can request.
-- minLevel is the personal Drug Selling level required to sell that item;
-- it is separate from Gang MDT gang XP.
---------------------------------------------------------------------
Config.Drugs = {
    ['ogkush_baggy'] = {
        label = 'OG Kush',
        minLevel = 0, -- Minimum personal drug-selling level
        minPrice = 50,
        maxPrice = 95,
        minAmount = 1,
        maxAmount = 10,
        successRate = 70,
        failRate = 30,
        useMetadataPrice = false,
        prop = 'prop_meth_bag_01',
    },
    ['bananakush_baggy'] = {
        label = 'Banana Kush',
        minLevel = 1, -- Minimum personal drug-selling level
        minPrice = 50,
        maxPrice = 95,
        minAmount = 1,
        maxAmount = 10,
        successRate = 70,
        failRate = 30,
        useMetadataPrice = false,
        prop = 'prop_meth_bag_01',
    },
    ['purplehaze_baggy'] = {
        label = 'Purple Haze',
        minLevel = 2, -- Minimum personal drug-selling level
        minPrice = 100,
        maxPrice = 150,
        minAmount = 1,
        maxAmount = 5,
        successRate = 70,
        failRate = 30,
        useMetadataPrice = false,
        prop = 'prop_meth_bag_01',
    },
    ['bluedream_baggy'] = {
        label = 'Blue Dream',
        minLevel = 3, -- Minimum personal drug-selling level
        minPrice = 150,
        maxPrice = 250,
        minAmount = 1,
        maxAmount = 3,
        successRate = 60,
        failRate = 40,
        useMetadataPrice = false,
        prop = 'prop_meth_bag_01',
    },
    ['bag_of_coke'] = {
        label = 'Cocaine',
        minLevel = 4, -- Minimum personal drug-selling level
        minPrice = 260,
        maxPrice = 300,
        minAmount = 1,
        maxAmount = 3,
        successRate = 100,
        failRate = 0,
        useMetadataPrice = true,
        prop = 'prop_meth_bag_01',
    },
    ['meth'] = {
        label = 'Methamphetamine',
        minLevel = 5, -- Minimum personal drug-selling level
        minPrice = 300,
        maxPrice = 360,
        minAmount = 1,
        maxAmount = 3,
        successRate = 60,
        failRate = 40,
        useMetadataPrice = true,
        prop = 'prop_meth_bag_01',
    },
}

---------------------------------------------------------------------
-- Interaction, timing, and sale restrictions
---------------------------------------------------------------------
Config.InteractionDistance = 2.0
Config.SellingDuration = 2 -- seconds

-- NPC transaction behaviour. Customers step closer where possible, face the
-- player during the deal, and cannot be repeatedly farmed during the cooldown.
Config.NPCBehavior = {
    approach = true,
    playerScenario = 'WORLD_HUMAN_DRUG_DEALER', -- Brief deal stance during the progress phase
    approachDistance = 1.15,
    approachTimeout = 2500,
    maxSaleDistance = 3.25,
    faceDuration = 350,
    lookDuration = 7000,
    customerCooldown = 60000, -- 60 seconds before the same ped can be approached again
}

-- Jobs that cannot sell. Keep this aligned with Setup.blacklistJobs.
Config.BlacklistJobs = { 'police', 'ambulance' }

-- Cash type used for NPC sales. The reference setup uses dirty money.
-- Supported handling depends on the server bridge; use 'cash' if required.
Config.SaleAccount = 'cash'

---------------------------------------------------------------------
-- Police scaling and per-zone police requirements
---------------------------------------------------------------------
Config.Police = {
    jobs = { 'police', 'sheriff' },
    risk = true,
    percent = 5, -- price increase per online police officer, when enabled
}

-- General call chance. Zone-specific callChance values override this value.
Config.CallCopsChance = 10

Config.DispatchAlert = {
    title = 'Suspicious Activity',
    message = 'A person attempted to sell drugs and failed.',
    radius = 50.0,
    alertChance = 100, -- Chance to send dispatch after the sale-failure call roll
}
Config.DispatchTriggerDirect = true -- Enable direct core_dispatch triggering

---------------------------------------------------------------------
-- SHOCKS Gang MDT V3 integration
-- Calls HandleTurfActivity once after a successful paid sale. The MDT
-- remains authoritative for turf eligibility, peaceful-turf suppression,
-- influence and gang XP. Do not also call AddTurfInfluenceByActivity here:
-- that would award influence twice.
---------------------------------------------------------------------
Config.GangMDT = {
    enabled = true,
    resource = 'SHOCKS-GangMDT',
    activity = 'drug_sale', -- configured in SHOCKS-GangMDT/config/TurfInfluence.lua
}

---------------------------------------------------------------------
-- Reputation and progression
---------------------------------------------------------------------
Config.Reputation = {
    levelUp = 25000,
    levels = {
        [1] = {
            label = 'Street Rookie',
            description = 'You are just starting out.',
            priceBoost = 0,
            reduceReject = 0,
            reduceRobbery = 0,
        },
        [2] = {
            label = 'Known Face',
            description = 'A few locals recognise you.',
            priceBoost = 5,
            reduceReject = 10,
            reduceRobbery = 0,
        },
        [3] = {
            label = 'Street Regular',
            description = 'You have built a small reputation.',
            priceBoost = 15,
            reduceReject = 20,
            reduceRobbery = 10,
        },
        [4] = {
            label = 'Trusted Dealer',
            description = 'Customers are more willing to deal with you.',
            priceBoost = 25,
            reduceReject = 30,
            reduceRobbery = 20,
        },
        [5] = {
            label = 'Local Plug',
            description = 'You are well established in the area.',
            priceBoost = 40,
            reduceReject = 40,
            reduceRobbery = 30,
        },
    },
}

---------------------------------------------------------------------
-- Sale / rejection / pickup animations
---------------------------------------------------------------------
Config.Animations = {
    -- Player hands the product across instead of playing a looping dealer scenario.
    accepted = {
        dict = 'mp_common',
        clip = 'givetake1_a',
        duration = 1400,
        prop = 'prop_meth_bag_01',
        flag = 49,
    },
    -- NPC mirrors the hand-off so both sides react to a completed transaction.
    npcAccepted = {
        dict = 'mp_common',
        clip = 'givetake1_a',
        duration = 1400,
        flag = 49,
    },
    -- No phone prop on the player for a simple rejected deal.
    rejected = {
        dict = 'gestures@m@standing@casual',
        clip = 'gesture_no_way',
        duration = 1250,
        flag = 49,
    },
    -- A suspicious customer checks a phone after rejecting the offer.
    npcRejected = {
        dict = 'cellphone@',
        clip = 'cellphone_call_listen_base',
        duration = 2500,
        prop = 'prop_npc_phone_02',
        flag = 49,
    },
    claimItems = {
        dict = 'pickup_object',
        clip = 'pickup_low',
        duration = 1500,
        flag = 49,
    },
}

---------------------------------------------------------------------
-- Optional metadata pricing
-- If an item has no purity metadata, the code should fall back to that
-- item's minPrice/maxPrice above. Metadata pricing requires server logic.
---------------------------------------------------------------------
Config.Metadata = {
    enabled = true,
    key = 'purity',
    pricePerPurity = 2.5,
    perfectBonus = 100,
    fallbackToConfiguredPrice = true,
    items = {
        ['bag_of_coke'] = true,
        ['meth'] = true,
    },
}

---------------------------------------------------------------------
-- Zones
-- `size` is the zone radius, in metres. Zone entries can override the
-- global price/call settings and control police, robbery, cooldowns, caps,
-- XP, blips and which drugs are available in each area.
---------------------------------------------------------------------
local allDrugs = {
    'ogkush_baggy',
    'bananakush_baggy',
    'purplehaze_baggy',
    'bluedream_baggy',
    'bag_of_coke',
    'meth',
}

local ignoredPoliceModels = {
    's_f_y_cop_01',
    's_f_y_sheriff_01',
    's_m_m_snowcop_01',
    's_m_y_cop_01',
    's_m_y_hwaycop_01',
    's_m_y_ranger_01',
    's_m_y_sheriff_01',
    's_m_y_swat_01',
    's_m_m_paramedic_01',
    's_m_y_paramedic_01',
    'u_m_m_paramedic_01',
    's_m_y_fireman_01',
}
Config.IgnoredPedModels = ignoredPoliceModels

local defaultBlip = {
    enabled = true,
    showRadius = true,
    sprite = 51,
    color = 1,
    scale = 0.8,
}

local function zone(name, coords, size, settings)
    settings = settings or {}
    return {
        name = name,
        coords = coords,
        size = size,
        daytime = settings.daytime ~= false,
        account = settings.account or Config.SaleAccount,
        metadataPricing = settings.metadataPricing ~= false,
        policeRequired = settings.policeRequired or 0,
        robbery = {
            enabled = settings.robberyEnabled ~= false,
            chance = settings.robberyChance or 5,
        },
        anonymousCalls = settings.anonymousCalls ~= false,
        callChance = settings.callChance or Config.CallCopsChance,
        cooldown = settings.cooldown or 0,
        limit = settings.limit or 0, -- 0 = unlimited
        xp = settings.xp or { min = 5, max = 15 },
        priceMultiplier = settings.priceMultiplier or 1.0,
        drugs = allDrugs,
        blip = {
            enabled = settings.blipEnabled ~= false,
            showRadius = defaultBlip.showRadius,
            sprite = defaultBlip.sprite,
            color = defaultBlip.color,
            scale = defaultBlip.scale,
        },
        ignoredPedModels = ignoredPoliceModels,
    }
end

Config.Zones = {
    ['vinewood'] = zone('Vinewood', vector3(284.3999, -86.8160, 70.1332), 500, {
        daytime = true,
        policeRequired = 0,
        robberyEnabled = true,
        robberyChance = 5,
        callChance = 10,
        cooldown = 0,
        limit = 0,
        xp = { min = 5, max = 15 },
    }),
    ['south_los_santos'] = zone('South Los Santos', vector3(179.9148, -1598.6139, 29.3298), 400, {
        daytime = false,
        policeRequired = 0,
        robberyEnabled = true,
        robberyChance = 25,
        callChance = 10,
        cooldown = 0,
        limit = 50,
        xp = { min = 15, max = 30 },
    }),
    ['del_perro_pier'] = zone('Del Perro Pier', vector3(-1708.1877, -1076.6757, 13.0809), 250, {
        daytime = true,
        policeRequired = 3,
        robberyEnabled = true,
        robberyChance = 5,
        callChance = 10,
        cooldown = 25,
        limit = 50,
        xp = { min = 5, max = 20 },
    }),
    ['vespucci'] = zone('Vespucci', vector3(-1113.7163, -1317.1970, 5.4447), 375, {
        daytime = true,
        policeRequired = 0,
        robberyEnabled = true,
        robberyChance = 10,
        callChance = 10,
        cooldown = 0,
        limit = 0,
        xp = { min = 5, max = 15 },
    }),
    ['ls_airport'] = zone('Los Santos International Airport', vector3(-1090.9209, -2617.4668, 13.6986), 500, {
        daytime = true,
        policeRequired = 3,
        robberyEnabled = true,
        robberyChance = 5,
        callChance = 10,
        cooldown = 0,
        limit = 0,
        xp = { min = 10, max = 20 },
    }),
    ['rockford_hills'] = zone('Rockford Hills', vector3(-794.8151, -272.5175, 37.0324), 400, {
        daytime = true,
        policeRequired = 0,
        robberyEnabled = false,
        robberyChance = 0,
        callChance = 10,
        cooldown = 0,
        limit = 0,
        xp = { min = 10, max = 25 },
    }),
}

---------------------------------------------------------------------
-- Ped models that players can target to sell drugs
-- The supplied list is preserved, including its existing duplicates.
---------------------------------------------------------------------
Config.PedModels = {
    -- Male pedestrians
    'a_m_m_acult_01', 'a_m_m_afriamer_01', 'a_m_m_beach_01', 'a_m_m_beach_02',
    'a_m_m_bevhills_01', 'a_m_m_bevhills_02', 'a_m_m_business_01', 'a_m_m_eastsa_01',
    'a_m_m_eastsa_02', 'a_m_m_farmer_01', 'a_m_m_fatlatin_01', 'a_m_m_genfat_01',
    'a_m_m_genfat_02', 'a_m_m_golfer_01', 'a_m_m_hasjew_01', 'a_m_m_hillbilly_01',
    'a_m_m_hillbilly_02', 'a_m_m_indian_01', 'a_m_m_ktown_01', 'a_m_m_malibu_01',
    'a_m_m_mexcntry_01', 'a_m_m_mexlabor_01', 'a_m_m_og_boss_01', 'a_m_m_paparazzi_01',
    'a_m_m_polynesian_01', 'a_m_m_prolhost_01', 'a_m_m_rurmeth_01', 'a_m_m_salton_01',
    'a_m_m_skater_01', 'a_m_m_skidrow_01', 'a_m_m_socenlat_01', 'a_m_m_soucent_01',
    'a_m_m_soucent_02', 'a_m_m_soucent_03', 'a_m_m_soucent_04', 'a_m_m_stlat_02',
    'a_m_m_tennis_01', 'a_m_m_tourist_01', 'a_m_m_tramp_01', 'a_m_m_trampbeac_01',
    'a_m_m_transvest_01', 'a_m_m_transvest_02', 'a_m_m_hacult_01',

    -- Female pedestrians
    'a_f_m_beach_01', 'a_f_m_bevhills_01', 'a_f_m_bevhills_02', 'a_f_m_bodybuild_01',
    'a_f_m_business_02', 'a_f_m_downtown_01', 'a_f_m_eastsa_01', 'a_f_m_eastsa_02',
    'a_f_m_fatwhite_01', 'a_f_m_ktown_01', 'a_f_m_ktown_02', 'a_f_m_prolhost_01',
    'a_f_m_salton_01', 'a_f_m_skater_01', 'a_f_m_soucent_01', 'a_f_m_soucent_02',
    'a_f_m_soucentmc_01', 'a_f_m_tourist_01', 'a_f_m_tramp_01',

    -- Female tourist pedestrians
    'a_f_o_genstreet_01', 'a_f_o_indian_01', 'a_f_o_ktown_01', 'a_f_o_salton_01',
    'a_f_o_soucent_01', 'a_f_o_soucent_02',

    -- Male tourist pedestrians
    'a_m_o_acult_01', 'a_m_o_acult_02', 'a_m_o_beach_01', 'a_m_o_genstreet_01',
    'a_m_o_ktown_01', 'a_m_o_salton_01', 'a_m_o_soucent_01', 'a_m_o_soucent_02',
    'a_m_o_soucent_03',

    -- Gangs (male)
    'g_m_m_armboss_01', 'g_m_m_armgoon_01', 'g_m_m_armlieut_01', 'g_m_m_chemwork_01',
    'g_m_m_chiboss_01', 'g_m_m_chicold_01', 'g_m_m_chigoon_01', 'g_m_m_chigoon_02',
    'g_m_m_korboss_01', 'g_m_m_mexboss_01', 'g_m_m_mexboss_02', 'g_m_y_armgoon_02',
    'g_m_y_azteca_01', 'g_m_y_ballaeast_01', 'g_m_y_ballaorig_01', 'g_m_y_ballasout_01',
    'g_m_y_famca_01', 'g_m_y_famdnf_01', 'g_m_y_famfor_01', 'g_m_y_korean_01',
    'g_m_y_korean_02', 'g_m_y_korlieut_01', 'g_m_y_lost_01', 'g_m_y_lost_02',
    'g_m_y_lost_03', 'g_m_y_mexgang_01', 'g_m_y_mexgoon_01', 'g_m_y_mexgoon_02',
    'g_m_y_mexgoon_03', 'g_m_y_pologoon_01', 'g_m_y_pologoon_02', 'g_m_y_salvaboss_01',
    'g_m_y_salvagoon_01', 'g_m_y_salvagoon_02', 'g_m_y_salvagoon_03', 'g_m_y_strpunk_01',
    'g_m_y_strpunk_02',

    -- Special male models (businessmen, professionals, etc.)
    's_m_m_autoshop_01', 's_m_m_autoshop_02', 's_m_m_bouncer_01', 's_m_m_ccrew_01',
    's_m_m_chemsec_01', 's_m_m_cntrybar_01', 's_m_m_dockwork_01', 's_m_m_doctor_01',
    's_m_m_fiboffice_01', 's_m_m_fiboffice_02', 's_m_m_gaffer_01', 's_m_m_gardener_01',
    's_m_m_gentransport', 's_m_m_hairdress_01', 's_m_m_highsec_01', 's_m_m_highsec_02',
    's_m_m_janitor', 's_m_m_lathandy_01', 's_m_m_lifeinvad_01', 's_m_m_linecook',
    's_m_m_lsmetro_01', 's_m_m_mariachi_01', 's_m_m_marine_01', 's_m_m_marine_02',
    's_m_m_migrant_01', 's_m_m_movalien_01', 's_m_m_movprem_01', 's_m_m_paramedic_01',
    's_m_m_pilot_01', 's_m_m_pilot_02', 's_m_m_postal_01', 's_m_m_postal_02',
    's_m_m_scientist_01', 's_m_m_security_01', 's_m_m_snowcop_01', 's_m_m_strperf_01',
    's_m_m_strpreach_01', 's_m_m_strvend_01', 's_m_m_trucker_01', 's_m_m_ups_01',
    's_m_m_ups_02', 's_m_o_busker_01',

    -- Special female models (businesswomen, professionals, etc.)
    's_f_m_fembarber', 's_f_m_maid_01', 's_f_m_shop_high', 's_f_m_sweatshop_01',
    's_f_y_airhostess_01', 's_f_y_bartender_01', 's_f_y_baywatch_01', 's_f_y_cop_01',
    's_f_y_factory_01', 's_f_y_hooker_01', 's_f_y_hooker_02', 's_f_y_hooker_03',
    's_f_y_migrant_01', 's_f_y_movprem_01', 's_f_y_ranger_01', 's_f_y_scrubs_01',
    's_f_y_sheriff_01', 's_f_y_shop_low', 's_f_y_shop_mid', 's_f_y_stripper_01',
    's_f_y_stripper_02', 's_f_y_stripperlite', 's_f_y_sweatshop_01',

    -- Military models
    's_m_m_armoured_01', 's_m_m_armoured_02', 's_m_y_armymech_01', 's_m_y_blackops_01',
    's_m_y_blackops_02', 's_m_y_blackops_03', 's_m_y_marine_01', 's_m_y_marine_02',
    's_m_y_marine_03',

    -- Law enforcement models (kept in the list but excluded from sales by IgnoredPedModels)
    's_f_y_sheriff_01', 's_m_m_paramedic_01', 's_m_y_cop_01', 's_m_y_hwaycop_01',
    's_m_y_ranger_01', 's_m_y_swat_01', 's_m_y_sheriff_01',

    -- Emergency services models
    's_m_y_fireman_01', 's_m_y_paramedic_01', 'u_m_m_paramedic_01',

    -- Service workers (bartenders, strippers, etc.)
    's_f_y_bartender_01', 's_f_y_hooker_01', 's_f_y_hooker_02', 's_f_y_hooker_03',
    's_m_m_bouncer_01', 's_m_y_ammucity_01', 's_m_m_autoshop_01',

    -- Miscellaneous NPCs (actors, zombies, clowns, etc.)
    'u_m_y_abner', 'u_m_y_babyd', 'u_m_y_baygor', 'u_m_y_burgerdrug_01', 'u_m_y_chip',
    'u_m_y_corpse_01', 'u_m_y_juggernaut_01', 'u_m_y_justin', 'u_m_y_mani', 'u_m_y_militarybum',
    'u_m_y_paparazzi', 'u_m_y_party_01', 'u_m_y_proldriver_01', 'u_m_y_prisoner_01',
    'u_m_y_rsranger_01', 'u_m_y_sbike', 'u_m_y_sbikef',
}
