--[[
	AnalyticsService.lua
	Thin wrapper around Roblox's native AnalyticsService, so the rest of the codebase
	calls clean, game-specific functions (LogFirstHatch, LogHatchPurchase, etc.) instead
	of scattering raw AnalyticsService calls with hand-typed step numbers everywhere --
	the step numbers, funnel names, and event shapes live in exactly one place.

	Deliberately does NOT reimplement session length or D1/D7 retention -- Roblox tracks
	those automatically for any published experience, visible on the Creator Dashboard
	with zero code required. This module only covers what Roblox does NOT give for free:
	a custom first-time-user-experience funnel (answers "where do players quit") and
	economy/progression events tied to real, discrete transactions (answers "is pricing
	right" and "is unlock/rebirth pacing right").

	Rate-limit discipline: Roblox budgets ~140 analytics calls per player. Passive income
	fires many times per SECOND, so it is deliberately never logged here -- only discrete,
	meaningful transactions (a hatch, a quest completion, a world unlock, a rebirth) are.
]]

local Players = game:GetService("Players")
local AnalyticsService = game:GetService("AnalyticsService")

local Analytics = {}

-- ===== Onboarding funnel: the first-time-user-experience, one-time per player =====
-- Steps must be logged in order for clean funnel data, but Roblox auto-completes any
-- skipped earlier steps, so a missed call here is forgiving, not catastrophic.
local ONBOARDING_STEPS = {
	Joined = 1,
	FirstHatch = 2,
	FirstQuestComplete = 3,
	FirstRealPurchaseHatch = 4,
	FirstWorldUnlock = 5,
	FirstRebirth = 6,
}

-- [userId] = { [stepKey] = true }. The header above says these are one-time per
-- player, but nothing enforced it: callers like LogFirstHatch run on EVERY hatch, so a
-- single 25x multi-hatch fired 25 duplicate "FirstHatch" funnel events. Measured live at
-- ~150 events from 75 hatches.
--
-- That isn't just quota waste -- it corrupts the funnel itself, which is the one report
-- that answers "where do players drop off". A step repeated 150 times makes the drop-off
-- between steps meaningless.
local onboardingSent = {}

local function logOnboardingStep(player, stepKey)
	local step = ONBOARDING_STEPS[stepKey]
	if not step then return end
	if not player then return end

	local userId = player.UserId
	onboardingSent[userId] = onboardingSent[userId] or {}
	if onboardingSent[userId][stepKey] then return end
	onboardingSent[userId][stepKey] = true

	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepKey)
	end)
	if not ok then
		warn("[AnalyticsService] onboarding step failed:", stepKey, err)
	end
end

function Analytics.LogPlayerJoined(player)
	logOnboardingStep(player, "Joined")
end

function Analytics.LogFirstHatch(player)
	logOnboardingStep(player, "FirstHatch")
end

function Analytics.LogFirstQuestComplete(player)
	logOnboardingStep(player, "FirstQuestComplete")
end

function Analytics.LogFirstRealPurchaseHatch(player)
	logOnboardingStep(player, "FirstRealPurchaseHatch")
end

function Analytics.LogFirstWorldUnlock(player)
	logOnboardingStep(player, "FirstWorldUnlock")
end

function Analytics.LogFirstRebirth(player)
	logOnboardingStep(player, "FirstRebirth")
end

