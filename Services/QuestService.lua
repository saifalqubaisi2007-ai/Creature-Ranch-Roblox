--[[
	QuestService.lua
	Always-have-a-goal system: one active quest per player at a time, shown on a
	persistent HUD card. Complete it, get a reward burst, a new one appears immediately.
	Progress is saved so quests survive disconnects.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local QuestService = {}

-- type: "orbs" | "sparks" | "hatch" | "explore"
-- minLevel: the player's level (PlayerDataService.GetLevel) must be >= this for the
-- template to be eligible. Gives "Level purpose" real teeth -- new, bigger-reward
-- quest tiers genuinely unlock as you level, not just Ranch tiers. Defaults to 0
-- (always available) when omitted.
-- Quest templates. Targets and rewards are BASE values scaled at roll time by the
-- player's progression (see scaleQuest below) -- a fixed 600-Spark reward is meaningless
-- once income is millions per second, and a fixed "hatch 3 eggs" is trivial once
-- multi-hatch grants 25 at a time.
--
-- minLevel still gates which templates can roll, so early players see simple objectives
-- and the harder shapes appear as they progress.
local QUEST_POOL = {
	{ type = "orbs", target = 10, text = "Collect %d/%d Spark Orbs", reward = 150 },
	{ type = "orbs", target = 20, text = "Collect %d/%d Spark Orbs", reward = 300 },
	{ type = "sparks", target = 200, text = "Earn %d/%d Sparks", reward = 100 },
	{ type = "sparks", target = 500, text = "Earn %d/%d Sparks", reward = 250 },
	{ type = "hatch", target = 1, text = "Hatch %d/%d egg", reward = 200 },
	-- Design-review fix (MEDIUM #5 + #7): routes new players past at least one built
	-- landmark (previously nothing did) AND adds real quest-type variety beyond the
	-- original 3 kinds. Reported by LandmarkService on first zone entry per session.
	{ type = "explore", target = 1, text = "Discover %d/%d Landmark", reward = 200 },
	-- Level-gated tiers -- bigger targets, bigger rewards, genuinely locked until the
	-- player has leveled up enough to see them roll.
	{ type = "orbs", target = 35, text = "Collect %d/%d Spark Orbs", reward = 500, minLevel = 10 },
	{ type = "sparks", target = 1500, text = "Earn %d/%d Sparks", reward = 450, minLevel = 15 },
	{ type = "hatch", target = 3, text = "Hatch %d/%d eggs", reward = 600, minLevel = 20 },
}

-- ===== INFINITE QUEST SCALING =====
-- The pool above has fixed targets and stops varying at level 20, and its rewards
-- (150-600 Sparks) were set before the economy rebalance -- they're now a rounding
-- error against a 20,000 Forest unlock, let alone lategame income.
--
-- Rather than hand-authoring more tiers that would go stale again, targets and rewards
-- now scale off the player's REBIRTH count, which is the cleanest available proxy for
-- overall progression (level plateaus, Sparks balance swings wildly, world count caps
-- at 7). A quest therefore stays proportionate forever.
--
-- Targets scale gently (x1.6/rebirth) and rewards steeply (x4/rebirth): a lategame
-- quest should be a meaningful payout without becoming a grind wall.
local QUEST_TARGET_SCALE = 1.6
local QUEST_REWARD_SCALE = 4

-- "sparks" quests need a MUCH steeper target curve than the others. Orb and hatch rates
-- are roughly flat across rebirths (a player still collects orbs one at a time), but
-- Sparks INCOME scales with every multiplier in the game -- so a gently-scaled Sparks
-- target that took minutes at R0 completes in under 5 seconds at R5, measured live.
-- 4x per rebirth keeps it proportionate to actual earning power.
local QUEST_TARGET_SCALE_BY_TYPE = { sparks = 4 }

local function scaledQuest(entry, rebirths, level)
	rebirths = rebirths or 0
	level = level or 1
	-- Level contributes a gentler secondary curve. Rebirths alone left a genuine gap: a
	-- level-500 player who has never rebirthed was still being handed the same 150-Spark
	-- starter quest as a brand-new account, because rebirths == 0 short-circuited here.
	local levelFactor = 1 + math.max(0, level - 1) * 0.04
	if rebirths <= 0 and levelFactor <= 1 then return entry end
	local copy = {}
	for k, v in pairs(entry) do copy[k] = v end
	local targetScale = QUEST_TARGET_SCALE_BY_TYPE[entry.type] or QUEST_TARGET_SCALE
	-- "explore" targets count landmarks that physically exist, so scaling them would
	-- make the quest literally uncompletable.
	if entry.type ~= "explore" then
		copy.target = math.max(1, math.floor(entry.target * (targetScale ^ rebirths) * levelFactor))
	end
	copy.reward = math.floor(entry.reward * (QUEST_REWARD_SCALE ^ rebirths) * levelFactor)
	return copy
end

-- Daily Quest: a SEPARATE, bigger-target/bigger-reward quest that resets once per real
-- day (not on completion, like the always-on quest above). Reuses the exact same
-- progress kinds (orbs/sparks/hatch) so ReportProgress can advance both in parallel
-- with zero new call sites anywhere else in the game -- every place that already
-- reports hatch/orb/sparks progress feeds this automatically.
local DAILY_QUEST_POOL = {
	{ type = "orbs", target = 50, text = "Collect %d/%d Spark Orbs", reward = 800 },
	{ type = "sparks", target = 3000, text = "Earn %d/%d Sparks", reward = 700 },
	{ type = "hatch", target = 5, text = "Hatch %d/%d eggs", reward = 1000 },
}

local function newQuest(player, excludeType)
	local level = PlayerDataService.GetLevel(player)
	local pool = {}
	for _, q in ipairs(QUEST_POOL) do
		if q.type ~= excludeType and level >= (q.minLevel or 0) then
			table.insert(pool, q)
		end
	end
	-- Fallback: excludeType could theoretically empty the pool if every eligible
	-- template happens to share that one type at a low level. Never actually happens
	-- with the current pool shape (multiple types are always eligible at every level),
	-- but retry without the exclusion rather than risk indexing an empty table.
	if #pool == 0 then
		for _, q in ipairs(QUEST_POOL) do
			if level >= (q.minLevel or 0) then table.insert(pool, q) end
		end
	end
	local template = pool[math.random(1, #pool)]
	-- Scale by rebirth count so quests stay proportionate forever rather than plateauing
	-- at the pool's hand-authored level-20 tier.
	local profile = PlayerDataService.Get(player)
	template = scaledQuest(template, profile and profile.rebirths or 0, level)
	return { type = template.type, target = template.target, textTemplate = template.text,
		reward = template.reward, progress = 0 }
end

local function pushQuest(player)
	local profile = PlayerDataService.Get(player)
	if not profile or not profile.activeQuest then return end
	local q = profile.activeQuest
	local text = string.format(q.textTemplate, math.min(q.progress, q.target), q.target)
	remotes.QuestUpdated:FireClient(player, text, q.progress, q.target, q.reward)
end

local function completeQuest(player)
	local profile = PlayerDataService.Get(player)
	if not profile or not profile.activeQuest then return end
	local q = profile.activeQuest
	-- Safety: only grant if this quest is genuinely complete. Combined with the guard
	-- in ReportProgress below, this makes double-completion structurally impossible.
	if q.progress < q.target then return end

	local newTotal = PlayerDataService.AddSparks(player, q.reward)
	remotes.SparksUpdated:FireClient(player, newTotal)
	remotes.QuestCompleted:FireClient(player, q.reward)
	AnalyticsService.LogRewardEarned(player, q.reward, newTotal, "QuestReward")
	AnalyticsService.LogFirstQuestComplete(player)

	local bonusXP = Constants.XP_REWARDS.questComplete
	if bonusXP and bonusXP > 0 then
		local newXP, level, xpIntoLevel, xpNeeded, leveledUp = PlayerDataService.AddXP(player, bonusXP)
		remotes.XPUpdated:FireClient(player, newXP, level, xpIntoLevel, xpNeeded)
		if leveledUp then remotes.LevelUp:FireClient(player, level) end
	end

	profile.activeQuest = newQuest(player, q.type) -- avoid immediate repeat of the same type
	pushQuest(player)
end

-- Rolls a fresh Daily Quest if the real-world day has changed since the last one, or if
-- none has ever been rolled. Idempotent -- safe to call on every login and every
-- progress report, since it only actually does anything once per day.
local function ensureDailyQuest(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	local today = os.time() // 86400
	if profile.dailyQuest and profile.lastDailyQuestDay == today then return end
	profile.lastDailyQuestDay = today
	local template = DAILY_QUEST_POOL[math.random(1, #DAILY_QUEST_POOL)]
	-- Daily quests scale on the same rebirth+level curve as regular quests.
	local dailyLevel = PlayerDataService.GetLevel(player)
	template = scaledQuest(template, profile.rebirths or 0, dailyLevel)
	profile.dailyQuest = { type = template.type, target = template.target,
		textTemplate = template.text, reward = template.reward, progress = 0, completed = false }
end

local function pushDailyQuest(player)
	local profile = PlayerDataService.Get(player)
	if not profile or not profile.dailyQuest then return end
	local q = profile.dailyQuest
	local text = string.format(q.textTemplate, math.min(q.progress, q.target), q.target)
	remotes.DailyQuestUpdated:FireClient(player, text, q.progress, q.target, q.reward, q.completed)
end

-- Unlike completeQuest, this does NOT roll a new one immediately -- the whole point of
-- a Daily Quest is that it stays completed/locked until the next real day. The
-- "completed" flag lets the client show a distinct "come back tomorrow" state instead
-- of silently vanishing.
local function completeDailyQuest(player)
	local profile = PlayerDataService.Get(player)
	if not profile or not profile.dailyQuest then return end
	local q = profile.dailyQuest
	if q.progress < q.target or q.completed then return end
	q.completed = true

	local newTotal = PlayerDataService.AddSparks(player, q.reward)
	remotes.SparksUpdated:FireClient(player, newTotal)
	remotes.DailyQuestCompleted:FireClient(player, q.reward)
	AnalyticsService.LogRewardEarned(player, q.reward, newTotal, "DailyQuestReward")

	local bonusXP = Constants.XP_REWARDS.questComplete
	if bonusXP and bonusXP > 0 then
		local newXP, level, xpIntoLevel, xpNeeded, leveledUp = PlayerDataService.AddXP(player, bonusXP * 2) -- daily is worth double the usual quest-complete XP
		remotes.XPUpdated:FireClient(player, newXP, level, xpIntoLevel, xpNeeded)
		if leveledUp then remotes.LevelUp:FireClient(player, level) end
	end

	pushDailyQuest(player)
end

-- Called by other services whenever progress-relevant events happen.
-- kind: "orbs" | "sparks" | "hatch" | "explore"
-- Optional hook invoked after every progress report. Main assigns this so the Next Goal
-- ladder can re-check on any meaningful action, WITHOUT QuestService having to require
-- Main (which would be a circular dependency). Left nil if nothing registers.
QuestService.onProgressReported = nil

-- Forward-declared so the public ReportProgress wrapper below can reference it.
local reportProgressImpl

function reportProgressImpl(player, kind, amount)
	amount = amount or 1
	local profile = PlayerDataService.Get(player)
	if not profile then return end

	-- XP is awarded for the ACTION ITSELF, unconditionally -- unlike quest progress below
	-- (which only advances if `kind` matches whatever quest happens to be active right
	-- now), XP must never silently drop just because the player's current quest is a
	-- different type. `sparks` deliberately maps to 0 in Constants.XP_REWARDS so passive
	-- income (which reports here many times/sec) never grants XP.
	local xpReward = Constants.XP_REWARDS[kind]
	if xpReward and xpReward > 0 then
		local newXP, level, xpIntoLevel, xpNeeded, leveledUp = PlayerDataService.AddXP(player, xpReward)
		remotes.XPUpdated:FireClient(player, newXP, level, xpIntoLevel, xpNeeded)
		if leveledUp then remotes.LevelUp:FireClient(player, level) end

		-- Achievement check: gated to the same "xpReward > 0" branch as above, which
		-- already excludes `sparks` (passive income reports here many times/sec and can
		-- never move a tracked achievement stat, so scanning on every tick would be pure
		-- waste). Every OTHER kind can move at least the `level` stat via the XP grant
		-- just above, so all of them are worth checking.
		local unlocked = PlayerDataService.CheckAchievements(player)
		if #unlocked > 0 then
			-- Each unlock grants its own XP bonus (inside CheckAchievements), so the XP/level
			-- numbers already announced above are now stale -- resync once with the true
			-- current state rather than leaving the client's bar lagging until the next
			-- unrelated action happens to refresh it.
			local freshLevel, freshInto, freshNeeded = PlayerDataService.GetLevel(player)
			local freshProfile = PlayerDataService.Get(player)
			remotes.XPUpdated:FireClient(player, freshProfile.xp, freshLevel, freshInto, freshNeeded)
			if freshLevel > level then remotes.LevelUp:FireClient(player, freshLevel) end
			for _, ach in ipairs(unlocked) do
				remotes.SparksUpdated:FireClient(player, freshProfile.sparks)
				remotes.AchievementUnlocked:FireClient(player, ach.id, ach.title, ach.reward)
			end
		end
	end

	if not profile.activeQuest then
		profile.activeQuest = newQuest(player)
	end
	-- Daily Quest advances independently of the always-on quest below -- moved BEFORE
	-- that quest's own early-returns (type mismatch, already-at-target) so those
	-- conditions on the REGULAR quest can never silently block the DAILY quest's
	-- progress. Two separate trackers reacting to the same event, genuinely independent.
	ensureDailyQuest(player)
	local dq = profile.dailyQuest
	if dq and dq.type == kind and dq.progress < dq.target and not dq.completionScheduled then
		dq.progress = math.min(dq.progress + amount, dq.target)
		pushDailyQuest(player)
		if dq.progress >= dq.target then
			dq.completionScheduled = true
			task.delay(0.4, completeDailyQuest, player)
		end
	end

	local q = profile.activeQuest
	if q.type ~= kind then return end
	-- CRITICAL GUARD: once a quest has reached its target, ignore all further progress
	-- reports for it. Without this, every additional qualifying report (there can be
	-- many per second from passive income alone) re-enters the completion branch below
	-- and schedules ANOTHER completeQuest call — confirmed via live testing to cause a
	-- real cascade of duplicate reward grants and reroll loops, not just a theoretical risk.
	if q.progress >= q.target or q.completionScheduled then return end

	q.progress = math.min(q.progress + amount, q.target)
	pushQuest(player)
	if q.progress >= q.target then
		q.completionScheduled = true
		task.delay(0.4, completeQuest, player) -- brief beat so the bar visibly fills before resetting
	end
end

-- Public entry point. Wraps the real implementation so the Next Goal hook fires on
-- EVERY call -- the implementation has several early returns (type mismatch,
-- already-complete quest), and a hook placed at its end would silently be skipped on
-- exactly the paths that matter most.
function QuestService.ReportProgress(player, kind, amount)
	reportProgressImpl(player, kind, amount)
	if QuestService.onProgressReported then
		local ok, err = pcall(QuestService.onProgressReported, player)
		if not ok then warn("[QuestService] onProgressReported hook failed:", err) end
	end
end

function QuestService.OnPlayerReady(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return end
	if not profile.activeQuest then
		-- Design-review fix (CRITICAL #2): a brand-new player's very first quest must
		-- never roll "hatch" -- hatching costs Sparks they don't have yet (250 minimum for
		-- the cheapest paid egg), so a "hatch" quest handed to a player with 0 Sparks is
		-- structurally impossible to act on until they've ALREADY solved their own
		-- onboarding problem some other way. Force it to "orbs" instead: always
		-- immediately actionable, and it's also the intended answer to "what do I do right
		-- now" that nothing else explicitly teaches without this. Gated on
		-- hatchesTotal==0, which is only ever true for a player who has NEVER hatched
		-- anything, ever -- a returning player always has >0 from their own past, and this
		-- check runs synchronously in onPlayerAdded, well before the starter critter grant
		-- even for a genuinely fresh player, so the timing can never race.
		if profile.hatchesTotal == 0 then
			local orbsTemplates = {}
			local level = PlayerDataService.GetLevel(player)
			for _, template in ipairs(QUEST_POOL) do
				if template.type == "orbs" and level >= (template.minLevel or 0) then
					table.insert(orbsTemplates, template)
				end
			end
			local template = orbsTemplates[math.random(1, #orbsTemplates)]
			-- Scaled too, so a rebirthed player restarting doesn't get a level-1 target.
			template = scaledQuest(template, profile.rebirths or 0, level)
			profile.activeQuest = { type = template.type, target = template.target,
				textTemplate = template.text, reward = template.reward, progress = 0 }
		else
			profile.activeQuest = newQuest(player)
		end
	end
	pushQuest(player)

	ensureDailyQuest(player)
	pushDailyQuest(player)
end

return QuestService
