--[[
	GiftService.lua
	One-directional critter gifting.

	Simpler than trading (no handshake, no lock window) but with a risk trading doesn't
	have: alt-account farming. A player can make a second account, funnel everything to
	their main, and repeat. The daily cap, account-age minimum, and audit logging exist
	specifically for that, and there is deliberately NO reward for gifting -- a gifter
	bonus would turn alt-farming from possible into worthwhile.

	Transfer safety mirrors TradeService: validate, then remove-before-add, so a uid can
	never exist in two profiles at once.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local CritterService = require(script.Parent.CritterService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local GiftService = {}

-- Returns (remaining, limit) for today, resetting lazily on a new day.
function GiftService.GetRemaining(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return 0, Constants.GIFT_DAILY_LIMIT end
	local today = os.time() // 86400
	if profile.giftsSentDay ~= today then
		profile.giftsSentDay = today
		profile.giftsSentToday = 0
	end
	return math.max(0, Constants.GIFT_DAILY_LIMIT - (profile.giftsSentToday or 0)),
		Constants.GIFT_DAILY_LIMIT
end

-- Returns (true) or (false, reason).
function GiftService.Send(sender, targetUserId, uid)
	if typeof(targetUserId) ~= "number" or typeof(uid) ~= "string" then
		return false, "Bad request."
	end
	if targetUserId == sender.UserId then
		return false, "You can't gift to yourself."
	end

	-- Account age gate: a freshly-made alt can't gift at all.
	if sender.AccountAge < Constants.GIFT_MIN_ACCOUNT_AGE_DAYS then
		return false, string.format("Your account must be %d days old to send gifts.",
			Constants.GIFT_MIN_ACCOUNT_AGE_DAYS)
	end

	local remaining = GiftService.GetRemaining(sender)
	if remaining <= 0 then
		return false, "You've sent all your gifts for today."
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then return false, "That player has left." end

	-- Proximity, same as trading -- gifting is face-to-face, which also makes
	-- server-wide gift spam impossible.
	local ca, cb = sender.Character, target.Character
	local ha = ca and ca:FindFirstChild("HumanoidRootPart")
	local hb = cb and cb:FindFirstChild("HumanoidRootPart")
	if not ha or not hb or (ha.Position - hb.Position).Magnitude > Constants.GIFT_MAX_DISTANCE then
		return false, "Get closer to gift to them."
	end

	local senderProfile = PlayerDataService.Get(sender)
	local targetProfile = PlayerDataService.Get(target)
	if not senderProfile or not targetProfile then return false, "Profile unavailable." end

	-- Validate ownership and lock state. A locked critter means "never remove" -- and a
	-- gift is irreversible, so that flag matters more here than in eviction.
	local record
	for _, rec in ipairs(senderProfile.ownedCritters) do
		if rec.uid == uid then record = rec break end
	end
	if not record then return false, "You don't own that critter." end
	if record.locked then return false, "That critter is locked. Unlock it to gift." end

	-- Receiver must have room. Silently evicting one of THEIR critters to make space for
	-- a gift would be a genuinely hostile outcome -- refuse instead.
	local maxSlots = PlayerDataService.GetMaxSlots(target, targetProfile)
	if #targetProfile.ownedCritters >= maxSlots then
		return false, target.DisplayName .. " has no free Critter slots."
	end

	-- Transfer: remove before add, so the uid can never exist in two profiles.
	CritterService.RemoveCritter(record.uid)
	PlayerDataService.RemoveOwnedCritter(sender, record.uid)
	PlayerDataService.AddOwnedCritter(target, record)

	senderProfile.giftsSentToday = (senderProfile.giftsSentToday or 0) + 1

	-- Audit trail: both sides logged, so alt-farming patterns are reviewable later.
	AnalyticsService.LogRewardEarned(sender, 0, senderProfile.sparks, "GiftSent")
	AnalyticsService.LogRewardEarned(target, 0, targetProfile.sparks, "GiftReceived")

	remotes.GiftResult:FireClient(sender, true, record.species, target.DisplayName,
		select(1, GiftService.GetRemaining(sender)))
	remotes.GiftReceived:FireClient(target, record.species, sender.DisplayName)
	remotes.InventoryData:FireClient(sender, PlayerDataService.GetInventoryState(sender))
	remotes.InventoryData:FireClient(target, PlayerDataService.GetInventoryState(target))
	return true
end

function GiftService.Init()
	remotes.RequestGift.OnServerEvent:Connect(function(player, targetUserId, uid)
		local ok, err = GiftService.Send(player, targetUserId, uid)
		if not ok then
			remotes.GiftResult:FireClient(player, false, err)
		end
	end)

	remotes.RequestGiftStatus.OnServerEvent:Connect(function(player)
		local remaining, limit = GiftService.GetRemaining(player)
		remotes.GiftStatus:FireClient(player, remaining, limit,
			player.AccountAge >= Constants.GIFT_MIN_ACCOUNT_AGE_DAYS)
	end)
end

return GiftService
