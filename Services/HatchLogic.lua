--[[
	HatchLogic.lua
	Shared purchase logic for hatching eggs and buying slots — called by BOTH the
	RemoteEvent handlers in Main (client-initiated) and HatcheryController's in-world
	ProximityPrompts (server-initiated). Exists so the logic lives in exactly one place.
]]

local RS = game:GetService("ReplicatedStorage")
local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local PlayerDataService = require(script.Parent.PlayerDataService)
local CritterService = require(script.Parent.CritterService)
local QuestService = require(script.Parent.QuestService)
local WorldService = require(script.Parent.WorldService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local HatchLogic = {}

-- ===== Hatch rate limiting =====
-- The prompt hold (0.25s) and the hatch cinematic gate a LEGITIMATE client, but neither
-- exists server-side: firing RequestHatch in a loop was accepted without limit --
-- verified live, 21 hatches landed in a single frame.
--
-- That isn't free Sparks (each hatch is still paid for), but it does let an exploiter
-- skip the entire hatch experience, spam the server, and burn through content at a rate
-- the economy was never balanced against.
--
-- The window is deliberately generous: multi-hatch legitimately fires 25 in quick
-- succession, so this must throttle abuse without breaking a normal x25 pull.
local MAX_HATCH_BURST = 60      -- two full x25 pulls plus headroom
local BURST_WINDOW = 3

-- [userId] = { last = os.clock(), stamps = { ... } }
local hatchRate = {}

-- Returns true if this hatch is allowed. Bounded and self-pruning.
local function allowHatch(player)
	if not player then return false end
	local now = os.clock()
	local rec = hatchRate[player.UserId]
	if not rec then
		rec = { stamps = {} }
		hatchRate[player.UserId] = rec
	end
	-- NO minimum per-hatch interval: a legitimate x25 multi-hatch runs all 25
	-- iterations inside a single frame, so any interval check throttles it to 1.
	-- Verified live -- an 0.12s interval cut a valid x25 down to one creature.
	-- The burst window alone is what distinguishes abuse from a normal pull.

	-- Drop stamps outside the window, then check the burst cap.
	local kept = {}
	for _, t in ipairs(rec.stamps) do
		if now - t < BURST_WINDOW then kept[#kept + 1] = t end
	end
	rec.stamps = kept
	if #kept >= MAX_HATCH_BURST then return false end

	rec.stamps[#rec.stamps + 1] = now
	return true
end

function HatchLogic.ForgetPlayer(userId)
	hatchRate[userId] = nil
end

local function maxSlotsFor(player, profile)
	return PlayerDataService.GetMaxSlots(player, profile)
end

-- Mirrors slot usage onto player attributes so the client HUD can show "Slots X/Y"
-- without any extra remote traffic.
-- Reports EQUIP slots, not inventory size. The HUD's "Slots X/Y" is about how many
-- creatures are EARNING -- inventory is separately capped at 500 and is not a thing the
-- player manages moment to moment.
function HatchLogic.SyncSlotAttributes(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	PlayerDataService.PruneEquipped(player)
	player:SetAttribute("SAC_UsedSlots", #(profile.equippedUids or {}))
	player:SetAttribute("SAC_MaxSlots", PlayerDataService.GetEquipCapacity(player))
	-- Inventory fullness is a separate, much rarer concern.
	player:SetAttribute("SAC_InventoryCount", #profile.ownedCritters)
	player:SetAttribute("SAC_InventoryCap", Constants.MAX_INVENTORY)
end

-- worldId: which world's Hatchery this hatch happened at -- resolves the correct
-- rarity/species tables for that world (two worlds can both have a "Rare" tier with
-- different stats, so which one applies depends entirely on where the hatch happened).
-- Rolls a rarity from a world's weight table. This is what makes a themed egg a real
-- gamble rather than a fixed purchase -- and what makes the posted odds meaningful.
-- Resolves a player's total luck from every live source. Kept here (rather than in
-- Constants) because it needs Player attributes, which Constants deliberately doesn't
-- depend on so it stays client-safe.
local function playerLuck(player)
	return Constants.GetTotalLuck({
		rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0,
		eventMult = workspace:GetAttribute("SAC_EventShinyMultiplier") or 1,
		hasLuckPass = player:GetAttribute("SAC_LuckPass") == true,
		hasVip = player:GetAttribute("SAC_VIP") == true,
		potionMult = player:GetAttribute("SAC_LuckPotion"),
		collectionLuckBonus = player:GetAttribute("SAC_CollectionLuckBonus"),
		levelLuckBonus = player:GetAttribute("SAC_LevelLuckBonus"),
		ranchLuckBonus = player:GetAttribute("SAC_RanchLuckBonus"),
		relicLuckBonus = player:GetAttribute("SAC_RelicLuckBonus"),
	})
end

local function rollRarity(world, player)
	local luck = player and playerLuck(player) or 1
	local weighted = Constants.GetLuckWeightedRarities(world.rarities, luck)
	-- GetLuckWeightedRarities returns {tier=,weight=} pairs when luck > 1, and the raw
	-- rarity list when luck == 1 -- normalise both shapes here so the roll below doesn't
	-- have to care which it got.
	local entries = {}
	if weighted ~= world.rarities then
		entries = weighted
	else
		for i, t in ipairs(world.rarities) do entries[i] = { tier = t, weight = t.weight or 0 } end
	end

	local total = 0
	for _, e in ipairs(entries) do total += (e.weight or 0) end
	if total <= 0 then return world.rarities[1] end
	local roll = math.random() * total
	local acc = 0
	for _, e in ipairs(entries) do
		acc += (e.weight or 0)
		if roll <= acc then return e.tier end
	end
	return world.rarities[1]
end

-- Hatches a world's THEMED egg: one price, random rarity by weight. Wraps PerformHatch
-- so every existing guard (unlock gate, eviction, refunds, onboarding rig, Double Hatch)
-- applies unchanged -- the only difference is the tier is rolled instead of chosen.
function HatchLogic.PerformThemedHatch(player, worldId)
	local world = WorldsData.GetWorld(worldId)
	if not world or not world.themedEgg then return false end
	local rolled = rollRarity(world, player)
	return HatchLogic.PerformHatch(player, worldId, rolled.id, world.themedEgg.cost)
end

function HatchLogic.PerformHatch(player, worldId, rarityId, priceOverride)
	-- Rate gate. Applied to PerformHatch specifically because every hatch path
	-- (themed, multi, direct) funnels through here, so one check covers them all.
	if not allowHatch(player) then return false, "TooFast" end	local world = WorldsData.GetWorld(worldId)
	if not world or not world.implemented then
		remotes.HatchResult:FireClient(player, false, nil, nil, nil)
		return false
	end
	-- Server-authoritative gate: even a direct/spoofed remote call can't hatch in a
	-- world this player hasn't actually unlocked.
	if not WorldService.IsUnlocked(player, worldId) then
		remotes.HatchResult:FireClient(player, false, nil, nil, nil)
		return false
	end

	local tier
	for _, t in ipairs(world.rarities) do
		if t.id == rarityId then tier = t end
	end
	-- A tier with cost 0 is normally unpurchasable (World 1's free starter Common), but
	-- a THEMED egg can legitimately roll it -- the player already paid the egg's price,
	-- so the tier's own cost is irrelevant. Only reject cost-0 tiers on direct buys.
	if not tier or (not priceOverride and tier.cost <= 0) then
		remotes.HatchResult:FireClient(player, false, nil, nil, nil)
		return false
	end

	local profile = PlayerDataService.Get(player)
	if not profile then return false end

	-- Half-Price Hatch world event: straight cost multiplier via the same decoupled
	-- workspace-attribute pattern as every other world event flag. Floor at 1 Spark so
	-- a free hatch can never accidentally happen from rounding.
	local costMult = workspace:GetAttribute("SAC_EventHatchCostMultiplier") or 1
	-- priceOverride is set by themed-egg hatches: the player pays the EGG's price, not
	-- the price of whatever rarity happened to roll. Without this a lucky Mythic roll
	-- would charge Mythic prices, which would make the themed egg unaffordable exactly
	-- when it paid off.
	local basePrice = priceOverride or tier.cost
	local cost = math.max(1, math.floor(basePrice * costMult))

	if not PlayerDataService.TrySpendSparks(player, cost) then
		remotes.HatchResult:FireClient(player, false, nil, nil, nil)
		return false
	end

	-- NOTHING IS EVICTED ANY MORE. Under the old model, slots capped BOTH inventory and
	-- income, so hatching at cap destroyed a creature -- making the core action of the
	-- game punishing. Inventory is now 500 and separate from equip slots, so a hatch
	-- always adds.
	--
	-- The only failure case left is a genuinely full inventory, which needs ~500
	-- creatures and is resolved by fusing, trading or releasing rather than by losing
	-- something at random.
	if #profile.ownedCritters >= Constants.MAX_INVENTORY then
		PlayerDataService.AddSparks(player, cost) -- refund, nothing was spawned
		remotes.HatchResult:FireClient(player, false, nil, nil, nil)
		remotes.HatchDenied:FireClient(player,
			"Inventory full! Fuse or trade some creatures to make room.")
		return false
	end

	-- Onboarding rig: quietly upgrade the OUTCOME of a new player's first few paid
	-- hatches. The player pays for what they picked (`tier`); `resultTier` is what they
	-- actually receive. Can only ever promote, never demote, and only within this world's
	-- own rarity table -- so a rigged result is always a legitimate creature for where
	-- they're standing. Permanently off after ONBOARDING_RIG_LAST_HATCH.
	profile.paidHatchesTotal = (profile.paidHatchesTotal or 0) + 1
	local resultTier = tier
	if profile.paidHatchesTotal <= Constants.ONBOARDING_RIG_LAST_HATCH then
		local rig = Constants.ONBOARDING_HATCH_RIG[profile.paidHatchesTotal]
		if rig and (rig.tiersUp or 0) > 0 and (not rig.chance or math.random() < rig.chance) then
			-- Find the bought tier's index, then step up by tiersUp within this world's
			-- own rarity list. Clamped to the table, so the top tier simply stays put.
			local boughtIndex
			for idx, t in ipairs(world.rarities) do
				if t.id == tier.id then boughtIndex = idx break end
			end
			if boughtIndex then
				local target = world.rarities[math.min(boughtIndex + rig.tiersUp, #world.rarities)]
				if target and target.sparksPerSecond > resultTier.sparksPerSecond then
					resultTier = target
				end
			end
		end
	end

	local species = world.species[resultTier.id][math.random(1, #world.species[resultTier.id])]
	-- Captured BEFORE spawning -- CritterService.SpawnForPlayer mutates both
	-- ownedCritters and collection internally, so "was this already owned" and "what
	-- was my previous best" have to be read first, or they'd just describe the NEW
	-- critter compared to itself.
	local wasAlreadyOwned = profile.collection[species] == "owned"
	local previousBest = 0
	for _, c in ipairs(profile.ownedCritters) do
		previousBest = math.max(previousBest, c.sparksPerSecond or 0)
	end
	local record = CritterService.SpawnForPlayer(player, resultTier, species, worldId)
	if not record then
		PlayerDataService.AddSparks(player, cost) -- refund on unexpected failure
		remotes.HatchResult:FireClient(player, false, nil, nil, nil)
		return false
	end

	remotes.SparksUpdated:FireClient(player, PlayerDataService.Get(player).sparks)
	remotes.HatchResult:FireClient(player, true, resultTier.id, species, record.uid, record.isShiny, record.personality)
	-- Hatch excitement (item #3): NEW-species badge and a Better/Worse-than-your-best
	-- comparison, so every hatch is immediately understandable rather than just a
	-- number quietly changing. previousBest == 0 means this is genuinely the player's
	-- first-ever critter -- no real "best" existed yet, so skip the comparison rather
	-- than claim it's "worse" than a nonexistent baseline.
	if previousBest > 0 then
		local diff = record.sparksPerSecond - previousBest
		remotes.HatchComparison:FireClient(player, not wasAlreadyOwned, diff >= 0, diff)
	else
		remotes.HatchComparison:FireClient(player, not wasAlreadyOwned, true, 0)
	end
	HatchLogic.SyncSlotAttributes(player)
	QuestService.ReportProgress(player, "hatch", 1)
	AnalyticsService.LogHatchPurchase(player, cost, PlayerDataService.Get(player).sparks, resultTier.id, worldId)
	AnalyticsService.LogFirstRealPurchaseHatch(player)

	-- Double Hatch world event: a second, freshly-rolled Critter of the SAME tier, at no
	-- extra cost -- re-checks the slot cap independently, since this second grant can
	-- evict the oldest critter on its own if the first grant already filled every slot.
	-- Fires its own HatchResult, so the reveal cinematic genuinely plays twice in a row --
	-- that's the intended "you got TWO!" moment, not a bug.
	if workspace:GetAttribute("SAC_EventDoubleHatch") then
		local bonusProfile = PlayerDataService.Get(player)
		if bonusProfile then
			local bonusMaxSlots = maxSlotsFor(player, bonusProfile)
			local bonusSkipped = false
			if #bonusProfile.ownedCritters >= bonusMaxSlots then
				local oldest = PlayerDataService.FindEvictionTarget(player)
				if oldest then
					CritterService.RemoveCritter(oldest.uid)
					PlayerDataService.RemoveOwnedCritter(player, oldest.uid)
				else
					-- Every slot locked: the PRIMARY hatch above already succeeded, so this
					-- just quietly skips the bonus rather than failing the whole hatch --
					-- the player still got what they paid for, they just don't get the
					-- free extra this one time.
					bonusSkipped = true
				end
			end
			if not bonusSkipped then
				local bonusSpecies = world.species[tier.id][math.random(1, #world.species[tier.id])]
				local bonusRecord = CritterService.SpawnForPlayer(player, tier, bonusSpecies, worldId)
				if bonusRecord then
					PlayerDataService.AddOwnedCritter(player, {
						uid = bonusRecord.uid, rarity = tier.id, species = bonusSpecies, worldId = worldId,
						sparksPerSecond = bonusRecord.sparksPerSecond, isShiny = bonusRecord.isShiny,
					})

					-- Auto-equip into a FREE slot. Without this a new player's first
					-- creature sits unequipped earning nothing, which reads as broken.
					-- Full slots leave it in inventory -- the intended decision.
					PlayerDataService.EquipCritter(player, bonusRecord.uid)					remotes.HatchResult:FireClient(player, true, tier.id, bonusSpecies, bonusRecord.uid,
						bonusRecord.isShiny, bonusRecord.personality)
					HatchLogic.SyncSlotAttributes(player)
				end
			end
		end
	end

	if resultTier.serverAnnounce or record.isShiny then
		local prefix = record.isShiny and "\u{2728} SHINY! \u{2728} " or "\u{2b50} "
		local text = string.format("%s%s HATCHED A %s%s CRITTER!", prefix, player.DisplayName:upper(),
			record.isShiny and "SHINY " or "", resultTier.id:upper())
		remotes.ServerAnnouncement:FireAllClients(text)
	end
	return true
end

-- Multi-Hatch: hatches `count` eggs in one action. Deliberately implemented as a
-- WRAPPER around PerformHatch rather than a rewrite of it -- PerformHatch contains the
-- world-unlock gate, the Half-Price event multiplier, the locked-slot eviction rules,
-- and three separate refund paths, all heavily verified. Re-implementing that inline
-- for bulk would risk every one of those guards. This loops it instead, stops cleanly
-- the moment any single hatch fails (out of Sparks / all slots locked), and reports
-- how many actually succeeded.
function HatchLogic.PerformMultiHatch(player, worldId, rarityId, count)
	count = math.clamp(tonumber(count) or 1, 1, Constants.MAX_MULTI_HATCH)
	local succeeded = 0
	for _ = 1, count do
		local ok = HatchLogic.PerformHatch(player, worldId, rarityId)
		if not ok then break end
		succeeded += 1
	end
	if succeeded > 0 then
		local multiRemote = remotes:FindFirstChild("MultiHatchSummary")
		if multiRemote then
			multiRemote:FireClient(player, succeeded, count)
		end
	end
	return succeeded
end

function HatchLogic.PerformBuySlot(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return false end
	local nextIndex = profile.extraSlotsPurchased + 1
	local cost = Constants.EXTRA_SLOT_COSTS[nextIndex]
	if not cost then return false end -- maxed out
	if PlayerDataService.TrySpendSparks(player, cost) then
		profile.extraSlotsPurchased += 1
		remotes.SparksUpdated:FireClient(player, profile.sparks)
		HatchLogic.SyncSlotAttributes(player)
		AnalyticsService.LogSlotPurchase(player, cost, profile.sparks)
		return true
	end
	return false
end

return HatchLogic