-- ===== Economy events: real Sparks flow, tied to a discrete transaction =====
-- ===== Economy event batching =====
-- Every economy event previously fired an immediate web call. Measured live: 75 hatches
-- produced several hundred events in seconds. Two problems with that:
--   * it burns Roblox's analytics quota fast under real player load, and
--   * it makes the DATA worse -- a player who 25x-hatches shows as 25 separate egg
--     purchases, which drowns the signal you actually want ("how much do players spend
--     per session, on what?").
--
-- Batched by (player, transactionType, itemSku): amounts are SUMMED and the ending
-- balance takes the LATEST value, so one flushed event faithfully represents the whole
-- burst. Flushed on a timer, on player leave, and on server close -- a player who
-- quits mid-burst must not lose their data.
local ECONOMY_FLUSH_SECONDS = 10

-- [userId] = { [key] = { flowType, amount, endingBalance, transactionType, itemSku } }
local economyBuffer = {}

local function flushEconomyFor(player)
	local userId = player.UserId
	local pending = economyBuffer[userId]
	if not pending then return end
	economyBuffer[userId] = nil
	for _, e in pairs(pending) do
		local ok, err = pcall(function()
			AnalyticsService:LogEconomyEvent(player, e.flowType, "Sparks", e.amount,
				e.endingBalance, e.transactionType, e.itemSku or "")
		end)
		if not ok then
			warn("[AnalyticsService] economy event failed:", e.transactionType, err)
		end
	end
end

local function flushAllEconomy()
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(flushEconomyFor, player)
	end
end

local function logEconomy(player, flowType, amount, endingBalance, transactionType, itemSku)
	if not player then return end
	local userId = player.UserId
	economyBuffer[userId] = economyBuffer[userId] or {}
	-- Key includes flowType: a Source and a Sink of the same type are different events
	-- and must never be merged into one.
	local key = tostring(flowType) .. "|" .. tostring(transactionType) .. "|" .. tostring(itemSku or "")
	local entry = economyBuffer[userId][key]
	if entry then
		entry.amount += (amount or 0)
		entry.endingBalance = endingBalance  -- latest balance is the accurate one
	else
		economyBuffer[userId][key] = {
			flowType = flowType, amount = amount or 0, endingBalance = endingBalance,
			transactionType = transactionType, itemSku = itemSku,
		}
	end
end

function Analytics.LogHatchPurchase(player, cost, newBalance, rarityId, worldId)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, cost, newBalance, "EggPurchase", (worldId or "") .. "_" .. (rarityId or ""))
end

function Analytics.LogWorldUnlock(player, cost, newBalance, worldId)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, cost, newBalance, "WorldUnlock", worldId)
end

-- Potions are a repeatable Sparks SINK -- tracking them separately from slot/trail
-- purchases is what makes "are potions actually absorbing surplus Sparks?" answerable.
function Analytics.LogPotionPurchase(player, cost, newBalance, potionId)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, cost, newBalance, "PotionPurchase", potionId)
end

function Analytics.LogSlotPurchase(player, cost, newBalance)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, cost, newBalance, "SlotPurchase")
end

function Analytics.LogTrailPurchase(player, cost, newBalance, trailId)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, cost, newBalance, "TrailPurchase", trailId)
end

function Analytics.LogRewardEarned(player, amount, newBalance, rewardType)
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Source, amount, newBalance, rewardType)
end

function Analytics.LogRebirthReset(player, sparksBeforeReset)
	-- The rebirth reset itself isn't a "purchase" -- logging the full pre-reset balance
	-- as a Sink is what makes "how much wealth accumulates before players rebirth"
	-- visible in the economy charts, which is real, useful rebirth-pacing signal.
	logEconomy(player, Enum.AnalyticsEconomyFlowType.Sink, sparksBeforeReset, 0, "RebirthReset")
end

-- ===== Progression events: world unlocks and rebirths, as Roblox "levels" =====
function Analytics.LogWorldUnlockProgression(player, worldOrder, worldDisplayName)
	local ok, err = pcall(function()
		AnalyticsService:LogProgressionCompleteEvent(player, "WorldUnlocks", worldOrder, worldDisplayName)
	end)
	if not ok then
		warn("[AnalyticsService] world progression event failed:", err)
	end
end

function Analytics.LogRebirthProgression(player, rebirthCount, tierTitle)
	local ok, err = pcall(function()
		AnalyticsService:LogProgressionCompleteEvent(player, "Rebirths", rebirthCount, tierTitle)
	end)
	if not ok then
		warn("[AnalyticsService] rebirth progression event failed:", err)
	end
end

-- Flush triggers. Three of them, because losing a player's session data is worse
-- than sending a few extra events:
--   * timer, for long sessions
--   * PlayerRemoving, so a quitter's buffer isn't lost
--   * BindToClose, so a server shutdown doesn't discard everyone's
function Analytics.StartBatching()
	task.spawn(function()
		while true do
			task.wait(ECONOMY_FLUSH_SECONDS)
			pcall(flushAllEconomy)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		pcall(flushEconomyFor, player)
		onboardingSent[player.UserId] = nil
	end)

	game:BindToClose(function()
		pcall(flushAllEconomy)
	end)
end

return Analytics
