--[[
	Main.lua
	Bootstraps all server services and wires RemoteEvent handlers for CREATURE RANCH.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")

local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(SSS.Services.PlayerDataService)
local CritterService = require(SSS.Services.CritterService)
local CritterVFX = require(SSS.Services.CritterVFX)
local MonetizationService = require(SSS.Services.MonetizationService)
local WorldEventService = require(SSS.Services.WorldEventService)
local WorldService = require(SSS.Services.WorldService)
local HatchLogic = require(SSS.Services.HatchLogic)
local OrbService = require(SSS.Services.OrbService)
local ForestSpriteService = require(SSS.Services.ForestSpriteService)
local BeachCrabService = require(SSS.Services.BeachCrabService)
local DesertSandstormService = require(SSS.Services.DesertSandstormService)
local CrystalExplosionService = require(SSS.Services.CrystalExplosionService)
local VolcanoMeteorService = require(SSS.Services.VolcanoMeteorService)
local SkyUpdraftService = require(SSS.Services.SkyUpdraftService)
local LimitedEggService = require(SSS.Services.LimitedEggService)
local PlaytimeRewardService = require(SSS.Services.PlaytimeRewardService)
local DiscoveryService = require(SSS.Services.DiscoveryService)
local AutoHatchService = require(SSS.Services.AutoHatchService)
local PotionService = require(SSS.Services.PotionService)
local TradeService = require(SSS.Services.TradeService)
local GiftService = require(SSS.Services.GiftService)
local OnboardingService = require(SSS.Services.OnboardingService)
local QuestService = require(SSS.Services.QuestService)
local RebirthService = require(SSS.Services.RebirthService)
local LandmarkService = require(SSS.Services.LandmarkService)
local RanchService = require(SSS.Services.RanchService)
local AnalyticsService = require(SSS.Services.AnalyticsService)
local TelemetryService = require(SSS.Services.TelemetryService)
local BadgeAwardService = require(SSS.Services.BadgeAwardService)
local ZoneHatcheryService = require(SSS.Services.ZoneHatcheryService)
local SnowIceService = require(SSS.Services.SnowIceService)

local remotes = RS.CritterRush.Remotes

PlayerDataService.Init() -- wires autosave loop, save-on-leave, and BindToClose flush.
-- NOTE: this was accidentally dropped in an earlier refactor, which silently disabled
-- ALL saving — data loaded fine but never wrote back. Load() is still called explicitly
-- in onPlayerAdded below (Init no longer handles PlayerAdded, see PlayerDataService).
CritterService.Init()
CritterVFX.StartCulling(CritterService.GetCritterModels)
MonetizationService.Init()
WorldEventService.Init()
WorldService.Init() -- builds physical World Gates for every implemented world
ZoneHatcheryService.Init() -- builds a physical Hatchery at every implemented world's zone
SnowIceService.Init() -- must run AFTER ZoneHatcheryService, needs Ground_Snow to already exist
OrbService.Init()
ForestSpriteService.Init()
BeachCrabService.Init()
DesertSandstormService.Init()
CrystalExplosionService.Init()
VolcanoMeteorService.Init()
SkyUpdraftService.Init()
LimitedEggService.Init()
PlaytimeRewardService.Init()
DiscoveryService.Init()
AutoHatchService.Init()
PotionService.Init()
TradeService.Init()
GiftService.Init()
OnboardingService.Init()
LandmarkService.Init()
RanchService.Init()

-- ===== Ancient Tree hidden chest: one-time discovery reward =====
-- Connected server-side directly to the prompt, matching HatcheryController's proven
-- pattern (no remote round-trip needed -- Triggered already only ever fires server-side
-- for a real, server-validated interaction).
do
	local tree = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Landmarks")
		and workspace.World.Landmarks:FindFirstChild("AncientTree")
	local chest = tree and tree:FindFirstChild("HiddenChest")
	local chestPrompt = chest and chest:FindFirstChild("Base") and chest.Base:FindFirstChildOfClass("ProximityPrompt")
	if chestPrompt then
		local CHEST_REWARD = 500
		chestPrompt.Triggered:Connect(function(player)
			local profile = PlayerDataService.Get(player)
			if not profile or profile.hasOpenedTreeChest then return end
			profile.hasOpenedTreeChest = true
			local newTotal = PlayerDataService.AddSparks(player, CHEST_REWARD)
			remotes.SparksUpdated:FireClient(player, newTotal)
			local chestRemote = remotes:FindFirstChild("TreeChestOpened")
			if chestRemote then
				chestRemote:FireClient(player, CHEST_REWARD)
			end
			AnalyticsService.LogRewardEarned(player, CHEST_REWARD, newTotal, "HiddenChest")
		end)
	else
		warn("[Main] Ancient Tree hidden chest prompt not found -- reward wiring skipped")
	end
end

-- ===== Ancient Tree Elder Critter: lore dialogue + a genuine daily reason to return.
-- NOT a full quest-giver yet (that's explicitly a later phase) -- but the daily gift IS
-- a real, provable "come back tomorrow" mechanic, deliberately requiring the PHYSICAL
-- visit (separate day-tracking field from the automatic login reward), matching the
-- creative director's core note: a landmark visited once and never again isn't enough.
do
	local tree = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Landmarks")
		and workspace.World.Landmarks:FindFirstChild("AncientTree")
	local elder = tree and tree:FindFirstChild("ElderCritter")
	local elderPrompt = elder and elder:FindFirstChild("Body") and elder.Body:FindFirstChildOfClass("ProximityPrompt")
	if elderPrompt then
		-- minLevel entries unlock new dialogue as the player actually progresses -- same
		-- "Level purpose" fix already proven on the quest pool, applied here too. Tied to
		-- the existing title milestones (Ranger@20/Master@35/Legend@50) plus Level 10
		-- (matching the existing "Rising Star" achievement) so the dialogue genuinely
		-- reacts to the same progression moments the rest of the game already celebrates.
		local DIALOGUE_LINES = {
			{ text = "Welcome, young rancher. This tree has stood since before the first Critter was ever hatched." },
			{ text = "They say a hidden chest rests among my roots... if you're brave enough to look." },
			{ text = "The forest to the south holds creatures unlike any you've seen here." },
			{ text = "Every ranch begins small. Yours will grow, in time." },
			{ text = "I've watched many rest by that pond. Sit a while, if you'd like." },
			{ text = "You're growing quickly! I remember when you couldn't even afford a single egg.", minLevel = 10 },
			{ text = "A Critter Ranger now, are you? The forest speaks well of rangers like yourself.", minLevel = 20 },
			{ text = "Critter Master... that title isn't given lightly. I'm proud of how far you've come.", minLevel = 35 },
			{ text = "A Legend walks among us. Few ever reach this height. The ranch itself seems to shine brighter with you here.", minLevel = 50 },
		}
		local ELDER_GIFT_AMOUNT = 300
		elderPrompt.Triggered:Connect(function(player)
			local profile = PlayerDataService.Get(player)
			if not profile then return end
			local today = os.time() // 86400
			if today > profile.lastElderGiftDay then
				profile.lastElderGiftDay = today
				local newTotal = PlayerDataService.AddSparks(player, ELDER_GIFT_AMOUNT)
				remotes.SparksUpdated:FireClient(player, newTotal)
				AnalyticsService.LogRewardEarned(player, ELDER_GIFT_AMOUNT, newTotal, "ElderDailyGift")
				local line = string.format(
					"Ah, a new day! Take this gift for visiting me: +%d Sparks. Come back tomorrow for more.",
					ELDER_GIFT_AMOUNT)
				remotes.ElderDialogue:FireClient(player, line, true)
			else
				local level = PlayerDataService.GetLevel(player)
				local eligible = {}
				for _, entry in ipairs(DIALOGUE_LINES) do
					if level >= (entry.minLevel or 0) then table.insert(eligible, entry) end
				end
				local line = eligible[math.random(1, #eligible)].text
				remotes.ElderDialogue:FireClient(player, line, false)
			end
		end)
	else
		warn("[Main] Ancient Tree Elder Critter prompt not found -- dialogue wiring skipped")
	end
end

-- Give every new player one free Starter Egg (Common tier) immediately after data loads,
-- so the very first thing that happens is the hatch cinematic (see Section 2A of the GDD).
-- Returning players instead get their SAVED critters respawned (no cinematic — it's a
-- reunion, not a birth).
local function spawnSavedCritters(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	task.wait(0.5)
	for _, saved in ipairs(profile.ownedCritters) do
	-- Only EQUIPPED creatures get a physical model. Previously every owned critter
		-- was spawned: with a 500-slot inventory that meant 100+ models following the
		-- player, of which only the equipped few actually earn. That was the ranch
		-- clutter, and it was also the source of the VFX load that caused client script
		-- timeouts. Unequipped creatures live in the inventory as data only.
		local isEquipped = false
		for _, uid in ipairs(profile.equippedUids or {}) do
			if uid == saved.uid then isEquipped = true break end
		end
		if not isEquipped then continue end
		-- worldId was backfilled onto every saved critter by PlayerDataService's reconcile()
		-- (anything from before this system existed defaults to StarterMeadow), so this is
		-- always safe to resolve, even for saves far older than the world system itself.
		local world = WorldsData.GetWorld(saved.worldId) or WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
		local tier
		for _, t in ipairs(world.rarities) do
			if t.id == saved.rarity then tier = t end
		end
		-- Limited Egg creatures don't belong to any world's rarity table (that's what makes
		-- them exclusive), so the lookup above can never find them. Reconstruct their tier
		-- from the saved record itself. Without this, every Limited creature silently
		-- vanished on relog -- caught by the "Could not resolve tier 'Limited'" warning.
		if not tier and saved.rarity == "Limited" then
			tier = {
				id = "Limited",
				sparksPerSecond = saved.sparksPerSecond or 260,
				sizeScale = 1.4,
				auraColor = Color3.fromRGB(150, 190, 255),
				cost = Constants.LIMITED_EGG_COST,
			}
		end
		if tier then
			local record = CritterService.SpawnForPlayer(player, tier, saved.species, saved.worldId, saved.uid, saved.isShiny or false, saved.personality)
			if not record then
				warn("[Main] Failed to respawn saved critter", saved.species, "for", player.Name)
			end
		else
			warn("[Main] Could not resolve tier '" .. tostring(saved.rarity) .. "' in world '" ..
				tostring(saved.worldId) .. "' for saved critter", saved.species, "-- skipping respawn for", player.Name)
		end
	end
end

local function trySpawnStarterCritter(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	if #profile.ownedCritters > 0 then
		spawnSavedCritters(player)
		return
	end
	task.wait(0.5) -- let character fully settle before spawning the critter
	local startWorld = WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
	local tier = startWorld.rarities[1] -- Common starter, guaranteed (not a paid roll)
	local species = startWorld.species[tier.id][math.random(1, #startWorld.species[tier.id])]
	local record = CritterService.SpawnForPlayer(player, tier, species, WorldsData.DEFAULT_WORLD_ID)
	if record then
		remotes.HatchResult:FireClient(player, true, tier.id, species, record.uid, record.isShiny, record.personality)
		-- Design-review fix (HIGH #3): without this, a new player's slots badge showed
		-- "0/N" (wrong) for their entire first session, because the ONLY prior sync
		-- happened earlier in onPlayerAdded, before this critter existed. First real
		-- feedback a new player gets about their own progress was incorrect.
		HatchLogic.SyncSlotAttributes(player)
		-- Design-review fix (HIGH #4): the starter grant IS a hatch, narratively (the GDD
		-- itself presents it as one via the cinematic) -- counting it toward "hatch 1 egg"
		-- quest progress means a player who rolls that quest later, after already having
		-- their starter critter, doesn't need to hatch a SECOND egg to complete it.
		QuestService.ReportProgress(player, "hatch", 1)
	end
end

-- Daily login reward: streak-scaled Sparks, resets if a day is skipped (Phase 6).
-- Reward = 50 + 25 per consecutive day, capped at day 7 (max 200/day).
-- VIP daily Sparks. Deliberately separate from the login streak (own day-stamp), so a
-- VIP player receives BOTH -- the pass is meant to feel additive every single day, not
-- to replace progression they'd already earned.
local function grantVipDaily(player)
	if not player:GetAttribute("SAC_VIP") then return end
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local today = os.time() // 86400
	if profile.lastVipRewardDay == today then return end
	profile.lastVipRewardDay = today

	local newTotal = PlayerDataService.AddSparks(player, Constants.VIP_DAILY_SPARKS)
	AnalyticsService.LogRewardEarned(player, Constants.VIP_DAILY_SPARKS, newTotal, "VIPDaily")
	remotes.SparksUpdated:FireClient(player, newTotal)
	local r = remotes:FindFirstChild("VipDailyGranted")
	if r then r:FireClient(player, Constants.VIP_DAILY_SPARKS) end
end

local function grantDailyReward(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local today = os.time() // 86400
	if profile.lastLoginDay == today then return end -- already claimed today

	if profile.lastLoginDay == today - 1 then
		-- Streak WRAPS rather than sticking at the cap: a player on a long streak keeps
		-- cycling back through to Day 7, so the big payoff stays repeatable instead of
		-- the ladder dead-ending after one good week.
		profile.loginStreak = (profile.loginStreak % Constants.LOGIN_STREAK_MAX) + 1
	else
		profile.loginStreak = 1 -- missed a day (or first ever login): streak resets
	end
	profile.lastLoginDay = today

	local entry = Constants.LOGIN_STREAK_REWARDS[profile.loginStreak]
		or Constants.LOGIN_STREAK_REWARDS[1]
	local newTotal = PlayerDataService.AddSparks(player, entry.sparks)

	if entry.limitedEggToken then
		profile.limitedEggTokens = (profile.limitedEggTokens or 0) + 1
	end

	AnalyticsService.LogRewardEarned(player, entry.sparks, newTotal,
		"LoginStreak_Day" .. profile.loginStreak)
	remotes.SparksUpdated:FireClient(player, newTotal)
	remotes.DailyRewardGranted:FireClient(player, entry.sparks, profile.loginStreak,
		entry.limitedEggToken == true)
end

-- Next Goal: checks, grants, and pushes the player's current objective. Called from a
-- single choke point (QuestService.ReportProgress via the hook below) plus the explicit
-- events that don't route through it -- world unlocks, rebirths, and fusion.
-- Tiered achievements ride the same choke point as the Next Goal ladder: any action
-- that reports quest progress also re-checks the endless achievement chains.
local function refreshAchievementTiers(player)
	local granted = PlayerDataService.CheckAchievementTiers(player)
	for _, a in ipairs(granted) do
		local profile = PlayerDataService.Get(player)
		remotes.SparksUpdated:FireClient(player, profile and profile.sparks or 0)
		AnalyticsService.LogRewardEarned(player, a.reward, profile and profile.sparks or 0, "AchievementTier")
		local r = remotes:FindFirstChild("AchievementUnlocked")
		if r then r:FireClient(player, a.title, a.reward) end
	end
end

local function refreshNextGoal(player)
	local completed = PlayerDataService.CheckNextGoal(player)
	for _, done in ipairs(completed) do
		local profile = PlayerDataService.Get(player)
		remotes.SparksUpdated:FireClient(player, profile and profile.sparks or 0)
		AnalyticsService.LogRewardEarned(player, done.reward,
			profile and profile.sparks or 0, "NextGoal")
		remotes.NextGoalCompleted:FireClient(player, done.title, done.reward)
	end
	remotes.NextGoalUpdated:FireClient(player, PlayerDataService.GetNextGoal(player))
end

remotes.RequestNextGoal.OnServerEvent:Connect(function(player)
	remotes.NextGoalUpdated:FireClient(player, PlayerDataService.GetNextGoal(player))
end)

-- Register the hook so any quest-progress-reporting action (hatch, orb, sparks,
-- explore) also re-checks the Next Goal ladder.
-- ===== Starter Pack offer =====
-- Pushed on join (after a beat so the HUD exists) and re-pushed on request. The client
-- shows a countdown; the server remains the source of truth on eligibility so a client
-- that fakes the timer still can't buy it late -- the purchase prompt simply won't open.
local function pushStarterPack(player)
	local eligible, remaining = PlayerDataService.GetStarterPackState(player)
	local info = Constants.DEV_PRODUCTS.StarterPack
	remotes.StarterPackState:FireClient(player, eligible, remaining, {
		sparks = info.sparks, extraSlots = info.extraSlots, tokens = info.limitedEggTokens,
	})
end

remotes.RequestStarterPack.OnServerEvent:Connect(function(player)
	local eligible = PlayerDataService.GetStarterPackState(player)
	if not eligible then
		pushStarterPack(player) -- correct the client's view rather than silently ignoring
		return
	end
	local info = Constants.DEV_PRODUCTS.StarterPack
	if info.id == 0 then
		remotes.HatchDenied:FireClient(player, "Starter Pack isn't available yet!")
		return
	end
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, info.id)
	end)
	if not ok then warn("[Main] starter pack prompt failed:", err) end
end)

QuestService.onProgressReported = function(player)
	refreshNextGoal(player)
	refreshAchievementTiers(player)
end

-- Live shiny-odds labels. The posted percentage must track the REAL roll, which changes
-- when a Lucky Hour event starts or ends -- a stale number on the egg would be actively
-- misleading. Watches the same workspace attribute the roll itself reads.
do
	local function refreshShinyOddsLabels()
		local eventMult = workspace:GetAttribute("SAC_EventShinyMultiplier") or 1
		local pct = Constants.SHINY_CHANCE * eventMult * 100
		local boosted = eventMult > 1
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == "ShinyOddsLabel" and d:IsA("TextLabel") then
				d.Text = string.format("\u{2728} Shiny: %.1f%%%s", pct, boosted and "  \u{1F340}LUCKY!" or "")
				d.TextColor3 = boosted and Color3.fromRGB(140, 255, 150) or Color3.fromRGB(255, 220, 120)
			end
		end
	end
	workspace:GetAttributeChangedSignal("SAC_EventShinyMultiplier"):Connect(refreshShinyOddsLabels)
	task.delay(3, refreshShinyOddsLabels) -- initial pass once all stands are built
end

-- Safety-net sweep. Most progression routes through ReportProgress or an explicit
-- refresh above, but world unlocks happen inside WorldService (which deliberately
-- doesn't depend on Main), and offline earnings can satisfy a goal between sessions.
-- A slow periodic check guarantees no goal ever sits silently completed.
task.spawn(function()
	while true do
		task.wait(10)
		for _, player in ipairs(Players:GetPlayers()) do
			local ok, err = pcall(refreshNextGoal, player)
			if not ok then warn("[Main] next-goal sweep failed:", err) end
		end
	end
end)

-- Forward declaration: pushCollection needs to re-apply walk speed when a completed
-- world grants a speed bonus, but applySpeedBonus is defined further down (next to the
-- other CharacterAdded appliers). Declaring it here keeps that grouping intact.
local applySpeedBonus

local function pushCollection(player)
	local profile = PlayerDataService.Get(player)
	if profile then
		-- Resync completion bonuses BEFORE pushing, so a set finished by the hatch that
		-- triggered this push applies immediately rather than on next rejoin.
		PlayerDataService.SyncWorldCompletionAttributes(player)
	PlayerDataService.SyncRelicAttributes(player)
	-- Ranch Power perks must be applied on JOIN too. Both existing calls sit inside
	-- event handlers (feeding, assigning), so a returning player's luck/income/slot
	-- bonuses stayed dead until they happened to open the sanctuary panel --
	-- verified live: SAC_RanchPower was nil after a fresh load.
	PlayerDataService.SyncRanchPowerAttributes(player)
	-- Migrate saves from the old "everything earns" model. Without this an existing
	-- player logs in with nothing equipped and zero income -- their whole collection
	-- intact but earning nothing, which reads as total data loss.
	PlayerDataService.MigrateToEquipModel(player)
	HatchLogic.SyncSlotAttributes(player)
	-- Push initial equip state so the inventory UI is correct the first time it's
	-- opened, rather than showing '?/?' until the player interacts.
	remotes.EquipState:FireClient(player, PlayerDataService.GetEquipState(player))
	-- Render the sanctuary on JOIN. Both existing SyncSanctuaryCreatures calls live
	-- inside the assign/unassign handlers, so a returning player saw an EMPTY ranch
	-- despite having creatures housed -- verified live: 37 assigned, 0 models. The
	-- bonuses applied correctly, but the creatures they came from were invisible.
	RanchService.SyncSanctuaryCreatures(player)
		if player.Character then applySpeedBonus(player, player.Character) end
		remotes.CollectionData:FireClient(player, PlayerDataService.GetCollectionSummary(player))
	end
end

-- Title nameplate above a player's head (Phase 7/8 Titles). Rebirth title always wins
-- once earned -- the stronger prestige signal, and the two systems shouldn't visually
-- compete -- otherwise shows a level title, but only once the player is far enough along
-- to have one worth showing (the baseline "Newcomer" tier is deliberately never
-- displayed: a tag on every single brand-new player would be noise, not a flex).
local function titleForLevel(level)
	local best = nil
	for _, entry in ipairs(Constants.LEVEL_TITLES) do
		if level >= entry.minLevel then
			best = entry
		end
	end
	return best
end

local function applyTitleTag(player, character)
	local head = character:WaitForChild("Head", 5)
	if not head then return end

	local text, color
	-- VIP takes precedence over earned titles: it's a paid status the player should see
	-- reflected immediately, and a VIP who happens to be low-level would otherwise show
	-- nothing at all. Rebirth/level titles still show for everyone else.
	if player:GetAttribute("SAC_VIP") then
		text = "\u{1F451} VIP"
		color = Constants.VIP_TAG_COLOR
	end
	local rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0
	if not text and rebirthCount > 0 then
		local tierInfo = Constants.GetRebirthTier(rebirthCount)
		if tierInfo then
			text = "\u{1F31F} " .. tierInfo.title
			color = tierInfo.auraColor
		end
	end
	if not text then
		local level = player:GetAttribute("SAC_Level") or 1
		local levelTitle = titleForLevel(level)
		if levelTitle and levelTitle.minLevel > 1 then
			text = "\u{1F396}\u{FE0F} " .. levelTitle.title
			color = levelTitle.color
		end
	end

	local tag = head:FindFirstChild("TitleTag")
	if not text then
		if tag then tag:Destroy() end -- nothing earned yet, e.g. a fresh post-rebirth starter
		return
	end

	if not tag then
		tag = Instance.new("BillboardGui")
		tag.Name = "TitleTag"
		tag.Size = UDim2.new(0, 160, 0, 32)
		tag.StudsOffset = Vector3.new(0, 2.6, 0)
		tag.AlwaysOnTop = true
		tag.Parent = head

		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 1, 0)
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextStrokeTransparency = 0.2
		label.Parent = tag
	end
	local label = tag:FindFirstChild("Label")
	if label then
		label.Text = text
		label.TextColor3 = color
	end
end

-- Cosmetic Trails: builds a real Roblox Trail between two attachment points on the
-- character's torso, colored per the player's equipped choice. Deliberately a separate
-- function/call pattern from applyTitleTag (direct calls from the purchase/equip
-- handlers, not an attribute-signal) since nothing else in the game needs to cheaply
-- read "current equipped trail" the way Ranch tier-sync needs to read Level.
local function applyTrail(player, character)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not torso then return end

	local existing = torso:FindFirstChild("CosmeticTrail")
	if existing then existing:Destroy() end

	local profile = PlayerDataService.Get(player)
	if not profile or not profile.equippedTrail then return end

	local trailData = nil
	for _, t in ipairs(Constants.COSMETIC_TRAILS) do
		if t.id == profile.equippedTrail then trailData = t break end
	end
	if not trailData then return end

	local att0 = torso:FindFirstChild("CosmeticTrailAtt0")
	if not att0 then
		att0 = Instance.new("Attachment")
		att0.Name = "CosmeticTrailAtt0"
		att0.Position = Vector3.new(-0.9, 0, 0)
		att0.Parent = torso
	end
	local att1 = torso:FindFirstChild("CosmeticTrailAtt1")
	if not att1 then
		att1 = Instance.new("Attachment")
		att1.Name = "CosmeticTrailAtt1"
		att1.Position = Vector3.new(0.9, 0, 0)
		att1.Parent = torso
	end

	local trail = Instance.new("Trail")
	trail.Name = "CosmeticTrail"
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Lifetime = 0.6
	trail.MinLength = 0.05
	trail.WidthScale = NumberSequence.new(1, 0)
	if trailData.rainbow then
		trail.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 80)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 230, 80)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(80, 220, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 100, 255)),
		})
	else
		trail.Color = ColorSequence.new(trailData.color)
	end
	trail.Transparency = NumberSequence.new(0, 1)
	trail.Parent = torso
end

-- Level Rewards (item #5): the Golden Aura -- a soft glowing PointLight + gentle
-- sparkle particles on the character, granted permanently at Level 25. Same
-- direct-call pattern as applyTrail (not an attribute-signal), wired into the same
-- CharacterAdded hooks so it's present on every spawn, not just the moment it's earned.
local function applyAura(player, character)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not torso then return end

	local existing = torso:FindFirstChild("LevelAura")
	if existing then existing:Destroy() end

	local profile = PlayerDataService.Get(player)
	if not profile or not profile.hasAura then return end

	local auraLight = Instance.new("PointLight")
	auraLight.Name = "LevelAura"
	auraLight.Color = Color3.fromRGB(255, 215, 90)
	auraLight.Brightness = 2
	auraLight.Range = 12
	auraLight.Parent = torso

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Name = "LevelAuraSparkle"
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 225, 140))
	sparkle.Lifetime = NumberRange.new(0.6, 1.0)
	sparkle.Speed = NumberRange.new(0.3, 0.8)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	sparkle.Rate = 4
	sparkle.LightEmission = 1
	sparkle.Parent = auraLight
end

-- Permanent Rebirth movement speed (item #6): applied directly to the Humanoid's
-- WalkSpeed, same CharacterAdded hook as title/trail/aura so it's present on every
-- spawn. Reads the default WalkSpeed off the Humanoid itself rather than a hardcoded
-- 16, so this stays correct even if the base speed is ever tuned elsewhere.
local DEFAULT_WALK_SPEED = 16
function applySpeedBonus(player, character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0
	local tier = Constants.GetRebirthTier(rebirthCount)
	local bonus = (tier and tier.speedBonus) or 0
	-- Permanent Collection Book completion bonus stacks additively with rebirth speed.
	bonus += player:GetAttribute("SAC_CollectionWalkSpeed") or 0
	humanoid.WalkSpeed = DEFAULT_WALK_SPEED + bonus
end

-- Forward-declared: onPlayerAdded calls this, but the body lives further down next to
-- the other leaderboard code. Without the declaration the call would capture nil.
local checkWeeklyReward
local checkSeasonReward

TelemetryService.Init()
BadgeAwardService.Init()
AnalyticsService.StartBatching()

local function onPlayerAdded(player)
	PlayerDataService.Load(player)
	AnalyticsService.LogPlayerJoined(player)
	grantDailyReward(player)
	HatchLogic.SyncSlotAttributes(player)
	QuestService.OnPlayerReady(player)
	PlaytimeRewardService.OnPlayerReady(player)
	DiscoveryService.OnPlayerReady(player)
	task.delay(2, function()
		if player.Parent then PotionService.SyncPlayer(player) end
	end)
	task.delay(3, function()
		if player.Parent then pushStarterPack(player) end
	end)
	-- VIP daily runs after a beat: gamepass ownership is resolved asynchronously by
	-- MonetizationService, so checking SAC_VIP immediately on join would race it and
	-- silently skip the payout for a genuine VIP.
	task.delay(4, function()
		if player.Parent then grantVipDaily(player) end
	end)
	-- Weekly leaderboard reward: delayed so the profile is fully loaded and the
	-- DataStore read doesn't compete with join-time traffic.
	-- Restore owned decorations. Delayed so the plot itself has been built first --
	-- SyncDecorations parents into the plot folder, which won't exist before then.
	task.delay(3, function()
		if player.Parent then
			local profile = PlayerDataService.Get(player)
			if profile and profile.ownedDecorations and next(profile.ownedDecorations) then
				local ok, err = pcall(RanchService.SyncDecorations, player, profile.ownedDecorations)
				if not ok then warn("[Main] decoration restore failed:", err) end
			end
		end
	end)
	task.delay(6, function()
		if player.Parent then
			local ok, err = pcall(checkWeeklyReward, player)
			if not ok then warn("[Main] weekly reward check failed:", err) end
			local ok2, err2 = pcall(checkSeasonReward, player)
			if not ok2 then warn("[Main] season reward check failed:", err2) end
		end
	end)
	RebirthService.SyncAttribute(player)
	PlayerDataService.SyncLevelAttribute(player)

	-- Offline earnings. Computed AFTER Load (needs the saved lastSeenAt/lastIncomeRate)
	-- and AFTER SyncAttribute (the rate snapshot is authoritative, but granting still
	-- goes through the normal AddSparks path so leaderstats/analytics stay consistent).
	-- Deliberately auto-granted rather than requiring a Claim button press: a player who
	-- misses the popup should never silently lose earnings they're owed.
	do
		local amount, secondsAway = PlayerDataService.ComputeOfflineEarnings(player)
		if amount > 0 then
			local newTotal = PlayerDataService.AddSparks(player, amount)
			remotes.SparksUpdated:FireClient(player, newTotal)
			AnalyticsService.LogRewardEarned(player, amount, newTotal, "OfflineEarnings")
			local offlineRemote = remotes:FindFirstChild("OfflineEarnings")
			if offlineRemote then
				-- Slight delay so the HUD has finished constructing before the popup lands.
				task.delay(2.5, function()
					if player.Parent then
						offlineRemote:FireClient(player, amount, secondsAway)
					end
				end)
			end
		end
	end
	-- Initial XPUpdated push: without this, a returning player with real progress sees
	-- the client HUD's hardcoded "Lv 1" placeholder until their next XP-granting action
	-- happens to fire the remote -- the level card only updates REACTIVELY to XPUpdated,
	-- it never independently reads the SAC_Level attribute set just above. Found live
	-- while testing the Achievements panel: the panel correctly showed "Reach Level 10
	-- (5/10)" while the HUD card next to it still said "Lv 1".
	do
		local level, xpIntoLevel, xpNeeded = PlayerDataService.GetLevel(player)
		local profile = PlayerDataService.Get(player)
		remotes.XPUpdated:FireClient(player, profile and profile.xp or 0, level, xpIntoLevel, xpNeeded)
	end
	-- Ranch Expansion: builds every tier the player's CURRENT level already qualifies
	-- for (catches a returning player up instantly, no need to re-watch old tier-ups),
	-- and remembers the resulting tier order so the live level-change hook below only
	-- celebrates a GENUINE new tier, not every level-up tick.
	local lastRanchTierOrder = RanchService.SyncPlotToLevel(player, PlayerDataService.GetLevel(player)).order
	task.delay(2, pushCollection, player) -- after HUD is up

	-- leaderstats: shows Sparks in the player list — free social visibility/competition,
	-- standard practice for this genre, costs nothing to add.
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	local sparksStat = Instance.new("IntValue")
	sparksStat.Name = "Sparks"
	sparksStat.Value = 0
	sparksStat.Parent = leaderstats
	local levelStat = Instance.new("IntValue")
	levelStat.Name = "Level"
	levelStat.Value = 1
	levelStat.Parent = leaderstats

	-- Live-update the title tag whenever level or rebirth count changes, without waiting
	-- for a character respawn -- same decoupled attribute-signal pattern as the rest of
	-- this codebase's cross-system bridges.
	player:GetAttributeChangedSignal("SAC_Level"):Connect(function()
		if player.Character then applyTitleTag(player, player.Character) end
		local level = player:GetAttribute("SAC_Level") or 1
		local tier = RanchService.SyncPlotToLevel(player, level)
		if tier.order > lastRanchTierOrder then
			lastRanchTierOrder = tier.order
			remotes.ServerAnnouncement:FireAllClients(
				string.format("\u{1F3E1} %s's ranch grew into a %s!", player.DisplayName:upper(), tier.name))
			local ranchTierUpRemote = remotes:FindFirstChild("RanchTierUp")
			if ranchTierUpRemote then
				ranchTierUpRemote:FireClient(player, tier.name, tier.order)
			end
		end
	end)
	player:GetAttributeChangedSignal("SAC_RebirthCount"):Connect(function()
		if player.Character then applyTitleTag(player, player.Character) end
	end)
	-- VIP resolves asynchronously after join, so the tag has to refresh when it lands --
	-- otherwise a VIP would spawn with no crown until their next respawn.
	player:GetAttributeChangedSignal("SAC_VIP"):Connect(function()
		if player.Character then applyTitleTag(player, player.Character) end
	end)

	player.CharacterAdded:Connect(function(character)
		task.spawn(trySpawnStarterCritter, player)
		applyTitleTag(player, character)
		applyTrail(player, character)
		applyAura(player, character)
		applySpeedBonus(player, character)
	end)
	if player.Character then
		task.spawn(trySpawnStarterCritter, player)
		applyTitleTag(player, player.Character)
		applyTrail(player, player.Character)
		applyAura(player, player.Character)
		applySpeedBonus(player, player.Character)
	end
end

for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
Players.PlayerAdded:Connect(onPlayerAdded)

-- ===== RequestHatch: player spends Sparks at the Hatchery for a new egg =====
-- (logic lives in HatchLogic so the in-world Hatchery prompts share the exact same path)
-- NOTE: the remote signature itself still only carries rarityId, not worldId -- there is
-- currently only one physical Hatchery in the game (World 1's), so defaulting here is
-- correct and honest. This becomes a real per-Hatchery worldId the moment World 2 gets
-- its own Hatchery landmark, at which point that landmark's prompts (built the same way
-- HatcheryController already builds World 1's) will pass their own world's id instead of
-- going through this remote path at all -- exactly how HatcheryController already calls
-- HatchLogic.PerformHatch directly rather than through a remote.

remotes.RequestHatch.OnServerEvent:Connect(function(player, rarityId)
	if typeof(rarityId) ~= "string" then return end
	HatchLogic.PerformHatch(player, WorldsData.DEFAULT_WORLD_ID, rarityId)
	-- Badges evaluated after the hatch so counters and collection are current.
	BadgeAwardService.CheckAll(player, PlayerDataService.Get(player))
end)



-- Multi-Hatch: count is clamped server-side inside PerformMultiHatch, so a spoofed
-- remote can't request an arbitrary batch size.
-- Multi-hatch now routes through the THEMED egg path, matching the in-world prompts.
-- The old signature took a rarityId and bought that specific tier -- left over from
-- before world-themed eggs existed. Kept accepting (and ignoring) the old argument so a
-- stale client can't error, but the roll is always the themed one now.
remotes.RequestMultiHatch.OnServerEvent:Connect(function(player, worldIdOrRarity, count)
	if typeof(count) ~= "number" then return end
	local worldId = WorldsData.GetWorld(worldIdOrRarity) and worldIdOrRarity or WorldsData.DEFAULT_WORLD_ID
	local clamped = math.clamp(math.floor(count), 1, Constants.MAX_MULTI_HATCH)
	for _ = 1, clamped do
		if not HatchLogic.PerformThemedHatch(player, worldId) then break end
	end
	BadgeAwardService.CheckAll(player, PlayerDataService.Get(player))
end)



-- ===== RequestGoToRanch: "My Ranch" HUD button teleports the player to their own
-- private plot. Server-authoritative position (RanchService.GetPlotPosition), never
-- trusts a client-supplied destination.
--
-- TWO real bugs caught and fixed while live-testing this, not left in: (1) the original
-- +35 stud Z offset placed the player OUTSIDE the plot's actual 30-stud platform radius
-- -- they missed the platform entirely, fell into the void, and Roblox's own fall-safety
-- net silently respawned them back at the main island. Reduced to +15, safely inside.
-- (2) directly setting hrp.CFrame on a client-owned HumanoidRootPart can get fought and
-- overridden by the client's own physics prediction for a large instant jump -- switched
-- to Model:PivotTo, the officially correct API for reliably repositioning a whole
-- character, which held correctly in live verification where the raw CFrame set didn't.
remotes.RequestGoToRanch.OnServerEvent:Connect(function(player)
	local char = player.Character
	if not char then return end
	local plotPos = RanchService.GetPlotPosition(player)
	char:PivotTo(CFrame.new(plotPos + Vector3.new(0, 8, 15), plotPos))
	remotes.GoToRanchResult:FireClient(player)
end)

-- ===== RequestVisitRanch: teleports the requester to ANOTHER currently-in-server
-- player's Ranch plot -- read-only, no plot mutation, genuinely just travel. Reuses
-- RanchService.GetPlotPosition (userId-based, deterministic) exactly like "My Ranch"
-- does for your own plot. Notifies the HOST too, so a visit is a real, felt social
-- moment on both ends, not something that happens silently to them. =====
-- ===== Friends in server =====
-- Friend status must be resolved SERVER-side: Player:IsFriendsWith yields on a web call
-- and is rate-limited, so having every client poll it for every other player would be
-- both slow and a good way to get throttled.
--
-- Results are cached per (player, target) pair for the session -- friendship doesn't
-- change mid-session in any way worth re-querying, and the cache turns an O(players^2)
-- web-call problem into a handful of one-time lookups.
local friendCache = {} -- [userId] = { [otherUserId] = true/false }

local function isFriendsCached(player, otherUserId)
	local cache = friendCache[player.UserId]
	if not cache then
		cache = {}
		friendCache[player.UserId] = cache
	end
	if cache[otherUserId] ~= nil then return cache[otherUserId] end
	local ok, result = pcall(function()
		return player:IsFriendsWith(otherUserId)
	end)
	local value = ok and result == true
	cache[otherUserId] = value
	return value
end

Players.PlayerRemoving:Connect(function(player)
	-- Free the hatch rate-limit record so it can't grow unbounded over a
	-- long-lived server.
	HatchLogic.ForgetPlayer(player.UserId)	friendCache[player.UserId] = nil
	-- Also drop this player from everyone else's cache so a rejoin re-resolves cleanly.
	for _, cache in pairs(friendCache) do
		cache[player.UserId] = nil
	end
end)

-- Friend proximity bonus. Runs on a slow sweep rather than per-heartbeat: this is a
-- multiplier that only needs to feel responsive within a couple of seconds, and
-- distance-checking every player pair every frame would be genuinely wasteful.
--
-- Reuses isFriendsCached, so this costs zero extra web calls beyond what the Visit Ranch
-- panel already resolved.
local function refreshFriendBonuses()
	local players = Players:GetPlayers()
	for _, player in ipairs(players) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then
			player:SetAttribute("SAC_FriendBonus", nil)
			player:SetAttribute("SAC_NearbyFriends", nil)
		else
			local nearby = 0
			for _, other in ipairs(players) do
				if other ~= player then
					local oc = other.Character
					local ohrp = oc and oc:FindFirstChild("HumanoidRootPart")
					if ohrp and (ohrp.Position - hrp.Position).Magnitude <= Constants.FRIEND_BONUS_RADIUS then
						if isFriendsCached(player, other.UserId) then
							nearby += 1
						end
					end
				end
			end
			if nearby > 0 then
				local bonus = math.min(nearby * Constants.FRIEND_BONUS_PER_FRIEND,
					Constants.FRIEND_BONUS_MAX)
				player:SetAttribute("SAC_FriendBonus", bonus)
				player:SetAttribute("SAC_NearbyFriends", nearby)
			else
				player:SetAttribute("SAC_FriendBonus", nil)
				player:SetAttribute("SAC_NearbyFriends", nil)
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(3)
		local ok, err = pcall(refreshFriendBonuses)
		if not ok then warn("[Main] friend bonus sweep failed:", err) end
	end
end)

remotes.RequestFriendsInServer.OnServerEvent:Connect(function(player)
	local result = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			result[#result + 1] = {
				userId = other.UserId,
				displayName = other.DisplayName,
				isFriend = isFriendsCached(player, other.UserId),
				likes = PlayerDataService.GetRanchLikes(other),
				alreadyLiked = PlayerDataService.HasLikedRanch(player, other.UserId),
			}
		end
	end
	-- Friends first, then alphabetical -- the whole point is making friends findable
	-- without scrolling a full server list.
	table.sort(result, function(a, b)
		if a.isFriend ~= b.isFriend then return a.isFriend end
		return a.displayName < b.displayName
	end)
	remotes.FriendsInServerData:FireClient(player, result)
end)

-- ===== Weekly leaderboard rewards =====
-- Checked on join rather than on a schedule: a player can only be paid while they're
-- actually here, and reading LAST week's final standings the first time they log in
-- during the new week is both correct and free of any timer that could fire into an
-- empty server.
-- Seasonal reward: same join-time pattern as the weekly one, reading LAST season's
-- final standings. Separate claim stamp so a player can receive both in the same login.
function checkSeasonReward(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local lastSeason = Constants.GetSeasonIndex() - 1
	if (profile.lastSeasonRewardSeason or 0) >= lastSeason then return end
	profile.lastSeasonRewardSeason = lastSeason

	local store
	local ok = pcall(function()
		store = DataStoreService:GetOrderedDataStore("SAC_SeasonRebirths_" .. lastSeason)
	end)
	if not ok or not store then return end

	local pagesOk, pages = pcall(function()
		return store:GetSortedAsync(false, 50)
	end)
	if not pagesOk or not pages then return end

	local myRank
	for i, entry in ipairs(pages:GetCurrentPage()) do
		if entry.key == tostring(player.UserId) then myRank = i break end
	end
	if not myRank then return end

	local reward = Constants.GetSeasonalReward(myRank)
	if not reward then return end

	local newTotal = PlayerDataService.AddSparks(player, reward.sparks)
	AnalyticsService.LogRewardEarned(player, reward.sparks, newTotal, "SeasonalLeaderboard")
	remotes.SparksUpdated:FireClient(player, newTotal)
	local r = remotes:FindFirstChild("WeeklyRewardGranted")
	if r then r:FireClient(player, myRank, reward.sparks, reward.label) end
end

function checkWeeklyReward(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local currentWeek = Constants.GetWeekIndex()
	local lastWeek = currentWeek - 1
	-- Already paid for that week (or never played it).
	if (profile.lastWeeklyRewardWeek or 0) >= lastWeek then return end
	profile.lastWeeklyRewardWeek = lastWeek

	local store
	local ok = pcall(function()
		store = DataStoreService:GetOrderedDataStore("SAC_WeeklySparks_" .. lastWeek)
	end)
	if not ok or not store then return end

	local pagesOk, pages = pcall(function()
		-- Top 50 is the deepest reward tier, so there's no reason to page further.
		return store:GetSortedAsync(false, 50)
	end)
	if not pagesOk or not pages then return end

	local page = pages:GetCurrentPage()
	local myRank
	for i, entry in ipairs(page) do
		if entry.key == tostring(player.UserId) then myRank = i break end
	end
	if not myRank then return end

	local reward = Constants.GetWeeklyReward(myRank)
	if not reward then return end

	local newTotal = PlayerDataService.AddSparks(player, reward.sparks)
	AnalyticsService.LogRewardEarned(player, reward.sparks, newTotal, "WeeklyLeaderboard")
	remotes.SparksUpdated:FireClient(player, newTotal)
	local r = remotes:FindFirstChild("WeeklyRewardGranted")
	if r then r:FireClient(player, myRank, reward.sparks, reward.label) end
end

-- ===== Ranch decorations =====
-- Purchase is a pure Sparks sink: no stat effect, so it can absorb surplus without
-- distorting the economy. The slot is assigned server-side to the lowest free index so
-- two decorations can never overlap.
remotes.RequestBuyDecoration.OnServerEvent:Connect(function(player, decoId)
	if typeof(decoId) ~= "string" then return end
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	profile.ownedDecorations = profile.ownedDecorations or {}

	local entry
	for _, d in ipairs(Constants.RANCH_DECORATIONS) do
		if d.id == decoId then entry = d break end
	end
	if not entry then return end
	if profile.ownedDecorations[decoId] then
		remotes.DecorationResult:FireClient(player, false, "You already own that.")
		return
	end

	-- Lowest free slot.
	local used = {}
	for _, slot in pairs(profile.ownedDecorations) do used[slot] = true end
	local freeSlot
	for s = 1, Constants.RANCH_DECORATION_SLOTS do
		if not used[s] then freeSlot = s break end
	end
	if not freeSlot then
		remotes.DecorationResult:FireClient(player, false, "Your ranch has no free spots.")
		return
	end

	if not PlayerDataService.TrySpendSparks(player, entry.cost) then
		remotes.DecorationResult:FireClient(player, false, "Not enough Sparks.")
		return
	end

	profile.ownedDecorations[decoId] = freeSlot
	AnalyticsService.LogTrailPurchase(player, entry.cost, profile.sparks, "deco_" .. decoId)
	remotes.SparksUpdated:FireClient(player, profile.sparks)
	RanchService.SyncDecorations(player, profile.ownedDecorations)
	remotes.DecorationResult:FireClient(player, true, entry.name)
	remotes.DecorationData:FireClient(player, profile.ownedDecorations)
end)

remotes.RequestDecorationData.OnServerEvent:Connect(function(player)
	local profile = PlayerDataService.Get(player)
	if profile then
		remotes.DecorationData:FireClient(player, profile.ownedDecorations or {})
	end
end)

-- ===== Ranch Likes =====
-- Server-authoritative: the client can request a like, but the one-per-player rule and
-- the count both live in the target's profile, so a spoofed remote can't inflate anyone.
remotes.RequestLikeRanch.OnServerEvent:Connect(function(player, targetUserId)
	if typeof(targetUserId) ~= "number" then return end
	local ok, result = PlayerDataService.LikeRanch(player, targetUserId)
	if not ok then
		remotes.RanchLikeResult:FireClient(player, false, result)
		return
	end
	remotes.RanchLikeResult:FireClient(player, true, result)

	-- Tell the owner, if they're still here. A like landing while they watch is the
	-- whole point of the feature -- a silent counter nobody sees isn't social.
	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		remotes.RanchLikesUpdated:FireClient(target, result, player.DisplayName)
	end
end)

remotes.RequestVisitRanch.OnServerEvent:Connect(function(player, targetUserId)
	if typeof(targetUserId) ~= "number" then return end
	if targetUserId == player.UserId then
		remotes.VisitRanchResult:FireClient(player, false, "That's your own ranch! Use My Ranch instead.")
		return
	end
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then
		remotes.VisitRanchResult:FireClient(player, false, "That player has left the server.")
		return
	end
	local char = player.Character
	if not char then return end
	local plotPos = RanchService.GetPlotPosition(targetPlayer)
	char:PivotTo(CFrame.new(plotPos + Vector3.new(0, 8, 15), plotPos))
	remotes.VisitRanchResult:FireClient(player, true, targetPlayer.DisplayName)
	remotes.VisitRanchResult:FireClient(targetPlayer, true, nil, player.DisplayName) -- distinct host-side notice
end)


-- ===== RequestAchievementsData: client pulls a fresh read-only snapshot whenever the
-- Achievements panel opens, rather than the server trying to push on every stat change
-- that might affect it (fewer moving parts, and the panel is only actually looked at
-- occasionally) =====
remotes.RequestAchievementsData.OnServerEvent:Connect(function(player)
	-- Sends one-shot achievements AND the current tier of every infinite chain. The chain
	-- tiers were being granted silently -- GetAchievementTierState existed but nothing
	-- called it, so a player earning "Hatcher 6" got the Sparks and never saw why.
	local combined = PlayerDataService.GetAchievementsState(player)
	for _, entry in ipairs(PlayerDataService.GetAchievementTierState(player)) do
		combined[#combined + 1] = entry
	end
	remotes.AchievementsData:FireClient(player, combined)
end)

-- ===== Long-Term Goals (item #11) =====
remotes.RequestGoalsData.OnServerEvent:Connect(function(player)
	remotes.GoalsData:FireClient(player, PlayerDataService.GetGoalsState(player))
end)

-- ===== Cosmetic Trails: purchase/equip/data =====
remotes.RequestTrailsData.OnServerEvent:Connect(function(player)
	remotes.TrailsData:FireClient(player, PlayerDataService.GetTrailsState(player))
end)
remotes.RequestPurchaseTrail.OnServerEvent:Connect(function(player, trailId)
	if typeof(trailId) ~= "string" then return end
	local ok, reason = PlayerDataService.PurchaseTrail(player, trailId)
	if ok then
		local profile = PlayerDataService.Get(player)
		remotes.SparksUpdated:FireClient(player, profile.sparks)
		if player.Character then applyTrail(player, player.Character) end
	end
	remotes.TrailPurchaseResult:FireClient(player, ok, reason)
	remotes.TrailsData:FireClient(player, PlayerDataService.GetTrailsState(player))
end)
remotes.RequestEquipTrail.OnServerEvent:Connect(function(player, trailId)
	-- trailId may legitimately be nil (unequip), so no typeof guard here beyond string-or-nil
	if trailId ~= nil and typeof(trailId) ~= "string" then return end
	local ok = PlayerDataService.EquipTrail(player, trailId)
	if ok and player.Character then applyTrail(player, player.Character) end
	remotes.TrailsData:FireClient(player, PlayerDataService.GetTrailsState(player))
end)

-- ===== Daily Shop (item #16): data pull + claim =====
remotes.RequestDailyShopData.OnServerEvent:Connect(function(player)
	remotes.DailyShopData:FireClient(player, PlayerDataService.GetDailyShopState(player))
end)
remotes.RequestPurchaseDailyShopOffer.OnServerEvent:Connect(function(player)
	local ok, reason = PlayerDataService.PurchaseDailyShopOffer(player)
	if ok then
		local profile = PlayerDataService.Get(player)
		remotes.SparksUpdated:FireClient(player, profile.sparks)
		if player.Character then applyTrail(player, player.Character) end
	end
	remotes.DailyShopData:FireClient(player, PlayerDataService.GetDailyShopState(player))
end)

-- ===== Egg odds: honest, live-calculated hatch information =====
-- Deliberately NOT a fake "70% Common / 20% Rare" table. In this game buying a Rare egg
-- GUARANTEES a Rare -- Constants.RARITIES has a `weight` field but nothing reads it, so
-- publishing tier percentages would be inventing odds that don't exist.
--
-- What IS random, and therefore what's worth showing: which species within the tier,
-- and the shiny roll -- which genuinely varies with the player's permanent rebirth luck
-- and any active Lucky Hour event. Computed server-side per request so the number shown
-- is the player's REAL current chance, not a static advertised one.
remotes.RequestEggOdds.OnServerEvent:Connect(function(player, worldId)
	if typeof(worldId) ~= "string" then worldId = WorldsData.DEFAULT_WORLD_ID end
	local world = WorldsData.GetWorld(worldId)
	if not world or not world.rarities then return end

	local luckyMult = workspace:GetAttribute("SAC_EventShinyMultiplier") or 1
	local rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0
	local rebirthTier = Constants.GetRebirthTier(rebirthCount)
	local rebirthLuck = (rebirthTier and rebirthTier.luckBonus) or 1
	local shinyChance = math.min(Constants.SHINY_CHANCE * luckyMult * rebirthLuck, 1)

	local rows = {}
	for _, tier in ipairs(world.rarities) do
		if tier.cost and tier.cost > 0 then
			local speciesList = world.species and world.species[tier.id]
			rows[#rows + 1] = {
				id = tier.id,
				cost = tier.cost,
				rate = tier.sparksPerSecond,
				speciesCount = speciesList and #speciesList or 0,
			}
		end
	end
	remotes.EggOddsData:FireClient(player, rows, shinyChance, luckyMult > 1)
end)

-- ===== Rebirth preview: show the player what they GAIN before they commit =====
-- Rebirth wipes Sparks and every critter, which reads as pure punishment unless the
-- upside is made concrete. This sends the real current income alongside the projected
-- post-rebirth income so the panel can show "52K/sec -> 410K/sec" instead of just a
-- scary reset warning.
--
-- Computed server-side because ComputeIncomeRate already accounts for the DoubleSparks
-- gamepass and the existing rebirth multiplier -- the client has no reliable way to
-- reproduce that.
remotes.RequestRebirthPreview.OnServerEvent:Connect(function(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local currentRate = PlayerDataService.ComputeIncomeRate(player, profile)
	local currentMult = 1
	if profile.rebirths > 0 and Constants.GetRebirthTier(profile.rebirths) then
		currentMult = Constants.GetRebirthTier(profile.rebirths).multiplier
	end
	local nextTier = Constants.GetRebirthTier(profile.rebirths + 1)
	if not nextTier then
		remotes.RebirthPreviewData:FireClient(player, currentRate, nil, nil)
		return
	end
	-- Projection deliberately assumes the player rebuilds an EQUIVALENT collection --
	-- it shows the multiplier's effect on their current earning power, not a promise
	-- about the moment immediately after the reset (when they'd have one starter).
	local projected = (currentRate / currentMult) * nextTier.multiplier
	remotes.RebirthPreviewData:FireClient(player, currentRate, projected, nextTier.multiplier)
end)

-- ===== Ranch feeding (visitor interaction) =====
-- Gives visiting a ranch something to DO. The visitor is paid for it too -- without a
-- reward nobody feeds a stranger's creatures, and the whole interaction stays dead.
remotes.RequestFeedRanch.OnServerEvent:Connect(function(player, targetUserId)
	if typeof(targetUserId) ~= "number" then return end
	local ok, result = PlayerDataService.FeedRanch(player, targetUserId)
	if not ok then
		remotes.FeedRanchResult:FireClient(player, false, result)
		return
	end

	-- Pay the visitor.
	local newTotal = PlayerDataService.AddSparks(player, Constants.FEED_VISITOR_SPARKS)
	remotes.SparksUpdated:FireClient(player, newTotal)
	AnalyticsService.LogRewardEarned(player, Constants.FEED_VISITOR_SPARKS, newTotal, "RanchFeed")
	remotes.FeedRanchResult:FireClient(player, true, Constants.FEED_VISITOR_SPARKS)

	-- Tell the owner if they're here, and refresh their perks -- happiness just
	-- changed, so their Ranch Power did too.
	local owner = Players:GetPlayerByUserId(targetUserId)
	if owner then
		PlayerDataService.SyncRanchPowerAttributes(owner)
		remotes.RanchFedNotice:FireClient(owner, player.DisplayName, result)
		remotes.SanctuaryState:FireClient(owner, PlayerDataService.GetSanctuaryState(owner))
	end
end)

-- ===== Group reward =====
-- Applied as an attribute on join so it flows through the same income chain as every
-- other bonus. IsInGroup is a web call, so it's wrapped in pcall and deliberately
-- non-fatal: a Roblox API hiccup must not block the player from playing.
local function applyGroupBonus(player)
	if Constants.GROUP_ID == 0 then return end
	local ok, inGroup = pcall(function()
		return player:IsInGroup(Constants.GROUP_ID)
	end)
	if ok and inGroup then
		player:SetAttribute("SAC_GroupBonus", Constants.GROUP_INCOME_BONUS)
	else
		player:SetAttribute("SAC_GroupBonus", nil)
	end
end

Players.PlayerAdded:Connect(function(player)
	task.delay(2, function()
		if player.Parent then pcall(applyGroupBonus, player) end
	end)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.delay(2, function()
		if player.Parent then pcall(applyGroupBonus, player) end
	end)
end

remotes.RequestRelicState.OnServerEvent:Connect(function(player)
	remotes.RelicState:FireClient(player, PlayerDataService.GetRelicState(player))
end)

-- ===== Promo codes =====
-- Rate-limited per player: codes are guessable by construction (they're meant to be
-- typed from a video), so without a limit a client could brute-force the table.
local lastCodeAttempt = {}
remotes.RequestRedeemCode.OnServerEvent:Connect(function(player, code)
	if typeof(code) ~= "string" then return end
	local now = os.clock()
	if lastCodeAttempt[player.UserId] and now - lastCodeAttempt[player.UserId] < 1.5 then
		remotes.RedeemCodeResult:FireClient(player, false, "TooFast")
		return
	end
	lastCodeAttempt[player.UserId] = now

	local ok, result = PlayerDataService.RedeemCode(player, code)
	if ok then
		local profile = PlayerDataService.Get(player)
		remotes.SparksUpdated:FireClient(player, profile and profile.sparks or 0)
		AnalyticsService.LogRewardEarned(player, result.sparks or 0,
			profile and profile.sparks or 0, "PromoCode")
	end
	remotes.RedeemCodeResult:FireClient(player, ok, ok and result.label or result)
end)

Players.PlayerRemoving:Connect(function(player)
	lastCodeAttempt[player.UserId] = nil
end)

-- ===== Bulk inventory operations =====
remotes.RequestBulkInventory.OnServerEvent:Connect(function(player, action, filter)
	if typeof(action) ~= "string" then return end
	-- Filter comes from the client, so validate every field rather than trusting the
	-- shape -- a malformed table here would otherwise reach the matcher directly.
	local clean = nil
	if typeof(filter) == "table" then
		clean = {}
		if typeof(filter.rarity) == "string" then clean.rarity = filter.rarity end
		if typeof(filter.variant) == "string" then clean.variant = filter.variant end
		if typeof(filter.isShiny) == "boolean" then clean.isShiny = filter.isShiny end
		if filter.excludeLocked ~= false then clean.excludeLocked = true end
	else
		clean = { excludeLocked = true }
	end

	local ok, result = PlayerDataService.BulkInventoryAction(player, action, clean)
	remotes.BulkInventoryResult:FireClient(player, ok, result)
	if ok then
		remotes.InventoryData:FireClient(player, PlayerDataService.GetInventoryState(player))
	end
end)

-- ===== Worlds panel: data + teleport =====
-- Players previously had to physically walk to a gate to change worlds. With 8 worlds
-- spread thousands of studs apart that's a long, dull trip every time -- and it hides
-- the progression, since you can't see what's ahead without travelling to it.
remotes.RequestWorldsData.OnServerEvent:Connect(function(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local out = {}
	for _, w in ipairs(WorldsData.WORLDS) do
		if w.implemented then
			-- Count owned species from the PREVIOUS world, so the panel can show exactly
			-- what's still needed rather than a bare "locked".
			local prev
			for _, o in ipairs(WorldsData.WORLDS) do
				if o.order == w.order - 1 then prev = o end
			end
			local owned, total = 0, 0
			if prev and prev.species then
				for _, list in pairs(prev.species) do
					for _, sp in ipairs(list) do
						total += 1
						if profile.collection[sp] == "owned" then owned += 1 end
					end
				end
			end
			out[#out + 1] = {
				id = w.id,
				name = w.displayName,
				order = w.order,
				unlocked = WorldService.IsUnlocked(player, w.id),
				cost = w.unlockCost or 0,
				requiredRebirths = w.requiredRebirths or 0,
				requiredPrevSpecies = w.requiredPrevSpecies,
				prevOwned = owned,
				prevName = prev and prev.displayName or nil,
			}
		end
	end
	table.sort(out, function(a, b) return a.order < b.order end)
	remotes.WorldsData:FireClient(player, out, profile.rebirths or 0)
end)

remotes.RequestTeleportWorld.OnServerEvent:Connect(function(player, worldId)
	if typeof(worldId) ~= "string" then return end
	local world = WorldsData.GetWorld(worldId)
	if not world then return end
	-- Server-authoritative: an unlocked check here is what stops a modified client
	-- teleporting straight into Volcano on their first minute.
	if not WorldService.IsUnlocked(player, worldId) then
		remotes.TeleportResult:FireClient(player, false, "Locked")
		return
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		remotes.TeleportResult:FireClient(player, false, "NoCharacter")
		return
	end
	-- Spawn slightly above the zone platform so the player never lands inside geometry.
	local dest = (world.order == 1)
		and Vector3.new(0, 8, 0)
		or (world.zonePosition + Vector3.new(0, 8, 14))
	char:PivotTo(CFrame.new(dest))
	remotes.TeleportResult:FireClient(player, true, world.displayName)
end)

-- ===== Equip / Unequip =====
-- Keeps the PHYSICAL models in sync with the equipped set: spawn on equip, destroy on
-- unequip. Without this the world shows a stale set -- either creatures that no longer
-- earn, or an equipped creature with no model at all.
local function syncEquippedModels(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	PlayerDataService.PruneEquipped(player)

	local equipped = {}
	for _, uid in ipairs(profile.equippedUids or {}) do equipped[uid] = true end

	-- Despawn anything no longer equipped.
	for _, model in ipairs(CritterService.GetCritterModels()) do
		local uid = model:GetAttribute("CritterUid")
		if uid and not equipped[uid] then
			CritterService.RemoveCritter(uid)
		end
	end

	-- Spawn anything equipped that has no model yet.
	local live = {}
	for _, model in ipairs(CritterService.GetCritterModels()) do
		local uid = model:GetAttribute("CritterUid")
		if uid then live[uid] = true end
	end
	for _, rec in ipairs(profile.ownedCritters) do
		if equipped[rec.uid] and not live[rec.uid] then
			local world = WorldsData.GetWorld(rec.worldId or WorldsData.DEFAULT_WORLD_ID)
			local tier
			if world then
				for _, t in ipairs(world.rarities) do
					if t.id == rec.rarity then tier = t end
				end
			end
			-- Limited creatures aren't in any world's rarity table, same as the
			-- reconstruction path.
			if not tier and rec.rarity == "Limited" then
				tier = {
					id = "Limited", sparksPerSecond = rec.sparksPerSecond or 260,
					sizeScale = 1.4, auraColor = Color3.fromRGB(150, 190, 255),
					cost = Constants.LIMITED_EGG_COST,
				}
			end
			if tier then
				CritterService.SpawnForPlayer(player, tier, rec.species, rec.worldId,
					rec.uid, rec.isShiny or false, rec.personality)
			end
		end
	end
end

local function pushEquip(player)
	HatchLogic.SyncSlotAttributes(player)
	syncEquippedModels(player)
	remotes.EquipState:FireClient(player, PlayerDataService.GetEquipState(player))
end

remotes.RequestEquipState.OnServerEvent:Connect(function(player)
	pushEquip(player)
end)

remotes.RequestEquip.OnServerEvent:Connect(function(player, uid)
	if typeof(uid) ~= "string" then return end
	local ok, reason = PlayerDataService.EquipCritter(player, uid)
	remotes.EquipResult:FireClient(player, ok, reason)
	pushEquip(player)
end)

remotes.RequestUnequip.OnServerEvent:Connect(function(player, uid)
	if typeof(uid) ~= "string" then return end
	local ok, reason = PlayerDataService.UnequipCritter(player, uid)
	remotes.EquipResult:FireClient(player, ok, reason)
	pushEquip(player)
end)

remotes.RequestEquipBest.OnServerEvent:Connect(function(player)
	local ok, count = PlayerDataService.EquipBest(player)
	remotes.EquipResult:FireClient(player, ok, ok and ("Equipped best " .. tostring(count)) or count)
	pushEquip(player)
end)


-- ===== Creature Sanctuary =====
-- Assigned creatures live at the ranch and contribute Ranch Power, which unlocks
-- permanent luck/income/slot perks. Capacity is capped by ranch tier on purpose --
-- uncapped, hoarding junk would beat curating quality.
local function pushSanctuary(player)
	PlayerDataService.SyncRanchPowerAttributes(player)
	remotes.SanctuaryState:FireClient(player, PlayerDataService.GetSanctuaryState(player))
end

remotes.RequestSanctuaryState.OnServerEvent:Connect(function(player)
	pushSanctuary(player)
end)

remotes.RequestAssignSanctuary.OnServerEvent:Connect(function(player, uid)
	if typeof(uid) ~= "string" then return end
	local ok, reason = PlayerDataService.AssignToSanctuary(player, uid)
	remotes.SanctuaryResult:FireClient(player, ok, reason)
	if ok then
		RanchService.SyncSanctuaryCreatures(player)
		HatchLogic.SyncSlotAttributes(player)
	end
	pushSanctuary(player)
end)

remotes.RequestUnassignSanctuary.OnServerEvent:Connect(function(player, uid)
	if typeof(uid) ~= "string" then return end
	local ok, reason = PlayerDataService.RemoveFromSanctuary(player, uid)
	remotes.SanctuaryResult:FireClient(player, ok, reason)
	if ok then
		RanchService.SyncSanctuaryCreatures(player)
		HatchLogic.SyncSlotAttributes(player)
	end
	pushSanctuary(player)
end)

-- ===== Fusion (duplicates -> higher variant tier) =====
remotes.RequestFusableGroups.OnServerEvent:Connect(function(player)
	remotes.FusableGroupsData:FireClient(player, PlayerDataService.GetFusableGroups(player))
end)
remotes.RequestFuse.OnServerEvent:Connect(function(player, species, variantId)
	if typeof(species) ~= "string" or typeof(variantId) ~= "string" then return end
	local ok, newVariantOrReason, fusedSpecies, newRecord, consumedUids = PlayerDataService.FuseCritters(player, species, variantId)
	if ok then
		-- Destroy the consumed creatures' live models. PlayerDataService removed their
		-- records but deliberately can't touch CritterService (circular dependency), so
		-- without this the models would linger in the world as orphans forever.
		for _, uid in ipairs(consumedUids or {}) do
			CritterService.RemoveCritter(uid)
		end
		-- The inputs' live models were removed from the world when their records were
		-- dropped; the fused result needs its own model spawned so the player actually
		-- sees what they just made. Reuses the exact same resolve-tier-then-SpawnForPlayer
		-- pattern as the rejoin path above, passing the record's existing uid so the live
		-- model and the saved record stay in sync.
		local world = WorldsData.GetWorld(newRecord.worldId) or WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
		local tier
		for _, t in ipairs(world.rarities) do
			if t.id == newRecord.rarity then tier = t end
		end
		if tier then
			local spawned = CritterService.SpawnForPlayer(player, tier, newRecord.species,
				newRecord.worldId, newRecord.uid, newRecord.isShiny or false, newRecord.personality)
			if spawned then
				-- SpawnForPlayer recomputes sparksPerSecond from the tier alone and knows
				-- nothing about variants, so the fused multiplier must be reapplied to the
				-- LIVE record or the creature would earn at base rate despite being Gold.
				spawned.sparksPerSecond = newRecord.sparksPerSecond
				spawned.variant = newRecord.variant
			end
		else
			warn("[Main] Fusion: could not resolve tier for", newRecord.species)
		end
		HatchLogic.SyncSlotAttributes(player)
	end
	remotes.FuseResult:FireClient(player, ok, newVariantOrReason, fusedSpecies)
	remotes.FusableGroupsData:FireClient(player, PlayerDataService.GetFusableGroups(player))
	remotes.InventoryData:FireClient(player, PlayerDataService.GetInventoryState(player))
	if ok then refreshNextGoal(player) end -- fusion doesn't route through ReportProgress
end)

-- ===== Creature Inventory: data pull + favorite/lock toggles =====
remotes.RequestInventoryData.OnServerEvent:Connect(function(player)
	remotes.InventoryData:FireClient(player, PlayerDataService.GetInventoryState(player))
end)
remotes.RequestToggleFavorite.OnServerEvent:Connect(function(player, uid)
	if typeof(uid) ~= "string" then return end
	PlayerDataService.ToggleFavorite(player, uid)
	remotes.InventoryData:FireClient(player, PlayerDataService.GetInventoryState(player))
end)
remotes.RequestToggleLock.OnServerEvent:Connect(function(player, uid)
	if typeof(uid) ~= "string" then return end
	PlayerDataService.ToggleLock(player, uid)
	remotes.InventoryData:FireClient(player, PlayerDataService.GetInventoryState(player))
end)

-- ===== RequestBuySlot =====
remotes.RequestBuySlot.OnServerEvent:Connect(function(player)
	HatchLogic.PerformBuySlot(player)
end)

-- ===== RequestRebirth =====
remotes.RequestRebirth.OnServerEvent:Connect(function(player)
	RebirthService.PerformRebirth(player)
	refreshNextGoal(player) -- rebirth doesn't route through ReportProgress
end)

-- leaderstats sync loop: cheap periodic push rather than touching every Sparks/XP
-- mutation site individually
task.spawn(function()
	while true do
		task.wait(1)
		for _, player in ipairs(Players:GetPlayers()) do
			local profile = PlayerDataService.Get(player)
			local leaderstats = player:FindFirstChild("leaderstats")
			if profile and leaderstats then
				local sparksStat = leaderstats:FindFirstChild("Sparks")
				if sparksStat then sparksStat.Value = profile.sparks end
				local levelStat = leaderstats:FindFirstChild("Level")
				if levelStat then levelStat.Value = PlayerDataService.GetLevel(player) end
			end
		end
	end
end)

print("[Main] CREATURE RANCH server bootstrapped.")
