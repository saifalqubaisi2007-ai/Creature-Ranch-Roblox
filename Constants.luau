--[[
	Constants.lua
	CREATURE RANCH -- single source of truth for game balance.
	Shared between server and client (read-only on client).
]]

local Constants = {}

-- ===== CURRENCY =====
Constants.STARTING_SPARKS = 0

-- ===== RARITY TIERS =====
-- Order matters (index = tier rank). Each tier defines visuals + economy.
-- ===== ECONOMY REBALANCE =====
-- Rates and costs derived by simulating a real new player's first 25 minutes (starting
-- from 0 Sparks, one free Common, ~1 orb per 25s) rather than picked by feel. The old
-- curve left a player with ~3,478 Sparks after 20 minutes against a 75,000 Forest cost
-- -- roughly 4.6% of the way there, or 2+ hours to World 2.
--
-- Verified pacing on this curve:
--   3m05s  -> first Rare      (12/s)
--   10m33s -> first Epic      (55/s)
--   16m28s -> Forest unlocked (20,000)
--   23m51s -> first Legendary (260/s)
--
-- Each tier costs ~7-8x the previous while granting ~4-5x the income, so upgrading is
-- always worth it but never instant -- that gap is what creates the grind-and-payoff
-- rhythm. Mythic is deliberately far out of reach in session one.
Constants.RARITIES = {
	{
		id = "Common",
		weight = 60,			-- hatch odds weight
		sizeScale = 1.0,		-- model scale multiplier
		sparksPerSecond = 3,
		auraColor = Color3.fromRGB(190, 190, 190),
		cost = 0,				-- Sparks cost at Hatchery (0 = free starter tier)
	},
	{
		id = "Rare",
		weight = 25,
		sizeScale = 1.25,
		sparksPerSecond = 12,
		auraColor = Color3.fromRGB(85, 170, 255),
		cost = 800,
	},
	{
		id = "Epic",
		weight = 10,
		sizeScale = 1.55,
		sparksPerSecond = 55,
		auraColor = Color3.fromRGB(190, 85, 255),
		cost = 6000,
	},
	{
		id = "Legendary",
		weight = 4,
		sizeScale = 1.9,
		sparksPerSecond = 260,
		auraColor = Color3.fromRGB(255, 200, 40),
		cost = 45000,
		serverAnnounce = true,
	},
	{
		id = "Mythic",
		weight = 1,
		sizeScale = 2.3,
		sparksPerSecond = 1400,
		auraColor = Color3.fromRGB(255, 60, 120),
		cost = 300000,
		serverAnnounce = true,
		skyBeam = true,
	},
}

-- Ten named Critter species per rarity tier (50 total).
-- Each entry maps to a model in ReplicatedStorage.CritterRush.Assets.Critters
Constants.CRITTER_SPECIES = {
	Common = { "Puffling", "Mossbit", "Pebblet", "Dewdrop", "Snoozle", "Chirpin", "Fluffkit", "Twiggle", "Hoglet", "Hopps" },
	Rare = { "Sparktail", "Bubbloon", "Thistlepuff", "Wispurr", "Puddlefin", "Zippy", "Glowmoth", "Cindertot", "Shellby", "Buzzbee" },
	Epic = { "Emberpaw", "Glimmerfin", "Frostfang", "Bloomtail", "Thornback", "Sparkhorn", "Duskrunner", "Coralwing", "Drakelet", "Frostmaw" },
	Legendary = { "Stormhorn", "Auroryx", "Emberwing", "Moonstag", "Frostcrown", "Solarix", "Tidecaller", "Skyrend", "Thundermane", "Serpentide" },
	Mythic = { "Voidling", "Sunfeather", "Startide", "Prismix", "Nebulus", "Chronix", "Eclipseer", "Aetherion", "Galaxhale", "Chronofox" },
}

-- ===== CRITTER STATE MACHINE =====
-- Simplified from the old Following/Wandering/Held/Loose steal-mechanic state machine:
-- a Critter now always stays with its owner and always earns passively. No stealing,
-- no vulnerability window, no wandering-off. Kept as a single-entry table (rather than
-- removing the concept of "state" entirely) because CritterStateChanged still carries a
-- state value for idle-animation broadcast purposes -- this keeps that payload shape
-- unchanged rather than touching every remote call site for a rename.
Constants.CRITTER_STATE = {
	FOLLOWING = "Following",
}

-- Follow offset behind/beside owner while Following
Constants.FOLLOW_OFFSET_STUDS = 6
Constants.FOLLOW_CATCHUP_SPEED = 18

-- ===== EXPRESSIVE IDLE ANIMATIONS =====
-- Independent per-critter random timers so nearby critters never sync up
Constants.IDLE_ANIM_IDS = {
	"Blink", "Bounce", "Wave", "Scratch", "Yawn",
	"Sneeze", "LookAround", "Trip", "Dance",
	"Spin", "Shiver", "Hop",
}
Constants.IDLE_ANIM_INTERVAL_SECONDS = { min = 4, max = 11 }

