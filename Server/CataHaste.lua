-- ============================================================
--  Cata-like Haste for DoTs/HoTs  |  WotLK 3.3.5
--  Engine: AzerothCore + Eluna
-- ============================================================

local HASTE_RATING_PER_PERCENT = 10    -- Lower numbers = faster ticks
local EXTRA_TICK_DMG_FACTOR    = 1.0
local STACK_DMG_FACTOR         = 1.0   -- global multiplier for stack-scaling damage spells (e.g. Deadly Poison)
local STACK_HEAL_FACTOR        = 1.0   -- global multiplier for stack-scaling heal spells (e.g. Lifebloom)
local MAX_HASTE_PERCENT        = 1000.0

local HEALING_POWER_OFFSET  = 1174
local SPELL_DMG_BASE_OFFSET = 1172
local ADDON_PREFIX          = "CATAHASTE"

-- ============================================================
--  UNIT FIELD OFFSETS
-- ============================================================
local HASTE_SPELL_OFFSET  = 1250   -- CR_HASTE_SPELL  (confirmed)
local HASTE_MELEE_OFFSET  = 1248   -- CR_HASTE_MELEE  (confirmed)
local HASTE_RANGED_OFFSET = 1249   -- CR_HASTE_RANGED (confirmed)

local MELEE_AP_BASE_OFFSET   = 123    -- UNIT_FIELD_ATTACK_POWER_BASE        (verified)
local MELEE_AP_BONUS_OFFSET  = 124    -- UNIT_FIELD_ATTACK_POWER_BONUS       (verified)
local RANGED_AP_BASE_OFFSET  = 126    -- UNIT_FIELD_RANGED_ATTACK_POWER_BASE (verified)
local RANGED_AP_BONUS_OFFSET = 127    -- UNIT_FIELD_RANGED_ATTACK_POWER_BONUS(verified)

-- ============================================================
--  SLOT REGISTRY
--  Assigns a persistent slot number (1..N) per target GUIDLow.
--  Allows the client to distinguish same-name NPCs.
-- ============================================================
local targetSlots = {}
local nextSlotId  = 0

local function getSlot(guidLow)
    if not targetSlots[guidLow] then
        nextSlotId = nextSlotId + 1
        targetSlots[guidLow] = nextSlotId
    end
    return targetSlots[guidLow]
end

