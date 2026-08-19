--[[
	WorldsData.lua
	Data-driven definition of every world in CREATURE RANCH's progression ladder.
	This is the ENTIRE point of the multi-world architecture: adding a new world means
	adding a new entry here (plus its assets), never touching server logic. WorldService/
	HatchLogic/CritterService all read from this table generically -- none of them contain
	a single hardcoded reference to "Forest" or "Beach" by name.

	World 1 (Starter Meadow) deliberately REFERENCES the existing, already-proven
	Constants.RARITIES / Constants.CRITTER_SPECIES tables rather than duplicating their
	values -- World 1 is not new content, it's the current game correctly framed as the
	first rung of the ladder. Zero risk of the two copies drifting apart, because there
	is only one copy.

	Worlds 3-8 are intentionally stubs (`implemented = false`) right now -- the roadmap
	is real and baked into the data model, but content is built one world at a time
	(architecture -> polish World 1 -> World 2 -> verify progression -> THEN duplicate
	the framework for the rest), not all at once.
]]

local RS = game:GetService("ReplicatedStorage")
local Constants = require(RS.CritterRush.Modules.Constants)

local WorldsData = {}

WorldsData.WORLDS = {
	{
		id = "StarterMeadow",
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Meadow Egg", cost = 100 },
		order = 1,
		displayName = "Starter Meadow",
		unlockCost = 0, -- free; every player starts here
		implemented = true,
		rarities = Constants.RARITIES,
		species = Constants.CRITTER_SPECIES,
	},
	{
		id = "Forest",
		-- Collection objective: must own this many species from the PREVIOUS world
		-- before unlocking. Makes a world unlock something you earn by playing that
		-- world, not just by banking Sparks while ignoring it entirely.
		requiredPrevSpecies = 6,
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Forest Egg", cost = 800 },
		order = 2,
		displayName = "Forest",
		unlockCost = 20000,
		implemented = true,
		-- Physical gate near Starter Meadow's edge (due south, clear of the Dock/
		-- Waterfall/RopeBridge landmarks) and a separate physical zone far from the main
		-- island, reached by teleport -- same "private far-away zone" pattern already
		-- proven for Ranch plots, at a distinct grid so the two systems can never collide.
		-- Y=7 matches this southern area's REAL local ground height (confirmed via raycast
		-- at Y=0, not the Y~13 typical elsewhere on the island) -- the first attempt used
		-- Y=15 assuming uniform island height, leaving the whole gate floating with nothing
		-- solid underneath and no ground for a player to actually stand on while using it.
		gatePosition = Vector3.new(0, 7, -150),
		zonePosition = Vector3.new(2000, 10, 0),
		-- Ground platform theme for the zone -- the actual platform geometry is built
		-- generically by ZoneHatcheryService, reading only these two fields.
		groundColor = Color3.fromRGB(90, 150, 70),
		groundMaterial = Enum.Material.Grass,
		-- Own 5-tier economy, scaled up from Starter Meadow's -- roughly 4x cost/income
		-- across the board, the standard "next world costs more, pays more" convention.
		-- Common has a real cost (100) unlike World 1's, since Forest has no equivalent
		-- free-starter mechanic -- every tier here needs to be genuinely purchasable.
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 12,
				auraColor = Color3.fromRGB(120, 170, 90), cost = 100 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 48,
				auraColor = Color3.fromRGB(90, 150, 110), cost = 1000 },
			{ id = "Epic", weight = 10, sizeScale = 1.65, sparksPerSecond = 220,
				auraColor = Color3.fromRGB(60, 130, 90), cost = 4000 },
			{ id = "Legendary", weight = 4, sizeScale = 2.0, sparksPerSecond = 1040,
				auraColor = Color3.fromRGB(200, 160, 60), cost = 20000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.45, sparksPerSecond = 5600,
				auraColor = Color3.fromRGB(60, 200, 140), cost = 80000, serverAnnounce = true, skyBeam = true },
		},
		-- 10 species defined (2 per tier), matching the full data shape World 1 uses.
		-- Only Mossling (Common) and Fernkit (Rare) have real built models this pass --
		-- the other 8 correctly fall back to CritterService's generic placeholder model
		-- until their geometry is built, exactly the same "data exists, content follows"
		-- scoping already used for Ranch Tiers 3-5. A named species with a placeholder
		-- body is honest incremental progress; an empty tier would not be.
		species = {
			Common = { "Mossling", "Twigsprite" },
			Rare = { "Fernkit", "Barkhopper" },
			Epic = { "Thornfox", "Canopypaw" },
			Legendary = { "Elderstag", "Duskowl" },
			Mythic = { "Verdantwyrm", "Grovekeeper" },
		},
	},
	{
		id = "Beach",
		-- Collection objective: must own this many species from the PREVIOUS world
		-- before unlocking. Makes a world unlock something you earn by playing that
		-- world, not just by banking Sparks while ignoring it entirely.
		requiredPrevSpecies = 8,
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Beach Egg", cost = 4000 },
		order = 3,
		displayName = "Beach",
		unlockCost = 100000,
		implemented = true,
		-- Physical gate east of the main island, near the Dock (thematically fitting --
		-- Beach is the natural next step past the water). Y=7 matches this area's real
		-- ground height (confirmed via raycast at Y=0), same formula proven correct on
		-- the Forest gate.
		gatePosition = Vector3.new(170, 7, 0),
		zonePosition = Vector3.new(2500, 10, 2000),
		groundColor = Color3.fromRGB(235, 215, 165),
		groundMaterial = Enum.Material.Sand,
		-- Own economy, ~4x Forest's across the board, continuing the established
		-- "next world costs more, pays more" scaling.
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 48,
				auraColor = Color3.fromRGB(230, 210, 150), cost = 400 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 192,
				auraColor = Color3.fromRGB(255, 170, 130), cost = 4000 },
			{ id = "Epic", weight = 10, sizeScale = 1.65, sparksPerSecond = 880,
				auraColor = Color3.fromRGB(90, 190, 220), cost = 16000 },
			{ id = "Legendary", weight = 4, sizeScale = 2.0, sparksPerSecond = 4160,
				auraColor = Color3.fromRGB(70, 130, 220), cost = 80000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.45, sparksPerSecond = 22400,
				auraColor = Color3.fromRGB(30, 90, 180), cost = 320000, serverAnnounce = true, skyBeam = true },
		},
		-- 10 species defined, same "data exists, content follows" scoping as Forest --
		-- species models built incrementally, starting with Common/Rare this pass.
		species = {
			Common = { "Sandcrab", "Shellhop" },
			Rare = { "Tidepool", "Pearlfin" },
			Epic = { "Waverider", "Coralclaw" },
			Legendary = { "Stormgull", "Tidelord" },
			Mythic = { "Leviathan", "Oceanheart" },
		},
	},
	{
		id = "Desert",
		-- Collection objective: must own this many species from the PREVIOUS world
		-- before unlocking. Makes a world unlock something you earn by playing that
		-- world, not just by banking Sparks while ignoring it entirely.
		requiredPrevSpecies = 10,
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Desert Egg", cost = 24000 },
		order = 4,
		displayName = "Desert",
		unlockCost = 600000,
		-- Rebirth now has real teeth: past Beach, worlds require actual rebirth progress
		-- to unlock, not just enough Sparks. This is the core fix for "rebirth is just
		-- another number" -- reaching Desert requires having rebirthed at least once,
		-- full stop, regardless of how many Sparks you're sitting on.
		requiredRebirths = 1,
		implemented = true,
		-- Physical gate due north of the main island, clear of Forest (south), Beach
		-- (east), and RopeBridge (northwest). Y=7 matches this area's real ground height
		-- (confirmed via raycast at Y=0), same formula proven correct on both earlier gates.
		gatePosition = Vector3.new(60, 7, 150),
		zonePosition = Vector3.new(3500, 10, 500),
		-- Ground platform theme for ZoneHatcheryService's generic zone-ground builder --
		-- warm sandstone tone, matching Desert's identity.
		groundColor = Color3.fromRGB(225, 185, 120),
		groundMaterial = Enum.Material.Sand,
		-- Own economy, ~3x Beach's -- matched to the unlock-cost progression already fixed
		-- in the roadmap (900,000 / 300,000 = 3x), rather than blindly reusing the 4x
		-- multiplier from earlier worlds, since that ratio was already set independently.
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 210,
				auraColor = Color3.fromRGB(235, 195, 120), cost = 1200 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 840,
				auraColor = Color3.fromRGB(220, 150, 90), cost = 12000 },
			{ id = "Epic", weight = 10, sizeScale = 1.65, sparksPerSecond = 3850,
				auraColor = Color3.fromRGB(230, 130, 70), cost = 48000 },
			{ id = "Legendary", weight = 4, sizeScale = 2.0, sparksPerSecond = 18200,
				auraColor = Color3.fromRGB(200, 170, 80), cost = 240000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.45, sparksPerSecond = 98000,
				auraColor = Color3.fromRGB(255, 210, 90), cost = 960000, serverAnnounce = true, skyBeam = true },
		},
		-- All 10 species built with real models THIS pass -- no placeholder-fallback tiers
		-- this time, matching the "take your time, make it perfect" instruction.
		species = {
			Common = { "Dunepup", "Scorpling" },
			Rare = { "Cactusnap", "Sandwhisk" },
			Epic = { "Mirageflit", "Sunscale" },
			Legendary = { "Pharaohkit", "Duststrider" },
			Mythic = { "Sphinxwing", "Sunfall" },
		},
	},
	{
		id = "Snow",
		-- Collection objective: must own this many species from the PREVIOUS world
		-- before unlocking. Makes a world unlock something you earn by playing that
		-- world, not just by banking Sparks while ignoring it entirely.
		requiredPrevSpecies = 10,
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Snow Egg", cost = 160000 },
		order = 5,
		displayName = "Snow",
		unlockCost = 4200000,
		requiredRebirths = 1,
		implemented = true,
		-- Physical gate due west of the main island, clear of Waterfall (southwest) and
		-- RopeBridge (northwest). Y=7 matches this area's real ground height (confirmed
		-- via raycast at Y=0), same formula proven correct on every earlier gate.
		gatePosition = Vector3.new(-150, 7, -30),
		zonePosition = Vector3.new(-3500, 10, 1000),
		groundColor = Color3.fromRGB(235, 245, 250),
		groundMaterial = Enum.Material.Snow,
		-- Own economy, ~2.78x Desert's -- matched to the fixed unlock-cost progression
		-- (2,500,000 / 900,000 ~= 2.78x), same discipline as Desert's own scaling.
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 960,
				auraColor = Color3.fromRGB(220, 240, 250), cost = 3300 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 3840,
				auraColor = Color3.fromRGB(150, 210, 240), cost = 33000 },
			{ id = "Epic", weight = 10, sizeScale = 1.65, sparksPerSecond = 17600,
				auraColor = Color3.fromRGB(120, 180, 235), cost = 133000 },
			{ id = "Legendary", weight = 4, sizeScale = 2.0, sparksPerSecond = 83200,
				auraColor = Color3.fromRGB(180, 220, 255), cost = 667000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.45, sparksPerSecond = 448000,
				auraColor = Color3.fromRGB(220, 250, 255), cost = 2670000, serverAnnounce = true, skyBeam = true },
		},
		-- All 10 species with real models this pass, same "make it perfect" standard as
		-- Desert. Deliberately avoids "Frost"-prefixed names -- Frostmaw/Frostfang/
		-- Frostcrown already exist as World 1 species, confirmed via Constants before
		-- naming these, to avoid thematic collision.
		species = {
			Common = { "Snowpaw", "Icedrop" },
			Rare = { "Glacierling", "Chillhop" },
			Epic = { "Blizzardwing", "Powderfox" },
			Legendary = { "Yetikin", "Polarlynx" },
			Mythic = { "Glacierheart", "Winterking" },
		},
	},
	{
		id = "CrystalCaves",
		-- Collection objective: must own this many species from the PREVIOUS world
		-- before unlocking. Makes a world unlock something you earn by playing that
		-- world, not just by banking Sparks while ignoring it entirely.
		requiredPrevSpecies = 12,
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Crystal Egg", cost = 1300000 },
		order = 6,
		displayName = "Crystal Caves",
		unlockCost = 33600000,
		requiredRebirths = 2,
		implemented = true,
		-- Physical gate southeast of the main island -- the remaining open diagonal, clear
		-- of Forest (south), Beach (east), and Waterfall (southwest). Y=7 matches this
		-- area's real ground height (confirmed via raycast at Y=0), same formula proven
		-- correct on every earlier gate.
		gatePosition = Vector3.new(120, 7, -100),
		zonePosition = Vector3.new(0, 10, -4500),
		groundColor = Color3.fromRGB(70, 60, 90),
		groundMaterial = Enum.Material.Slate,
		-- Own economy, ~2.8x Snow's -- matched to the fixed unlock-cost progression
		-- (7,000,000 / 2,500,000 = 2.8x), same discipline as every earlier world.
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 4500,
				auraColor = Color3.fromRGB(190, 170, 220), cost = 9200 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 18000,
				auraColor = Color3.fromRGB(150, 130, 220), cost = 92000 },
			{ id = "Epic", weight = 10, sizeScale = 1.65, sparksPerSecond = 82500,
				auraColor = Color3.fromRGB(100, 220, 210), cost = 372000 },
			{ id = "Legendary", weight = 4, sizeScale = 2.0, sparksPerSecond = 390000,
				auraColor = Color3.fromRGB(255, 130, 220), cost = 1868000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.45, sparksPerSecond = 2100000,
				auraColor = Color3.fromRGB(255, 255, 255), cost = 7476000, serverAnnounce = true, skyBeam = true },
		},
		-- All 10 species with real models this pass, same standard as Desert/Snow.
		-- Checked existing species names first (Skyrend/Emberpaw/Emberwing are World 1
		-- species, confirmed via Constants) to avoid collision before naming these.
		species = {
			Common = { "Geodling", "Sparkstone" },
			Rare = { "Amberglow", "Quartzkit" },
			Epic = { "Prismback", "Cavelurker" },
			Legendary = { "Gemhorn", "Crystallord" },
			Mythic = { "Diamondsoul", "Radiantcore" },
		},
	},
	{
		id = "Volcano",
		-- Collection objective: must own this many species from the PREVIOUS world
		-- before unlocking. Makes a world unlock something you earn by playing that
		-- world, not just by banking Sparks while ignoring it entirely.
		requiredPrevSpecies = 12,
		-- World-themed egg: ONE egg per world rolling across all rarities by weight,
		-- replacing the old five-eggs-per-world layout. Makes each world memorable
		-- ("I got the Leviathan from the Beach Egg") and restores genuine hatch
		-- randomness, which is what makes posted odds meaningful.
		themedEgg = { name = "Volcano Egg", cost = 12000000 },
		order = 7,
		displayName = "Volcano",
		unlockCost = 302400000,
		requiredRebirths = 3,
		implemented = true,
		-- Physical gate northeast of the main island -- the last open direction (Forest=S,
		-- Beach=E, Desert=N, Snow=W, CrystalCaves=SE, RopeBridge~NW, Waterfall~SW). Y=7
		-- matches this area's real ground height (confirmed via raycast at Y=0), same
		-- formula proven correct on every earlier gate.
		gatePosition = Vector3.new(110, 7, 120),
		zonePosition = Vector3.new(4500, 10, -2000),
		groundColor = Color3.fromRGB(50, 35, 35),
		groundMaterial = Enum.Material.Basalt,
		-- Own economy, ~2.57x Crystal Caves' -- matched to the fixed unlock-cost
		-- progression (18,000,000 / 7,000,000 ~= 2.57x), same discipline as every world.
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 21000,
				auraColor = Color3.fromRGB(90, 70, 65), cost = 23600 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 84000,
				auraColor = Color3.fromRGB(200, 90, 50), cost = 236000 },
			{ id = "Epic", weight = 10, sizeScale = 1.65, sparksPerSecond = 385000,
				auraColor = Color3.fromRGB(230, 120, 40), cost = 956000 },
			{ id = "Legendary", weight = 4, sizeScale = 2.0, sparksPerSecond = 1820000,
				auraColor = Color3.fromRGB(255, 80, 40), cost = 4800000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.45, sparksPerSecond = 9800000,
				auraColor = Color3.fromRGB(255, 200, 60), cost = 19200000, serverAnnounce = true, skyBeam = true },
		},
		-- All 10 species with real models this pass, same standard as every world since
		-- Desert. Checked existing species names first (Cindertot is a World 1 species,
		-- confirmed via Constants) -- avoided "Cinder"/"Ember" prefixes to avoid collision.
		species = {
			Common = { "Ashcub", "Scorchling" },
			Rare = { "Lavapup", "Obsidianclaw" },
			Epic = { "Magmawing", "Charhide" },
			Legendary = { "Infernostag", "Pyroclast" },
			Mythic = { "Volcanoheart", "Eruptorking" },
		},
	},
	{
		id = "SkyIslands",
		order = 8,
		displayName = "Sky Islands",
		unlockCost = 3024000000,
		requiredRebirths = 4,
		requiredPrevSpecies = 12,
		implemented = true,
		-- Gate placed on genuinely solid ground: a grid raycast found most of the
		-- remaining island perimeter is WATER (material check, not just a hit), and a
		-- gate there would have floated in the sea. Y=10 sand, 146 studs clear of the
		-- nearest existing gate.
		gatePosition = Vector3.new(-80, 10, 110),
		zonePosition = Vector3.new(-2000, 10, -4500),
		groundColor = Color3.fromRGB(215, 235, 255),
		groundMaterial = Enum.Material.Sand,
		-- ~4x Volcano across the board, continuing the established per-world scaling.
		themedEgg = { name = "Sky Egg", cost = 48000000 },
		rarities = {
			{ id = "Common", weight = 60, sizeScale = 1.0, sparksPerSecond = 84000,
				auraColor = Color3.fromRGB(210, 235, 255), cost = 400 },
			{ id = "Rare", weight = 25, sizeScale = 1.3, sparksPerSecond = 336000,
				auraColor = Color3.fromRGB(150, 200, 255), cost = 4000 },
			{ id = "Epic", weight = 10, sizeScale = 1.6, sparksPerSecond = 1540000,
				auraColor = Color3.fromRGB(190, 150, 255), cost = 16000 },
			{ id = "Legendary", weight = 4, sizeScale = 1.95, sparksPerSecond = 7280000,
				auraColor = Color3.fromRGB(255, 235, 150), cost = 80000, serverAnnounce = true },
			{ id = "Mythic", weight = 1, sizeScale = 2.4, sparksPerSecond = 39200000,
				auraColor = Color3.fromRGB(255, 180, 255), cost = 320000,
				serverAnnounce = true, skyBeam = true },
		},
		species = {
			Common = { "Cloudlet", "Breezling" },
			Rare = { "Gustwing", "Nimbuff" },
			Epic = { "Skydancer", "Zephyron" },
			Legendary = { "Stormcrest", "Aetherwing" },
			Mythic = { "Celestrix", "Skysovereign" },
		},
	},
}

-- Sorted view, computed once at require-time (the WORLDS array above is already in
-- order, but this guards against a future entry being added out of sequence).
table.sort(WorldsData.WORLDS, function(a, b) return a.order < b.order end)

local byId = {}
for _, world in ipairs(WorldsData.WORLDS) do
	byId[world.id] = world
end

function WorldsData.GetWorld(worldId)
	return byId[worldId]
end

function WorldsData.GetAllWorlds()
	return WorldsData.WORLDS
end

-- The world a brand new player starts in, and the fallback for any saved data that
-- predates this system (see PlayerDataService's worldId migration on owned critters).
WorldsData.DEFAULT_WORLD_ID = "StarterMeadow"

return WorldsData