-- ===== TREASURE FIND (item #2: "some creatures occasionally find treasure") =====
-- Deliberately random-chance-per-check rather than a fixed timer, so it genuinely
-- feels like a surprise rather than a predictable tick -- same spirit as the World
-- Events' unpredictability, but personal and per-critter instead of server-wide.
Constants.TREASURE_FIND_CHECK_INTERVAL_SECONDS = { min = 30, max = 60 }
Constants.TREASURE_FIND_CHANCE = 0.08
Constants.TREASURE_FIND_REWARD = { min = 20, max = 80 }

-- ===== CRITTER PAT (review item #1: "make Sparks generation fun") =====
-- A real, optional, ACTIVE bonus layered on top of the existing passive income drip
-- rather than replacing it -- deliberately low-risk: doesn't touch the verified
-- passive-income pipeline at all, just adds a genuine reason to walk up and interact.
Constants.PAT_REWARD = { min = 5, max = 15 }
Constants.PAT_COOLDOWN_SECONDS = 20

-- ===== MULTI-HATCH =====
-- Single-hatch-only is the #1 thing that makes a simulator exhausting past the first
-- 15 minutes. MULTI_HATCH_TIERS are the buttons offered at each Hatchery; the cap is
-- enforced server-side so a spoofed remote can't request an arbitrarily huge batch.
Constants.MULTI_HATCH_TIERS = { 1, 3, 8, 25 }
Constants.MAX_MULTI_HATCH = 25

-- ===== OFFLINE EARNINGS =====
-- Capped at 8h so leaving for a week isn't dramatically better than logging in daily --
-- the goal is rewarding RETURN, not rewarding absence. The 0.5 multiplier keeps offline
-- strictly worse than active play, so it supplements the loop instead of replacing it.
-- MIN prevents a trivial "claim 3 Sparks" popup on a quick rejoin after a disconnect.
Constants.OFFLINE_MAX_SECONDS = 8 * 60 * 60
Constants.OFFLINE_MIN_SECONDS = 60
Constants.OFFLINE_RATE_MULTIPLIER = 0.5

-- ===== PERSONALITY =====
-- "The most alive creature simulator on Roblox" -- this is the identity's foundation.
-- Rolled ONCE per individual creature at hatch time and permanent for that creature's
-- life (never re-rolled on respawn/rejoin -- see the migration in PlayerDataService).
-- Deliberately small (6 traits, no more): legibility dies past a handful, and the whole
-- point is a player can read a name ("Curious") and immediately understand what to
-- expect, the same way a player reads a rarity tier today.
--
-- favoriteAnims bias which of the EXISTING 12 idle animations this creature reaches for
-- more often (weighted PERSONALITY_FAVORITE_WEIGHT:1 against every other anim) --
-- deliberately built as a bias layer on top of the already-proven idle-anim system
-- rather than a new animation set, so day one there's already real behavioral variety
-- with zero new animation content required. intervalMult scales how often a creature
-- animates at all -- a Lazy creature should visibly move less than a Curious one.
Constants.PERSONALITIES = {
	Playful = { favoriteAnims = { "Dance", "Bounce", "Hop" }, intervalMult = 0.7, color = Color3.fromRGB(255, 170, 60) },
	Shy = { favoriteAnims = { "LookAround", "Blink", "Trip" }, intervalMult = 1.3, color = Color3.fromRGB(150, 190, 255) },
	Curious = { favoriteAnims = { "LookAround", "Sneeze", "Scratch" }, intervalMult = 0.6, color = Color3.fromRGB(140, 255, 170) },
	Lazy = { favoriteAnims = { "Yawn", "Blink", "Scratch" }, intervalMult = 1.8, color = Color3.fromRGB(190, 170, 220) },
	Brave = { favoriteAnims = { "Spin", "Hop", "Wave" }, intervalMult = 0.9, color = Color3.fromRGB(255, 90, 90) },
	Affectionate = { favoriteAnims = { "Wave", "Dance", "Bounce" }, intervalMult = 0.85, color = Color3.fromRGB(255, 130, 200) },
}
Constants.PERSONALITY_IDS = { "Playful", "Shy", "Curious", "Lazy", "Brave", "Affectionate" }
Constants.PERSONALITY_FAVORITE_WEIGHT = 4

-- ===== ECONOMY =====
Constants.EXTRA_SLOT_COSTS = { 2000, 12000, 60000 } -- Sparks cost for 2nd/3rd/4th slot (pre-gamepass)

-- ===== PROGRESSION (Player Level / XP, P8) =====
-- XP is awarded for discrete meaningful ACTIONS only (hatch, orb, quest completion,
-- collection milestone, rebirth) -- never for passive Sparks income ticks, which fire
-- many times/sec and would make leveling trivial/meaningless.
-- Level requires BASE + (level-1)*GROWTH xp to advance from that level to the next, an
-- easy-to-reason-about linearly-increasing curve (level 1->2 needs 100, 2->3 needs 140,
-- 3->4 needs 180, ...).
Constants.XP_PER_LEVEL_BASE = 100
Constants.XP_PER_LEVEL_GROWTH = 40
Constants.XP_REWARDS = {
	hatch = 10,
	orbs = 2,
	sparks = 0, -- deliberately zero: passive income must never grant XP
	explore = 30, -- discovering a landmark for the first time this session -- "Constant
	-- Discovery" is one of the game's stated design pillars, so this should feel like a
	-- real, generous reward, not an afterthought bolted onto the orbs/hatch/sparks list
	questComplete = 25,
	collectionMilestone = 50,
	rebirth = 200,
}
-- Level titles shown above a player's head when they haven't rebirthed yet (a rebirth
-- title always takes precedence once earned -- that's the stronger prestige signal and
-- the two systems shouldn't visually compete). Ordered ascending; the display picks the
-- highest entry the player's level qualifies for.
Constants.LEVEL_TITLES = {
	{ minLevel = 1, title = "Newcomer", color = Color3.fromRGB(200, 195, 215) },
	{ minLevel = 5, title = "Critter Scout", color = Color3.fromRGB(140, 255, 160) },
	{ minLevel = 10, title = "Critter Keeper", color = Color3.fromRGB(90, 190, 255) },
	{ minLevel = 20, title = "Critter Ranger", color = Color3.fromRGB(190, 130, 255) },
	{ minLevel = 35, title = "Critter Master", color = Color3.fromRGB(255, 196, 60) },
	{ minLevel = 50, title = "Critter Legend", color = Color3.fromRGB(255, 90, 140) },
}

-- ===== COSMETIC TRAILS =====
-- A genuine Sparks sink with real player choice, deliberately separate from the
-- automatic level/rebirth title system above -- those are earned progression signals
-- and shouldn't be diluted by something purchasable. Purchasing immediately equips;
-- switching between already-owned trails is free and instant. "rainbow" uses a
-- multi-stop ColorSequence instead of a flat color, priced higher as the premium option.
Constants.COSMETIC_TRAILS = {
	{ id = "skyBlue", name = "Sky Blue Trail", cost = 2000, color = Color3.fromRGB(110, 190, 255) },
	{ id = "sunsetOrange", name = "Sunset Orange Trail", cost = 2000, color = Color3.fromRGB(255, 140, 80) },
	{ id = "toxicGreen", name = "Toxic Green Trail", cost = 2000, color = Color3.fromRGB(140, 255, 90) },
	{ id = "rainbow", name = "Rainbow Trail", cost = 8000, rainbow = true },
}

-- ===== LEVEL REWARDS (item #5: "every level should unlock something") =====
-- Deliberately layered ON TOP of what levels already unlock (Ranch tiers, titles) --
-- these are the genuinely NEW rewards, so leveling up has a real, growing reason to
-- feel exciting at levels that previously had nothing tied to them at all.
-- Rewards at every 5 levels through 100, then every 10 to 200. Previously only three
-- existed (5/15/25) and the largest was 2,000 Sparks -- a rounding error once the
-- economy was rebalanced, so levelling past 25 gave literally nothing.
--
-- Sparks amounts track the economy curve rather than being flat, and the ladder mixes
-- in permanent unlocks (slots, luck, trails, auras) so a level-up is occasionally a
-- capability change rather than only a number.
Constants.LEVEL_REWARDS = {
	{ level = 5,   type = "trail",       trailId = "skyBlue",  label = "Sky Blue Trail" },
	{ level = 10,  type = "sparksBonus", amount = 5000,        label = "+5,000 Sparks" },
	{ level = 15,  type = "slot",        amount = 1,           label = "+1 Critter Slot" },
	{ level = 20,  type = "sparksBonus", amount = 20000,       label = "+20,000 Sparks" },
	{ level = 25,  type = "aura",                              label = "Golden Aura" },
	{ level = 30,  type = "luck",        amount = 0.05,        label = "+5% permanent Luck" },
	{ level = 35,  type = "sparksBonus", amount = 75000,       label = "+75,000 Sparks" },
	{ level = 40,  type = "slot",        amount = 1,           label = "+1 Critter Slot" },
	{ level = 45,  type = "sparksBonus", amount = 150000,      label = "+150,000 Sparks" },
	{ level = 50,  type = "luck",        amount = 0.10,        label = "+10% permanent Luck" },
	{ level = 55,  type = "sparksBonus", amount = 300000,      label = "+300,000 Sparks" },
	{ level = 60,  type = "slot",        amount = 1,           label = "+1 Critter Slot" },
	{ level = 65,  type = "sparksBonus", amount = 600000,      label = "+600,000 Sparks" },
	{ level = 70,  type = "luck",        amount = 0.10,        label = "+10% permanent Luck" },
	{ level = 75,  type = "sparksBonus", amount = 1200000,     label = "+1.2M Sparks" },
	{ level = 80,  type = "slot",        amount = 1,           label = "+1 Critter Slot" },
	{ level = 85,  type = "sparksBonus", amount = 2500000,     label = "+2.5M Sparks" },
	{ level = 90,  type = "luck",        amount = 0.15,        label = "+15% permanent Luck" },
	{ level = 95,  type = "sparksBonus", amount = 5000000,     label = "+5M Sparks" },
	{ level = 100, type = "slot",        amount = 2,           label = "+2 Critter Slots" },
	{ level = 110, type = "sparksBonus", amount = 12000000,    label = "+12M Sparks" },
	{ level = 120, type = "luck",        amount = 0.15,        label = "+15% permanent Luck" },
	{ level = 130, type = "sparksBonus", amount = 30000000,    label = "+30M Sparks" },
	{ level = 140, type = "slot",        amount = 1,           label = "+1 Critter Slot" },
	{ level = 150, type = "luck",        amount = 0.20,        label = "+20% permanent Luck" },
	{ level = 160, type = "sparksBonus", amount = 120000000,   label = "+120M Sparks" },
	{ level = 170, type = "slot",        amount = 1,           label = "+1 Critter Slot" },
	{ level = 180, type = "sparksBonus", amount = 300000000,   label = "+300M Sparks" },
	{ level = 190, type = "luck",        amount = 0.25,        label = "+25% permanent Luck" },
	{ level = 200, type = "slot",        amount = 2,           label = "+2 Critter Slots" },
}

-- ===== ACHIEVEMENTS (P8) =====
-- Pure data only, deliberately no embedded check functions -- consistent with how
-- QUEST_POOL/COLLECTION_MILESTONES already separate data from logic, and this table is
-- required on the client too (for a future browsable panel), where server-only checking
-- logic has no business living anyway. `statKey` names a field in the stats table
-- PlayerDataService.CheckAchievements builds each call (some keys are stored profile
-- fields directly, others -- collectionOwnedCount, level -- are derived fresh each time,
-- exactly mirroring how CheckCollectionMilestone already derives ownedCount on the fly
-- rather than caching it).
-- One-shot "first time" achievements. These stay finite on purpose -- they mark genuine
-- milestones that only happen once. Repeatable progress lives in ACHIEVEMENT_CHAINS
-- below, which generates tiers procedurally and never runs out.
Constants.ACHIEVEMENTS = {
	{ id = "firstHatch", title = "Getting Started", desc = "Hatch your first Critter", reward = 500, statKey = "hatchesTotal", threshold = 1 },
	{ id = "rebirth1", title = "Reborn", desc = "Complete your first Rebirth", reward = 25000, statKey = "rebirths", threshold = 1 },
	{ id = "shinyHunter", title = "Shiny Hunter", desc = "Hatch a Shiny Critter", reward = 5000, statKey = "hasOwnedShiny", threshold = 1 },
	{ id = "firstFuse", title = "Alchemist", desc = "Fuse your first creature", reward = 15000, statKey = "fusionsTotal", threshold = 1 },
}

-- ===== TIERED ACHIEVEMENTS (infinite) =====
-- The six above are one-time "firsts" and permanently exhaust. These are the endless
-- track: each chain keeps generating the next tier forever, so a veteran always has
-- something ticking up rather than a fully-cleared list.
--
-- Tiers are GENERATED rather than listed, so the chain never runs out and the table
-- stays readable. Thresholds scale x2.5 and rewards x3 per tier -- rewards outpace
-- thresholds deliberately, so later tiers stay worth chasing as income grows.
Constants.ACHIEVEMENT_CHAINS = {
	{ id = "hatcher",   title = "Hatcher",       statKey = "hatchesTotal",         base = 10,  desc = "Hatch %s Critters" },
	{ id = "orbs",      title = "Orb Collector", statKey = "orbsCollectedTotal",   base = 100, desc = "Collect %s Spark Orbs" },
	-- collectionOwnedCount is HARD-CAPPED by how many species exist (110), so an
	-- unbounded x2.5 chain would demand 125+ species and stall forever at tier 3.
	-- maxTier ends the chain at the last achievable value instead.
	{ id = "collector", title = "Collector",     statKey = "collectionOwnedCount", base = 20,  desc = "Own %s different species", maxTier = 2 },
	{ id = "leveler",   title = "Veteran",       statKey = "level",                base = 20,  desc = "Reach Level %s" },
	{ id = "fuser",     title = "Fusionist",     statKey = "fusionsTotal",         base = 5,   desc = "Fuse %s times" },
}
Constants.ACHIEVEMENT_TIER_THRESHOLD_SCALE = 2.5
Constants.ACHIEVEMENT_TIER_REWARD_SCALE = 3
Constants.ACHIEVEMENT_TIER_BASE_REWARD = 1000

-- Returns the achievement definition for a given chain at a given tier (1-indexed).
-- Pure function of (chain, tier) so server grants and client display can never disagree.
function Constants.GetAchievementTier(chain, tier)
	local threshold = math.floor(chain.base * (Constants.ACHIEVEMENT_TIER_THRESHOLD_SCALE ^ (tier - 1)))
	local reward = math.floor(Constants.ACHIEVEMENT_TIER_BASE_REWARD
		* (Constants.ACHIEVEMENT_TIER_REWARD_SCALE ^ (tier - 1)))
	return {
		id = chain.id .. "_t" .. tier,
		title = chain.title .. " " .. tier,
		desc = string.format(chain.desc, Constants.FormatNumber(threshold)),
		statKey = chain.statKey,
		threshold = threshold,
		reward = reward,
		tier = tier,
		chainId = chain.id,
	}
end

-- ===== LONG-TERM GOALS (item #11: "never let 'what now?' happen") =====
-- Deliberately distinct from Achievements (mostly one-time firsts) and the rotating
-- Quest system (short, resets constantly) -- these are the big, standing "what am I
-- working toward" targets that stay visible across many play sessions. statKey mirrors
-- Achievements' pattern (computed fresh from real profile/derived stats, never cached).
-- "100 rebirths" from the design brainstorm doesn't fit this game's actual 5-tier
-- rebirth cap (Constants.REBIRTH_TIERS has exactly 5 entries, and PerformRebirth
-- rejects a 6th) -- corrected to the real achievable ceiling, reaching the final tier.
Constants.LONG_TERM_GOALS = {
	{ id = "level50", title = "Reach Level 50", statKey = "level", threshold = 50 },
	{ id = "income100", title = "Reach 100 Sparks/sec income", statKey = "totalIncome", threshold = 100 },
	{ id = "maxRebirth", title = "Reach the Eternal Rebirth Tier", statKey = "rebirths", threshold = 5 },
	{ id = "eggs1000", title = "Hatch 1,000 Critters", statKey = "hatchesTotal", threshold = 1000 },
	{ id = "fullCollection", title = "Complete the Collection Book", statKey = "collectionOwnedCount", threshold = 50 },
	{ id = "orbs500", title = "Collect 500 Spark Orbs", statKey = "orbsCollectedTotal", threshold = 500 },
	{ id = "unlockVolcano", title = "Unlock the Volcano", statKey = "volcanoUnlocked", threshold = 1 },
}

-- ===== SHINY VARIANTS =====
-- Every hatch has a chance to be Shiny: same species, 1.5x income, a distinct sparkle
-- aura, and its own line in the hatch cinematic. This is the actual "one more egg"
-- driver — species choice already existed, but nothing made a hatch feel like a pull.
Constants.SHINY_CHANCE = 1 / 25
Constants.SHINY_INCOME_MULTIPLIER = 1.5

-- ===== ONBOARDING RIG =====
-- The first few PAID hatches are quietly upgraded to a better tier than the player
-- paid for. Standard practice in the genre: a new player who opens three Commons in a
-- row concludes the game is boring before its systems have a chance to show themselves.
--
-- What this does NOT do: it never downgrades, never touches free/starter grants, and
-- switches to true RNG permanently after the listed hatches. `upgradeTo` is the tier
-- the result is promoted to -- the player still pays only what they chose to buy, so
-- the rig can only ever be a pleasant surprise, never a loss.
--
-- Indexed by PAID hatch number (hatchesTotal at time of purchase, +1).
-- `tiersUp` promotes RELATIVE to whatever the player bought, rather than naming a
-- fixed tier. A fixed target only works if you know what they purchased -- and since
-- Common is free (cost 0, not purchasable), the cheapest real egg IS Rare, so a
-- "guarantee Rare" rig would silently never fire. Relative promotion always lands.
Constants.ONBOARDING_HATCH_RIG = {
	[1] = { tiersUp = 0 },                 -- honest roll, sets the baseline
	[2] = { tiersUp = 0 },                 -- honest roll
	[3] = { tiersUp = 1 },                 -- guaranteed one tier up: the "oh!" beat
	[5] = { tiersUp = 1, chance = 0.35 },  -- a second, less certain spike
}
-- After this many paid hatches, the rig is permanently off and RNG is fully honest.
Constants.ONBOARDING_RIG_LAST_HATCH = 5

-- Sparks threshold at which onboarding teases the Forest gate. ~60% of the 20,000
-- unlock cost -- close enough that the goal feels reachable, far enough that the tip
-- lands before the player is already standing at the gate.
Constants.WORLD_TEASE_SPARKS = 12000

-- ===== NEXT GOAL LADDER =====
-- A single always-visible objective that auto-advances, so the player never wonders
-- what to do. Deliberately SEQUENTIAL (not a pool like QUEST_POOL): the whole point is
-- a guided path through the game's systems in the order they become relevant.
--
-- statKey values are resolved by PlayerDataService.GetNextGoal against the same stats
-- table Achievements/Goals already use, so a goal can never drift out of sync with the
-- real progression it's tracking.
--
-- Ordered to mirror the rebalanced economy's actual pacing: the Forest goal lands
-- around the 16-minute mark a real player reaches it, not an arbitrary early number.
Constants.NEXT_GOAL_LADDER = {
	{ id = "hatch1",      title = "Hatch your first egg",        statKey = "hatchesTotal",         target = 1,     reward = 250 },
	{ id = "orbs10",      title = "Collect 10 Spark Orbs",       statKey = "orbsCollectedTotal",   target = 10,    reward = 500 },
	{ id = "hatch10",     title = "Hatch 10 eggs",               statKey = "hatchesTotal",         target = 10,    reward = 1500 },
	{ id = "level5",      title = "Reach Level 5",               statKey = "level",                target = 5,     reward = 2500 },
	{ id = "species10",   title = "Collect 10 species",          statKey = "collectionOwnedCount", target = 10,    reward = 4000 },
	{ id = "forest",      title = "Unlock the Forest",           statKey = "worldsUnlocked",       target = 1,     reward = 8000 },
	{ id = "hatch50",     title = "Hatch 50 eggs",               statKey = "hatchesTotal",         target = 50,    reward = 12000 },
	{ id = "level15",     title = "Reach Level 15",              statKey = "level",                target = 15,    reward = 20000 },
	{ id = "beach",       title = "Unlock the Beach",            statKey = "worldsUnlocked",       target = 2,     reward = 35000 },
	{ id = "fuse1",       title = "Fuse your first creature",    statKey = "fusionsTotal",         target = 1,     reward = 50000 },
	{ id = "rebirth1",    title = "Complete your first Rebirth", statKey = "rebirths",             target = 1,     reward = 80000 },
	{ id = "species25",   title = "Collect 25 species",          statKey = "collectionOwnedCount", target = 25,    reward = 150000 },
	{ id = "desert",      title = "Unlock the Desert",           statKey = "worldsUnlocked",       target = 3,     reward = 300000 },
	{ id = "level30",     title = "Reach Level 30",              statKey = "level",                target = 30,    reward = 600000 },
	{ id = "hatch250",    title = "Hatch 250 eggs",              statKey = "hatchesTotal",         target = 250,   reward = 1200000 },
	{ id = "rebirth2",    title = "Reach Rebirth 2",             statKey = "rebirths",             target = 2,     reward = 2500000 },
	{ id = "snow",        title = "Unlock the Snow",             statKey = "worldsUnlocked",       target = 4,     reward = 5000000 },
	{ id = "species40",   title = "Collect 40 species",          statKey = "collectionOwnedCount", target = 40,    reward = 10000000 },
	{ id = "caves",       title = "Unlock the Crystal Caves",    statKey = "worldsUnlocked",       target = 5,     reward = 25000000 },
	{ id = "rebirth3",    title = "Reach Rebirth 3",             statKey = "rebirths",             target = 3,     reward = 60000000 },
	{ id = "volcano",     title = "Unlock the Volcano",          statKey = "worldsUnlocked",       target = 6,     reward = 150000000 },
	{ id = "collection",  title = "Complete the Collection Book", statKey = "collectionOwnedCount", target = 50,   reward = 400000000 },
	{ id = "rebirth5",    title = "Reach the Eternal Tier",      statKey = "rebirths",             target = 5,     reward = 1000000000 },
}

-- ===== DAILY LOGIN STREAK =====
-- Replaces the original flat 50 + 25/day curve, which topped out at 200 Sparks -- far
-- too small next to a single Playtime milestone (40K) or an egg (25K), so it read as a
-- rounding error rather than a reason to come back.
--
-- Day 7 is deliberately a large jump AND a Limited Egg token: the whole point of a
-- streak is that the last step must be worth protecting the first six for.
Constants.LOGIN_STREAK_REWARDS = {
	{ day = 1, sparks = 1000 },
	{ day = 2, sparks = 2500 },
	{ day = 3, sparks = 5000 },
	{ day = 4, sparks = 9000 },
	{ day = 5, sparks = 15000 },
	{ day = 6, sparks = 25000 },
	{ day = 7, sparks = 60000, limitedEggToken = true },
}
Constants.LOGIN_STREAK_MAX = 7

-- ===== PLAYTIME REWARDS =====
-- Escalating rewards at fixed in-SESSION milestones. Deliberately session-based (reset
-- on every join) rather than cumulative-lifetime: the goal is extending the CURRENT
-- session, so a returning player should always have the full ladder ahead of them
-- again. Rewards escalate steeply so the later tiers are genuinely worth staying for.
Constants.PLAYTIME_REWARDS = {
	{ minutes = 5,  sparks = 500 },
	{ minutes = 15, sparks = 2000 },
	{ minutes = 30, sparks = 6000 },
	{ minutes = 60, sparks = 18000 },
	{ minutes = 90, sparks = 40000 },
}

-- ===== LIMITED EGG (weekly rotation) =====
-- The single strongest Day-7 retention lever: an egg containing exclusive species that
-- rotates every real week and NEVER returns. Creates genuine urgency ("I have to hatch
-- this before Sunday") that no permanent content can replicate.
--
-- Rotation is derived from the real-world week number rather than stored per-player, so
-- every player on every server sees the SAME limited egg at the same time -- essential
-- for it to feel like a shared event rather than a personal RNG roll.
Constants.LIMITED_EGG_COST = 25000
Constants.LIMITED_EGG_ROTATIONS = {
	{
		id = "CelestialWeek",
		displayName = "Celestial Egg",
		auraColor = Color3.fromRGB(150, 190, 255),
		sparksPerSecond = 260,
		species = { "Astrafox", "Lunamoth", "Cometkit", "Starhorn", "Novabloom", "Zephyrid" },
	},
	{
		id = "AbyssWeek",
		displayName = "Abyss Egg",
		auraColor = Color3.fromRGB(120, 90, 200),
		sparksPerSecond = 260,
		species = { "Deepfin", "Voidcrab", "Gloomray", "Inkspire", "Trenchmaw", "Siltwyrm" },
	},
	{
		id = "EmberWeek",
		displayName = "Ember Egg",
		auraColor = Color3.fromRGB(255, 140, 70),
		sparksPerSecond = 260,
		species = { "Cinderwing", "Flarepup", "Ashmane", "Kindlefox", "Pyrelet", "Emberox" },
	},
	{
		id = "VerdantWeek",
		displayName = "Verdant Egg",
		auraColor = Color3.fromRGB(120, 230, 130),
		sparksPerSecond = 260,
		species = { "Petalynx", "Rootling", "Vinewisp", "Bloomhart", "Sagefern", "Thornbud" },
	},
}

-- Returns (rotationTable, secondsRemaining) for the CURRENT week. Uses os.time()
-- divided by a week so it advances automatically forever without any scheduled job or
-- stored state -- a server that boots months from now computes the same answer as one
-- booting today.
local SECONDS_PER_WEEK = 7 * 24 * 60 * 60
function Constants.GetCurrentLimitedEgg()
	local weekIndex = math.floor(os.time() / SECONDS_PER_WEEK)
	local rotation = Constants.LIMITED_EGG_ROTATIONS[(weekIndex % #Constants.LIMITED_EGG_ROTATIONS) + 1]
	local secondsIntoWeek = os.time() % SECONDS_PER_WEEK
	return rotation, SECONDS_PER_WEEK - secondsIntoWeek
end

-- Effective shiny chance for a given player, mirroring the exact roll in
-- CritterService.SpawnForPlayer (base x Lucky Hour event x permanent rebirth luck).
-- Lives here so the displayed odds and the actual roll can never drift apart -- a
-- posted percentage that doesn't match reality is worse than posting none at all.
-- Single source of truth for a player's total luck multiplier. Every luck source
-- multiplies in here, so adding a new one (a potion, an event, a pass) means touching
-- exactly one function rather than hunting down every roll site.
--
-- Takes a plain table of flags rather than a Player so it's callable from the client
-- (for display) and the server (for rolls) with identical results -- a luck number the
-- HUD shows that doesn't match the actual roll would be worse than showing nothing.
function Constants.GetTotalLuck(opts)
	opts = opts or {}
	local luck = 1
	-- Must go through GetRebirthTier, NOT REBIRTH_TIERS[n] directly: the array only holds
	-- the 5 authored tiers, so a direct index returns nil for anyone past R5 and silently
	-- drops their entire rebirth luck bonus. Found live at R9, where a tier granting
	-- luckBonus=4 was contributing nothing.
	local rebirthTier = Constants.GetRebirthTier(opts.rebirthCount or 0)
	if rebirthTier and rebirthTier.luckBonus then luck *= rebirthTier.luckBonus end
	if opts.eventMult then luck *= opts.eventMult end
	if opts.hasLuckPass then luck *= Constants.LUCK_PASS_MULTIPLIER end
	if opts.hasVip then luck *= Constants.VIP_LUCK_MULTIPLIER end
	if opts.potionMult then luck *= opts.potionMult end
	-- Permanent Collection Book completion bonus, expressed as a fraction (0.25 = +25%).
	if opts.collectionLuckBonus then luck *= (1 + opts.collectionLuckBonus) end
	-- Permanent luck earned from level rewards, same additive-fraction form.
	if opts.levelLuckBonus then luck *= (1 + opts.levelLuckBonus) end
	-- Ranch Power perk, same additive-fraction form.
	if opts.ranchLuckBonus then luck *= (1 + opts.ranchLuckBonus) end
	-- World relic milestones.
	if opts.relicLuckBonus then luck *= (1 + opts.relicLuckBonus) end
	return luck
end

function Constants.GetEffectiveShinyChance(rebirthCount, eventMult, opts)
	opts = opts or {}
	opts.rebirthCount = rebirthCount
	opts.eventMult = eventMult
	return math.min(Constants.SHINY_CHANCE * Constants.GetTotalLuck(opts), 1)
end

-- Returns a copy of `rarities` with weights biased by luck. At luck == 1 the weights are
-- returned unchanged, so the no-luck path is exactly the old behaviour.
function Constants.GetLuckWeightedRarities(rarities, luck)
	if not luck or luck <= 1 then return rarities end
	local out = {}
	local baseWeight = rarities[1] and rarities[1].weight or 1
	for i, tier in ipairs(rarities) do
		local copy = tier
		-- Scale each tier's weight UP by how rare it is relative to Common, so luck
		-- pulls probability mass toward the top of the table.
		local rarityFactor = baseWeight / math.max(tier.weight, 0.0001)
		local boost = rarityFactor ^ (Constants.LUCK_RARITY_EXPONENT * math.log(luck, 2))
		out[i] = { tier = copy, weight = tier.weight * boost }
	end
	return out
end

-- ===== FUSION / VARIANT TIERS =====
-- Turns duplicates from junk into currency: combine N of the same species+variant into
-- one of the next variant up. This is the single feature that retroactively gives value
-- to every creature already in a player's collection.
--
-- Deliberately a SEPARATE axis from Shiny, not a replacement for it: Shiny is a rare
-- roll at hatch time, variant is earned through fusion. A creature can be both, and the
-- multipliers stack -- so a Shiny Rainbow is a genuine trophy rather than the two
-- systems fighting over the same slot.
Constants.VARIANT_TIERS = {
	{ id = "Normal", displayName = "", multiplier = 1, color = nil },
	{ id = "Gold", displayName = "Gold", multiplier = 3, color = Color3.fromRGB(255, 205, 60) },
	{ id = "Rainbow", displayName = "Rainbow", multiplier = 10, color = Color3.fromRGB(255, 120, 220) },
	-- Endgame tiers. A player who fused everything to Rainbow previously had no further
	-- use for duplicates -- the whole duplicate sink dead-ended. These extend it into a
	-- genuine long-tail chase: each costs 5 of the previous, so a single Void requires
	-- 625 base creatures and an Eclipse requires 15,625.
	{ id = "Void", displayName = "Void", multiplier = 40, color = Color3.fromRGB(150, 90, 255) },
	{ id = "Prism", displayName = "Prism", multiplier = 175, color = Color3.fromRGB(120, 255, 235) },
	{ id = "Eclipse", displayName = "Eclipse", multiplier = 800, color = Color3.fromRGB(255, 245, 200) },
}Constants.FUSION_REQUIRED_COUNT = 5

-- Index lookup so callers never scan the array by hand.
Constants.VARIANT_INDEX = {}
for i, v in ipairs(Constants.VARIANT_TIERS) do
	Constants.VARIANT_INDEX[v.id] = i
end

-- ===== INFINITE VARIANT TIERS (endgame) =====
-- Fusion previously dead-ended at Rainbow: a maxed player's duplicates became worthless
-- again, which is exactly the problem fusion was built to solve. Tiers beyond the three
-- authored ones are generated forever, so duplicates never stop having a use.
--
-- This is the endgame progression layer. It's deliberately built on fusion rather than
-- as a separate system: the deepest sink in the game should be the one that consumes the
-- most creatures, and every 5 duplicates -> 1 next-tier keeps compounding indefinitely.
Constants.VARIANT_GENERATED_MULT_SCALE = 3.2
Constants.VARIANT_GENERATED_NAME = "Prismatic"

function Constants.GetVariantTier(n)
	if n <= 0 then return nil end
	local authored = Constants.VARIANT_TIERS[n]
	if authored then return authored end
	local last = Constants.VARIANT_TIERS[#Constants.VARIANT_TIERS]
	local steps = n - #Constants.VARIANT_TIERS
	-- Hue cycles per tier so each generated variant is visually distinct rather than
	-- every one sharing Rainbow's colour.
	local hue = (steps * 0.13) % 1
	return {
		id = Constants.VARIANT_GENERATED_NAME .. steps,
		displayName = Constants.VARIANT_GENERATED_NAME .. " " .. steps,
		multiplier = last.multiplier * (Constants.VARIANT_GENERATED_MULT_SCALE ^ steps),
		color = Color3.fromHSV(hue, 0.85, 1),
		generated = true,
	}
end

-- Index of a variant by id, including generated ones. Returns nil for unknown ids.
function Constants.GetVariantIndex(variantId)
	local authored = Constants.VARIANT_INDEX[variantId]
	if authored then return authored end
	local steps = tostring(variantId):match("^" .. Constants.VARIANT_GENERATED_NAME .. "(%d+)$")
	if steps then return #Constants.VARIANT_TIERS + tonumber(steps) end
	return nil
end
-- ===== COLLECTION BOOK MILESTONES (Achievements) =====
-- One-time Sparks bonuses as the Book fills up — reuses the existing collection
-- tracking, so this is pure payoff logic with no new data model.
Constants.COLLECTION_MILESTONES = {
	{ count = 5, reward = 500 },
	{ count = 10, reward = 1500 },
	{ count = 15, reward = 3000 },
	{ count = 20, reward = 6000 },
	{ count = 25, reward = 12000 },
	{ count = 30, reward = 25000 },
	{ count = 35, reward = 45000 },
	{ count = 40, reward = 80000 },
	{ count = 45, reward = 140000 },
	{ count = 50, reward = 250000 }, -- full Collection Book, all 50 species
}
-- Prestige loop: reset your Sparks and Critters for a permanent income multiplier
-- and a visible aura tier everyone can see. The "2-3 hours before you've seen it all"
-- lever — without this, income growth has a ceiling; with it, there isn't one.
-- magnetRadius (item #6): PERMANENT, stacking per-tier -- Spark Orbs within this range
-- auto-collect, no walking required. Also closes the "magnet upgrade" gap from the
-- core-loop pass (item #1) -- same system, earned through rebirth instead of purchased.
-- luckBonus: permanent multiplier on Shiny odds, stacking with the Lucky Hour event.
-- speedBonus / xpMultBonus (item #6, completing the list): permanent WalkSpeed add-on
-- and permanent XP multiplier -- the two "every rebirth should make you stronger"
-- dimensions that weren't covered by magnetRadius/luckBonus/the income multiplier.
Constants.REBIRTH_TIERS = {
	{ cost = 150000, multiplier = 1.5, title = "Reborn", auraColor = Color3.fromRGB(180, 220, 255),
		magnetRadius = 8, luckBonus = 1.2, speedBonus = 2, xpMultBonus = 1.1 },
	{ cost = 1200000, multiplier = 2.0, title = "Twice Reborn", auraColor = Color3.fromRGB(150, 255, 200),
		magnetRadius = 14, luckBonus = 1.5, speedBonus = 4, xpMultBonus = 1.25 },
	{ cost = 9000000, multiplier = 3.0, title = "Ascended", auraColor = Color3.fromRGB(255, 210, 100),
		magnetRadius = 20, luckBonus = 1.8, speedBonus = 6, xpMultBonus = 1.4 },
	{ cost = 70000000, multiplier = 4.5, title = "Ascended II", auraColor = Color3.fromRGB(255, 150, 220),
		magnetRadius = 28, luckBonus = 2.2, speedBonus = 8, xpMultBonus = 1.6 },
	{ cost = 600000000, multiplier = 7.0, title = "Eternal", auraColor = Color3.fromRGB(255, 90, 90),
		magnetRadius = 38, luckBonus = 3.0, speedBonus = 10, xpMultBonus = 2.0 },
}
-- ===== INFINITE REBIRTH =====
-- The five tiers above are the hand-authored, NAMED prestige levels. Beyond them, tiers
-- are generated forever -- previously PerformRebirth returned "max rebirth reached" at 5
-- and the entire prestige loop dead-ended, which also froze the rebirth-scaled quest
-- targets and luck bonuses that now depend on this number climbing.
--
-- Generated tiers keep the same shape as authored ones so every consumer (income
-- multiplier, luck, speed, XP, quest scaling) works unchanged.
Constants.REBIRTH_COST_SCALE = 6.5
Constants.REBIRTH_MULT_SCALE = 1.5
Constants.REBIRTH_GENERATED_TITLE = "Eternal"

function Constants.GetRebirthTier(n)
	if n <= 0 then return nil end
	local authored = Constants.REBIRTH_TIERS[n]
	if authored then return authored end

	-- Extrapolate from the last authored tier. `steps` is how far past it we are.
	local last = Constants.REBIRTH_TIERS[#Constants.REBIRTH_TIERS]
	local steps = n - #Constants.REBIRTH_TIERS
	return {
		title = Constants.REBIRTH_GENERATED_TITLE .. " " .. (steps + 1),
		cost = math.floor(last.cost * (Constants.REBIRTH_COST_SCALE ^ steps)),
		multiplier = last.multiplier * (Constants.REBIRTH_MULT_SCALE ^ steps),
		-- Secondary bonuses keep growing but far more slowly than the income multiplier,
		-- so they stay meaningful without trivialising luck or outrunning WalkSpeed's
		-- practical ceiling.
		magnetRadius = last.magnetRadius + steps * 4,
		luckBonus = last.luckBonus + steps * 0.25,
		speedBonus = math.min(last.speedBonus + steps, 30),
		-- Field is xpMultBonus (matching the authored tiers), not xpMult -- an earlier
		-- version invented the shorter name and the generator errored on nil arithmetic.
		xpMultBonus = last.xpMultBonus + steps * 0.25,
		auraColor = last.auraColor,
		generated = true,
	}
end

-- ===== MONETIZATION =====
-- REAL, LIVE IDs — these are actual Game Passes / Developer Products already created for
-- this experience via the Creator Dashboard. Do NOT edit these values casually; changing
-- an id here repoints real purchase flow at a different (or nonexistent) product. The
-- comment used to say "placeholder id = 0" from before these were filled in — that was
-- stale and has misled at least one read-through of this file; corrected during the
-- pre-launch monetization verification pass.
Constants.GAME_PASSES = {
	DoubleSparks = {
		id = 1933875962,
		name = "2x Sparks",
		description = "Permanently doubles your passive Sparks income.",
	},
	InstantExtraSlot = {
		id = 1932200382,
		name = "Extra Critter Slot",
		description = "Own 2 Critters at once, free — skips the Spark cost entirely.",
	},
	VipTrail = {
		id = 1933365951,
		name = "VIP Sparkle Trail",
		description = "A cosmetic sparkle trail behind your Critter. Shows off, no gameplay effect.",
	},
	-- id = 0 until this pass is created on the Creator Dashboard. MonetizationService's
	-- existing guard treats id == 0 as "not purchasable yet" and never grants it, so
	-- shipping with the placeholder is safe -- the shop row simply won't do anything
	-- until the real ID is filled in.
	AutoHatch = {
		id = 1937712727,
		name = "Auto Hatch",
		description = "Automatically hatches your chosen egg every few seconds while you play.",
	},
	-- VIP: the recurring-value pass. Deliberately a BUNDLE of small permanent perks plus
	-- a daily payout, rather than one big multiplier -- a player who buys VIP should feel
	-- it every session, not just once. id = 0 until created on the Creator Dashboard.
	VIP = {
		id = 1939392366,
		name = "VIP",
		description = "Daily Sparks bonus, +25% income, a gold nametag, and 1 extra Critter slot.",
	},
	-- Luck pass: doubles total luck, raising both shiny odds and rare-tier odds on every
	-- hatch. id = 0 until created on the Creator Dashboard.
	-- Equip slots are THE progression axis under the equip model, so a slot pass is the
	-- most honest kind of purchase here: it doesn't multiply numbers, it lets a player
	-- use more of what they already own.
	MultiSlotPass = {
		id = 1935052463,
		name = "+5 Equip Slots",
		description = "Equip 5 more creatures at once, permanently. More equipped means more Sparks every second.",
	},
	-- Targets short-session players specifically -- the group that's otherwise hardest
	-- to monetise, since they see the least of the active loop.
	OfflinePass = {
		id = 1935316238,
		name = "2x Offline Earnings",
		description = "Double the Sparks your creatures earn while you're offline.",
	},
	LuckPass = {
		id = 1935615103,
		name = "2x Luck",
		description = "Doubles your Luck — better odds for Shiny creatures and rare tiers, forever.",
	},
}

Constants.DEV_PRODUCTS = {
	-- Spark Packs. Amounts raised 100x and 200x from the original 500/2,500, which a
	-- player earned free within their first minutes -- a visibly bad offer makes players
	-- distrust the whole shop. 50K is five Forest unlocks; 500K nearly reaches World 4.
	--
	-- Large is 10x the Sparks for 4x the price on purpose: the bigger pack has to be
	-- OBVIOUSLY better value, or it just pads the shop without ever selling.
	SparkPackSmall = { id = 3613109342, name = "Spark Pack (Small)", sparks = 50000 },
	SparkPackLarge = { id = 3613109304, name = "Spark Pack (Large)", sparks = 500000 },
	-- Starter Pack: a one-time, first-24-hours bundle. id = 0 until it's created on the
	-- Creator Dashboard; MonetizationService's existing guard treats id == 0 as
	-- not-purchasable, so shipping with the placeholder is safe.
	--
	-- Bundles Sparks + slots + a boost rather than pure currency, because the point is
	-- accelerating a new player past the slowest part of the curve, not selling them a
	-- number. Deliberately the best Sparks-per-Robux in the game and never repeatable --
	-- that's what makes it convert.
	StarterPack = {
		id = 3629305144,
		name = "Starter Pack",
		sparks = 25000,
		extraSlots = 2,
		limitedEggTokens = 1,
		oneTimeOnly = true,
	},
}

-- ===== WEEKLY LEADERBOARD =====
-- A competitive track that RESETS, alongside the permanent all-time board. The all-time
-- board is effectively frozen for anyone who didn't start early -- a new player can see
-- it but never realistically enter it, so it stops being a goal. A weekly reset gives
-- everyone a live race they can actually win.
--
-- Scores are "Sparks earned THIS WEEK", not total balance, so it measures current
-- activity rather than accumulated wealth.
Constants.WEEKLY_LEADERBOARD_REWARDS = {
	{ rank = 1,  sparks = 5000000, label = "1st Place" },
	{ rank = 2,  sparks = 3000000, label = "2nd Place" },
	{ rank = 3,  sparks = 2000000, label = "3rd Place" },
	{ rank = 10, sparks = 500000,  label = "Top 10" },
	{ rank = 50, sparks = 100000,  label = "Top 50" },
}

-- Returns the reward for a given finishing rank, or nil if unplaced.
function Constants.GetWeeklyReward(rank)
	for _, r in ipairs(Constants.WEEKLY_LEADERBOARD_REWARDS) do
		if rank <= r.rank then return r end
	end
	return nil
end

-- Week index from real time, so every server agrees on which week it is without any
-- stored state -- same approach as the Limited Egg rotation.
function Constants.GetWeekIndex()
	return math.floor(os.time() / (7 * 24 * 60 * 60))
end

-- ===== EQUIP SLOTS =====
-- Only EQUIPPED creatures generate Sparks. Everything else lives in a large inventory.
--
-- This replaces the old model where every owned creature earned simultaneously and the
-- slot cap doubled as an inventory cap. That model had a real flaw: hitting the cap
-- EVICTED a creature, so hatching became punishing rather than exciting. Splitting the
-- two means hatching is never destructive, and every hatch instead asks a question --
-- "is this better than my weakest equipped?" -- which is a decision, not a loss.
--
-- Three distinct roles for a creature now:
--   equipped  -> earns Sparks
--   sanctuary -> passive Luck/income bonuses (Ranch Power)
--   inventory -> fusion material, trade stock, collection completion
Constants.BASE_EQUIP_SLOTS = 3
Constants.MAX_EQUIP_SLOTS = 20   -- hard ceiling across every source

-- Equip slots granted by world progression, keyed by world order. Reaching World 8
-- takes a player from 3 to 10 without spending anything.
Constants.EQUIP_SLOTS_BY_WORLD_ORDER = {
	[2] = 1, [3] = 1, [4] = 1, [5] = 1, [6] = 1, [7] = 1, [8] = 1,
}

-- Inventory is deliberately huge rather than unlimited: DataStore entries have a size
-- limit, and an unbounded array will eventually fail to save -- silently losing a
-- player's entire collection. 500 is far beyond normal play while staying safe.
Constants.MAX_INVENTORY = 500

-- ===== CREATURE SANCTUARY =====
-- Assign spare creatures to live at the ranch. They wander the plot and contribute
-- Ranch Power, which unlocks permanent account-wide perks.
--
-- The whole design rests on CAPACITY BEING LIMITED. Uncapped, the optimal play would be
-- hoarding 500 Commons for a flat bonus -- "more junk = more power", which rewards
-- never making a decision. Capped slots force a real choice about which creatures earn
-- a place, and make rarity matter more than volume.
--
-- Power is rarity-weighted (not per-head) for the same reason: 10 Mythics should beat
-- 50 Commons, so the question is quality, not quantity.
Constants.SANCTUARY_POWER_BY_RARITY = {
	Common = 1, Rare = 5, Epic = 15, Legendary = 40, Mythic = 100, Limited = 60,
}

-- Variants multiply a creature's power, so a fused Gold/Rainbow is worth housing over
-- its inputs -- this keeps fusion and the sanctuary complementary rather than rival
-- sinks competing for the same creatures.
Constants.SANCTUARY_VARIANT_MULTIPLIER = {
	Normal = 1, Gold = 3, Rainbow = 8, Void = 20, Prism = 50, Eclipse = 150,
}
Constants.SANCTUARY_SHINY_MULTIPLIER = 1.5

-- Capacity by ranch tier order (1-7), hung off the EXISTING tier system rather than a
-- new progression axis -- upgrading the ranch already means something, and this gives
-- it a mechanical payoff instead of a purely visual one.
Constants.SANCTUARY_SLOTS_BY_TIER = { 5, 8, 12, 18, 26, 36, 50 }

-- Ranch Power thresholds -> permanent perks. Deliberately additive fractions so they
-- flow through the same GetTotalLuck / income paths as every other bonus rather than
-- needing their own multiplier chain.
Constants.RANCH_POWER_PERKS = {
	{ power = 25,    luck = 0.05, income = 0.00, slots = 0, label = "+5% Luck" },
	{ power = 100,   luck = 0.05, income = 0.10, slots = 0, label = "+10% Sparks" },
	{ power = 300,   luck = 0.10, income = 0.10, slots = 1, label = "+1 Critter Slot" },
	{ power = 800,   luck = 0.10, income = 0.20, slots = 1, label = "+20% Sparks" },
	{ power = 2000,  luck = 0.15, income = 0.20, slots = 2, label = "+15% Luck, +2 Slots" },
	{ power = 5000,  luck = 0.20, income = 0.35, slots = 2, label = "+35% Sparks" },
	{ power = 15000, luck = 0.30, income = 0.50, slots = 3, label = "+30% Luck, +50% Sparks" },
}

-- Returns the cumulative perk totals for a given Ranch Power.
function Constants.GetRanchPerks(power)
	local luck, income, slots, label = 0, 0, 0, nil
	for _, p in ipairs(Constants.RANCH_POWER_PERKS) do
		if power >= p.power then
			luck, income, slots, label = p.luck, p.income, p.slots, p.label
		end
	end
	return { luck = luck, income = income, slots = slots, label = label }
end

-- Power contributed by one creature record.
function Constants.GetCreaturePower(rec)
	local base = Constants.SANCTUARY_POWER_BY_RARITY[rec.rarity] or 1
	local variant = Constants.SANCTUARY_VARIANT_MULTIPLIER[rec.variant or "Normal"] or 1
	local shiny = rec.isShiny and Constants.SANCTUARY_SHINY_MULTIPLIER or 1
	return math.floor(base * variant * shiny)
end

-- ===== RANCH HAPPINESS =====
-- Visitors can feed sanctuary creatures, raising the owner's Ranch Happiness. Happiness
-- multiplies Ranch Power, so a socially-active ranch genuinely outperforms an isolated
-- one -- which is the point: it gives visiting a mechanical reason to exist beyond
-- looking at someone's decorations.
--
-- Two anti-abuse properties matter more than the numbers here:
--  * A visitor can only feed a given ranch ONCE per day, so alt-accounts can't farm it.
--  * Happiness DECAYS daily, so it can't be banked once and forgotten -- a ranch stays
--    happy only while people keep visiting.
Constants.HAPPINESS_PER_FEED = 5
Constants.HAPPINESS_MAX = 100
Constants.HAPPINESS_DAILY_DECAY = 8
-- At full happiness Ranch Power is multiplied by this. Deliberately modest: it should
-- reward social play, not make a solo player's sanctuary feel broken.
Constants.HAPPINESS_MAX_POWER_BONUS = 0.5

-- Feeding rewards the VISITOR too, or nobody would bother doing it for someone else.
Constants.FEED_VISITOR_SPARKS = 2500

function Constants.GetHappinessMultiplier(happiness)
	local h = math.clamp((happiness or 0) / Constants.HAPPINESS_MAX, 0, 1)
	return 1 + h * Constants.HAPPINESS_MAX_POWER_BONUS
end

-- ===== SANCTUARY DISCOVERIES =====
-- Assigned creatures periodically find things while the player plays. This is what
-- makes the ranch worth RETURNING to rather than a one-time setup screen.
--
-- Chance scales with Ranch Power, so investing better creatures pays off twice (perks
-- AND discovery rate) -- but it's capped, so a maxed sanctuary doesn't turn into a
-- firehose that devalues the shop.
--
-- Deliberately awards EXISTING currencies (potions, limited-egg tokens, Sparks) rather
-- than inventing a new resource. Another currency would mean another UI, another
-- balance axis, and another thing to explain -- for no gain over rewarding things the
-- player already understands and wants.
Constants.DISCOVERY_INTERVAL_SECONDS = { min = 180, max = 300 }
-- Tuned so the curve rewards investment across the WHOLE power range rather than
-- saturating early. At divisor 4000 the cap was hit by power 2000 -- reachable just by
-- assigning creatures a mid-game player already owns, which removed any reason to
-- improve the sanctuary afterward. At 30000 the cap needs ~15000 power, which requires
-- deliberately housing Mythics and fused variants.
Constants.DISCOVERY_BASE_CHANCE = 0.25
Constants.DISCOVERY_POWER_DIVISOR = 30000
Constants.DISCOVERY_MAX_CHANCE = 0.75

-- Weighted loot table. Sparks is the common filler; tokens are the rare prize.
Constants.DISCOVERY_LOOT = {
	{ kind = "sparks",     weight = 55, min = 2000, max = 12000 },
	{ kind = "potion",     weight = 30, potionId = "Luck" },
	{ kind = "potion",     weight = 10, potionId = "Sparks" },
	{ kind = "limitedEgg", weight = 5 },
}

-- Sparks reward scales with Ranch Power so it stays relevant late-game rather than
-- becoming a rounding error the moment a player's income outgrows it.
Constants.DISCOVERY_SPARKS_POWER_SCALE = 6

function Constants.RollDiscoveryLoot()
	local total = 0
	for _, l in ipairs(Constants.DISCOVERY_LOOT) do total += l.weight end
	local roll = math.random() * total
	local acc = 0
	for _, l in ipairs(Constants.DISCOVERY_LOOT) do
		acc += l.weight
		if roll <= acc then return l end
	end
	return Constants.DISCOVERY_LOOT[1]
end

function Constants.GetDiscoveryChance(power)
	return math.min(
		Constants.DISCOVERY_BASE_CHANCE + (power / Constants.DISCOVERY_POWER_DIVISOR),
		Constants.DISCOVERY_MAX_CHANCE)
end

-- ===== BADGES =====
-- Roblox badges (distinct from the in-game achievement system). These appear on the
-- experience page, which matters at launch: a game page with badges reads as
-- established, an empty one reads as abandoned.
--
-- All ids are 0 until created on the Creator Dashboard. A 0 id is treated as "not
-- configured" and skipped silently -- the game must never error or spam warnings just
-- because badges haven't been set up yet.
--
-- Deliberately a SHORT list. Roblox badges are permanent and public, so they should
-- mark genuine milestones; a badge for every small step devalues all of them.
Constants.BADGES = {
	FirstHatch    = { id = 0, name = "First Friend",     desc = "Hatch your first Critter." },
	FirstRebirth  = { id = 0, name = "Reborn",           desc = "Complete your first Rebirth." },
	FirstShiny    = { id = 0, name = "Shiny Hunter",     desc = "Hatch a Shiny Critter." },
	FirstFusion   = { id = 0, name = "Alchemist",        desc = "Fuse two creatures together." },
	ReachForest   = { id = 0, name = "Explorer",         desc = "Unlock the Forest." },
	ReachVolcano  = { id = 0, name = "Fireproof",        desc = "Unlock the Volcano." },
	ReachSky      = { id = 0, name = "Skybound",         desc = "Unlock the Sky Islands." },
	Collector50   = { id = 0, name = "Collector",        desc = "Discover 50 species." },
	CollectorMax  = { id = 0, name = "Completionist",    desc = "Discover every species." },
	Mythic        = { id = 0, name = "Mythic Owner",     desc = "Hatch a Mythic Critter." },
}

-- ===== WORLD RELICS =====
-- A rare persistent drop from each world's mechanic. Every world event currently pays
-- instant Sparks and leaves nothing behind, so once a player out-scales a world there is
-- no reason to ever trigger its mechanic again -- the content simply stops mattering.
--
-- Relics fix that: they're a slow collection with permanent payoffs, so returning to an
-- "old" world stays worthwhile long after its Sparks are trivial. Deliberately RARE
-- (~8% per mechanic payout) so they read as a find rather than a currency.
Constants.WORLD_RELICS = {
	Forest       = { id = "Forest",       name = "Verdant Seed",   icon = "\u{1F331}" },
	Beach        = { id = "Beach",        name = "Tide Pearl",     icon = "\u{1F41A}" },
	Desert       = { id = "Desert",       name = "Sun Shard",      icon = "\u{2600}\u{FE0F}" },
	Snow         = { id = "Snow",         name = "Frost Core",     icon = "\u{2744}\u{FE0F}" },
	CrystalCaves = { id = "CrystalCaves", name = "Prism Geode",    icon = "\u{1F48E}" },
	Volcano      = { id = "Volcano",      name = "Ember Heart",    icon = "\u{1F525}" },
	SkyIslands   = { id = "SkyIslands",   name = "Storm Feather",  icon = "\u{1FAB6}" },
}

Constants.RELIC_DROP_CHANCE = 0.08

-- Milestones are per-relic COUNTS, not totals, so a player can't max everything by
-- farming one easy world -- each bonus requires engaging with that specific mechanic.
Constants.RELIC_MILESTONES = {
	{ count = 5,  luck = 0.02, income = 0.03 },
	{ count = 15, luck = 0.05, income = 0.08 },
	{ count = 40, luck = 0.10, income = 0.15 },
	{ count = 100, luck = 0.20, income = 0.30 },
}

-- Totals across all relic types.
function Constants.GetRelicBonuses(relicCounts)
	local luck, income = 0, 0
	for _, count in pairs(relicCounts or {}) do
		for _, m in ipairs(Constants.RELIC_MILESTONES) do
			if count >= m.count then
				luck, income = luck + m.luck, income + m.income
			end
		end
	end
	return luck, income
end

-- ===== GROUP REWARD =====
-- Permanent income bonus for group members. Checked server-side via
-- Player:IsInGroup, which is authoritative -- a client can't fake membership.
--
-- GROUP_ID = 0 disables the check entirely, so the feature is inert until a real group
-- exists rather than erroring or granting to everyone.
Constants.GROUP_ID = 0
Constants.GROUP_INCOME_BONUS = 0.10

-- ===== PROMO CODES =====
-- Redeemable codes for launch, updates, and social posts. Codes are validated
-- SERVER-SIDE against this table and recorded per-profile, so a client can neither
-- invent a code nor redeem one twice.
--
-- Rewards reuse existing currencies (Sparks, potions, limited-egg tokens) rather than
-- inventing anything -- a code should feel like a gift of something you already want.
--
-- `expires` is an os.time() stamp; nil means no expiry. Keeping expired codes in the
-- table (rather than deleting them) means a late redeemer gets "this code expired"
-- instead of "invalid code", which is the difference between a clear message and a
-- player thinking they typed it wrong.
Constants.PROMO_CODES = {
	LAUNCH = { sparks = 25000, potions = { Luck = 1 }, label = "Launch celebration!" },
	WELCOME = { sparks = 10000, label = "Welcome to Creature Ranch!" },
	SANCTUARY = { sparks = 15000, limitedEggTokens = 1, label = "Sanctuary update!" },
	SKYISLANDS = { sparks = 50000, potions = { Luck = 1, Sparks = 1 }, label = "Sky Islands!" },
	THANKYOU = { sparks = 20000, label = "Thanks for playing!" },
}

-- Codes are matched case-insensitively and trimmed, because players type them from
-- videos and screenshots -- rejecting "  launch " for whitespace would be hostile.
function Constants.NormalizeCode(input)
	if typeof(input) ~= "string" then return nil end
	local trimmed = input:gsub("^%s+", ""):gsub("%s+$", "")
	if #trimmed == 0 or #trimmed > 32 then return nil end
	return trimmed:upper()
end

-- ===== RANCH DECORATIONS =====
-- Player-placed cosmetics for their private plot. This exists mainly as a SPARKS SINK:
-- almost every other sink in the game is "buy a bigger egg", which means a player who
-- has out-scaled their current world has nowhere to spend. Decorations absorb surplus
-- without granting power, so they never distort the economy.
--
-- Prices deliberately span four orders of magnitude so there's something worth buying at
-- every stage rather than everything being affordable at once.
--
-- Each entry is built from primitives at a fixed offset from the plot centre; `slot`
-- indexes a placement position so two decorations can't occupy the same spot.
Constants.RANCH_DECORATIONS = {
	{ id = "flowerbed",  name = "Flower Bed",      cost = 5000,       kind = "flowers" },
	{ id = "lamppost",   name = "Lamp Post",       cost = 25000,      kind = "lamp" },
	{ id = "fountain",   name = "Stone Fountain",  cost = 150000,     kind = "fountain" },
	{ id = "statue",     name = "Critter Statue",  cost = 800000,     kind = "statue" },
	{ id = "topiary",    name = "Topiary Hedge",   cost = 3000000,    kind = "topiary" },
	{ id = "crystaltree",name = "Crystal Tree",    cost = 20000000,   kind = "crystaltree" },
	{ id = "archway",    name = "Golden Archway",  cost = 100000000,  kind = "archway" },
	{ id = "obelisk",    name = "Eternal Obelisk", cost = 1000000000, kind = "obelisk" },
}

Constants.RANCH_DECORATION_SLOTS = 8

-- ===== GIFTING =====
-- One-directional transfer, which makes it structurally simpler than trading but opens a
-- risk trading doesn't have: ALT-ACCOUNT FARMING. Nothing stops a player making a second
-- account, funnelling everything to their main, and repeating.
--
-- Three constraints address that, and they're the reason the numbers here are
-- conservative rather than generous:
--   * a daily cap on gifts SENT, so a mule account can only feed a main so fast
--   * an account-age minimum, so freshly-made alts can't gift at all
--   * gifts are logged with both parties, so the pattern is auditable after the fact
--
-- Deliberately NO reward for gifting. A "gifter bonus" would be exactly the incentive
-- that turns alt-farming from possible into worthwhile.
Constants.GIFT_DAILY_LIMIT = 3
Constants.GIFT_MIN_ACCOUNT_AGE_DAYS = 7
Constants.GIFT_MAX_DISTANCE = 40

-- ===== TRADING =====
-- Trading is the single highest-risk system in the game: bugs cause permanent item loss
-- or duplication, and it's the standard vector for scams and real-money trading. Every
-- value here exists to constrain one of those failure modes.
--
-- TRADE_CONFIRM_LOCK_SECONDS is the anti-scam core: after BOTH players accept, the offer
-- is frozen and re-shown for a few seconds before execution. The classic scam is swapping
-- your offer to something worthless in the instant before the other player confirms --
-- a lock window makes that impossible, because any change re-opens acceptance.
Constants.TRADE_MAX_ITEMS = 4
Constants.TRADE_CONFIRM_LOCK_SECONDS = 5
Constants.TRADE_REQUEST_TIMEOUT = 30
Constants.TRADE_MAX_DISTANCE = 40

-- ===== SEASONAL LEADERBOARD =====
-- A ~monthly track sitting between the weekly race and the permanent all-time board.
--
-- Deliberately measures REBIRTHS rather than Sparks: the weekly board already ranks
-- Sparks earned, so a seasonal Sparks board would just be the same race with a longer
-- timer and bigger numbers. Ranking rebirths rewards a different kind of play -- deep
-- progression rather than raw accumulation -- so the two boards don't collapse into one.
Constants.SEASON_LENGTH_DAYS = 28
Constants.SEASONAL_LEADERBOARD_REWARDS = {
	{ rank = 1,  sparks = 50000000,  label = "Season Champion" },
	{ rank = 3,  sparks = 25000000,  label = "Season Top 3" },
	{ rank = 10, sparks = 8000000,   label = "Season Top 10" },
	{ rank = 50, sparks = 2000000,   label = "Season Top 50" },
}

function Constants.GetSeasonIndex()
	return math.floor(os.time() / (Constants.SEASON_LENGTH_DAYS * 24 * 60 * 60))
end

-- Seconds until the current season ends, for the board's countdown.
function Constants.GetSeasonSecondsRemaining()
	local len = Constants.SEASON_LENGTH_DAYS * 24 * 60 * 60
	return len - (os.time() % len)
end

function Constants.GetSeasonalReward(rank)
	for _, r in ipairs(Constants.SEASONAL_LEADERBOARD_REWARDS) do
		if rank <= r.rank then return r end
	end
	return nil
end

-- ===== FRIEND BONUS =====
-- A stacking income bonus for playing near friends. The point is to make bringing a
-- friend into the game mechanically worthwhile, not just socially pleasant -- friend
-- referral is the cheapest growth channel a Roblox game has.
--
-- Capped so a large friend group doesn't trivialise the economy, and radius-gated so it
-- rewards actually playing TOGETHER rather than merely being in the same server.
Constants.FRIEND_BONUS_PER_FRIEND = 0.10
Constants.FRIEND_BONUS_MAX = 0.50
Constants.FRIEND_BONUS_RADIUS = 60

-- ===== WORLD COMPLETION BONUSES =====
-- Permanent, stacking rewards for owning every species in a world. This is what turns
-- the Collection Book from a checklist into progression -- previously completing a
-- world's set did nothing mechanical at all.
--
-- Deliberately varied bonus TYPES rather than "+X% income" seven times: each world
-- rewards a different axis, so completing Beach feels different from completing Snow and
-- players have a reason to care which set they finish next.
--
-- Values are modest individually (they stack to a meaningful total only when several
-- worlds are complete) and every one is permanent -- these are the long-tail payoff for
-- the hardest content in the game.
Constants.WORLD_COMPLETION_BONUSES = {
	StarterMeadow = { statKey = "incomeMult",  value = 0.05, label = "+5% Sparks income" },
	Forest        = { statKey = "incomeMult",  value = 0.10, label = "+10% Sparks income" },
	Beach         = { statKey = "luckMult",    value = 0.10, label = "+10% Luck" },
	Desert        = { statKey = "walkSpeed",   value = 2,    label = "+2 Walk Speed" },
	Snow          = { statKey = "luckMult",    value = 0.15, label = "+15% Luck" },
	CrystalCaves  = { statKey = "incomeMult",  value = 0.20, label = "+20% Sparks income" },
	Volcano       = { statKey = "incomeMult",  value = 0.30, label = "+30% Sparks income" },
}

-- ===== POTIONS =====
-- Timed consumable boosts. Deliberately a Sparks sink rather than Robux-only: the game
-- badly needs somewhere to SPEND Sparks (previously almost every sink was "buy a bigger
-- egg"), and a repeatable purchase that expires is exactly that.
--
-- Durations are short enough that a player feels the clock and considers rebuying, and
-- long enough to survive a genuine play session. Effects multiply with everything else
-- (passes, VIP, rebirth, events) via the same central luck/income paths -- no separate
-- roll sites.
Constants.POTIONS = {
	Luck = {
		id = "Luck",
		name = "Luck Potion",
		description = "2x Luck for 10 minutes.",
		attribute = "SAC_LuckPotion",
		multiplier = 2,
		durationSeconds = 600,
		cost = 15000,
		color = Color3.fromRGB(140, 255, 150),
	},
	Sparks = {
		id = "Sparks",
		name = "Sparks Potion",
		description = "2x Sparks income for 10 minutes.",
		attribute = "SAC_SparksPotion",
		multiplier = 2,
		durationSeconds = 600,
		cost = 20000,
		color = Color3.fromRGB(255, 205, 60),
	},
	HatchSpeed = {
		id = "HatchSpeed",
		name = "Swift Potion",
		description = "Faster hatch animations for 10 minutes.",
		attribute = "SAC_HatchSpeedPotion",
		multiplier = 2,
		durationSeconds = 600,
		cost = 8000,
		color = Color3.fromRGB(120, 200, 255),
	},
}

-- Stacking rule: buying a potion you already have EXTENDS it rather than stacking the
-- multiplier. Stacking multipliers would let a wealthy player buy 20 Luck potions for a
-- 2^20 multiplier -- an obvious economy break. Extension is the standard, safe choice.
Constants.POTION_MAX_STACK_SECONDS = 3600

-- ===== SHOP PRESENTATION =====
-- The shop previously iterated GAME_PASSES/DEV_PRODUCTS with pairs(), so row order was
-- effectively random and changed every time the panel opened. That's actively bad for
-- conversion (nothing anchors, the eye can't learn the layout) and reads as broken.
--
-- sortOrder gives a deliberate hierarchy; badge highlights the intended anchor offer.
-- Only ONE item carries "BEST VALUE" -- the whole point of an anchor is that it's
-- singular. Starter Pack is deliberately first and flagged, since it's time-limited and
-- the highest-converting offer a new player will ever see.
-- Keyed by pass/product name so the render loop can look up a row's presentation
-- directly. `order` drives LayoutOrder, giving a stable sequence -- the shop previously
-- iterated with pairs(), which is nondeterministic in Lua, so rows genuinely reshuffled
-- between sessions and a player could never learn where anything was.
--
-- Sequenced by intent: the expiring Starter Pack first, then the best standing value,
-- then individual passes, then raw currency last.
Constants.SHOP_ORDER = {
	StarterPack      = { sortOrder = 1, badge = "LIMITED",    badgeColor = Color3.fromRGB(255, 90, 90) },
	VIP              = { sortOrder = 2, badge = "BEST VALUE", badgeColor = Color3.fromRGB(255, 205, 60) },
	LuckPass         = { sortOrder = 3, badge = "POPULAR",    badgeColor = Color3.fromRGB(140, 200, 255) },
	MultiSlotPass    = { sortOrder = 4 },
	AutoHatch        = { sortOrder = 5 },
	DoubleSparks     = { sortOrder = 6 },
	OfflinePass      = { sortOrder = 7 },
	InstantExtraSlot = { sortOrder = 8 },
	VipTrail         = { sortOrder = 9 },
	SparkPackLarge   = { sortOrder = 10 },
	SparkPackSmall   = { sortOrder = 11 },
}



-- ===== LUCK STAT =====
-- Luck was previously scattered across three unrelated places (rebirth luckBonus, the
-- Lucky Hour event multiplier, and a hardcoded shiny constant) and affected exactly one
-- thing. This makes it a single visible, stackable stat the player can actually reason
-- about and invest in.
--
-- Luck raises the odds of the GOOD outcomes in a hatch: shiny rolls and rarity rolls.
-- It's expressed as a multiplier where 1.0 = base. Sources multiply together, so a
-- rebirthed VIP during a Lucky Hour genuinely stacks -- that compounding is the point.
Constants.LUCK_PASS_MULTIPLIER = 2.0
Constants.VIP_LUCK_MULTIPLIER = 1.25

-- Rarity-roll luck: at luck > 1, weights shift toward the rarer tiers. Applied as an
-- exponent on each tier's weight relative to Common, so higher luck compresses the gap
-- between Common and Mythic without ever guaranteeing a top-tier roll.
-- Deliberately gentler than the shiny effect: doubling Mythic odds is a far bigger
-- economic lever than doubling shiny odds, since rarity drives income directly.
Constants.LUCK_RARITY_EXPONENT = 0.35

-- ===== VIP =====
-- Income bonus is modest (+25%) on purpose: it stacks with the existing 2x Sparks pass
-- and rebirth multipliers, so a large number here would compound into something that
-- trivialises the economy for anyone holding both.
Constants.VIP_INCOME_MULTIPLIER = 1.25
Constants.VIP_DAILY_SPARKS = 15000
Constants.VIP_EXTRA_SLOTS = 1
Constants.VIP_TAG_COLOR = Color3.fromRGB(255, 205, 60)

-- ===== STARTER PACK OFFER =====
-- Only shown during the player's first STARTER_PACK_WINDOW_HOURS of account age in this
-- game, and only if unpurchased. Real scarcity (it genuinely expires) rather than a fake
-- countdown that resets -- players notice the difference and it poisons trust in every
-- other offer.
Constants.STARTER_PACK_WINDOW_HOURS = 24

-- ===== NUMBER FORMATTING =====
-- Raw balances render as unreadable digit soup ("769522421"). Every top simulator
-- abbreviates, both for readability and because watching the SUFFIX change (K -> M ->
-- B -> T) is itself a progression reward. Lives in Constants so client display and any
-- future server-side text share one implementation and can never disagree.
--
-- Deliberately truncates rather than rounds: 999,999 must never display as "1M" when
-- the player can't yet afford a 1M purchase -- that reads as a bug or a cheat.
local NUMBER_SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
function Constants.FormatNumber(n)
	n = tonumber(n) or 0
	local negative = n < 0
	n = math.abs(n)
	if n < 1000 then
		local s = tostring(math.floor(n))
		return negative and ("-" .. s) or s
	end
	local tier = math.floor(math.log(n, 1000))
	tier = math.clamp(tier, 1, #NUMBER_SUFFIXES - 1)
	local scaled = n / (1000 ^ tier)
	-- Truncate to 1 decimal (never round up past a threshold).
	scaled = math.floor(scaled * 10) / 10
	local s
	if scaled >= 100 then
		s = string.format("%d%s", math.floor(scaled), NUMBER_SUFFIXES[tier + 1])
	else
		s = string.format("%.1f%s", scaled, NUMBER_SUFFIXES[tier + 1])
	end
	return negative and ("-" .. s) or s
end




-- Single return at the END of the file. It previously sat ~18,000 chars earlier,
-- which silently stranded 40 constants -- BADGES, PROMO_CODES, WORLD_RELICS,
-- GROUP_ID, RELIC_* and GetDiscoveryChance never existed at runtime, so badges,
-- promo codes, relics and the group bonus were all dead despite their code being
-- present and correct. Anything appended after a return is invisible; keep this last.
return Constants