-- ============================================================
--  SPELL DATABASE
--  hasteType: "spell" (default) | "melee" | "ranged"
--  coeff:     SP/AP/RAP coefficient per tick
--  baseAmount: DBC BasePoints+1 (base tick value without gear)
--  = coeff not yet verified in-game
-- ============================================================
--  HOW THE TICK DAMAGE FORMULA WORKS
--  ----------------------------------
--  Each extra tick deals:
--    tickAmount = baseAmount + (power * coeff * EXTRA_TICK_DMG_FACTOR)
--
--  power  = SP, Melee AP, or Ranged AP depending on the spell's hasteType:
--             hasteType unset / "spell" -> Spell Power (school-specific)
--             hasteType = "melee"       -> Melee AP (base + bonus)
--             hasteType = "ranged"      -> Ranged AP (base + bonus)
--             type = "hot"              -> Healing Power
--
--  coeff  = scaling knob per spell entry in SPELL_DB.
--           Think of 0.1000 as the neutral baseline:
--             < 0.1000  ->  weaker SP/AP influence  (e.g. 0.0500 = half)
--             > 0.1000  ->  stronger SP/AP influence (e.g. 0.2000 = double)
--           All spells start at 0.1000 - tune up or down per spell as needed.
--
--  EXTRA_TICK_DMG_FACTOR (global) scales ALL extra tick damage at once.
--
--  COMBO POINTS (comboScaling = true in SPELL_DB)
--  CPs are captured at cast time. tickAmount * (cp / 5):
--    1 CP = 20%,  3 CP = 60%,  5 CP = 100%
--  Spells: Rip, Rupture
--
--  STACKS (stackScaling = true in SPELL_DB)
--  Stacks are read live on every extra tick (not snapshotted).
--  Two models:
--    Default (build-up to 5-stack cap, e.g. Deadly Poison):
--      tickAmount * (stacks / 5) * STACK_DMG_FACTOR
--      1 stack = 20%, 3 = 60%, 5 = 100%   (baseAmount = full 5-stack value)
--    stackLinear = true (each stack is one full tick, e.g. Lifebloom):
--      tickAmount * stacks * (STACK_HEAL_FACTOR for hots / STACK_DMG_FACTOR for dots)
--      1 stack = 100%, 2 = 200%, 3 = 300%  (baseAmount = 1-stack value)
-- ============================================================
local SPELL_DB = {
    -- ----------------------------------------------------
    --  PRIEST
    -- ----------------------------------------------------
    -- DoTs
    [  589] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=5    },  -- Shadow Word: Pain Rank 1
    [  594] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=10   },  -- Shadow Word: Pain Rank 2
    [  970] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=20   },  -- Shadow Word: Pain Rank 3
    [  992] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=35   },  -- Shadow Word: Pain Rank 4
    [ 2767] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=55   },  -- Shadow Word: Pain Rank 5
    [10892] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=77   },  -- Shadow Word: Pain Rank 6
    [10893] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=101  },  -- Shadow Word: Pain Rank 7
    [10894] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=128  },  -- Shadow Word: Pain Rank 8
    [27605] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=142  },  -- Shadow Word: Pain Rank 8
    [25367] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=151  },  -- Shadow Word: Pain Rank 9
    [25368] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=186  },  -- Shadow Word: Pain Rank 10
    [48124] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=196  },  -- Shadow Word: Pain Rank 11
    [48125] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=230  },  -- Shadow Word: Pain Rank 12

    [ 2944] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=16   },  -- Devouring Plague Rank 1
    [19276] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=30   },  -- Devouring Plague Rank 2
    [19277] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=48   },  -- Devouring Plague Rank 3
    [19278] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=73   },  -- Devouring Plague Rank 4
    [19279] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=103  },  -- Devouring Plague Rank 5
    [19280] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=140  },  -- Devouring Plague Rank 6
    [25467] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=168  },  -- Devouring Plague Rank 7
    [48299] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=160  },  -- Devouring Plague Rank 8
    [48300] = { duration=24 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=172  },  -- Devouring Plague Rank 9

    [14914] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=3   },  -- Holy Fire Rank 1
    [15262] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=4   },  -- Holy Fire Rank 2
    [15263] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=6   },  -- Holy Fire Rank 3
    [15264] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=8   },  -- Holy Fire Rank 4
    [15265] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=10  },  -- Holy Fire Rank 5
    [15266] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=13  },  -- Holy Fire Rank 6
    [15267] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=16  },  -- Holy Fire Rank 7
    [15261] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=18  },  -- Holy Fire Rank 8
    [25384] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=21  },  -- Holy Fire Rank 9
    [48134] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=41  },  -- Holy Fire Rank 10
    [48135] = { duration=10 , tick=1, school=2 , type="dot", coeff=0.1000, baseAmount=50  },  -- Holy Fire Rank 11

    [34914] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=90   },  -- Vampiric Touch Rank 1
    [34916] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=120  },  -- Vampiric Touch Rank 2
    [34917] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=130  },  -- Vampiric Touch Rank 3
    [48159] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=147  },  -- Vampiric Touch Rank 4
    [48160] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=170  },  -- Vampiric Touch Rank 5

    -- HoTs
    [  139] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=9    },  -- Renew Rank 1
    [ 6074] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=20   },  -- Renew Rank 2
    [ 6075] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=35   },  -- Renew Rank 3
    [ 6076] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=49   },  -- Renew Rank 4
    [ 6077] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=63   },  -- Renew Rank 5
    [ 6078] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=80   },  -- Renew Rank 6
    [10927] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=102  },  -- Renew Rank 7
    [10928] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=130  },  -- Renew Rank 8
    [10929] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=162  },  -- Renew Rank 9
    [27606] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=162  },  -- Renew Rank 9
    [25315] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=194  },  -- Renew Rank 10
    [25221] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=202  },  -- Renew Rank 11
    [25222] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=222  },  -- Renew Rank 12
    [48067] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=247  },  -- Renew Rank 13
    [48068] = { duration=15 , tick=3, school=2  , type="hot", coeff=0.3770, baseAmount=280  },  -- Renew Rank 14

    [ 7001] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.3340, baseAmount=267 },  -- Lightwell Renew Rank 1
    [27873] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.3340, baseAmount=388 },  -- Lightwell Renew Rank 2
    [27874] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.3340, baseAmount=533 },  -- Lightwell Renew Rank 3
    [28276] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.3340, baseAmount=787 },  -- Lightwell Renew Rank 4
    [48084] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.3340, baseAmount=1305},  -- Lightwell Renew Rank 5
    [48085] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.3340, baseAmount=1540},  -- Lightwell Renew Rank 6

    [27813] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.1000, baseAmount=1   },  -- Blessed Recovery Rank 1
    [27817] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.1000, baseAmount=1   },  -- Blessed Recovery Rank 2
    [27818] = { duration=16 , tick=2, school=2 , type="hot", coeff=0.1000, baseAmount=1   },  -- Blessed Recovery Rank 3

    -- ----------------------------------------------------
    --  DEATH KNIGHT
    -- ----------------------------------------------------
    -- DoTs
    [48680] = { duration=5 , tick=1, school=32, type="dot", coeff=0.1000, baseAmount=185 },  -- Strangulate Rank 1
    [49913] = { duration=5 , tick=5, school=32, type="dot", coeff=0.1000, baseAmount=95  },  -- Strangulate Rank 2
    [49914] = { duration=5 , tick=5, school=32, type="dot", coeff=0.1000, baseAmount=110 },  -- Strangulate Rank 3
    [49915] = { duration=5 , tick=5, school=32, type="dot", coeff=0.1000, baseAmount=150 },  -- Strangulate Rank 4
    [49916] = { duration=5 , tick=5, school=32, type="dot", coeff=0.1000, baseAmount=180 },  -- Strangulate Rank 5

    [52373] = { duration=12 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=73  },  -- Plague Strike Rank 1
    [59133] = { duration=12 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=73  },  -- Plague Strike Rank 1
    [60186] = { duration=12 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=213 },  -- Plague Strike Rank 6

    [55078] = { duration=15 , tick=3, school=32 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=0    },  -- Blood Plague -

    [55095] = { duration=15 , tick=3, school=16 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=0    },  -- Frost Fever -

    -- ----------------------------------------------------
    --  MAGE
    -- ----------------------------------------------------
    -- DoTs
    [  133] = { duration=4  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=1   },  -- Fireball Rank 1
    [  143] = { duration=16 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=1   },  -- Fireball Rank 2
    [  145] = { duration=16 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=2   },  -- Fireball Rank 3
    [ 3140] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=3   },  -- Fireball Rank 4
    [ 8400] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=5   },  -- Fireball Rank 5
    [ 8401] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=7   },  -- Fireball Rank 6
    [ 8402] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=8   },  -- Fireball Rank 7
    [10148] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=10  },  -- Fireball Rank 8
    [10149] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=13  },  -- Fireball Rank 9
    [10150] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=15  },  -- Fireball Rank 10
    [10151] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=18  },  -- Fireball Rank 11
    [25306] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=19  },  -- Fireball Rank 12
    [27070] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=21  },  -- Fireball Rank 13
    [38692] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=23  },  -- Fireball Rank 14
    [42832] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=25  },  -- Fireball Rank 15
    [42833] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=29  },  -- Fireball Rank 16
    [42834] = { duration=8  , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=29  },  -- Fireball Rank 17

    [ 2120] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=12  },  -- Flamestrike Rank 1
    [ 2121] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=22  },  -- Flamestrike Rank 2
    [ 8422] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=35  },  -- Flamestrike Rank 3
    [ 8423] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=49  },  -- Flamestrike Rank 4
    [10215] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=66  },  -- Flamestrike Rank 5
    [10216] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=85  },  -- Flamestrike Rank 6
    [27086] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=106 },  -- Flamestrike Rank 7
    [42925] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=155 },  -- Flamestrike Rank 8
    [42926] = { duration=8 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=195 },  -- Flamestrike Rank 9

    [11366] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=14  },  -- Pyroblast Rank 1
    [12505] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=18  },  -- Pyroblast Rank 2
    [12522] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=24  },  -- Pyroblast Rank 3
    [12523] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=31  },  -- Pyroblast Rank 4
    [12524] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=39  },  -- Pyroblast Rank 5
    [12525] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=47  },  -- Pyroblast Rank 6
    [12526] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=57  },  -- Pyroblast Rank 7
    [18809] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=67  },  -- Pyroblast Rank 8
    [27132] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=78  },  -- Pyroblast Rank 9
    [33938] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=89  },  -- Pyroblast Rank 10
    [42890] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=96  },  -- Pyroblast Rank 11
    [42891] = { duration=12 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=113 },  -- Pyroblast Rank 12

    [44457] = { duration=12 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=153  },  -- Living Bomb Rank 1
    [55359] = { duration=12 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=256  },  -- Living Bomb Rank 2
    [55360] = { duration=12 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=345  },  -- Living Bomb Rank 3

    [44614] = { duration=9 , tick=3, school=20, type="dot", coeff=0.1000, baseAmount=20  },  -- Frostfire Bolt Rank 1
    [47610] = { duration=9 , tick=3, school=20, type="dot", coeff=0.1000, baseAmount=30  },  -- Frostfire Bolt Rank 2

    -- ----------------------------------------------------
    --  WARLOCK
    -- ----------------------------------------------------
    -- DoTs
    [  172] = { duration=12 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=10   },  -- Corruption Rank 1
    [ 6222] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=18   },  -- Corruption Rank 2
    [ 6223] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=37   },  -- Corruption Rank 3
    [ 7648] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=54   },  -- Corruption Rank 4
    [11671] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=81   },  -- Corruption Rank 5
    [11672] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=111  },  -- Corruption Rank 6
    [25311] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=137  },  -- Corruption Rank 7
    [27216] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=150  },  -- Corruption Rank 8
    [47812] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=164  },  -- Corruption Rank 9
    [47813] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=180  },  -- Corruption Rank 10

    [  348] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=4   },  -- Immolate Rank 1
    [  707] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=8   },  -- Immolate Rank 2
    [ 1094] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=18  },  -- Immolate Rank 3
    [ 2941] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=33  },  -- Immolate Rank 4
    [11665] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=51  },  -- Immolate Rank 5
    [11667] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=73  },  -- Immolate Rank 6
    [11668] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=97  },  -- Immolate Rank 7
    [25309] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=102 },  -- Immolate Rank 8
    [27215] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=123 },  -- Immolate Rank 9
    [47810] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=139 },  -- Immolate Rank 10
    [47811] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=157 },  -- Immolate Rank 11

    [  603] = { duration=60 , tick=60, school=32, type="dot", coeff=0.1000, baseAmount=3200},  -- Curse of Doom Rank 1
    [30910] = { duration=60 , tick=60, school=32, type="dot", coeff=0.1000, baseAmount=4200},  -- Curse of Doom Rank 2
    [47867] = { duration=60 , tick=60, school=32, type="dot", coeff=0.1000, baseAmount=7300},  -- Curse of Doom Rank 3

    [  980] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=7    },  -- Curse of Agony Rank 1
    [ 1014] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=15   },  -- Curse of Agony Rank 2
    [ 6217] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=27   },  -- Curse of Agony Rank 3
    [11711] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=42   },  -- Curse of Agony Rank 4
    [11712] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=65   },  -- Curse of Agony Rank 5
    [11713] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=87   },  -- Curse of Agony Rank 6
    [27218] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=113  },  -- Curse of Agony Rank 7
    [47863] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=120  },  -- Curse of Agony Rank 8
    [47864] = { duration=24 , tick=2, school=32 , type="dot", coeff=0.1000, baseAmount=145  },  -- Curse of Agony Rank 9

    [ 1120] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=11  },  -- Drain Soul Rank 1
    [ 8288] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=31  },  -- Drain Soul Rank 2
    [ 8289] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=59  },  -- Drain Soul Rank 3
    [11675] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=91  },  -- Drain Soul Rank 4
    [27217] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=124 },  -- Drain Soul Rank 5
    [47855] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=142 },  -- Drain Soul Rank 6

    [27243] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=174  },  -- Seed of Corruption Rank 1
    [47835] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=216  },  -- Seed of Corruption Rank 2
    [47836] = { duration=18 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=253  },  -- Seed of Corruption Rank 3

    [30108] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=110  },  -- Unstable Affliction Rank 1
    [30404] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=140  },  -- Unstable Affliction Rank 2
    [30405] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=175  },  -- Unstable Affliction Rank 3
    [47841] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=197  },  -- Unstable Affliction Rank 4
    [47843] = { duration=15 , tick=3, school=32 , type="dot", coeff=0.1000, baseAmount=230  },  -- Unstable Affliction Rank 5

    [47206] = { duration=18 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=150 },  -- Atrocity Rank 1 (Only works on main target)

    -- HoTs
    [17767] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=105 },  -- Consume Shadows Rank 1
    [17850] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=188 },  -- Consume Shadows Rank 2
    [17851] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=277 },  -- Consume Shadows Rank 3
    [17852] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=374 },  -- Consume Shadows Rank 4
    [17853] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=508 },  -- Consume Shadows Rank 5
    [17854] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=652 },  -- Consume Shadows Rank 6
    [27272] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=821 },  -- Consume Shadows Rank 7
    [47987] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=1003},  -- Consume Shadows Rank 8
    [47988] = { duration=16 , tick=2, school=32, type="hot", coeff=0.1000, baseAmount=1156},  -- Consume Shadows Rank 9

    -- ----------------------------------------------------
    --  DRUID
    -- ----------------------------------------------------
    -- DoTs
    [  339] = { duration=12 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=5   },  -- Entangling Roots Rank 1
    [19975] = { duration=12 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=5   },  -- Entangling Roots Rank 1
    [ 1062] = { duration=15 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=10  },  -- Entangling Roots Rank 2
    [19974] = { duration=15 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=10  },  -- Entangling Roots Rank 2
    [ 5195] = { duration=18 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=15  },  -- Entangling Roots Rank 3
    [19973] = { duration=18 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=15  },  -- Entangling Roots Rank 3
    [ 5196] = { duration=21 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=20  },  -- Entangling Roots Rank 4
    [19972] = { duration=21 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=20  },  -- Entangling Roots Rank 4
    [ 9852] = { duration=24 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=25  },  -- Entangling Roots Rank 5
    [19971] = { duration=24 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=25  },  -- Entangling Roots Rank 5
    [ 9853] = { duration=27 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=30  },  -- Entangling Roots Rank 6
    [19970] = { duration=27 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=30  },  -- Entangling Roots Rank 6
    [26989] = { duration=27 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=39  },  -- Entangling Roots Rank 7
    [27010] = { duration=27 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=39  },  -- Entangling Roots Rank 7
    [53308] = { duration=27 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=47  },  -- Entangling Roots Rank 8
    [53313] = { duration=27 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=47  },  -- Entangling Roots Rank 8

    [ 1079] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=3   , comboScaling=true},  -- Rip Rank 1
    [ 9492] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=4   , comboScaling=true},  -- Rip Rank 2
    [ 9493] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=6   , comboScaling=true},  -- Rip Rank 3
    [ 9752] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=9   , comboScaling=true},  -- Rip Rank 4
    [ 9894] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=12  , comboScaling=true},  -- Rip Rank 5
    [ 9896] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=17  , comboScaling=true},  -- Rip Rank 6
    [27008] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=24  , comboScaling=true},  -- Rip Rank 7
    [49799] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=30  , comboScaling=true},  -- Rip Rank 8
    [49800] = { duration=12 , tick=2, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=36  , comboScaling=true},  -- Rip Rank 9

    [ 1822] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=30  },  -- Rake Rank 1
    [ 1823] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=45  },  -- Rake Rank 2
    [ 1824] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=69  },  -- Rake Rank 3
    [ 9904] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=99  },  -- Rake Rank 4
    [27003] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=138 },  -- Rake Rank 5
    [48573] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=297 },  -- Rake Rank 6
    [48574] = { duration=9 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=358 },  -- Rake Rank 7

    [ 5570] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=24   },  -- Insect Swarm Rank 1
    [24974] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=39   },  -- Insect Swarm Rank 2
    [24975] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=62   },  -- Insect Swarm Rank 3
    [24976] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=90   },  -- Insect Swarm Rank 4
    [24977] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=124  },  -- Insect Swarm Rank 5
    [27013] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=172  },  -- Insect Swarm Rank 6
    [48468] = { duration=12 , tick=2, school=8  , type="dot", coeff=0.1000, baseAmount=215  },  -- Insect Swarm Rank 7

    [ 8921] = { duration=9  , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=4   },  -- Moonfire Rank 1
    [ 8924] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=8   },  -- Moonfire Rank 2
    [ 8925] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=13  },  -- Moonfire Rank 3
    [ 8926] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=20  },  -- Moonfire Rank 4
    [ 8927] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=31  },  -- Moonfire Rank 5
    [ 8928] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=41  },  -- Moonfire Rank 6
    [ 8929] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=53  },  -- Moonfire Rank 7
    [ 9833] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=66  },  -- Moonfire Rank 8
    [ 9834] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=80  },  -- Moonfire Rank 9
    [ 9835] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=96  },  -- Moonfire Rank 10
    [26987] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=111 },  -- Moonfire Rank 11
    [26988] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=150 },  -- Moonfire Rank 12
    [48462] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=171 },  -- Moonfire Rank 13
    [48463] = { duration=12 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=200 },  -- Moonfire Rank 14

    [33745] = { duration=15 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=31  },  -- Lacerate Rank 1
    [48567] = { duration=15 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=51  },  -- Lacerate Rank 2
    [48568] = { duration=15 , tick=3, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=64  },  -- Lacerate Rank 3

    [40090] = { duration=20 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=1665},  -- Hurricane

    [48628] = { duration=3 , tick=1, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=50  },  -- Lock Jaw Rank 1

    -- HoTs
    [  774] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=8    },  -- Rejuvenation Rank 1
    [ 1058] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=14   },  -- Rejuvenation Rank 2
    [ 1430] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=29   },  -- Rejuvenation Rank 3
    [ 2090] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=45   },  -- Rejuvenation Rank 4
    [ 2091] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=61   },  -- Rejuvenation Rank 5
    [ 3627] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=76   },  -- Rejuvenation Rank 6
    [ 8910] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=97   },  -- Rejuvenation Rank 7
    [ 9839] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=122  },  -- Rejuvenation Rank 8
    [ 9840] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=152  },  -- Rejuvenation Rank 9
    [ 9841] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=189  },  -- Rejuvenation Rank 10
    [25299] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=222  },  -- Rejuvenation Rank 11
    [26981] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=233  },  -- Rejuvenation Rank 12
    [26982] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=265  },  -- Rejuvenation Rank 13
    [48440] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=298  },  -- Rejuvenation Rank 14
    [48441] = { duration=15 , tick=3, school=8  , type="hot", coeff=0.3770, baseAmount=338  },  -- Rejuvenation Rank 15

    [ 8936] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=14   },  -- Regrowth Rank 1
    [ 8938] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=25   },  -- Regrowth Rank 2
    [ 8939] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=37   },  -- Regrowth Rank 3
    [ 8940] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=49   },  -- Regrowth Rank 4
    [ 8941] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=61   },  -- Regrowth Rank 5
    [ 9750] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=78   },  -- Regrowth Rank 6
    [ 9856] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=98   },  -- Regrowth Rank 7
    [ 9857] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=123  },  -- Regrowth Rank 8
    [ 9858] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=152  },  -- Regrowth Rank 9
    [26980] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=182  },  -- Regrowth Rank 10
    [48442] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=256  },  -- Regrowth Rank 11
    [48443] = { duration=21 , tick=3, school=8  , type="hot", coeff=0.1880, baseAmount=335  },  -- Regrowth Rank 12

    [33763] = { duration=10 , tick=1, school=8  , type="hot", coeff=0.1000, baseAmount=32   , stackScaling=true, stackLinear=true },  -- Lifebloom Rank 1
    [48450] = { duration=10 , tick=1, school=8  , type="hot", coeff=0.1000, baseAmount=41   , stackScaling=true, stackLinear=true },  -- Lifebloom Rank 2
    [48451] = { duration=10 , tick=1, school=8  , type="hot", coeff=0.1000, baseAmount=53   , stackScaling=true, stackLinear=true },  -- Lifebloom Rank 3

    [48438] = { duration=10 , tick=1, school=8 , type="hot", coeff=0.1000, baseAmount=98  },  -- Wild Growth Rank 1
    [53248] = { duration=10 , tick=1, school=8 , type="hot", coeff=0.1000, baseAmount=123 },  -- Wild Growth Rank 2
    [53249] = { duration=10 , tick=1, school=8 , type="hot", coeff=0.1000, baseAmount=177 },  -- Wild Growth Rank 3
    [53251] = { duration=10 , tick=1, school=8 , type="hot", coeff=0.1000, baseAmount=206 },  -- Wild Growth Rank 4

    -- ----------------------------------------------------
    --  SHAMAN
    -- ----------------------------------------------------
    -- DoTs
    [ 8050] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=7    },  -- Flame Shock Rank 1
    [ 8052] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=12   },  -- Flame Shock Rank 2
    [ 8053] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=24   },  -- Flame Shock Rank 3
    [10447] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=42   },  -- Flame Shock Rank 4
    [10448] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=64   },  -- Flame Shock Rank 5
    [29228] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=86   },  -- Flame Shock Rank 6
    [25457] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=105  },  -- Flame Shock Rank 7
    [49232] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=119  },  -- Flame Shock Rank 8
    [49233] = { duration=18 , tick=3, school=4  , type="dot", coeff=0.1000, baseAmount=139  },  -- Flame Shock Rank 9

    -- HoTs
    [51945] = { duration=12 , tick=3, school=8 , type="hot", coeff=0.1640, baseAmount=29  },  -- Earthliving Rank 1
    [51990] = { duration=12 , tick=3, school=8 , type="hot", coeff=0.1640, baseAmount=40  },  -- Earthliving Rank 2
    [51997] = { duration=12 , tick=3, school=8 , type="hot", coeff=0.1640, baseAmount=55  },  -- Earthliving Rank 3
    [51998] = { duration=12 , tick=3, school=8 , type="hot", coeff=0.1640, baseAmount=87  },  -- Earthliving Rank 4
    [51999] = { duration=12 , tick=3, school=8 , type="hot", coeff=0.1640, baseAmount=114 },  -- Earthliving Rank 5
    [52000] = { duration=12 , tick=3, school=8 , type="hot", coeff=0.1640, baseAmount=163 },  -- Earthliving Rank 6

    [61295] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1880, baseAmount=133 },  -- Riptide Rank 1
    [61299] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1880, baseAmount=177 },  -- Riptide Rank 2
    [61300] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1880, baseAmount=287 },  -- Riptide Rank 3
    [61301] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1880, baseAmount=334 },  -- Riptide Rank 4

    -- ----------------------------------------------------
    --  WARRIOR
    -- ----------------------------------------------------
    -- DoTs
    [  772] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=9    },  -- Rend Rank 1
    [ 6546] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=18   },  -- Rend Rank 2
    [ 6547] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=33   },  -- Rend Rank 3
    [ 6548] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=49   },  -- Rend Rank 4
    [11572] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=70   },  -- Rend Rank 5
    [11573] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=83   },  -- Rend Rank 6
    [11574] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=97   },  -- Rend Rank 7
    [25208] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=151  },  -- Rend Rank 8
    [46845] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=163  },  -- Rend Rank 9
    [47465] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=196  },  -- Rend Rank 9
    [47466] = { duration=15 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=239  },  -- Rend Rank 10

    [12721] = { duration=16 , tick=1, school=1 , type="dot", hasteType="melee", coeff=0.1000, baseAmount=1   },  -- Deep Wounds

    -- ----------------------------------------------------
    --  ROGUE
    -- ----------------------------------------------------
    -- DoTs
    [  703] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=20   },  -- Garrote Rank 1
    [ 8631] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=27   },  -- Garrote Rank 2
    [ 8632] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=37   },  -- Garrote Rank 3
    [ 8633] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=45   },  -- Garrote Rank 4
    [11289] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=57   },  -- Garrote Rank 5
    [11290] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=71   },  -- Garrote Rank 6
    [26839] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=85   },  -- Garrote Rank 7
    [26884] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=102  },  -- Garrote Rank 8
    [48675] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=110  },  -- Garrote Rank 9
    [48676] = { duration=18 , tick=3, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=119  },  -- Garrote Rank 10

    [ 1943] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=8    , comboScaling=true},  -- Rupture Rank 1
    [ 8639] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=12   , comboScaling=true},  -- Rupture Rank 2
    [ 8640] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=18   , comboScaling=true},  -- Rupture Rank 3
    [11273] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=27   , comboScaling=true},  -- Rupture Rank 4
    [11274] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=37   , comboScaling=true},  -- Rupture Rank 5
    [11275] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=60   , comboScaling=true},  -- Rupture Rank 6
    [26867] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=70   , comboScaling=true},  -- Rupture Rank 7
    [48671] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=107  , comboScaling=true},  -- Rupture Rank 8
    [48672] = { duration=16 , tick=2, school=1  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=127  , comboScaling=true},  -- Rupture Rank 9

    [ 2818] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=6    , stackScaling=true},  -- Deadly Poison Rank 1
    [ 2819] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=9    , stackScaling=true},  -- Deadly Poison Rank 2
    [11353] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=14   , stackScaling=true},  -- Deadly Poison Rank 3
    [11354] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=19   , stackScaling=true},  -- Deadly Poison Rank 4
    [25349] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=24   , stackScaling=true},  -- Deadly Poison Rank 5
    [26968] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=40   , stackScaling=true},  -- Deadly Poison Rank 6
    [27187] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=51   , stackScaling=true},  -- Deadly Poison Rank 7
    [57969] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=61   , stackScaling=true},  -- Deadly Poison Rank 8
    [57970] = { duration=12 , tick=3, school=8  , type="dot", hasteType="melee", coeff=0.1000, baseAmount=74   , stackScaling=true},  -- Deadly Poison Rank 9

    -- ----------------------------------------------------
    --  HUNTER
    -- ----------------------------------------------------
    -- DoTs
    [ 1978] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=12   },  -- Serpent Sting Rank 1
    [13549] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=23   },  -- Serpent Sting Rank 2
    [13550] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=36   },  -- Serpent Sting Rank 3
    [13551] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=53   },  -- Serpent Sting Rank 4
    [13552] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=78   },  -- Serpent Sting Rank 5
    [13553] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=103  },  -- Serpent Sting Rank 6
    [13554] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=143  },  -- Serpent Sting Rank 7
    [13555] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=183  },  -- Serpent Sting Rank 8
    [25295] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=242  },  -- Serpent Sting Rank 9
    [27016] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=132  },  -- Serpent Sting Rank 10
    [49000] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=299  },  -- Serpent Sting Rank 10
    [49001] = { duration=15 , tick=3, school=8  , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=347  },  -- Serpent Sting Rank 11

    [ 3674] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=157 },  -- Black Arrow Rank 1
    [63668] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=188 },  -- Black Arrow Rank 2
    [63669] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=241 },  -- Black Arrow Rank 3
    [63670] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=296 },  -- Black Arrow Rank 4
    [63671] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=448 },  -- Black Arrow Rank 5
    [63672] = { duration=15 , tick=3, school=32, type="dot", coeff=0.1000, baseAmount=553 },  -- Black Arrow Rank 6

    [13797] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=21  },  -- Immolation Trap Rank 1
    [14298] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=43  },  -- Immolation Trap Rank 2
    [14299] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=68  },  -- Immolation Trap Rank 3
    [14300] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=102 },  -- Immolation Trap Rank 4
    [14301] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=138 },  -- Immolation Trap Rank 5
    [27024] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=197 },  -- Immolation Trap Rank 6
    [49053] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=308 },  -- Immolation Trap Rank 7
    [49054] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=377 },  -- Immolation Trap Rank 8

    [13812] = { duration=20 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=15  },  -- Explosive Trap Effect Rank 1
    [14314] = { duration=20 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=24  },  -- Explosive Trap Effect Rank 2
    [14315] = { duration=20 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=33  },  -- Explosive Trap Effect Rank 3
    [27026] = { duration=20 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=45  },  -- Explosive Trap Effect Rank 4
    [49064] = { duration=20 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=74  },  -- Explosive Trap Effect Rank 5
    [49065] = { duration=20 , tick=2, school=4 , type="dot", coeff=0.1000, baseAmount=90  },  -- Explosive Trap Effect Rank 6

    [22908] = { duration=16 , tick=1, school=64, type="dot", coeff=0.1000, baseAmount=300 },  -- Volley
    [30933] = { duration=16 , tick=1, school=64, type="dot", coeff=0.1000, baseAmount=180 },  -- Volley
    [34100] = { duration=16 , tick=1, school=64, type="dot", coeff=0.1000, baseAmount=420 },  -- Volley
    [35950] = { duration=16 , tick=1, school=64, type="dot", coeff=0.1000, baseAmount=540 },  -- Volley

    [24131] = { duration=16 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=100 },  -- Wyvern Sting Rank 1
    [24134] = { duration=16 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=140 },  -- Wyvern Sting Rank 2
    [24135] = { duration=16 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=200 },  -- Wyvern Sting Rank 3
    [27069] = { duration=16 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=314 },  -- Wyvern Sting Rank 4
    [49009] = { duration=16 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=694 },  -- Wyvern Sting Rank 5
    [49010] = { duration=16 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=820 },  -- Wyvern Sting Rank 6

    [32652] = { duration=15 , tick=3, school=64, type="dot", coeff=0.1000, baseAmount=100 },  -- Shattered Vessel Rank 1

    [34889] = { duration=8 , tick=1, school=4 , type="dot", coeff=0.1000, baseAmount=1   },  -- Fire Breath Rank 1
    [35323] = { duration=8 , tick=1, school=4 , type="dot", coeff=0.1000, baseAmount=3   },  -- Fire Breath Rank 2
    [55482] = { duration=8 , tick=1, school=4 , type="dot", coeff=0.1000, baseAmount=4   },  -- Fire Breath Rank 3
    [55483] = { duration=8 , tick=1, school=4 , type="dot", coeff=0.1000, baseAmount=7   },  -- Fire Breath Rank 4
    [55484] = { duration=8 , tick=1, school=4 , type="dot", coeff=0.1000, baseAmount=11  },  -- Fire Breath Rank 5
    [55485] = { duration=8 , tick=1, school=4 , type="dot", coeff=0.1000, baseAmount=22  },  -- Fire Breath Rank 6

    [35387] = { duration=8 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=1   },  -- Poison Spit Rank 1
    [35389] = { duration=8 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=3   },  -- Poison Spit Rank 2
    [35392] = { duration=8 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=4   },  -- Poison Spit Rank 3
    [55555] = { duration=8 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=8   },  -- Poison Spit Rank 4
    [55556] = { duration=8 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=12  },  -- Poison Spit Rank 5
    [55557] = { duration=8 , tick=2, school=8 , type="dot", coeff=0.1000, baseAmount=26  },  -- Poison Spit Rank 6

    [50245] = { duration=4 , tick=1, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=1   },  -- Pin Rank 1
    [53544] = { duration=4 , tick=1, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=4   },  -- Pin Rank 2
    [53545] = { duration=4 , tick=1, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=5   },  -- Pin Rank 3
    [53546] = { duration=4 , tick=1, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=9   },  -- Pin Rank 4
    [53547] = { duration=4 , tick=1, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=14  },  -- Pin Rank 5
    [53548] = { duration=4 , tick=1, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=28  },  -- Pin Rank 6

    [50274] = { duration=9 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=1   },  -- Spore Cloud Rank 1
    [53593] = { duration=9 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=2   },  -- Spore Cloud Rank 2
    [53594] = { duration=9 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=4   },  -- Spore Cloud Rank 3
    [53596] = { duration=9 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=7   },  -- Spore Cloud Rank 4
    [53597] = { duration=9 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=11  },  -- Spore Cloud Rank 5
    [53598] = { duration=9 , tick=3, school=8 , type="dot", coeff=0.1000, baseAmount=22  },  -- Spore Cloud Rank 6

    [50498] = { duration=15 , tick=5, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=1   },  -- Savage Rend Rank 1
    [53578] = { duration=15 , tick=5, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=2   },  -- Savage Rend Rank 2
    [53579] = { duration=15 , tick=5, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=3   },  -- Savage Rend Rank 3
    [53580] = { duration=15 , tick=5, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=6   },  -- Savage Rend Rank 4
    [53581] = { duration=15 , tick=5, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=10  },  -- Savage Rend Rank 5
    [53582] = { duration=15 , tick=5, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=21  },  -- Savage Rend Rank 6

    [51740] = { duration=15 , tick=3, school=4 , type="dot", coeff=0.1000, baseAmount=713 },  -- Immolation Trap Effect Rank 8

    [54706] = { duration=4 , tick=1, school=8 , type="dot", coeff=0.1000, baseAmount=1   },  -- Venom Web Spray Rank 1
    [55505] = { duration=4 , tick=1, school=8 , type="dot", coeff=0.1000, baseAmount=7   },  -- Venom Web Spray Rank 2
    [55506] = { duration=4 , tick=1, school=8 , type="dot", coeff=0.1000, baseAmount=13  },  -- Venom Web Spray Rank 3
    [55507] = { duration=4 , tick=1, school=8 , type="dot", coeff=0.1000, baseAmount=21  },  -- Venom Web Spray Rank 4
    [55508] = { duration=4 , tick=1, school=8 , type="dot", coeff=0.1000, baseAmount=33  },  -- Venom Web Spray Rank 5
    [55509] = { duration=4 , tick=1, school=8 , type="dot", coeff=0.1000, baseAmount=46  },  -- Venom Web Spray Rank 6

    [59881] = { duration=9 , tick=3, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=1   },  -- Rake Rank 1
    [59882] = { duration=9 , tick=3, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=1   },  -- Rake Rank 2
    [59883] = { duration=9 , tick=3, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=2   },  -- Rake Rank 3
    [59884] = { duration=9 , tick=3, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=4   },  -- Rake Rank 4
    [59885] = { duration=9 , tick=3, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=7   },  -- Rake Rank 5
    [59886] = { duration=9 , tick=3, school=1 , type="dot", hasteType="ranged", coeff=0.1000, baseAmount=19  },  -- Rake Rank 6

    [61193] = { duration=16 , tick=6, school=64, type="dot", coeff=0.1000, baseAmount=7   },  -- Spirit Strike Rank 1
    [61194] = { duration=16 , tick=6, school=64, type="dot", coeff=0.1000, baseAmount=7   },  -- Spirit Strike Rank 2
    [61195] = { duration=16 , tick=6, school=64, type="dot", coeff=0.1000, baseAmount=9   },  -- Spirit Strike Rank 3
    [61196] = { duration=16 , tick=6, school=64, type="dot", coeff=0.1000, baseAmount=15  },  -- Spirit Strike Rank 4
    [61197] = { duration=16 , tick=6, school=64, type="dot", coeff=0.1000, baseAmount=23  },  -- Spirit Strike Rank 5
    [61198] = { duration=16 , tick=6, school=64, type="dot", coeff=0.1000, baseAmount=49  },  -- Spirit Strike Rank 6

    -- HoTs
    [  136] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=25  },  -- Mend Pet Rank 1
    [ 3111] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=50  },  -- Mend Pet Rank 2
    [ 3661] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=90  },  -- Mend Pet Rank 3
    [ 3662] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=140 },  -- Mend Pet Rank 4
    [13542] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=200 },  -- Mend Pet Rank 5
    [13543] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=280 },  -- Mend Pet Rank 6
    [13544] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=365 },  -- Mend Pet Rank 7
    [27046] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=475 },  -- Mend Pet Rank 8
    [48989] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=850 },  -- Mend Pet Rank 9
    [48990] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.1000, baseAmount=1050},  -- Mend Pet Rank 10

    [50318] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.0130, baseAmount=8   },  -- Serenity Dust Rank 1
    [52012] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.0130, baseAmount=30  },  -- Serenity Dust Rank 2
    [52013] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.0130, baseAmount=42  },  -- Serenity Dust Rank 3
    [52014] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.0130, baseAmount=68  },  -- Serenity Dust Rank 4
    [52015] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.0130, baseAmount=111 },  -- Serenity Dust Rank 5
    [52016] = { duration=15 , tick=3, school=8 , type="hot", coeff=0.0130, baseAmount=165 },  -- Serenity Dust Rank 6
}

