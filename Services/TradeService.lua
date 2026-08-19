--[[
	TradeService.lua
	Player-to-player critter trading.

	This is the highest-risk system in the game. The design is shaped entirely around
	three failure modes:

	 1. DUPLICATION / LOSS -- execution is atomic. Every item is validated as still-owned
	    and still-unlocked immediately before transfer, and the whole trade is assembled
	    in memory before ANY profile is mutated. A mid-trade failure aborts with nothing
	    moved, rather than leaving one side paid.

	 2. SCAMMING -- after both players accept, the offer LOCKS for a few seconds and is
	    re-shown before executing. The classic scam (swap your offer to junk the instant
	    before the other side confirms) is impossible, because ANY change to either offer
	    clears both acceptances and re-opens the trade.

	 3. STATE CORRUPTION -- a player leaving, dying, or walking away cancels the trade
	    cleanly. Sessions are keyed both ways so neither player can be in two trades.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local CritterService = require(script.Parent.CritterService)
local AnalyticsService = require(script.Parent.AnalyticsService)

local remotes = RS.CritterRush.Remotes

local TradeService = {}

-- [userId] = session. Both participants map to the SAME table, so neither can be in
-- two trades at once and either can mutate/cancel it.
local sessions = {}
-- [userId] = { fromUserId = expiryTime } -- pending invitations
local pendingRequests = {}

local function now() return os.clock() end

local function bothPlayers(session)
	return Players:GetPlayerByUserId(session.a), Players:GetPlayerByUserId(session.b)
end

local function pushState(session)
	local pa, pb = bothPlayers(session)
	local function payload(forUserId)
		local mine = (forUserId == session.a) and session.offerA or session.offerB
		local theirs = (forUserId == session.a) and session.offerB or session.offerA
		local myAccept = (forUserId == session.a) and session.acceptA or session.acceptB
		local theirAccept = (forUserId == session.a) and session.acceptB or session.acceptA
		local otherId = (forUserId == session.a) and session.b or session.a
		local other = Players:GetPlayerByUserId(otherId)
		return {
			otherName = other and other.DisplayName or "?",
			myOffer = mine,
			theirOffer = theirs,
			myAccepted = myAccept,
			theirAccepted = theirAccept,
			locked = session.locked == true,
			lockRemaining = session.lockUntil and math.max(0, math.ceil(session.lockUntil - now())) or 0,
		}
	end
	if pa then remotes.TradeState:FireClient(pa, payload(session.a)) end
	if pb then remotes.TradeState:FireClient(pb, payload(session.b)) end
end

local function endSession(session, reasonA, reasonB)
	local pa, pb = bothPlayers(session)
	sessions[session.a] = nil
	sessions[session.b] = nil
	if pa then remotes.TradeEnded:FireClient(pa, reasonA) end
	if pb then remotes.TradeEnded:FireClient(pb, reasonB or reasonA) end
end

function TradeService.Cancel(player, reason)
	local session = sessions[player.UserId]
	if not session then return end
	endSession(session, reason or "Trade cancelled.")
end

-- Any change to either offer clears BOTH acceptances. This is the anti-scam invariant:
-- you can never be holding an acceptance against an offer you didn't see.
local function invalidateAcceptance(session)
	session.acceptA = false
	session.acceptB = false
	session.locked = false
	session.lockUntil = nil
end

function TradeService.Request(player, targetUserId)
	if typeof(targetUserId) ~= "number" then return false, "Bad request." end
	if targetUserId == player.UserId then return false, "You can't trade with yourself." end
	if sessions[player.UserId] then return false, "You're already in a trade." end
	if sessions[targetUserId] then return false, "They're already in a trade." end

	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then return false, "That player has left." end

	-- Proximity requirement: trading is a face-to-face interaction, which also makes
	-- drive-by scam requests across a whole server impossible.
	local ca, cb = player.Character, target.Character
	local ha = ca and ca:FindFirstChild("HumanoidRootPart")
	local hb = cb and cb:FindFirstChild("HumanoidRootPart")
	if not ha or not hb or (ha.Position - hb.Position).Magnitude > Constants.TRADE_MAX_DISTANCE then
		return false, "Get closer to trade with them."
	end

	pendingRequests[targetUserId] = pendingRequests[targetUserId] or {}
	pendingRequests[targetUserId][player.UserId] = now() + Constants.TRADE_REQUEST_TIMEOUT
	remotes.TradeRequestReceived:FireClient(target, player.UserId, player.DisplayName)
	return true
end

function TradeService.Accept(player, fromUserId)
	local pending = pendingRequests[player.UserId]
	local expiry = pending and pending[fromUserId]
	if not expiry or expiry < now() then return false, "That trade request expired." end
	pending[fromUserId] = nil

	if sessions[player.UserId] or sessions[fromUserId] then
		return false, "One of you is already trading."
	end
	local other = Players:GetPlayerByUserId(fromUserId)
	if not other then return false, "That player has left." end

	local session = {
		a = fromUserId, b = player.UserId,
		offerA = {}, offerB = {},
		acceptA = false, acceptB = false,
		locked = false,
	}
	sessions[session.a] = session
	sessions[session.b] = session
	pushState(session)
	return true
end

-- Adds or removes a critter from the caller's offer.
function TradeService.ToggleOffer(player, uid)
	local session = sessions[player.UserId]
	if not session then return false, "You're not in a trade." end
	if session.locked then return false, "Offer is locked -- confirm or cancel." end

	local isA = (player.UserId == session.a)
	local offer = isA and session.offerA or session.offerB

	-- Already offered? Remove it.
	for i, entry in ipairs(offer) do
		if entry.uid == uid then
			table.remove(offer, i)
			invalidateAcceptance(session)
			pushState(session)
			return true
		end
	end

	if #offer >= Constants.TRADE_MAX_ITEMS then
		return false, "That's the maximum items per trade."
	end

	-- Validate ownership and that the critter isn't locked. Locked critters are exactly
	-- the ones a player marked "never remove" -- honouring that here matters more than
	-- in eviction, since a trade is irreversible.
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "No profile." end
	local found
	for _, rec in ipairs(profile.ownedCritters) do
		if rec.uid == uid then found = rec break end
	end
	if not found then return false, "You don't own that critter." end
	if found.locked then return false, "That critter is locked. Unlock it to trade." end

	table.insert(offer, {
		uid = found.uid, species = found.species, rarity = found.rarity,
		variant = found.variant or "Normal", isShiny = found.isShiny or false,
		sparksPerSecond = found.sparksPerSecond or 0,
	})
	invalidateAcceptance(session)
	pushState(session)
	return true
end

function TradeService.SetAccepted(player, accepted)
	local session = sessions[player.UserId]
	if not session then return false, "You're not in a trade." end
	if session.locked then return false, "Offer is locked." end

	if player.UserId == session.a then session.acceptA = accepted and true or false
	else session.acceptB = accepted and true or false end

	if session.acceptA and session.acceptB then
		-- Both accepted: LOCK and start the confirmation window. Nothing can change
		-- during this period, and the client re-displays both offers.
		session.locked = true
		session.lockUntil = now() + Constants.TRADE_CONFIRM_LOCK_SECONDS
		pushState(session)
		task.delay(Constants.TRADE_CONFIRM_LOCK_SECONDS, function()
			-- Session may have ended during the window (someone left/cancelled).
			if sessions[session.a] ~= session then return end
			TradeService.Execute(session)
		end)
	else
		pushState(session)
	end
	return true
end

-- Atomic execution. Everything is validated and assembled BEFORE any profile changes,
-- so a failure at any point leaves both players exactly as they were.
function TradeService.Execute(session)
	local pa, pb = bothPlayers(session)
	if not pa or not pb then
		endSession(session, "Trade cancelled -- a player left.")
		return
	end

	local profA, profB = PlayerDataService.Get(pa), PlayerDataService.Get(pb)
	if not profA or not profB then
		endSession(session, "Trade failed. Nothing was exchanged.")
		return
	end

	-- Re-validate EVERY item as still owned and still unlocked. State can have changed
	-- since the offer was made (eviction, fusion, a lock toggle).
	local function collect(profile, offer)
		local records = {}
		for _, entry in ipairs(offer) do
			local found
			for _, rec in ipairs(profile.ownedCritters) do
				if rec.uid == entry.uid then found = rec break end
			end
			if not found or found.locked then return nil end
			records[#records + 1] = found
		end
		return records
	end

	local recsA = collect(profA, session.offerA)
	local recsB = collect(profB, session.offerB)
	if not recsA or not recsB then
		endSession(session, "Trade failed -- an item is no longer available. Nothing was exchanged.")
		return
	end

	-- Point of no return. Remove both sides first, then add, so a uid can never exist
	-- in two profiles simultaneously even for an instant.
	for _, rec in ipairs(recsA) do
		CritterService.RemoveCritter(rec.uid)
		PlayerDataService.RemoveOwnedCritter(pa, rec.uid)
	end
	for _, rec in ipairs(recsB) do
		CritterService.RemoveCritter(rec.uid)
		PlayerDataService.RemoveOwnedCritter(pb, rec.uid)
	end
	for _, rec in ipairs(recsA) do
		PlayerDataService.AddOwnedCritter(pb, rec)
	end
	for _, rec in ipairs(recsB) do
		PlayerDataService.AddOwnedCritter(pa, rec)
	end

	AnalyticsService.LogRewardEarned(pa, 0, profA.sparks, "TradeCompleted")
	AnalyticsService.LogRewardEarned(pb, 0, profB.sparks, "TradeCompleted")

	sessions[session.a] = nil
	sessions[session.b] = nil
	remotes.TradeCompleted:FireClient(pa, #recsB, #recsA)
	remotes.TradeCompleted:FireClient(pb, #recsA, #recsB)
end

function TradeService.Init()
	remotes.RequestTrade.OnServerEvent:Connect(function(player, targetUserId)
		local ok, err = TradeService.Request(player, targetUserId)
		if not ok then remotes.TradeEnded:FireClient(player, err) end
	end)

	remotes.RequestTradeAccept.OnServerEvent:Connect(function(player, fromUserId)
		if typeof(fromUserId) ~= "number" then return end
		local ok, err = TradeService.Accept(player, fromUserId)
		if not ok then remotes.TradeEnded:FireClient(player, err) end
	end)

	remotes.RequestTradeOffer.OnServerEvent:Connect(function(player, uid)
		if typeof(uid) ~= "string" then return end
		local ok, err = TradeService.ToggleOffer(player, uid)
		if not ok then remotes.TradeError:FireClient(player, err) end
	end)

	remotes.RequestTradeSetAccept.OnServerEvent:Connect(function(player, accepted)
		if typeof(accepted) ~= "boolean" then return end
		local ok, err = TradeService.SetAccepted(player, accepted)
		if not ok then remotes.TradeError:FireClient(player, err) end
	end)

	remotes.RequestTradeCancel.OnServerEvent:Connect(function(player)
		TradeService.Cancel(player, "Trade cancelled.")
	end)

	Players.PlayerRemoving:Connect(function(player)
		TradeService.Cancel(player, "Trade cancelled -- a player left.")
		pendingRequests[player.UserId] = nil
		for _, pending in pairs(pendingRequests) do
			pending[player.UserId] = nil
		end
	end)

	-- Distance sweep: walking away cancels. Keeps trading face-to-face and prevents a
	-- session lingering forever if someone wanders off mid-trade.
	task.spawn(function()
		while true do
			task.wait(3)
			local seen = {}
			for _, session in pairs(sessions) do
				if not seen[session] then
					seen[session] = true
					local pa, pb = bothPlayers(session)
					local ca = pa and pa.Character and pa.Character:FindFirstChild("HumanoidRootPart")
					local cb = pb and pb.Character and pb.Character:FindFirstChild("HumanoidRootPart")
					if not ca or not cb then
						endSession(session, "Trade cancelled -- a player left.")
					elseif (ca.Position - cb.Position).Magnitude > Constants.TRADE_MAX_DISTANCE then
						endSession(session, "Trade cancelled -- you moved too far apart.")
					end
				end
			end
		end
	end)
end

return TradeService
