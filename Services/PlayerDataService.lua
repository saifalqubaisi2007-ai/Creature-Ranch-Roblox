--[[
	PlayerDataService.lua
	Session-locked DataStore persistence for CREATURE RANCH.
	Handles: Sparks balance, owned Critters, extra slots purchased.
	Pattern: in-memory session cache + UpdateAsync w/ session lock, retry with backoff,
	autosave loop, BindToClose flush. Server-authoritative — clients never write directly.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")
local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local AnalyticsService = require(script.Parent.AnalyticsService)
local remotes = RS.CritterRush.Remotes

local STORE_NAME = "SAC_PlayerData_v1"
local AUTOSAVE_INTERVAL = 120
local MAX_RETRIES = 5

local dataStore
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		dataStore = result
	else
		warn("[PlayerDataService] DataStores unavailable (place not published / API access off). " ..
			"Running in-memory only - progress will NOT persist. Enable 'Studio Access to API Services' " ..
			"in Game Settings > Security, and publish the place, for real saving.")
	end
end
local sessionId = HttpService:GenerateGUID(false)

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

local profiles = {} -- [userId] = profileTable

local function defaultData()
	return {
		sparks = 0,
		ownedCritters = {}, -- array of { rarity, species, uid, sparksPerSecond }
		extraSlotsPurchased = 0,
		createdAt = os.time(),
		-- Daily login system (Phase 6)
		lastLoginDay = 0, -- os.time() // 86400 of the last rewarded login
		loginStreak = 0,
		-- Collection book (Phase 7): [speciesName] = "seen" | "owned"
		collection = {},
		-- Quest system: current single active quest, plus lifetime orb counter
		activeQuest = nil,
		orbsCollectedTotal = 0,
		-- Rebirth: how many times reset, applies a permanent income multiplier
		rebirths = 0,
		-- Collection milestones already claimed (by count), prevents re-granting
		claimedMilestones = {},
		-- Progression (P8): total lifetime XP. Level is ALWAYS derived from this (never
		-- stored separately) so there's exactly one source of truth and no way for a
		-- stored level to drift out of sync with its xp.
		xp = 0,
		-- Achievements (P8): lifetime counters some achievements check against, plus the
		-- claimed-set guard (same pattern as claimedMilestones). hatchesTotal counts EVERY
		-- critter gain (starter, paid hatch, rebirth starter) -- getting your very first
		-- starter critter IS your "first hatch" narratively, the game presents it as one.
		hatchesTotal = 0,
		hasOwnedShiny = false,
		claimedAchievements = {},
		-- Multi-world progression: which worlds beyond the free starting one this player
		-- has unlocked. StarterMeadow itself is never stored here -- WorldService treats
		-- it as always-unlocked by definition, so this table only ever grows from empty.
		unlockedWorlds = {},
		-- Ancient Tree hidden chest: one-time discovery reward, same sticky-flag pattern
		-- as hasOwnedShiny -- prevents re-opening for a reward on every visit.
		hasOpenedTreeChest = false,
		-- Elder Mossbeard's daily gift: DELIBERATELY separate from lastLoginDay's automatic
		-- reward -- this one only grants if the player actually walks to the tree and talks
		-- to him, so it's a genuine "give players a reason to revisit this specific place"
		-- mechanic, not a duplicate of the login bonus.
		lastElderGiftDay = 0,
		-- Daily Quest: a SEPARATE, bigger-reward quest slot from the always-on activeQuest,
		-- resetting once per real day. dailyQuest holds the current roll (nil until first
		-- assigned); lastDailyQuestDay tracks which day it was rolled for, same day-index
		-- pattern as lastElderGiftDay/lastLoginDay.
		dailyQuest = nil,
		lastDailyQuestDay = 0,
		-- Cosmetic Trails: a real Sparks sink with player choice, separate from earned
		-- progression titles. ownedTrails is a set (id -> true); equippedTrail is a single
		-- id or nil (no trail).
		ownedTrails = {},
		equippedTrail = nil,
		-- Offline earnings: real os.time() timestamp of the player's last save. On rejoin,
		-- elapsed time * their income rate becomes a claimable payout. Stored as an
		-- absolute timestamp (not a duration) so it survives an unclean disconnect --
		-- a crashed server still leaves a valid "last seen" marker from the autosave loop.
		lastSeenAt = 0,
		-- Free Limited Egg hatches, granted by the Day 7 login streak reward. Stored as a
		-- count rather than a boolean so multiple weeks of streaks stack rather than
		-- silently overwriting each other.
		limitedEggTokens = 0,
		-- Lifetime fusion counter, for the Next Goal ladder. Incremented in FuseCritters.
		fusionsTotal = 0,
		-- PAID hatches only, for the onboarding rig. Deliberately separate from
		-- hatchesTotal, which also counts the free starter and rebirth grants -- rigging
		-- should key off what the player actually chose to buy, not gifts.
		paidHatchesTotal = 0,
		-- True until the player finishes their first session. Gates the first-session
		-- guidance beats so a returning player is never re-tutorialised.
		firstSessionDone = false,
		-- Starter Pack: firstJoinAt anchors the 24h offer window (set once, on first ever
		-- join). starterPackBought makes it one-time-only. Both persist, so the window is
		-- real wall-clock time rather than resetting every session.
		firstJoinAt = 0,
		starterPackBought = false,
		-- VIP daily bonus: separate day-stamp from the login streak so a VIP who already
		-- claimed their streak today still receives the VIP payout.
		lastVipRewardDay = 0,
		-- Active potions: [potionId] = expiry os.time(). Absolute timestamps so a potion
		-- keeps burning while offline and its remaining time survives a rejoin without a
		-- persistence tick loop.
		activePotions = {},
		-- Tiered achievements: [chainId] = highest tier CLAIMED. Stored as a single number
		-- per chain rather than a set of claimed ids, so an endless chain can't grow the
		-- save file without bound.
		achievementTiers = {},
		-- Ranch Likes: a persistent count of likes received, plus who has already liked
		-- this ranch. Storing the liker set (rather than just a total) is what makes the
		-- one-like-per-player rule survive a rejoin -- a bare counter could be farmed by
		-- leaving and returning.
		ranchLikes = 0,
		ranchLikedBy = {},
		-- Weekly leaderboard: Sparks earned during the CURRENT week, plus which week that
		-- figure belongs to. Storing the week index alongside the total is what makes the
		-- reset automatic -- on the first login of a new week the total is simply zeroed,
		-- with no scheduled job needed.
		weeklySparks = 0,
		weeklySparksWeek = 0,
		lastWeeklyRewardWeek = 0,
		-- Seasonal leaderboard: rebirths completed this season, plus which season that
		-- figure belongs to. Same lazy-reset pattern as the weekly board.
		seasonRebirths = 0,
		seasonRebirthsSeason = 0,
		lastSeasonRewardSeason = 0,
		-- Gifting: how many gifts sent today, and which day that count belongs to. Same
		-- lazy day-stamp reset as the login streak, so no scheduled job is needed.
		giftsSentToday = 0,
		giftsSentDay = 0,
		-- Ranch decorations the player owns, keyed by decoration id. Owning is separate
		-- from placement so a future "move things around" feature doesn't need a data
		-- migration -- the slot is stored per-decoration rather than as a separate map.
		ownedDecorations = {},
		-- Owned but unused potions: [potionId] = count.
		potionInventory = {},
		-- Permanent luck earned from level rewards, as an additive fraction (0.05 = +5%).
		-- Kept separate from pass/potion/rebirth luck so each source stays independently
		-- auditable rather than being folded into one opaque number.
		levelLuckBonus = 0,
		-- Creature Sanctuary: array of critter uids assigned to live at the ranch.
		-- Stored as uids (not copies) so a sanctuary creature is still the SAME record
		-- in ownedCritters -- it can be un-assigned, fused, or traded without any
		-- duplication risk.
		sanctuaryUids = {},
		-- Uids of creatures currently EARNING Sparks. Everything else is stored.
		-- Stored as uids (not copies) so an equipped creature is the same record in
		-- ownedCritters and can be fused, traded or gifted with no duplication risk --
		-- same pattern as sanctuaryUids.
		equippedUids = {},
		-- Redeemed promo codes (set: CODE -> true).
		redeemedCodes = {},
		-- Per-world relic counts: [worldId] = count.
		relicCounts = {},
		-- Ranch Happiness, raised by visitors feeding your sanctuary creatures and
		-- decayed daily so it reflects CURRENT social activity rather than a one-time
		-- peak. Multiplies Ranch Power.
		ranchHappiness = 0,
		lastHappinessDecayDay = 0,
		-- [visitorUserId] = day index, so each visitor can only feed once per day.
		fedBy = {},
		-- Active potions: [potionId] = absolute os.time() expiry. Stored as absolute
		-- timestamps rather than remaining-duration so a potion keeps ticking while the
		-- player is offline -- a 10-minute boost that pauses on logout would be exploitable
		-- (buy one, log off, keep it forever).
		activePotions = {},
		-- Onboarding beats already shown, so a returning player never re-sees them.
		onboardingSeen = {},
		-- Next Goal ladder progress: index into Constants.NEXT_GOAL_LADDER. Advances
		-- permanently as goals complete, so a completed goal never reappears.
		nextGoalIndex = 1,
		-- Income rate snapshotted at save time. Offline earnings CANNOT recompute this on
		-- rejoin from ownedCritters alone, because rebirth/gamepass/event multipliers all
		-- feed the live rate -- snapshotting the real effective rate is the only way the
		-- payout matches what the player was actually earning when they left.
		lastIncomeRate = 0,
		-- Daily Shop (item #16): a rotating deal that resets once per real day, same
		-- day-index pattern as lastElderGiftDay/lastDailyQuestDay. dailyShopOffer holds
		-- { type = "trail"|"sparksBonus", trailId, discountedCost, claimed }.
		dailyShopOffer = nil,
		lastDailyShopDay = 0,
		-- Level Rewards (item #5): claimedLevelRewards prevents re-granting the same
		-- reward if a player's level fluctuates (e.g. dips after a rebirth reset, then
		-- climbs back past a threshold already paid out). hasAura is a separate flag
		-- (not just "level >= 25") so the aura persists correctly through a rebirth reset
		-- even though level itself is derived from xp and could theoretically drop.
		claimedLevelRewards = {},
		hasAura = false,
		_session = sessionId,
	}
 end

-- Backfill any fields added after a profile was first created, so old saves
-- never nil-error against new systems. Also de-duplicates ownedCritters by uid,
-- healing any profile corrupted by a prior double-add (defense in depth alongside
-- the guard in AddOwnedCritter).
local function reconcile(profile)
	local defaults = defaultData()
	for key, value in pairs(defaults) do
		if profile[key] == nil then
			profile[key] = value
		end
	end

	if profile.ownedCritters then
		local seen = {}
		local deduped = {}
		for _, entry in ipairs(profile.ownedCritters) do
			if not seen[entry.uid] then
				seen[entry.uid] = true
				-- Multi-world migration: any critter saved before this system existed is,
				-- by definition, from the only world that existed then.
				entry.worldId = entry.worldId or WorldsData.DEFAULT_WORLD_ID
				-- Personality migration: any critter saved before this system existed gets ONE
				-- random personality rolled right here, right now -- and because this happens
				-- during reconcile (which runs once per load, on the same persistent profile
				-- table), that roll is exactly as permanent as one rolled at hatch time. An old
				-- creature doesn't get a NEW personality every time it respawns after this --
				-- it gets one once, here, and keeps it forever after, same as a creature
				-- hatched natively with this system already in place.
				entry.personality = entry.personality or Constants.PERSONALITY_IDS[math.random(1, #Constants.PERSONALITY_IDS)]
				table.insert(deduped, entry)
			end
		end
		profile.ownedCritters = deduped
	end

	return profile
end

local function withRetry(fn)
	local attempt = 0
	while attempt < MAX_RETRIES do
		attempt += 1
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(string.format("[PlayerDataService] attempt %d failed: %s", attempt, tostring(result)))
		task.wait(attempt * 0.75) -- backoff
	end
	return false, nil
end

function PlayerDataService.Load(player)
	if not dataStore then
		local loaded = reconcile(defaultData())
		profiles[player.UserId] = loaded
		return loaded
	end

	local key = "Player_" .. player.UserId
	local loaded
	local lastErr

	-- Session-lock-aware retry, NOT the generic withRetry helper. A lock is only
	-- genuinely stale after 30s (the staleness check inside the transform below), but
	-- withRetry's backoff gives up after ~11.25s total -- meaning a normal quick
	-- server-hop or rapid reconnect, landing on this server BEFORE the old server's
	-- disconnect-triggered Release() save has actually finished, would previously fall
	-- through to a brand-new DEFAULT PROFILE instead of waiting for the legitimate
	-- unlock -- silently discarding the player's real progress for the session, and
	-- risking PERMANENT loss if that session later autosaves over the real data. FOUND
	-- while writing the multiplayer test plan's "server hopping" section, by tracing the
	-- exact retry math against the lock's own staleness window rather than trusting the
	-- summary already written about it -- the numbers didn't line up.
	local deadline = os.clock() + 34 -- safely past the 30s staleness window
	local attempt = 0
	local ok = false
	while os.clock() < deadline do
		attempt += 1
		local success, result = pcall(function()
			dataStore:UpdateAsync(key, function(old)
				if old == nil then
					loaded = defaultData()
					return loaded
				end
				-- session lock: refuse to load if another server claims it and is recent
				if old._session and old._session ~= sessionId and old._lockTime and (os.time() - old._lockTime) < 30 then
					error("DataLockedByAnotherServer")
				end
				old._session = sessionId
				old._lockTime = os.time()
				loaded = old
				return old
			end)
		end)
		if success then
			ok = true
			break
		end
		lastErr = result
		warn(string.format("[PlayerDataService] load attempt %d failed for %s: %s", attempt, player.Name, tostring(result)))
		-- Lock errors: keep retrying at a steady pace all the way to the deadline -- the
		-- lock WILL clear, either because the old server's Release() finally lands or
		-- because it naturally goes stale at the 30s mark. Any OTHER error (a real
		-- DataStore hiccup, unrelated to locking): don't hammer the API for an unrelated
		-- outage -- fall back after the usual handful of attempts instead, same as before.
		if tostring(result):find("DataLockedByAnotherServer") then
			task.wait(2)
		elseif attempt >= MAX_RETRIES then
			break
		else
			task.wait(attempt * 0.75)
		end
	end

	if not ok or not loaded then
		warn("[PlayerDataService] Failed to load data for", player.Name,
			"- using session-only fallback. Last error:", tostring(lastErr))
		loaded = defaultData()
	end

	reconcile(loaded)
	profiles[player.UserId] = loaded
	return loaded
end

function PlayerDataService.Get(player)
	return profiles[player.UserId]
end

function PlayerDataService.Save(player, releaseLock)
	local profile = profiles[player.UserId]
	if not profile then return end
	if not dataStore then return end
	local key = "Player_" .. player.UserId

	-- Offline-earnings snapshot. Written on EVERY save (autosave loop + leave + shutdown),
	-- not just on leave, so an unclean disconnect or server crash still leaves a recent,
	-- valid marker rather than a stale one from session start.
	profile.lastSeenAt = os.time()
	profile.lastIncomeRate = PlayerDataService.ComputeIncomeRate(player, profile)

	withRetry(function()
		dataStore:UpdateAsync(key, function(old)
			if old and old._session and old._session ~= sessionId then
				-- another server has taken ownership since; don't clobber
				error("LostSessionLock")
			end
			profile._lockTime = releaseLock and nil or os.time()
			if releaseLock then
				profile._session = nil
			end
			return profile
		end)
	end)
end

function PlayerDataService.Release(player)
	PlayerDataService.Save(player, true)
	profiles[player.UserId] = nil
end

-- ===== Mutators (server-only entry points; called by other services after validation) =====

function PlayerDataService.AddSparks(player, amount)
	local profile = profiles[player.UserId]
	if not profile then return 0 end
	profile.sparks = math.max(0, profile.sparks + amount)

	-- Weekly leaderboard accrual. Hooked here because AddSparks is the single point all
	-- income flows through -- passive ticks, orbs, quests, rewards, everything. Only
	-- GAINS count, so spending doesn't reduce a weekly score (the board measures activity,
	-- not hoarding).
	if amount > 0 then
		local week = Constants.GetWeekIndex()
		if profile.weeklySparksWeek ~= week then
			-- First gain of a new week: reset. No scheduled job needed -- the reset
			-- happens lazily the moment it becomes relevant.
			profile.weeklySparksWeek = week
			profile.weeklySparks = 0
		end
		profile.weeklySparks = (profile.weeklySparks or 0) + amount
	end

	return profile.sparks
end

function PlayerDataService.TrySpendSparks(player, amount)
	local profile = profiles[player.UserId]
	if not profile then return false end
	if profile.sparks < amount then return false end
	profile.sparks -= amount
	return true
end

-- Returns (level, xpIntoLevel, xpNeededForLevel) for a given total xp. Pure function,
-- no profile mutation -- level is always DERIVED, never stored, so it can never drift
-- out of sync with the xp it's computed from.
local function levelForXP(xp)
	local level = 1
	local remaining = xp
	for _ = 1, 500 do -- defensive iteration cap; real play never gets close to this
		local needed = Constants.XP_PER_LEVEL_BASE + (level - 1) * Constants.XP_PER_LEVEL_GROWTH
		if remaining < needed then
			return level, remaining, needed
		end
		remaining -= needed
		level += 1
	end
	return level, remaining, Constants.XP_PER_LEVEL_BASE + (level - 1) * Constants.XP_PER_LEVEL_GROWTH
end

-- Grants any Level Rewards the player has just newly qualified for. Safe to call
-- directly from inside AddXP (unlike CheckAchievements, called externally to avoid
-- recursion) because none of these reward types grant XP themselves -- trail/
-- sparksBonus/aura, zero risk of AddXP calling itself.
local function checkLevelRewards(player, profile, newLevel)
	for _, reward in ipairs(Constants.LEVEL_REWARDS) do
		if newLevel >= reward.level and not profile.claimedLevelRewards[reward.level] then
			profile.claimedLevelRewards[reward.level] = true
			if reward.type == "trail" then
				profile.ownedTrails[reward.trailId] = true
			elseif reward.type == "sparksBonus" then
				profile.sparks += reward.amount
				-- Direct mutation above (not AddSparks) to avoid re-entering the Sparks
				-- pipeline mid-XP-grant -- but that means the client needs its own explicit
				-- notification here, since none of AddXP's existing callers expect a Sparks
				-- change as a side effect of leveling up.
				remotes.SparksUpdated:FireClient(player, profile.sparks)
			elseif reward.type == "aura" then
				profile.hasAura = true
			elseif reward.type == "luck" then
				-- Additive permanent luck. Mirrored onto an attribute so the roll paths
				-- (which read attributes, not the profile) actually see it -- without this
				-- the reward would be stored and silently never applied.
				profile.levelLuckBonus = (profile.levelLuckBonus or 0) + (reward.amount or 0)
				player:SetAttribute("SAC_LevelLuckBonus", profile.levelLuckBonus)
			elseif reward.type == "slot" then
				profile.extraSlotsPurchased = (profile.extraSlotsPurchased or 0) + (reward.amount or 1)
				-- Mirror the new cap onto attributes the HUD reads. Done inline rather than
				-- via HatchLogic.SyncSlotAttributes because PlayerDataService can't require
				-- HatchLogic (HatchLogic already requires this module).
				player:SetAttribute("SAC_UsedSlots", #profile.ownedCritters)
				player:SetAttribute("SAC_MaxSlots", PlayerDataService.GetMaxSlots(player, profile))
			elseif reward.type == "limitedEgg" then
				profile.limitedEggTokens = (profile.limitedEggTokens or 0) + (reward.amount or 1)
			elseif reward.type == "potion" then
				-- Grant as active time directly. PotionService owns the buy path, but a
				-- level reward isn't a purchase -- writing the expiry here keeps this module
				-- from depending on PotionService just to hand out one free potion.
				local potion = Constants.POTIONS[reward.potionId]
				if potion then
					profile.activePotions = profile.activePotions or {}
					local now = os.time()
					local current = profile.activePotions[potion.id]
					local base = (current and current > now) and current or now
					profile.activePotions[potion.id] = base + potion.durationSeconds
					player:SetAttribute(potion.attribute, potion.multiplier)
				end
			end
			remotes.LevelRewardGranted:FireClient(player, reward.level, reward.label, reward.type)
		end
	end
end

-- Awards XP for a discrete action. Returns (newXP, level, xpIntoLevel, xpNeededForLevel,
-- leveledUp). Callers that care about celebrating a level-up check the 5th return value
-- rather than re-deriving it themselves, so the "did we cross a level boundary" logic
-- lives in exactly one place.
function PlayerDataService.AddXP(player, amount)
	local profile = profiles[player.UserId]
	if not profile or amount <= 0 then
		local lvl, into, needed = levelForXP(profile and profile.xp or 0)
		return profile and profile.xp or 0, lvl, into, needed, false
	end
	-- Double XP world event: straight multiplier applied HERE, the single choke point
	-- every XP-granting call site already funnels through (hatch/grab/reclaim/orbs/quest
	-- completion/collection milestone/rebirth) -- same decoupled workspace-attribute
	-- pattern as every other world event, but applied once instead of repeated at each
	-- of those 7 call sites.
	local eventMult = workspace:GetAttribute("SAC_EventXPMultiplier") or 1
	-- Permanent Rebirth XP multiplier (item #6): stacks multiplicatively with the
	-- temporary Double XP event, same choke point, same pattern as the permanent luck
	-- multiplier already stacking with Lucky Hour in CritterService.
	local rebirthCount = player:GetAttribute("SAC_RebirthCount") or 0
	local rebirthTier = Constants.GetRebirthTier(rebirthCount)
	local rebirthXpMult = (rebirthTier and rebirthTier.xpMultBonus) or 1
	amount = math.floor(amount * eventMult * rebirthXpMult)
	local oldLevel = levelForXP(profile.xp)
	profile.xp += amount
	local newLevel, xpIntoLevel, xpNeeded = levelForXP(profile.xp)
	-- Bridging attribute (same decoupled pattern as SAC_RebirthCount) so the title-tag
	-- display in Main.lua can live-update on every level change without cross-requiring
	-- this module or waiting for a character respawn.
	player:SetAttribute("SAC_Level", newLevel)
	if newLevel > oldLevel then
		checkLevelRewards(player, profile, newLevel)
	end
	return profile.xp, newLevel, xpIntoLevel, xpNeeded, newLevel > oldLevel
end

function PlayerDataService.GetLevel(player)
	local profile = profiles[player.UserId]
	if not profile then return 1, 0, Constants.XP_PER_LEVEL_BASE end
	return levelForXP(profile.xp)
end

-- Call once on player join so SAC_Level has a correct value immediately, mirroring
-- RebirthService.SyncAttribute's role for SAC_RebirthCount.
function PlayerDataService.SyncLevelAttribute(player)
	local level = PlayerDataService.GetLevel(player)
	player:SetAttribute("SAC_Level", level)
end

function PlayerDataService.AddOwnedCritter(player, critterRecord)
	local profile = profiles[player.UserId]
	if not profile then return end
	-- Guard against duplicate entries: never insert a uid that's already present.
	-- (Protects against any double-call from a caller, and the exact symptom seen
	-- in testing — identical uid appearing twice in a saved profile.)
	for _, existing in ipairs(profile.ownedCritters) do
		if existing.uid == critterRecord.uid then return end
	end
	-- Inventory flags default here (not at every individual call site) so every
	-- existing AddOwnedCritter caller gets them for free, no other file needs to change.
	if critterRecord.favorite == nil then critterRecord.favorite = false end
	if critterRecord.locked == nil then critterRecord.locked = false end
	if critterRecord.hatchedAt == nil then critterRecord.hatchedAt = os.time() end
	-- Fusion variant tier. Defaults here (not at each call site) so every existing
	-- AddOwnedCritter caller gets it for free and old saves backfill correctly.
	if critterRecord.variant == nil then critterRecord.variant = "Normal" end
	table.insert(profile.ownedCritters, critterRecord)
	-- Achievement counters: single choke point every critter-gain path already calls
	-- through (paid hatch, free starter, post-rebirth starter), so these need no
	-- additional call sites anywhere else. hasOwnedShiny is sticky -- once true, always
	-- true, even if the shiny critter is later replaced or lost to a rebirth wipe.
	profile.hatchesTotal = (profile.hatchesTotal or 0) + 1
	if critterRecord.isShiny then
		profile.hasOwnedShiny = true
	end
end

function PlayerDataService.RemoveOwnedCritter(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return end
	for i, rec in ipairs(profile.ownedCritters) do
		if rec.uid == uid then
			table.remove(profile.ownedCritters, i)
			return true
		end
	end
	return false
end

-- Toggles the favorite flag on an owned critter. Purely cosmetic/organizational --
-- unlike locked below, favoriting never affects eviction. Returns the NEW state, or
-- nil if the uid wasn't found.
function PlayerDataService.ToggleFavorite(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return nil end
	for _, rec in ipairs(profile.ownedCritters) do
		if rec.uid == uid then
			rec.favorite = not rec.favorite
			return rec.favorite
		end
	end
	return nil
end

-- Toggles the locked flag on an owned critter. A locked critter is EXEMPT from the
-- at-cap auto-eviction in HatchLogic (see FindEvictionTarget below) -- the real,
-- functional answer to "don't treat creatures as disposable": you now have a genuine
-- way to protect a specific critter from ever being silently replaced, without
-- changing the underlying slot economy. Returns the NEW state, or nil if not found.
function PlayerDataService.ToggleLock(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return nil end
	for _, rec in ipairs(profile.ownedCritters) do
		if rec.uid == uid then
			rec.locked = not rec.locked
			return rec.locked
		end
	end
	return nil
end

-- Finds the critter HatchLogic should evict when at cap: the OLDEST (first in
-- insertion-ordered ownedCritters) critter that ISN'T locked. Returns nil if every
-- owned critter is locked (caller must handle this -- hatching should fail cleanly
-- with a clear message, not silently do something wrong).
-- Picks which critter gets replaced when hatching at the slot cap.
--
-- Previously this returned the FIRST unlocked record in array order -- i.e. the oldest.
-- That meant a player at capacity who hatched a Common could lose a Mythic they'd spent
-- hours getting, purely because it happened to be earlier in the list. Losing your best
-- creature to a worse one is the single most punishing thing an idle game can do, and
-- it happened silently.
--
-- Now evicts the WEAKEST unlocked critter by income, which is the value the player
-- actually feels. Ties break toward the older record so behaviour stays deterministic.
-- Sanctuary-assigned creatures are protected too: housing one is a deliberate choice,
-- and having it evicted by an unrelated hatch would undo that silently.
function PlayerDataService.FindEvictionTarget(player)
	local profile = profiles[player.UserId]
	if not profile then return nil end

	local housed = {}
	for _, uid in ipairs(profile.sanctuaryUids or {}) do housed[uid] = true end

	local worst, worstIncome
	for _, rec in ipairs(profile.ownedCritters) do
		if not rec.locked and not housed[rec.uid] then
			local income = rec.sparksPerSecond or 0
			if worstIncome == nil or income < worstIncome then
				worst, worstIncome = rec, income
			end
		end
	end
	-- Fall back to ignoring sanctuary protection only if EVERY unlocked critter is
	-- housed -- otherwise a full sanctuary would make hatching fail outright.
	if not worst then
		for _, rec in ipairs(profile.ownedCritters) do
			if not rec.locked then
				local income = rec.sparksPerSecond or 0
				if worstIncome == nil or income < worstIncome then
					worst, worstIncome = rec, income
				end
			end
		end
	end
	return worst
end

function PlayerDataService.MarkCollection(player, species, status)
	-- status: "seen" or "owned"; "owned" always wins over "seen"
	local profile = profiles[player.UserId]
	if not profile then return end
	if profile.collection[species] == "owned" then return end
	profile.collection[species] = status
end

-- Returns the newly-claimed milestone reward amount, or nil if none was crossed.
-- Also returns XP info (newXP, level, xpIntoLevel, xpNeeded, leveledUp) alongside the
-- Sparks reward, same "mutate here, caller fires the remotes" pattern already used for
-- the Sparks half of this function.
-- Call after MarkCollection whenever a species flips to "owned".
function PlayerDataService.CheckCollectionMilestone(player)
	local profile = profiles[player.UserId]
	if not profile then return nil end

	local ownedCount = 0
	for _, status in pairs(profile.collection) do
		if status == "owned" then ownedCount += 1 end
	end

	for _, milestone in ipairs(Constants.COLLECTION_MILESTONES) do
		if ownedCount >= milestone.count and not profile.claimedMilestones[tostring(milestone.count)] then
			profile.claimedMilestones[tostring(milestone.count)] = true
			profile.sparks += milestone.reward
			local bonusXP = Constants.XP_REWARDS.collectionMilestone
			local newXP, level, xpIntoLevel, xpNeeded, leveledUp
			if bonusXP and bonusXP > 0 then
				newXP, level, xpIntoLevel, xpNeeded, leveledUp = PlayerDataService.AddXP(player, bonusXP)
			end
			return milestone.reward, milestone.count, newXP, level, xpIntoLevel, xpNeeded, leveledUp
		end
	end
	return nil
end

-- Shared by CheckAchievements (server-only, mutates/grants) and GetAchievementsState
-- (read-only, for the client panel) so the two never drift out of sync on what counts
-- toward each stat.
local function computeAchievementStats(profile)
	local ownedCount = 0
	for _, status in pairs(profile.collection) do
		if status == "owned" then ownedCount += 1 end
	end
	local level = levelForXP(profile.xp)
	-- totalIncome / volcanoUnlocked: added for Long-Term Goals (item #11), computed here
	-- rather than a separate function so both Achievements and Goals stay guaranteed
	-- consistent on every OTHER shared stat, with zero duplicated derivation logic.
	local totalIncome = 0
	for _, rec in ipairs(profile.ownedCritters) do
		totalIncome += rec.sparksPerSecond or 0
	end
	return {
		hatchesTotal = profile.hatchesTotal or 0,
		orbsCollectedTotal = profile.orbsCollectedTotal or 0,
		rebirths = profile.rebirths or 0,
		collectionOwnedCount = ownedCount,
		level = level,
		hasOwnedShiny = profile.hasOwnedShiny and 1 or 0,
		totalIncome = totalIncome,
		volcanoUnlocked = (profile.unlockedWorlds and profile.unlockedWorlds["Volcano"]) and 1 or 0,
		-- Next Goal ladder keys. worldsUnlocked counts beyond the always-free starter
		-- world, so "unlock the Forest" is 1 rather than 2.
		worldsUnlocked = (function()
			local n = 0
			for _ in pairs(profile.unlockedWorlds or {}) do n += 1 end
			return n
		end)(),
		fusionsTotal = profile.fusionsTotal or 0,
	}
end

-- Checks all achievements against current profile stats and claims any newly-qualified
-- ones. Returns an array of { id, title, reward } for whatever was newly unlocked this
-- call (empty if nothing new). Grants BOTH Sparks and XP per unlock -- safe to call
-- AddXP here because this function is called FROM QuestService.ReportProgress and
-- RebirthService.PerformRebirth, never from inside AddXP itself, so there is no
-- recursion risk (AddXP -> CheckAchievements -> AddXP would be a real re-entrancy bug
-- if this were hooked the other way around -- deliberately avoided).
function PlayerDataService.CheckAchievements(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end

	local stats = computeAchievementStats(profile)

	local unlocked = {}
	for _, ach in ipairs(Constants.ACHIEVEMENTS) do
		if not profile.claimedAchievements[ach.id] and (stats[ach.statKey] or 0) >= ach.threshold then
			profile.claimedAchievements[ach.id] = true
			profile.sparks += ach.reward
			PlayerDataService.AddXP(player, ach.reward // 5) -- modest XP bonus alongside Sparks
			table.insert(unlocked, { id = ach.id, title = ach.title, reward = ach.reward })
		end
	end
	return unlocked
end

-- Read-only snapshot for the client's Achievements panel: every achievement with its
-- unlocked status and current progress toward the threshold. Never mutates anything
-- (unlike CheckAchievements) -- safe to call as often as the panel wants to refresh.
function PlayerDataService.GetAchievementsState(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end

	local stats = computeAchievementStats(profile)
	local result = {}
	for _, ach in ipairs(Constants.ACHIEVEMENTS) do
		table.insert(result, {
			id = ach.id,
			title = ach.title,
			desc = ach.desc,
			reward = ach.reward,
			unlocked = profile.claimedAchievements[ach.id] == true,
			current = math.min(stats[ach.statKey] or 0, ach.threshold),
			threshold = ach.threshold,
		})
	end
	return result
end

-- Read-only snapshot for the client's Goals panel (item #11): every long-term goal with
-- its current progress and completion state. Purely derived from computeAchievementStats
-- (no separate claim/reward mechanic like Achievements -- these are reference targets to
-- work toward, not one-time payouts, so "completed" is just current >= threshold).
function PlayerDataService.GetGoalsState(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end

	local stats = computeAchievementStats(profile)
	local result = {}
	for _, goal in ipairs(Constants.LONG_TERM_GOALS) do
		local current = math.min(stats[goal.statKey] or 0, goal.threshold)
		table.insert(result, {
			id = goal.id,
			title = goal.title,
			current = current,
			threshold = goal.threshold,
			completed = current >= goal.threshold,
		})
	end
	return result
end

-- Attempts to buy trailId for player. Returns (true) on success, (false, reason) on
-- failure -- reason is one of "UnknownTrail", "AlreadyOwned", "InsufficientSparks".
-- Purchasing immediately equips the trail (no separate equip step needed for a fresh
-- buy), matching the "one clear action" simplicity of every other purchase in this game.
function PlayerDataService.PurchaseTrail(player, trailId)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	local trail = nil
	for _, t in ipairs(Constants.COSMETIC_TRAILS) do
		if t.id == trailId then trail = t break end
	end
	if not trail then return false, "UnknownTrail" end
	if profile.ownedTrails[trailId] then return false, "AlreadyOwned" end
	if not PlayerDataService.TrySpendSparks(player, trail.cost) then return false, "InsufficientSparks" end
	profile.ownedTrails[trailId] = true
	profile.equippedTrail = trailId
	AnalyticsService.LogTrailPurchase(player, trail.cost, profile.sparks, trailId)
	return true
end

-- Switches the currently-equipped trail to an ALREADY-OWNED one, or clears it (pass
-- nil) -- free and instant, since the Sparks cost was already paid at purchase time.
-- Returns (true) on success, (false, reason) on failure -- reason is "NotOwned" (the
-- only way this can fail, since equipping nothing is always valid).
function PlayerDataService.EquipTrail(player, trailId)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	if trailId ~= nil and not profile.ownedTrails[trailId] then return false, "NotOwned" end
	profile.equippedTrail = trailId
	return true
end

-- Read-only snapshot for the client's Shop panel: every trail with its owned/equipped
-- state, so the UI can show "Buy" / "Equip" / "Equipped" correctly without the client
-- needing to track purchase state itself.
function PlayerDataService.GetTrailsState(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end
	local result = {}
	for _, t in ipairs(Constants.COSMETIC_TRAILS) do
		table.insert(result, {
			id = t.id, name = t.name, cost = t.cost,
			owned = profile.ownedTrails[t.id] == true,
			equipped = profile.equippedTrail == t.id,
		})
	end
	return result
end

-- Read-only snapshot for the client's Inventory panel: every owned critter plus
-- summary stats (total count, total income/sec, best critter). Sorting happens
-- client-side (cheap, and lets the player re-sort without a round trip) -- this just
-- returns the raw list in the same insertion order ownedCritters already keeps
-- (oldest first), which the client uses directly for the "Newest" sort.
-- Computes the player's CURRENT effective Sparks/sec, mirroring the live per-heartbeat
-- calculation in CritterService exactly (base rate x DoubleSparks gamepass x permanent
-- rebirth multiplier).
--
-- DELIBERATELY EXCLUDES the temporary SAC_EventDoubleSparks world event: that's a
-- short, live-only buff, and letting it multiply many HOURS of offline time would pay
-- out enormously more than the player would ever have earned actually playing. Offline
-- earnings should reflect steady-state income, not a lucky snapshot moment.
function PlayerDataService.ComputeIncomeRate(player, profile)
	profile = profile or profiles[player.UserId]
	if not profile then return 0 end
	-- Only EQUIPPED creatures contribute. Must mirror CritterService's income loop
	-- exactly, or offline earnings and the rebirth projection would both promise income
	-- from creatures that aren't actually earning.
	local equippedSet = {}
	for _, uid in ipairs(profile.equippedUids or {}) do equippedSet[uid] = true end
	local base = 0
	for _, rec in ipairs(profile.ownedCritters) do
		if equippedSet[rec.uid] then
			base += rec.sparksPerSecond or 0
		end
	end
	local mult = player:GetAttribute("SAC_DoubleSparks") and 2 or 1
	local rebirthMult = player:GetAttribute("SAC_RebirthMultiplier")
	if rebirthMult then mult *= rebirthMult end
	-- VIP must be mirrored here too, or offline earnings and the rebirth projection
	-- would both understate what a VIP player actually earns.
	if player:GetAttribute("SAC_VIP") then
		mult *= Constants.VIP_INCOME_MULTIPLIER
	end
	-- Collection completion bonuses ARE included here (unlike potions/events): they're
	-- permanent, so they genuinely describe the player's steady-state earning rate.
	local collBonus = player:GetAttribute("SAC_CollectionIncomeBonus")
	if collBonus then mult *= (1 + collBonus) end
	-- Friend proximity bonus is EXCLUDED for the same reason as potions below: it only
	-- holds while friends are actually standing nearby, so baking it into an 8-hour
	-- offline snapshot would pay for a condition that ended the moment they logged off.
	-- Sparks Potions are deliberately EXCLUDED here, for the same reason the Double
	-- Sparks world event is: this rate is snapshotted for offline earnings, and letting
	-- a 10-minute potion multiply 8 hours of offline time would pay out far more than
	-- the player could ever have earned actually playing.
	return base * mult
end

-- Calculates (but does NOT grant) offline earnings for a returning player. Returns
-- (amount, secondsAway) or (0, 0) if there's nothing to claim. Caller grants and
-- notifies -- same "compute here, caller fires the remotes" split used elsewhere.
function PlayerDataService.ComputeOfflineEarnings(player)
	local profile = profiles[player.UserId]
	if not profile then return 0, 0 end
	local lastSeen = profile.lastSeenAt or 0
	if lastSeen <= 0 then return 0, 0 end -- brand-new player, or pre-feature save

	local now = os.time()
	local elapsed = now - lastSeen
	-- Guard against a negative delta from clock skew between servers.
	if elapsed <= 0 then return 0, 0 end
	if elapsed < Constants.OFFLINE_MIN_SECONDS then return 0, 0 end

	local capped = math.min(elapsed, Constants.OFFLINE_MAX_SECONDS)
	local rate = profile.lastIncomeRate or 0
	if rate <= 0 then return 0, elapsed end

	-- 2x Offline Earnings gamepass raises the offline rate from 0.5x to the full 1.0x.
	-- Expressed as a doubling of the multiplier rather than a flat override, so if the
	-- base rate is ever retuned the pass keeps its stated "double" meaning.
	local offlineMult = Constants.OFFLINE_RATE_MULTIPLIER
	if player:GetAttribute("SAC_OfflinePass") then offlineMult *= 2 end
	local amount = math.floor(rate * capped * offlineMult)
	if amount <= 0 then return 0, elapsed end
	return amount, elapsed
end

-- Fuses FUSION_REQUIRED_COUNT duplicates of the same species+variant into one of the
-- next variant tier up. Returns (true, newVariantId, species) on success, or
-- (false, reason) -- reasons: "NoProfile", "UnknownVariant", "MaxVariant",
-- "NotEnough", "SpawnFailed".
--
-- Locked creatures are EXCLUDED from being consumed: fusion permanently destroys the
-- inputs, so it must respect the same protection the player set to stop auto-eviction.
-- Anything else would make the lock button a lie.
function PlayerDataService.FuseCritters(player, species, variantId)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end

	local fromIndex = Constants.GetVariantIndex(variantId)
	if not fromIndex then return false, "UnknownVariant" end
	local nextTier = Constants.GetVariantTier(fromIndex + 1)
	if not nextTier then return false, "MaxVariant" end

	-- Collect eligible inputs: matching species AND variant, not locked.
	local eligible = {}
	for _, rec in ipairs(profile.ownedCritters) do
		if rec.species == species and (rec.variant or "Normal") == variantId and not rec.locked then
			eligible[#eligible + 1] = rec
			if #eligible >= Constants.FUSION_REQUIRED_COUNT then break end
		end
	end
	if #eligible < Constants.FUSION_REQUIRED_COUNT then return false, "NotEnough" end

	-- Capture template stats from the first input BEFORE removing anything, so the
	-- fused result inherits the correct rarity/world rather than being rebuilt from
	-- a guess.
	local template = eligible[1]
	local baseRate = (template.sparksPerSecond or 0) / (Constants.GetVariantTier(fromIndex).multiplier or 1)
	local newRecord = {
		uid = HttpService:GenerateGUID(false),
		rarity = template.rarity,
		species = species,
		worldId = template.worldId,
		personality = template.personality,
		isShiny = template.isShiny,
		variant = nextTier.id,
		sparksPerSecond = baseRate * nextTier.multiplier,
		favorite = false,
		locked = false,
		hatchedAt = os.time(),
	}

	-- Remove the inputs, then add the result. Order matters: removing first guarantees
	-- the new creature can't be evicted by its own slot-cap check.
	-- NOTE: this removes the RECORDS only. The caller is responsible for destroying the
	-- corresponding live models via CritterService.RemoveCritter -- PlayerDataService
	-- deliberately doesn't require CritterService (that would be a circular dependency).
	local consumedUids = {}
	for _, rec in ipairs(eligible) do
		consumedUids[#consumedUids + 1] = rec.uid
		PlayerDataService.RemoveOwnedCritter(player, rec.uid)
	end
	table.insert(profile.ownedCritters, newRecord)
	profile.fusionsTotal = (profile.fusionsTotal or 0) + 1

	return true, nextTier.id, species, newRecord, consumedUids
end

-- Read-only: what CAN this player fuse right now? Returns an array of
-- { species, variant, count, nextVariant } for every group at or above the threshold.
function PlayerDataService.GetFusableGroups(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end

	local groups = {}
	for _, rec in ipairs(profile.ownedCritters) do
		if not rec.locked then
			local variant = rec.variant or "Normal"
			local key = rec.species .. "|" .. variant
			groups[key] = groups[key] or { species = rec.species, variant = variant, count = 0 }
			groups[key].count += 1
		end
	end

	local result = {}
	for _, g in pairs(groups) do
		local idx = Constants.GetVariantIndex(g.variant)
		local nextTier = idx and Constants.GetVariantTier(idx + 1)
		if nextTier and g.count >= Constants.FUSION_REQUIRED_COUNT then
			result[#result + 1] = {
				species = g.species, variant = g.variant,
				count = g.count, nextVariant = nextTier.id,
			}
		end
	end
	table.sort(result, function(a, b) return a.species < b.species end)
	return result
end

-- Returns the player's current Next Goal as { id, title, current, target, reward },
-- or nil once the whole ladder is finished. Read-only -- advancing happens in
-- CheckNextGoal below so the caller controls when rewards actually fire.
function PlayerDataService.GetNextGoal(player)
	local profile = profiles[player.UserId]
	if not profile then return nil end
	local index = profile.nextGoalIndex or 1
	local goal = Constants.NEXT_GOAL_LADDER[index]
	if not goal then return nil end
	local stats = computeAchievementStats(profile)
	local current = stats[goal.statKey] or 0
	return {
		id = goal.id,
		title = goal.title,
		current = math.min(current, goal.target),
		target = goal.target,
		reward = goal.reward,
	}
end

-- Advances the ladder past every goal the player now satisfies, granting each reward.
-- Loops rather than advancing one step, because a single action (or an offline gap)
-- can legitimately satisfy several goals at once -- stopping at one would leave the
-- player owed rewards they'd earned.
-- Returns an array of { title, reward } for everything newly completed.
function PlayerDataService.CheckNextGoal(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end
	local completed = {}
	-- Bounded loop: can never exceed the ladder length, so a bad statKey can't hang it.
	for _ = 1, #Constants.NEXT_GOAL_LADDER do
		local index = profile.nextGoalIndex or 1
		local goal = Constants.NEXT_GOAL_LADDER[index]
		if not goal then break end
		local stats = computeAchievementStats(profile)
		if (stats[goal.statKey] or 0) < goal.target then break end
		profile.nextGoalIndex = index + 1
		profile.sparks += goal.reward
		completed[#completed + 1] = { title = goal.title, reward = goal.reward }
	end
	return completed
end

-- Starter Pack eligibility. Returns (eligible, secondsRemaining).
-- Stamps firstJoinAt on first call so the window anchors to the player's genuine first
-- join rather than drifting each session.
function PlayerDataService.GetStarterPackState(player)
	local profile = profiles[player.UserId]
	if not profile then return false, 0 end
	if profile.firstJoinAt == 0 then
		profile.firstJoinAt = os.time()
	end
	if profile.starterPackBought then return false, 0 end
	local windowSeconds = Constants.STARTER_PACK_WINDOW_HOURS * 3600
	local elapsed = os.time() - profile.firstJoinAt
	if elapsed >= windowSeconds then return false, 0 end
	return true, windowSeconds - elapsed
end

-- Single source of truth for a player's Critter slot cap. The formula was previously
-- duplicated in HatchLogic, LimitedEggService and MonetizationService -- adding the VIP
-- slot to three copies is exactly how one gets missed and a paying player silently
-- loses a slot depending on which code path ran.
function PlayerDataService.GetMaxSlots(player, profile)
	profile = profile or profiles[player.UserId]
	if not profile then return 1 end
	local slots = 1 + (profile.extraSlotsPurchased or 0)
	if player:GetAttribute("SAC_ExtraSlotPass") then slots += 1 end
	if player:GetAttribute("SAC_VIP") then slots += Constants.VIP_EXTRA_SLOTS end
	-- Ranch Power perk slots.
	slots += player:GetAttribute("SAC_RanchBonusSlots") or 0
	return slots
end

-- Rich collection summary: per-world progress plus milestone previews.
-- The client previously received only the raw collection table, so it could show WHICH
-- species were owned but not how far along the player was, nor what completing anything
-- would actually give them -- both of which are the reasons a collection system drives
-- retention at all.
function PlayerDataService.GetCollectionSummary(player)
	local profile = profiles[player.UserId]
	if not profile then return nil end

	local WorldsData = require(RS.CritterRush.Modules.WorldsData)
	local worlds, totalOwned, totalSpecies = {}, 0, 0

	for _, world in ipairs(WorldsData.WORLDS) do
		if world.species then
			local owned, total = 0, 0
			for _, list in pairs(world.species) do
				for _, sp in ipairs(list) do
					total += 1
					if profile.collection[sp] == "owned" then owned += 1 end
				end
			end
			if total > 0 then
				worlds[#worlds + 1] = {
					id = world.id,
					displayName = world.displayName or world.id,
					owned = owned,
					total = total,
					percent = math.floor((owned / total) * 100),
					complete = owned >= total,
				}
				totalOwned += owned
				totalSpecies += total
			end
		end
	end

	-- Milestone previews: what the NEXT milestone gives, and everything already claimed.
	-- Showing the reward before it's earned is the whole point -- an unlabelled progress
	-- bar gives a player no reason to chase it.
	local milestones = {}
	for _, ms in ipairs(Constants.COLLECTION_MILESTONES) do
		milestones[#milestones + 1] = {
			count = ms.count,
			reward = ms.reward,
			-- Field is `claimedMilestones`, keyed by tostring(count) -- matching exactly what
			-- CheckCollectionMilestone writes. An earlier version of this read a
			-- `collectionMilestonesClaimed` field that nothing ever writes, so every
			-- milestone reported unclaimed and the panel always showed "Next: 5 species"
			-- to a player with 108 of them.
			claimed = (profile.claimedMilestones or {})[tostring(ms.count)] == true,
			reached = totalOwned >= ms.count,
		}
	end

	return {
		collection = profile.collection,
		worlds = worlds,
		totalOwned = totalOwned,
		totalSpecies = totalSpecies,
		totalPercent = totalSpecies > 0 and math.floor((totalOwned / totalSpecies) * 100) or 0,
		milestones = milestones,
		completionBonuses = select(2, PlayerDataService.GetWorldCompletionBonuses(player)),
	}
end

-- Totals up every completed world's permanent bonus. Returns a table of accumulated
-- values keyed by statKey, plus the list of completed world ids for display.
--
-- Recomputed from the collection on demand rather than stored, for the same reason
-- level is derived from XP: a stored copy can drift out of sync with the thing it
-- describes, and there's no cheap way to notice when it has.
function PlayerDataService.GetWorldCompletionBonuses(player)
	local profile = profiles[player.UserId]
	if not profile then return {}, {} end

	local WorldsData = require(RS.CritterRush.Modules.WorldsData)
	local totals = { incomeMult = 0, luckMult = 0, walkSpeed = 0 }
	local completed = {}

	for _, world in ipairs(WorldsData.WORLDS) do
		if world.species then
			local owned, total = 0, 0
			for _, list in pairs(world.species) do
				for _, sp in ipairs(list) do
					total += 1
					if profile.collection[sp] == "owned" then owned += 1 end
				end
			end
			if total > 0 and owned >= total then
				local bonus = Constants.WORLD_COMPLETION_BONUSES[world.id]
				if bonus then
					totals[bonus.statKey] = (totals[bonus.statKey] or 0) + bonus.value
					completed[#completed + 1] = { id = world.id, label = bonus.label }
				end
			end
		end
	end
	return totals, completed
end

-- Mirrors completion bonuses onto player attributes, which is where the income, luck and
-- movement systems already read their multipliers from. Called whenever the collection
-- changes, so finishing a set applies immediately rather than on next rejoin.
function PlayerDataService.SyncWorldCompletionAttributes(player)
	local totals = PlayerDataService.GetWorldCompletionBonuses(player)
	player:SetAttribute("SAC_CollectionIncomeBonus", totals.incomeMult > 0 and totals.incomeMult or nil)
	player:SetAttribute("SAC_CollectionLuckBonus", totals.luckMult > 0 and totals.luckMult or nil)
	player:SetAttribute("SAC_CollectionWalkSpeed", totals.walkSpeed > 0 and totals.walkSpeed or nil)
	-- Level-reward luck is stored on the profile but read from an attribute by the roll
	-- paths, so it must be restored on join -- otherwise a player's earned permanent luck
	-- silently resets to zero every session.
	local profile = profiles[player.UserId]
	if profile then
		local lvlLuck = profile.levelLuckBonus or 0
		player:SetAttribute("SAC_LevelLuckBonus", lvlLuck > 0 and lvlLuck or nil)
	end
end

-- Checks every achievement CHAIN and grants any newly-completed tiers.
-- Loops per chain because a single action (or an offline gap) can legitimately clear
-- several tiers at once -- stopping at one would leave the player owed rewards.
-- Returns an array of { title, reward } for everything newly granted.
function PlayerDataService.CheckAchievementTiers(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end
	profile.achievementTiers = profile.achievementTiers or {}

	local stats = computeAchievementStats(profile)
	local granted = {}

	for _, chain in ipairs(Constants.ACHIEVEMENT_CHAINS) do
		local claimed = profile.achievementTiers[chain.id] or 0
		-- Bounded: never more than 50 tiers in one pass, so a bad statKey can't hang this.
		for _ = 1, 50 do
			local nextTier = claimed + 1
			if chain.maxTier and nextTier > chain.maxTier then break end
			local ach = Constants.GetAchievementTier(chain, nextTier)
			if (stats[ach.statKey] or 0) < ach.threshold then break end
			claimed = nextTier
			profile.achievementTiers[chain.id] = claimed
			profile.sparks += ach.reward
			granted[#granted + 1] = { title = ach.title, reward = ach.reward }
		end
	end
	return granted
end

-- Read-only: the CURRENT in-progress tier for each chain, for the achievements panel.
function PlayerDataService.GetAchievementTierState(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end
	profile.achievementTiers = profile.achievementTiers or {}
	local stats = computeAchievementStats(profile)
	local result = {}
	for _, chain in ipairs(Constants.ACHIEVEMENT_CHAINS) do
		local claimed = profile.achievementTiers[chain.id] or 0
		local nextTier = claimed + 1
		if not (chain.maxTier and nextTier > chain.maxTier) then
			local ach = Constants.GetAchievementTier(chain, nextTier)
			result[#result + 1] = {
				id = ach.id, title = ach.title, desc = ach.desc,
				current = math.min(stats[ach.statKey] or 0, ach.threshold),
				threshold = ach.threshold, reward = ach.reward, tier = nextTier,
			}
		else
			result[#result + 1] = {
				id = chain.id .. "_max", title = chain.title .. " (MAX)",
				desc = "Chain complete!", current = 1, threshold = 1, reward = 0, tier = claimed,
				maxed = true,
			}
		end
	end
	return result
end

-- Records a like from `liker` on `target`'s ranch.
-- Returns (true, newTotal) or (false, reason) -- reasons: "NoProfile", "SelfLike",
-- "AlreadyLiked".
--
-- The liker set is keyed by tostring(userId) because DataStore serialisation turns
-- numeric table keys into strings on the round-trip -- using raw numbers would make
-- every like look new again after a rejoin, which is exactly the farming hole this
-- system exists to close.
function PlayerDataService.LikeRanch(liker, targetUserId)
	if liker.UserId == targetUserId then return false, "SelfLike" end
	local profile = profiles[targetUserId]
	if not profile then return false, "NoProfile" end
	profile.ranchLikedBy = profile.ranchLikedBy or {}
	local key = tostring(liker.UserId)
	if profile.ranchLikedBy[key] then return false, "AlreadyLiked" end
	profile.ranchLikedBy[key] = true
	profile.ranchLikes = (profile.ranchLikes or 0) + 1
	return true, profile.ranchLikes
end

function PlayerDataService.GetRanchLikes(player)
	local profile = profiles[player.UserId]
	if not profile then return 0 end
	return profile.ranchLikes or 0
end

-- Has `liker` already liked `targetUserId`'s ranch? Used to render the button state.
function PlayerDataService.HasLikedRanch(liker, targetUserId)
	local profile = profiles[targetUserId]
	if not profile then return false end
	return (profile.ranchLikedBy or {})[tostring(liker.UserId)] == true
end

-- ===== World relics =====
-- Rolls for a relic drop from a world mechanic payout. Returns the relic info on a
-- successful drop, or nil.
function PlayerDataService.TryDropRelic(player, worldId)
	local profile = profiles[player.UserId]
	if not profile then return nil end
	local relic = Constants.WORLD_RELICS[worldId]
	if not relic then return nil end
	if math.random() > Constants.RELIC_DROP_CHANCE then return nil end

	profile.relicCounts = profile.relicCounts or {}
	profile.relicCounts[worldId] = (profile.relicCounts[worldId] or 0) + 1
	PlayerDataService.SyncRelicAttributes(player)
	return relic, profile.relicCounts[worldId]
end

-- Mirrors relic milestone bonuses onto the attributes the luck/income chains read.
function PlayerDataService.SyncRelicAttributes(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	local luck, income = Constants.GetRelicBonuses(profile.relicCounts)
	player:SetAttribute("SAC_RelicLuckBonus", luck > 0 and luck or nil)
	player:SetAttribute("SAC_RelicIncomeBonus", income > 0 and income or nil)
end

function PlayerDataService.GetRelicState(player)
	local profile = profiles[player.UserId]
	if not profile then return {} end
	profile.relicCounts = profile.relicCounts or {}
	local out = {}
	for worldId, relic in pairs(Constants.WORLD_RELICS) do
		local count = profile.relicCounts[worldId] or 0
		-- Next milestone, so the UI can show progress rather than a bare number.
		local nextAt
		for _, m in ipairs(Constants.RELIC_MILESTONES) do
			if count < m.count then nextAt = m.count break end
		end
		out[#out + 1] = {
			id = worldId, name = relic.name, icon = relic.icon,
			count = count, nextAt = nextAt,
		}
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	local luck, income = Constants.GetRelicBonuses(profile.relicCounts)
	return { relics = out, luckBonus = luck, incomeBonus = income }
end

-- ===== Promo codes =====
-- Returns (true, rewardTable) or (false, reason).
function PlayerDataService.RedeemCode(player, rawCode)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end

	local code = Constants.NormalizeCode(rawCode)
	if not code then return false, "Invalid" end

	local reward = Constants.PROMO_CODES[code]
	if not reward then return false, "Invalid" end

	if reward.expires and os.time() > reward.expires then return false, "Expired" end

	profile.redeemedCodes = profile.redeemedCodes or {}
	if profile.redeemedCodes[code] then return false, "AlreadyRedeemed" end
	-- Mark BEFORE granting: if a grant errors we must not leave the code redeemable,
	-- which would let a retry double-claim it.
	profile.redeemedCodes[code] = true

	if reward.sparks then
		PlayerDataService.AddSparks(player, reward.sparks)
	end
	if reward.potions then
		profile.potionInventory = profile.potionInventory or {}
		for potionId, count in pairs(reward.potions) do
			profile.potionInventory[potionId] = (profile.potionInventory[potionId] or 0) + count
		end
	end
	if reward.limitedEggTokens then
		profile.limitedEggTokens = (profile.limitedEggTokens or 0) + reward.limitedEggTokens
	end

	return true, reward
end

-- ===== Bulk inventory operations =====
-- Toggling 70 creatures one at a time is 70 remote round-trips and 70 re-renders. These
-- do the whole set server-side and push ONE refresh.
--
-- `filter` is a table of optional criteria; nil fields match everything:
--   { rarity = "Common", variant = "Normal", isShiny = false, excludeLocked = true }
local function matchesFilter(rec, filter)
	if not filter then return true end
	if filter.rarity and rec.rarity ~= filter.rarity then return false end
	if filter.variant and (rec.variant or "Normal") ~= filter.variant then return false end
	if filter.isShiny ~= nil and (rec.isShiny or false) ~= filter.isShiny then return false end
	-- Locked means "never touch this". Bulk ops respect it by default because the whole
	-- point of locking is protection from exactly this kind of sweeping action.
	if filter.excludeLocked and rec.locked then return false end
	return true
end

-- action: "lock" | "unlock" | "favorite" | "unfavorite"
-- Returns (true, affectedCount) or (false, reason).
function PlayerDataService.BulkInventoryAction(player, action, filter)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end

	local VALID = { lock = true, unlock = true, favorite = true, unfavorite = true }
	if not VALID[action] then return false, "UnknownAction" end

	-- Unlocking must NOT exclude locked items -- that would match nothing and silently
	-- do no work, which reads as a broken button.
	local effective = filter and table.clone(filter) or {}
	if action == "unlock" then effective.excludeLocked = nil end

	local count = 0
	for _, rec in ipairs(profile.ownedCritters) do
		if matchesFilter(rec, effective) then
			if action == "lock" then
				if not rec.locked then rec.locked = true count += 1 end
			elseif action == "unlock" then
				if rec.locked then rec.locked = false count += 1 end
			elseif action == "favorite" then
				if not rec.favorite then rec.favorite = true count += 1 end
			elseif action == "unfavorite" then
				if rec.favorite then rec.favorite = false count += 1 end
			end
		end
	end
	return true, count
end

-- ===== Ranch Happiness =====

-- Applies any missed daily decay. Lazy (computed on read) rather than scheduled, so it
-- works correctly for a player who was offline for a week without needing a job that
-- touches every profile in existence.
function PlayerDataService.ApplyHappinessDecay(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	local today = os.time() // 86400
	local last = profile.lastHappinessDecayDay or 0
	if last == 0 then
		profile.lastHappinessDecayDay = today
		return
	end
	local daysMissed = today - last
	if daysMissed <= 0 then return end
	profile.lastHappinessDecayDay = today
	profile.ranchHappiness = math.max(0,
		(profile.ranchHappiness or 0) - daysMissed * Constants.HAPPINESS_DAILY_DECAY)
	-- Old feed records are only needed to block same-day repeats; drop stale ones so
	-- this table can't grow without bound over a ranch's lifetime.
	local kept = {}
	for uid, day in pairs(profile.fedBy or {}) do
		if day >= today then kept[uid] = day end
	end
	profile.fedBy = kept
end

function PlayerDataService.GetHappiness(player)
	local profile = profiles[player.UserId]
	if not profile then return 0 end
	PlayerDataService.ApplyHappinessDecay(player)
	return profile.ranchHappiness or 0
end

-- Feeds targetUserId's sanctuary. Returns (true, newHappiness) or (false, reason).
function PlayerDataService.FeedRanch(visitor, targetUserId)
	if visitor.UserId == targetUserId then return false, "SelfFeed" end
	local target = profiles[targetUserId]
	if not target then return false, "NoProfile" end
	-- Nothing to feed if the sanctuary is empty -- feeding an empty plot would be
	-- free happiness for the owner with no investment behind it.
	if #(target.sanctuaryUids or {}) == 0 then return false, "NoCreatures" end

	local today = os.time() // 86400
	target.fedBy = target.fedBy or {}
	local key = tostring(visitor.UserId)
	if target.fedBy[key] == today then return false, "AlreadyFedToday" end
	target.fedBy[key] = today

	target.ranchHappiness = math.min(Constants.HAPPINESS_MAX,
		(target.ranchHappiness or 0) + Constants.HAPPINESS_PER_FEED)
	return true, target.ranchHappiness
end

-- ===== Equip slots =====

-- Total equip capacity: base + world progression + passes + Ranch Power.
function PlayerDataService.GetEquipCapacity(player)
	local profile = profiles[player.UserId]
	if not profile then return Constants.BASE_EQUIP_SLOTS end

	local slots = Constants.BASE_EQUIP_SLOTS
	local WorldsData = require(RS.CritterRush.Modules.WorldsData)
	for _, world in ipairs(WorldsData.WORLDS) do
		if world.order and (profile.unlockedWorlds or {})[world.id] then
			slots += Constants.EQUIP_SLOTS_BY_WORLD_ORDER[world.order] or 0
		end
	end
	-- Purchased and earned slots carry over from the old model, so nobody loses what
	-- they already bought.
	slots += profile.extraSlotsPurchased or 0
	if player:GetAttribute("SAC_ExtraSlotPass") then slots += 1 end
	if player:GetAttribute("SAC_VIP") then slots += Constants.VIP_EXTRA_SLOTS end
	slots += player:GetAttribute("SAC_RanchBonusSlots") or 0
	-- +5 Equip Slots gamepass.
	if player:GetAttribute("SAC_MultiSlotPass") then slots += 5 end

	return math.clamp(slots, Constants.BASE_EQUIP_SLOTS, Constants.MAX_EQUIP_SLOTS)
end

-- Drops uids whose creature no longer exists (fused, traded, gifted).
function PlayerDataService.PruneEquipped(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	profile.equippedUids = profile.equippedUids or {}
	local owned = {}
	for _, rec in ipairs(profile.ownedCritters) do owned[rec.uid] = true end
	local kept = {}
	for _, uid in ipairs(profile.equippedUids) do
		if owned[uid] then kept[#kept + 1] = uid end
	end
	profile.equippedUids = kept
end

function PlayerDataService.IsEquipped(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return false end
	for _, u in ipairs(profile.equippedUids or {}) do
		if u == uid then return true end
	end
	return false
end

-- Returns (true) or (false, reason).
function PlayerDataService.EquipCritter(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	PlayerDataService.PruneEquipped(player)

	if PlayerDataService.IsEquipped(player, uid) then return false, "AlreadyEquipped" end

	local rec
	for _, r in ipairs(profile.ownedCritters) do
		if r.uid == uid then rec = r break end
	end
	if not rec then return false, "NotOwned" end

	if #profile.equippedUids >= PlayerDataService.GetEquipCapacity(player) then
		return false, "NoFreeSlots"
	end

	table.insert(profile.equippedUids, uid)
	return true
end

function PlayerDataService.UnequipCritter(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	profile.equippedUids = profile.equippedUids or {}
	for i, u in ipairs(profile.equippedUids) do
		if u == uid then
			table.remove(profile.equippedUids, i)
			return true
		end
	end
	return false, "NotEquipped"
end

-- Fills empty slots with the highest-income unequipped creatures. This is the
-- "Equip Best" convenience: with a 500-slot inventory, hand-picking is tedious and the
-- optimal choice is unambiguous anyway.
function PlayerDataService.EquipBest(player)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	PlayerDataService.PruneEquipped(player)

	local capacity = PlayerDataService.GetEquipCapacity(player)
	-- Sort ALL owned by income and take the top N, rather than only filling gaps --
	-- otherwise a player with a full-but-bad loadout gets no benefit from the button.
	local sorted = {}
	for _, rec in ipairs(profile.ownedCritters) do sorted[#sorted + 1] = rec end
	table.sort(sorted, function(a, b)
		return (a.sparksPerSecond or 0) > (b.sparksPerSecond or 0)
	end)

	local newEquipped = {}
	for i = 1, math.min(capacity, #sorted) do
		newEquipped[#newEquipped + 1] = sorted[i].uid
	end
	profile.equippedUids = newEquipped
	return true, #newEquipped
end

-- One-time migration for saves created under the old "everything earns" model.
-- Without this, an existing player logs in to find NOTHING equipped and zero income.
function PlayerDataService.MigrateToEquipModel(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	if profile.equipMigrated then return end
	profile.equipMigrated = true
	-- Auto-equip their best, so the change is a reshuffle rather than a loss.
	PlayerDataService.EquipBest(player)
end

function PlayerDataService.GetEquipState(player)
	local profile = profiles[player.UserId]
	if not profile then return { equipped = {}, capacity = 0 } end
	PlayerDataService.PruneEquipped(player)
	local set = {}
	for _, uid in ipairs(profile.equippedUids) do set[uid] = true end
	local equipped, totalIncome = {}, 0
	for _, rec in ipairs(profile.ownedCritters) do
		if set[rec.uid] then
			equipped[#equipped + 1] = {
				uid = rec.uid, species = rec.species, rarity = rec.rarity,
				variant = rec.variant or "Normal", isShiny = rec.isShiny or false,
				sparksPerSecond = rec.sparksPerSecond or 0,
			}
			totalIncome += rec.sparksPerSecond or 0
		end
	end
	return {
		equipped = equipped,
		capacity = PlayerDataService.GetEquipCapacity(player),
		totalIncome = totalIncome,
		ownedCount = #profile.ownedCritters,
		inventoryCap = Constants.MAX_INVENTORY,
	}
end

-- ===== Creature Sanctuary =====

-- Capacity from the player's CURRENT ranch tier, so upgrading the ranch has a real
-- mechanical payoff rather than only a visual one.
function PlayerDataService.GetSanctuaryCapacity(player)
	local profile = profiles[player.UserId]
	if not profile then return 0 end
	local RanchData = require(RS.CritterRush.Modules.RanchData)
	local level = levelForXP(profile.xp)
	local tier = RanchData.GetTierForLevel(level)
	local order = math.clamp(tier and tier.order or 1, 1, #Constants.SANCTUARY_SLOTS_BY_TIER)
	return Constants.SANCTUARY_SLOTS_BY_TIER[order]
end

-- Total Ranch Power from assigned creatures. Recomputed from live records rather than
-- cached, so fusing or trading an assigned creature can never leave a stale total.
function PlayerDataService.GetRanchPower(player)
	local profile = profiles[player.UserId]
	if not profile then return 0 end
	profile.sanctuaryUids = profile.sanctuaryUids or {}
	local byUid = {}
	for _, rec in ipairs(profile.ownedCritters) do byUid[rec.uid] = rec end
	local power = 0
	for _, uid in ipairs(profile.sanctuaryUids) do
		local rec = byUid[uid]
		if rec then power += Constants.GetCreaturePower(rec) end
	end
	-- Happiness multiplies the total, so a ranch people actually visit outperforms an
	-- isolated one. Applied here (rather than at each perk site) so every consumer of
	-- Ranch Power sees the same number.
	PlayerDataService.ApplyHappinessDecay(player)
	local mult = Constants.GetHappinessMultiplier(profile.ranchHappiness or 0)
	return math.floor(power * mult)
end

-- Drops uids whose creature no longer exists (fused, traded, gifted, evicted). Called
-- before any read so the sanctuary can't hold ghosts.
function PlayerDataService.PruneSanctuary(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	profile.sanctuaryUids = profile.sanctuaryUids or {}
	local owned = {}
	for _, rec in ipairs(profile.ownedCritters) do owned[rec.uid] = true end
	local kept = {}
	for _, uid in ipairs(profile.sanctuaryUids) do
		if owned[uid] then kept[#kept + 1] = uid end
	end
	profile.sanctuaryUids = kept
end

-- Returns (true) or (false, reason).
function PlayerDataService.AssignToSanctuary(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	PlayerDataService.PruneSanctuary(player)

	for _, existing in ipairs(profile.sanctuaryUids) do
		if existing == uid then return false, "AlreadyAssigned" end
	end
	local rec
	for _, r in ipairs(profile.ownedCritters) do
		if r.uid == uid then rec = r break end
	end
	if not rec then return false, "NotOwned" end

	local cap = PlayerDataService.GetSanctuaryCapacity(player)
	if #profile.sanctuaryUids >= cap then return false, "SanctuaryFull" end

	table.insert(profile.sanctuaryUids, uid)
	return true
end

function PlayerDataService.RemoveFromSanctuary(player, uid)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	profile.sanctuaryUids = profile.sanctuaryUids or {}
	for i, existing in ipairs(profile.sanctuaryUids) do
		if existing == uid then
			table.remove(profile.sanctuaryUids, i)
			return true
		end
	end
	return false, "NotAssigned"
end

-- Mirrors Ranch Power perks onto attributes the luck/income paths already read.
function PlayerDataService.SyncRanchPowerAttributes(player)
	local power = PlayerDataService.GetRanchPower(player)
	local perks = Constants.GetRanchPerks(power)
	player:SetAttribute("SAC_RanchPower", power)
	player:SetAttribute("SAC_RanchLuckBonus", perks.luck > 0 and perks.luck or nil)
	player:SetAttribute("SAC_RanchIncomeBonus", perks.income > 0 and perks.income or nil)
	player:SetAttribute("SAC_RanchBonusSlots", perks.slots > 0 and perks.slots or nil)
end

function PlayerDataService.GetSanctuaryState(player)
	local profile = profiles[player.UserId]
	if not profile then return { assigned = {}, capacity = 0, power = 0 } end
	PlayerDataService.PruneSanctuary(player)
	local byUid = {}
	for _, rec in ipairs(profile.ownedCritters) do byUid[rec.uid] = rec end
	local assigned = {}
	for _, uid in ipairs(profile.sanctuaryUids) do
		local rec = byUid[uid]
		if rec then
			assigned[#assigned + 1] = {
				uid = rec.uid, species = rec.species, rarity = rec.rarity,
				variant = rec.variant or "Normal", isShiny = rec.isShiny or false,
				power = Constants.GetCreaturePower(rec),
			}
		end
	end
	local power = PlayerDataService.GetRanchPower(player)
	return {
		assigned = assigned,
		capacity = PlayerDataService.GetSanctuaryCapacity(player),
		power = power,
		perks = Constants.GetRanchPerks(power),
		happiness = profile.ranchHappiness or 0,
		happinessMax = Constants.HAPPINESS_MAX,
	}
end

function PlayerDataService.GetInventoryState(player)
	local profile = profiles[player.UserId]
	if not profile then return { critters = {}, totalIncome = 0, bestCritter = nil } end

	local critters = {}
	local totalIncome = 0
	local best = nil
	for _, rec in ipairs(profile.ownedCritters) do
		table.insert(critters, {
			uid = rec.uid, species = rec.species, rarity = rec.rarity, worldId = rec.worldId,
			sparksPerSecond = rec.sparksPerSecond, isShiny = rec.isShiny, personality = rec.personality,
			favorite = rec.favorite or false, locked = rec.locked or false, hatchedAt = rec.hatchedAt or os.time(),
			variant = rec.variant or "Normal",
		})
		totalIncome += rec.sparksPerSecond or 0
		if not best or (rec.sparksPerSecond or 0) > best.sparksPerSecond then
			best = rec
		end
	end

	return {
		critters = critters,
		totalIncome = totalIncome,
		bestCritter = best and { species = best.species, sparksPerSecond = best.sparksPerSecond, isShiny = best.isShiny } or nil,
	}
end

-- Rolls a fresh Daily Shop offer if the real-world day has changed. Prefers a random
-- trail the player doesn't already own, at 30% off -- a genuine, meaningful discount
-- on something they'd otherwise pay full price for. If every trail is already owned,
-- falls back to a flat Sparks bonus so the daily deal never has nothing to offer.
local DAILY_SHOP_DISCOUNT = 0.7 -- 30% off
local DAILY_SHOP_SPARKS_BONUS = 1000
local function ensureDailyShopOffer(player)
	local profile = profiles[player.UserId]
	if not profile then return end
	local today = os.time() // 86400
	if profile.dailyShopOffer and profile.lastDailyShopDay == today then return end
	profile.lastDailyShopDay = today

	local unowned = {}
	for _, t in ipairs(Constants.COSMETIC_TRAILS) do
		if not profile.ownedTrails[t.id] then table.insert(unowned, t) end
	end

	if #unowned > 0 then
		local trail = unowned[math.random(1, #unowned)]
		profile.dailyShopOffer = {
			type = "trail", trailId = trail.id, trailName = trail.name,
			originalCost = trail.cost, discountedCost = math.floor(trail.cost * DAILY_SHOP_DISCOUNT),
			claimed = false,
		}
	else
		profile.dailyShopOffer = { type = "sparksBonus", amount = DAILY_SHOP_SPARKS_BONUS, claimed = false }
	end
end

-- Attempts to claim today's Daily Shop offer. Returns (true) on success, (false, reason)
-- on failure -- reason is "AlreadyClaimed" or "InsufficientSparks".
function PlayerDataService.PurchaseDailyShopOffer(player)
	local profile = profiles[player.UserId]
	if not profile then return false, "NoProfile" end
	ensureDailyShopOffer(player)
	local offer = profile.dailyShopOffer
	if offer.claimed then return false, "AlreadyClaimed" end

	if offer.type == "trail" then
		if not PlayerDataService.TrySpendSparks(player, offer.discountedCost) then
			return false, "InsufficientSparks"
		end
		profile.ownedTrails[offer.trailId] = true
		profile.equippedTrail = offer.trailId
		AnalyticsService.LogTrailPurchase(player, offer.discountedCost, profile.sparks, offer.trailId)
	else
		PlayerDataService.AddSparks(player, offer.amount)
	end
	offer.claimed = true
	return true
end

-- Read-only snapshot for the client's Shop panel Daily Deal section.
function PlayerDataService.GetDailyShopState(player)
	local profile = profiles[player.UserId]
	if not profile then return nil end
	ensureDailyShopOffer(player)
	return profile.dailyShopOffer
end

-- Note: initial Load() is called explicitly and synchronously by Main.lua's onPlayerAdded,
-- so downstream systems (e.g. starter critter spawn) can rely on profile being ready —
-- avoids a PlayerAdded-listener-ordering race. Init() here only owns save/cleanup lifecycle.
function PlayerDataService.Init()
	Players.PlayerRemoving:Connect(function(player)
		PlayerDataService.Release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				PlayerDataService.Save(player, false)
			end
		end
	end)

	game:BindToClose(function()
		for _, player in ipairs(Players:GetPlayers()) do
			PlayerDataService.Release(player)
		end
		task.wait(1) -- give UpdateAsync calls a moment to flush
	end)
end

return PlayerDataService