local SCHOOL_TO_INDEX = { [1]=0,[2]=1,[4]=2,[8]=3,[16]=4,[32]=5,[64]=6 }

-- ============================================================
--  CALCULATIONS
-- ============================================================
local function getHastePct(player, hasteType)
    local offset
    if     hasteType == "melee"  then offset = HASTE_MELEE_OFFSET
    elseif hasteType == "ranged" then offset = HASTE_RANGED_OFFSET
    else                              offset = HASTE_SPELL_OFFSET
    end
    local ok, rating = pcall(function() return player:GetUInt32Value(offset) end)
    if ok and rating and rating > 0 then
        return math.min(rating / HASTE_RATING_PER_PERCENT, MAX_HASTE_PERCENT)
    end
    return 0.0
end

local function calcWotlkTicks(info)
    return math.floor(info.duration / info.tick)
end

local function calcCataTicks(info, hastePct)
    -- + epsilon so exact integer boundaries (e.g. Fireball at 25% = 5.0) don't
    -- fall to the lower tick count through float error (8/1.6 = 4.9999...).
    return math.floor(info.duration / (info.tick / (1.0 + hastePct / 100.0)) + 1e-9)
end

local function calcTickAmount(caster, info, comboPoints)
    local power = 0
    local ht = info.hasteType or "spell"

    if ht == "melee" then
        local ok1, base  = pcall(function() return caster:GetUInt32Value(MELEE_AP_BASE_OFFSET)  end)
        local ok2, bonus = pcall(function() return caster:GetUInt32Value(MELEE_AP_BONUS_OFFSET) end)
        if ok1 and base  then power = power + base  end
        if ok2 and bonus then power = power + bonus end

    elseif ht == "ranged" then
        local ok1, base  = pcall(function() return caster:GetUInt32Value(RANGED_AP_BASE_OFFSET)  end)
        local ok2, bonus = pcall(function() return caster:GetUInt32Value(RANGED_AP_BONUS_OFFSET) end)
        if ok1 and base  then power = power + base  end
        if ok2 and bonus then power = power + bonus end

    elseif info.type == "hot" then
        local ok, val = pcall(function() return caster:GetUInt32Value(HEALING_POWER_OFFSET) end)
        if ok and val then power = val end

    else  -- spell dot
        local idx = SCHOOL_TO_INDEX[info.school] or 5
        local ok, val = pcall(function() return caster:GetUInt32Value(SPELL_DMG_BASE_OFFSET + idx) end)
        if ok and val then power = val end
    end

    local total = info.baseAmount + (power * info.coeff * EXTRA_TICK_DMG_FACTOR)
    if info.comboScaling then
        local cp = (comboPoints and comboPoints > 0) and comboPoints or 1
        total = total * (cp / 5)
    end
    return math.max(math.floor(total + 0.0001), 1)
end

-- ============================================================
--  CREATURE LOOKUP
-- ============================================================
local function getCreatureFromMap(cGuid, tLowGuid, tFullGuid)
    local caster = GetPlayerByGUID(cGuid)
    if not caster then return nil end
    local okM, map = pcall(function() return caster:GetMap() end)
    if not okM or not map then return nil end
    local ok1, c1 = pcall(function() return map:GetCreature(tLowGuid) end)
    if ok1 and c1 then return c1 end
    local ok2, c2 = pcall(function() return map:GetWorldObject(tFullGuid) end)
    if ok2 and c2 then return c2 end
    return nil
end

-- ============================================================
--  ADDON MESSAGE  (via SendBroadcastMessage -> CHAT_MSG_SYSTEM)
--  SendAddonMessage is not available in this Eluna build.
--  Protocol: CATAHASTE:spellId|amount|slot|name|newHp|guidLow|dist
-- ============================================================
local function sendAddonMsg(player, msg)
    player:SendBroadcastMessage(ADDON_PREFIX .. ":" .. msg)
end

local function applyDotDamage(caster, target, spellId, amount)
    local newHp = math.max(1, target:GetHealth() - amount)
    pcall(function() target:SetHealth(newHp) end)
    local ok,  guidLow = pcall(function() return target:GetGUIDLow() end)
    local ok2, tName   = pcall(function() return target:GetName()    end)
    local ok3, dist3d  = pcall(function() return caster:GetDistance(target) end)
    local gl   = (ok  and guidLow) and guidLow or 0
    local name = (ok2 and tName)   and tName   or ""
    local dist = (ok3 and dist3d)  and math.floor(dist3d + 0.5) or 0
    local slot = getSlot(gl)
    sendAddonMsg(caster, string.format("%d|%d|%d|%s|%d|%d|%d", spellId, amount, slot, name, newHp, gl, dist))
end

-- ============================================================
--  TIMERS
--  Note: tFullGuid is ~1.74e19 (> 2^53), so Lua doubles lose
--  precision. tLowGuid is always used as the unique key instead.
-- ============================================================
local activeTimers  = {}
local hpPingRunning = {}
local castComboPoints = {}  -- [cGuid.."-"..spellId] = comboPoints at cast time

local function makeKey(cGuid, spellId, tFullGuid, tLowGuid)
    local tId = (tLowGuid and tLowGuid > 0) and tLowGuid or tFullGuid
    return tostring(cGuid) .. "-" .. tostring(spellId) .. "-" .. tostring(tId)
end

local function cancelTimer(key)
    if activeTimers[key] then
        RemoveEventById(activeTimers[key])
        activeTimers[key] = nil
    end
end

-- ============================================================
--  PHASE 1: BELOW-80 EXTRA-TICK DAMAGE CAP  ("Loot-Mode")
--  Caps the TOTAL extra-tick (SetHealth) damage dealt to a mob at
--  CAP_FRACTION of its max HP. The real engine ticks then always
--  account for > 50% of the kill, so AzerothCore awards loot/XP/quest
--  credit (m_PlayerDamageReq). Each chain's share of the remaining
--  budget is spread smoothly over its remaining ticks; multiple DoTs
--  share one budget (already-running DoTs shrink as new ones join).
--  Only for casters below level 80; level 80 keeps full server values.
-- ============================================================
local CAP_FRACTION  = 0.45
local CAP_MAX_LEVEL = 80          -- cap applies while caster level < this
local capBudget = {}   -- [tLowGuid] = { maxHp = n, used = n }
local capChains = {}   -- [tLowGuid] = { [key] = true }  (active chains, for fair sharing)

local function capChainCount(gl)
    local t = capChains[gl]
    if not t then return 1 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return (n > 0) and n or 1
end

local function capRegister(gl, key, maxHp)
    if not capBudget[gl] then capBudget[gl] = { maxHp = maxHp, used = 0, lastHp = nil } end
    local c = capChains[gl]
    if not c then c = {}; capChains[gl] = c end
    c[key] = true
end

local function capUnregisterChain(gl, key)
    local c = capChains[gl]
    if c then c[key] = nil end
end

local function capClear(gl)        -- mob dead / no longer tracked: reset budget
    if not gl then return end      -- HoT / player targets have no tLowGuid
    capBudget[gl] = nil
    capChains[gl] = nil
end

-- Scaled damage for one capped extra tick. Spreads this chain's fair share of
-- the remaining budget over its remaining ticks and consumes it. Returns 0 when
-- the budget is spent (caller then skips the tick entirely -- no fake numbers).
local function capScaledDamage(gl, rawAmount, remainingTicks, currentHp)
    local b = capBudget[gl]
    if not b then return rawAmount end          -- not capped (level 80) -> full
    -- Heal detection: if HP went UP since the last tick, the mob was healed (e.g. GM reset).
    -- The extra-tick damage we banked no longer matters → reset the budget.
    if currentHp and b.lastHp and currentHp > b.lastHp then b.used = 0 end
    if currentHp then b.lastHp = currentHp end
    local left = b.maxHp * CAP_FRACTION - b.used
    if left < 1 then return 0 end
    local rt    = (remainingTicks and remainingTicks > 0) and remainingTicks or 1
    local share = left / capChainCount(gl)
    local dmg   = math.floor(share / rt)
    if dmg < 1 then dmg = 1 end
    if dmg > left then dmg = math.floor(left) end
    if dmg < 1 then return 0 end
    b.used = b.used + dmg
    return dmg
end

-- ============================================================
--  PHASE 2: PLAYER MODE  ("CH Loot" / "CH Power")
-- ============================================================
-- Two top-level modes per player:
--   "normal" = force a haste value (0..75%) so players WITHOUT haste gear still get
--              extra ticks. Forced haste < 100% keeps the real engine ticks above
--              50% of the kill, so loot/XP come naturally. NO damage cap, full ticks.
--   "haste"  = use the player's REAL haste rating, with a Loot/Power sub-mode
--              (Loot = 45% damage cap, Power = uncapped + manual XP/credit).
local playerTop     = {}   -- [casterGuidLow] = "normal" | "haste"
local playerForced  = {}   -- [casterGuidLow] = 0..75  (forced haste %, normal mode)
local playerSub     = {}   -- [casterGuidLow] = "loot" | "power"  (haste mode)
local xpCache       = {}   -- ["pLvl:mLvl"] = xp (learned from ON_GIVE_XP)
local xpServerRate  = nil  -- derived from equal-level kills for fallback formula
local powerTracked  = {}   -- [tLowGuid] = casterGuidLow  (mobs with uncapped extra-ticks)

local function getXpForKill(pLvl, mLvl)
    local cached = xpCache[pLvl .. ":" .. mLvl]
    if cached then return cached end
    local base = 45 + 5 * mLvl
    local rate = xpServerRate or 1
    if pLvl > mLvl then
        local diff = pLvl - mLvl
        if diff >= 8 then return 0 end
        base = base * (1 - diff / 8)
    elseif mLvl > pLvl then
        base = base * (1 + 0.05 * math.min(mLvl - pLvl, 4))
    end
    return math.floor(base * rate)
end

local function startExtraTicks(cGuid, spellId, tFullGuid, tLowGuid, extraTicks, info, tickAmount, isPlayer)
    local key = makeKey(cGuid, spellId, tFullGuid, tLowGuid)
    cancelTimer(key)
    if extraTicks <= 0 then return end

    -- Cap / power-tracking only applies in HASTE mode. Normal mode caps nothing:
    -- the forced haste (<=75%) already keeps extra-tick damage well under 50%.
    if info.type == "dot" and not isPlayer then
        local casterRef  = GetPlayerByGUID(cGuid)
        local okCL, cLow = pcall(function() return casterRef and casterRef:GetGUIDLow() end)
        local top        = (okCL and cLow and playerTop[cLow]) or "normal"
        if top == "haste" then
            local okL, lvl = pcall(function() return casterRef:GetLevel() end)
            if okL and lvl and lvl < CAP_MAX_LEVEL then
                local sub = (okCL and cLow and playerSub[cLow]) or "loot"
                if sub == "loot" then
                    local tref      = getCreatureFromMap(cGuid, tLowGuid, tFullGuid)
                    local okMH, mhp = pcall(function() return tref and tref:GetMaxHealth() end)
                    if okMH and mhp and mhp > 0 then capRegister(tLowGuid, key, mhp) end
                elseif okCL and cLow then
                    powerTracked[tLowGuid] = cLow
                end
            end
        end
    end

    local normalTicks = calcWotlkTicks(info)
    local normalIntMs = info.tick * 1000

    -- Option B: place extra ticks inside the gaps between normal ticks.
    -- Gap i covers [(i-1)*normalInt, i*normalInt). With n extras per gap and
    -- sub-interval W/(n+1), all ticks land before the normal tick at i*normalInt.
    -- For integer haste multipliers (100%, 200%, 300%) this produces a perfectly
    -- uniform combined stream; for fractional multipliers it is a close approximation.
    local basePerGap = math.floor(extraTicks / normalTicks)
    local remainder  = extraTicks % normalTicks

    -- Spread the 'remainder' single extras EVENLY (centred) across the gaps instead
    -- of front-loading the first 'remainder' gaps, so higher haste feels uniformly
    -- denser rather than "fast burst at the start, normal at the end". Extra k lands
    -- in gap round((k-0.5) * normalTicks / remainder); step > 1 keeps gaps distinct.
    local bonusGap = {}
    for k = 1, remainder do
        local g = math.floor((k - 0.5) * normalTicks / remainder + 0.5)
        if g < 1 then g = 1 elseif g > normalTicks then g = normalTicks end
        bonusGap[g] = true
    end

    local absTimes = {}   -- absolute fire times in ms from cast start
    for gap = 1, normalTicks do
        local gapStartMs = (gap - 1) * normalIntMs
        local n = basePerGap + (bonusGap[gap] and 1 or 0)
        if n > 0 then
            local subIntMs = math.floor(normalIntMs / (n + 1))
            for j = 1, n do
                absTimes[#absTimes + 1] = gapStartMs + j * subIntMs
            end
        end
    end

    -- Convert to inter-tick delays for the chained timer
    local delays = {}
    local prev = 0
    for _, t in ipairs(absTimes) do
        delays[#delays + 1] = math.max(t - prev, 1)
        prev = t
    end

    local remaining = { n = #delays }

    -- TIMELINE packet --------------------------------------------------------
    -- Format: CATAHASTE:TIMELINE:slot|duration|maxHp|hp0|hp1|...|hpN
    do
        local caster = GetPlayerByGUID(cGuid)
        if caster then
            local target
            if isPlayer then
                target = GetPlayerByGUID(tFullGuid)
            else
                target = getCreatureFromMap(cGuid, tLowGuid, tFullGuid)
            end
            if target and target:IsInWorld() then
                local okH, curHp = pcall(function() return target:GetHealth() end)
                local okG, gl    = pcall(function() return target:GetGUIDLow() end)
                if okH and curHp and okG and gl then
                    local slot       = getSlot(gl)
                    local normalIntS = info.tick
                    local okMH, mhpRaw = pcall(function() return target:GetMaxHealth() end)
                    local mhp = (okMH and mhpRaw and mhpRaw > 0) and mhpRaw or 0
                    local hpParts = { tostring(slot), tostring(info.duration), tostring(mhp) }
                    local hp = curHp
                    for t = 0, info.duration do
                        local nf = math.min(math.floor(t / normalIntS), normalTicks)
                        local ef = 0
                        for _, at in ipairs(absTimes) do
                            if at <= t * 1000 then ef = ef + 1 end
                        end
                        hp = math.max(1, curHp - (nf + ef) * tickAmount)
                        hpParts[#hpParts + 1] = tostring(hp)
                    end
                    sendAddonMsg(caster, "TIMELINE:" .. table.concat(hpParts, "|"))
                end
            end
        end
    end
    -- -------------------------------------------------------------------------

    local tickIdx = { v = 1 }

    local function tick()
        local caster = GetPlayerByGUID(cGuid)
        if not caster then activeTimers[key] = nil; capUnregisterChain(tLowGuid, key); return end

        local target
        if isPlayer then
            target = GetPlayerByGUID(tFullGuid)
        else
            target = getCreatureFromMap(cGuid, tLowGuid, tFullGuid)
        end
        if not target or not target:IsInWorld() then activeTimers[key] = nil; capUnregisterChain(tLowGuid, key); return end

        local okA, hasIt = pcall(function() return target:HasAura(spellId) end)
        if not okA or not hasIt then activeTimers[key] = nil; capUnregisterChain(tLowGuid, key); return end

        local dmg = tickAmount
        if info.stackScaling then
            local okA2, aura = pcall(function() return target:GetAura(spellId) end)
            local s = 1
            if okA2 and aura then
                local okS, stacks = pcall(function() return aura:GetStackAmount() end)
                if okS and stacks and stacks > 0 then s = stacks end
            end
            local caster2 = GetPlayerByGUID(cGuid)
            if caster2 then
                dmg = calcTickAmount(caster2, info, nil)
            end
            if info.stackLinear then
                local factor = (info.type == "hot") and STACK_HEAL_FACTOR or STACK_DMG_FACTOR
                dmg = math.max(math.floor(dmg * s * factor + 0.0001), 1)
            else
                dmg = math.max(math.floor(dmg * (s / 5) * STACK_DMG_FACTOR + 0.0001), 1)
            end
        end

        if info.type == "dot" then
            local okCH, curHp = pcall(function() return target:GetHealth() end)
            dmg = capScaledDamage(tLowGuid, dmg, remaining.n, okCH and curHp or nil)
            if dmg > 0 then applyDotDamage(caster, target, spellId, dmg) end
        else
            pcall(function() caster:DealHeal(target, spellId, dmg) end)
        end

        remaining.n = remaining.n  - 1
        tickIdx.v   = tickIdx.v    + 1
        if remaining.n > 0 then
            activeTimers[key] = CreateLuaEvent(tick, delays[tickIdx.v], 1)
        else
            activeTimers[key] = nil
        end
    end

    activeTimers[key] = CreateLuaEvent(tick, delays[1], 1)
end

-- ============================================================
--  TRACKED TARGETS + BACKGROUND SCANNER  (declarations)
--  Moved here so startHpPing and handleDotHot can close over
--  these locals correctly (Lua 5.1 forward-reference rule).
-- ============================================================
local trackedTargets = {}
local bgScanRunning  = {}
local BG_SCAN_MS     = 150

-- ============================================================
--  HP PING  (every 50 ms while extra ticks are running)
--  Format: CATAHASTE:HP:slot|currentHp
--  Sends real mob HP so the client can bind nameplates by HP
--  even after the target returns from off-screen.
-- ============================================================
local function startHpPing(cGuid)
    if hpPingRunning[cGuid] then return end
    hpPingRunning[cGuid] = true

    local function ping()
        local caster = GetPlayerByGUID(cGuid)
        if not caster or not caster:IsInWorld() then
            hpPingRunning[cGuid] = nil; return
        end

        local anyActive = false
        local targets = trackedTargets[cGuid]
        if targets then
            for tKey, tInfo in pairs(targets) do
                local target
                if tInfo.isPlayer then
                    target = GetPlayerByGUID(tInfo.tFullGuid)
                else
                    target = getCreatureFromMap(cGuid, tInfo.tLowGuid, tInfo.tFullGuid)
                end
                if target and target:IsInWorld() then
                    local hasTimer = false
                    for spellId in pairs(SPELL_DB) do
                        local key = makeKey(cGuid, spellId, tInfo.tFullGuid, tInfo.tLowGuid)
                        if activeTimers[key] then hasTimer = true; break end
                    end
                    if hasTimer then
                        anyActive = true
                        local okH, hp = pcall(function() return target:GetHealth() end)
                        local okG, gl = pcall(function() return target:GetGUIDLow() end)
                        if okH and hp and okG and gl then
                            local slot = getSlot(gl)
                            sendAddonMsg(caster, string.format("HP:%d|%d", slot, hp))
                        end
                    end
                end
            end
        end

        if anyActive then
            CreateLuaEvent(ping, 50, 1)
        else
            hpPingRunning[cGuid] = nil
        end
    end

    CreateLuaEvent(ping, 50, 1)
end

-- ============================================================
--  HASTE CALCULATION + EXTRA TICK START
--  forceRestart=true on new cast: replaces the existing timer.
--  forceRestart=false in background scan: only starts if no timer is running.
-- ============================================================
local function handleDotHot(cGuid, tFullGuid, tLowGuid, spellId, info, isPlayer, forceRestart)
    local key = makeKey(cGuid, spellId, tFullGuid, tLowGuid)
    if activeTimers[key] and not forceRestart then return end

    local caster = GetPlayerByGUID(cGuid)
    if not caster then return end

    local hastePct
    do
        local okCL, cLow = pcall(function() return caster:GetGUIDLow() end)
        local top = (okCL and cLow and playerTop[cLow]) or "normal"
        if top == "haste" then
            hastePct = getHastePct(caster, info.hasteType or "spell")
        else
            -- Normal mode: forced haste from the slider (0 default = no extra ticks).
            hastePct = (okCL and cLow and playerForced[cLow]) or 0
        end
    end
    local wotlkTicks = calcWotlkTicks(info)
    local cataTicks  = calcCataTicks(info, hastePct)
    local extraTicks = cataTicks - wotlkTicks
    local cp         = castComboPoints[tostring(cGuid) .. "-" .. tostring(spellId)]
    local tickAmount = calcTickAmount(caster, info, cp)

    if extraTicks > 0 then
        startExtraTicks(cGuid, spellId, tFullGuid, tLowGuid, extraTicks, info, tickAmount, isPlayer)
        startHpPing(cGuid)
    end
end

-- ============================================================
--  TRACKED TARGETS + BACKGROUND SCANNER
--  Checks every 150 ms whether auras are still active and
--  restarts extra-tick timers as needed (e.g. after recast).
-- ============================================================

local function trackTarget(cGuid, tFullGuid, tLowGuid, isPlayer)
    if not trackedTargets[cGuid] then trackedTargets[cGuid] = {} end
    local tKey = tostring((tLowGuid and tLowGuid > 0) and tLowGuid or tFullGuid)
    trackedTargets[cGuid][tKey] = { tFullGuid=tFullGuid, tLowGuid=tLowGuid, isPlayer=isPlayer }
end

local function bgScanPlayer(cGuid)
    local caster = GetPlayerByGUID(cGuid)
    if not caster or not caster:IsInWorld() then
        trackedTargets[cGuid] = nil
        bgScanRunning[cGuid]  = nil
        return
    end
    local okA, alive = pcall(function() return caster:IsAlive() end)
    if okA and not alive then
        trackedTargets[cGuid] = nil
        bgScanRunning[cGuid]  = nil
        return
    end

    local targets = trackedTargets[cGuid]
    if not targets then
        bgScanRunning[cGuid] = nil
        return
    end

    local anyAlive = false
    for tKey, tInfo in pairs(targets) do
        local target
        if tInfo.isPlayer then
            target = GetPlayerByGUID(tInfo.tFullGuid)
        else
            target = getCreatureFromMap(cGuid, tInfo.tLowGuid, tInfo.tFullGuid)
        end

        if target and target:IsInWorld() then
            local anyAura = false
            for spellId, info in pairs(SPELL_DB) do
                local okH, hasIt = pcall(function() return target:HasAura(spellId) end)
                if okH and hasIt then
                    anyAura  = true
                    anyAlive = true
                    handleDotHot(cGuid, tInfo.tFullGuid, tInfo.tLowGuid, spellId, info, tInfo.isPlayer, false)
                end
            end
            if not anyAura then
                -- Grace period: don't remove the target immediately if no aura found.
                -- On-hit DoTs (e.g. Fireball burn) are applied after projectile travel,
                -- which can be 1-3 seconds after Event5. Without this, the bgScanner
                -- removes the target before the DoT ever appears.
                -- Once an aura has been seen (hadAura=true), remove immediately on expiry.
                local e = targets[tKey]
                e.misses = (e.misses or 0) + 1
                if e.hadAura or e.misses > 40 then  -- 40 * 150ms = 6s grace
                    targets[tKey] = nil
                    if tInfo.tLowGuid then
                        capClear(tInfo.tLowGuid)
                        powerTracked[tInfo.tLowGuid] = nil
                    end
                else
                    anyAlive = true  -- keep bgScanner running during grace period
                end
            else
                targets[tKey].hadAura = true
                targets[tKey].misses  = 0
            end
        else
            targets[tKey] = nil
            if tInfo.tLowGuid then
                capClear(tInfo.tLowGuid)
                powerTracked[tInfo.tLowGuid] = nil
            end
        end
    end

    if anyAlive then
        CreateLuaEvent(function() bgScanPlayer(cGuid) end, BG_SCAN_MS, 1)
    else
        bgScanRunning[cGuid] = nil
    end
end

local function ensureBgScan(cGuid, delayMs)
    bgScanRunning[cGuid] = true
    local d = delayMs or BG_SCAN_MS
    CreateLuaEvent(function() bgScanPlayer(cGuid) end, d, 1)
end

-- ============================================================
--  SCAN UNIT  -  checks a specific target for active auras
-- ============================================================
local function scanUnit(cGuid, tFullGuid, tLowGuid, isPlayer, forceRestart)
    local caster = GetPlayerByGUID(cGuid)
    if not caster then return end

    local target
    if isPlayer then
        target = GetPlayerByGUID(tFullGuid)
    else
        target = getCreatureFromMap(cGuid, tLowGuid, tFullGuid)
    end
    if not target then return end

    local found = false
    for spellId, info in pairs(SPELL_DB) do
        local okH, hasIt = pcall(function() return target:HasAura(spellId) end)
        if okH and hasIt then
            found = true
            handleDotHot(cGuid, tFullGuid, tLowGuid, spellId, info, isPlayer, forceRestart)
        end
    end

    if found then
        trackTarget(cGuid, tFullGuid, tLowGuid, isPlayer)
        ensureBgScan(cGuid)
    end
end

-- ============================================================
--  SPELL CAST EVENTS
--  Event5  = SPELL_CAST_START  -> records SpellId + Target
--  Event33 = SPELL_CAST_SUCCESS -> has the correct target directly
--  Fallback timer fires if Event33 doesn't arrive.
-- ============================================================
-- Per-spell pending casts, keyed [playerGuidLow][spellId].  Concurrent casts
-- (e.g. Rejuv + Lifebloom) get separate slots so they can't overwrite each
-- other, and a non-DB cast can never wipe a pending DB cast.
local pendingCasts     = {}   -- [keyId][spellId] = { spellId, cGuid, tFullGuid, tLowGuid, isPlayer }
local lastPendingSpell = {}   -- [keyId] = spellId  (Event33 carries no spellId)

-- Commits one pending cast: track the target (so the bgScanner keeps it for
-- cast-time spells) and start the extra-tick timer.
local function commitPending(p)
    trackTarget(p.cGuid, p.tFullGuid, p.tLowGuid, p.isPlayer)
    if p.tFullGuid ~= p.cGuid then
        trackTarget(p.cGuid, p.cGuid, nil, true)
    end
    local ci = SPELL_DB[p.spellId]
    handleDotHot(p.cGuid, p.tFullGuid, p.tLowGuid, p.spellId, ci, p.isPlayer, true)
    bgScanRunning[p.cGuid] = nil
    ensureBgScan(p.cGuid, 100)
end

local function onEvent5(event, player, spell, skipCheck)
    local keyId = player:GetGUIDLow()
    local ok, spellId = pcall(function() return spell:GetEntry() end)
    if not ok or not spellId then
        local ok2, sid = pcall(function() return spell:GetId() end)
        if ok2 then spellId = sid end
    end
    -- Non-DB cast: leave any pending DB casts untouched (do NOT wipe them).
    if not spellId or not SPELL_DB[spellId] then return end

    local cGuid     = player:GetGUID()
    local tFullGuid = cGuid
    local tLowGuid  = nil
    local isPlayer  = true
    local okSel, sel = pcall(function() return player:GetSelection() end)
    if okSel and sel and sel ~= false then
        local okG, fg = pcall(function() return sel:GetGUID() end)
        local okL, lg = pcall(function() return sel:GetGUIDLow() end)
        local okP, ip = pcall(function() return sel:IsPlayer() end)
        tLowGuid  = (okL and lg and lg > 0) and lg or nil
        tFullGuid = (okG and fg) or tLowGuid or cGuid
        isPlayer  = (okP and ip) or false
    end

    if not pendingCasts[keyId] then pendingCasts[keyId] = {} end
    pendingCasts[keyId][spellId] = { spellId=spellId, cGuid=cGuid,
        tFullGuid=tFullGuid, tLowGuid=tLowGuid, isPlayer=isPlayer }
    lastPendingSpell[keyId] = spellId

    -- Capture combo points at cast time for CP-scaling spells
    local info = SPELL_DB[spellId]
    if info and info.comboScaling then
        local okCP, cp = pcall(function() return player:GetComboPoints() end)
        local cpVal = (okCP and cp and cp > 0) and cp or 1
        castComboPoints[tostring(cGuid) .. "-" .. tostring(spellId)] = cpVal
    end

    -- Per-spell fallback if Event33 doesn't fire (it doesn't, in this build).
    CreateLuaEvent(function()
        local bucket  = pendingCasts[keyId]
        local pending = bucket and bucket[spellId]
        if not pending then return end       -- already committed by Event33
        bucket[spellId] = nil
        commitPending(pending)
    end, 150, 1)
end

local function onEvent33(event, player, target, skipCheck)
    local keyId   = player:GetGUIDLow()
    local spellId = lastPendingSpell[keyId]
    local bucket  = pendingCasts[keyId]
    local pending = (spellId and bucket) and bucket[spellId] or nil
    if not pending then return end
    bucket[spellId] = nil

    local cGuid     = pending.cGuid
    local tFullGuid = pending.tFullGuid
    local tLowGuid  = pending.tLowGuid
    local isPlayer  = pending.isPlayer

    if target and target ~= false then
        local okL, lg = pcall(function() return target:GetGUIDLow() end)
        local okG, fg = pcall(function() return target:GetGUID()    end)
        local okP, ip = pcall(function() return target:IsPlayer()   end)
        -- BUG FIX: In this Eluna build Event33 sometimes passes a Spell object
        -- instead of the target Unit.  Only trust the GUID when the object is a
        -- genuine Unit (creature OR player); otherwise keep the Event5 data.
        local okCr, isCr = pcall(function() return target:IsCreature() end)
        local isUnit = (okP and ip) or (okCr and isCr)
        if okL and lg and lg > 0 and isUnit then
            tLowGuid  = lg
            tFullGuid = (okG and fg) or lg
            isPlayer  = (okP and ip) or false
        end
    end

    -- Refine the captured target, then commit shortly after.
    pending.tFullGuid = tFullGuid
    pending.tLowGuid  = tLowGuid
    pending.isPlayer  = isPlayer
    CreateLuaEvent(function() commitPending(pending) end, 50, 1)
end

RegisterPlayerEvent(5,  onEvent5)
RegisterPlayerEvent(33, onEvent33)

-- ============================================================
--  PHASE 2: XP CACHE + POWER-MODE CREDIT + MODE TOGGLE
-- ============================================================

-- ON_GIVE_XP (Event 12): learn XP values from real (engine) kills
RegisterPlayerEvent(12, function(event, player, amount, victim)
    if not player or not victim then return end
    local okPL, pLvl = pcall(function() return player:GetLevel() end)
    local okML, mLvl = pcall(function() return victim:GetLevel() end)
    if not (okPL and pLvl and okML and mLvl) then return end
    xpCache[pLvl .. ":" .. mLvl] = amount
    if pLvl == mLvl then
        local base = 45 + 5 * mLvl
        if base > 0 then xpServerRate = amount / base end
    end
end)

-- ON_KILL_CREATURE (PlayerEvent 7): award XP + quest credit in Power-Mode
RegisterPlayerEvent(7, function(event, player, creature)
    if not player or not creature then return end
    local okGL, tLow = pcall(function() return creature:GetGUIDLow() end)
    if not (okGL and tLow) then return end
    local owner = powerTracked[tLow]
    if not owner then return end
    powerTracked[tLow] = nil
    local okPL0, pLow = pcall(function() return player:GetGUIDLow() end)
    if not (okPL0 and pLow == owner) then return end
    local okPL, pLvl = pcall(function() return player:GetLevel() end)
    local okML, mLvl = pcall(function() return creature:GetLevel() end)
    if okPL and pLvl and okML and mLvl and pLvl < CAP_MAX_LEVEL then
        local xp = getXpForKill(pLvl, mLvl)
        if xp and xp > 0 then
            pcall(function() player:GiveXP(xp) end)
            pcall(function()
                player:SendBroadcastMessage(
                    "[CataHaste] Power-Mode: +" .. xp .. " XP")
            end)
        end
    end
    local okE, entry = pcall(function() return creature:GetEntry() end)
    if okE and entry then
        pcall(function() player:KilledMonsterCredit(entry) end)
    end
end)

-- SAY handler: "ch set <top> <pct> <sub>" pushed by the client window.
-- (Client is authoritative; it re-sends on login and when combat ends.)
RegisterPlayerEvent(18, function(event, player, msg)
    if not msg then return end
    local top, pct, sub = msg:lower():match("^ch set (%a+) (%d+) (%a+)$")
    if not top then return end           -- not our command -> let chat through
    local okC, inCombat = pcall(function() return player:IsInCombat() end)
    if okC and inCombat then
        pcall(function() player:SendBroadcastMessage(
            "[CataHaste] Aenderung erst nach dem Kampf uebernommen.") end)
        return false                     -- still suppress the say text
    end
    local cLow = player:GetGUIDLow()
    if top ~= "haste"  then top = "normal" end
    if sub ~= "power"  then sub = "loot"   end
    local p = tonumber(pct) or 0
    if p < 0 then p = 0 elseif p > 75 then p = 75 end
    playerTop[cLow]    = top
    playerForced[cLow] = p
    playerSub[cLow]    = sub
    return false
end)

print("[CataHaste] loaded | Spells: " .. (function()
    local n=0; for _ in pairs(SPELL_DB) do n=n+1 end; return n
end)())