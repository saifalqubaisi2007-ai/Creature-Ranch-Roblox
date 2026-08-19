--[[
	TelemetryService.lua
	Captures runtime errors so a live problem is discoverable rather than invisible.

	Without this, a script error in production is seen only by whichever player hit it --
	the developer has no signal at all. This hooks ScriptContext.Error (server) and
	relays client errors over a remote, then aggregates.

	Deliberate choices:
	 * DEDUPLICATED by message+script. One broken loop can throw thousands of times a
	   minute; logging each occurrence would bury every other error and hammer the
	   DataStore. We keep a count instead.
	 * RATE LIMITED per error signature, so a hot loop can't drown the buffer.
	 * Flushed on a timer AND on shutdown via BindToClose, so errors from the final
	   moments of a server's life aren't lost.
	 * Never throws. Every path is pcall-wrapped -- an error reporter that itself errors
	   is worse than none, because it destroys the signal it was meant to preserve.
]]

local DataStoreService = game:GetService("DataStoreService")
local ScriptContext = game:GetService("ScriptContext")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")

local TelemetryService = {}

local FLUSH_INTERVAL = 60
local MAX_SIGNATURES = 200      -- cap distinct errors held in memory
local MAX_PER_SIGNATURE = 50    -- stop counting past this; the count is already damning
local MAX_MESSAGE_CHARS = 300

local store
pcall(function()
	store = DataStoreService:GetDataStore("SAC_ErrorLog")
end)

-- [signature] = { message, source, trace, count, firstAt, lastAt, side }
local buffer = {}
local bufferCount = 0

-- Strips the "Script.Path:LINE:" prefix Roblox prepends to error messages before
-- building the signature. Without this, the SAME logical error thrown from two
-- different lines produces two entries -- verified live: two identical errors at
-- Main:737 and Main:739 failed to dedupe. Grouping by message text is what makes the
-- count meaningful.
local function signatureFor(message, source)
	local msg = tostring(message or "?")
	msg = msg:gsub("^.-:%d+:%s*", "")
	return (tostring(source) or "?") .. "|" .. msg:sub(1, 120)
end

function TelemetryService.Report(side, message, trace, source, playerName)
	-- Never let the reporter itself break the game.
	local ok = pcall(function()
		message = tostring(message or "unknown"):sub(1, MAX_MESSAGE_CHARS)
		trace = tostring(trace or ""):sub(1, MAX_MESSAGE_CHARS)
		source = tostring(source or "?")

		local sig = signatureFor(message, source)
		local entry = buffer[sig]
		if entry then
			if entry.count < MAX_PER_SIGNATURE then
				entry.count += 1
			end
			entry.lastAt = os.time()
			return
		end

		-- New signature. Refuse past the cap rather than growing without bound.
		if bufferCount >= MAX_SIGNATURES then return end
		bufferCount += 1
		buffer[sig] = {
			side = side, message = message, trace = trace, source = source,
			count = 1, firstAt = os.time(), lastAt = os.time(),
			player = playerName,
		}
	end)
	return ok
end

-- Writes the buffer to the DataStore and clears it. Safe to call repeatedly.
function TelemetryService.Flush()
	if not store then return end
	if bufferCount == 0 then return end

	local snapshot = buffer
	buffer, bufferCount = {}, 0

	local payload = {}
	for _, e in pairs(snapshot) do
		payload[#payload + 1] = e
	end
	if #payload == 0 then return end

	-- Key by day + jobId so concurrent servers never collide on one key.
	local key = string.format("%d_%s", os.time() // 86400, tostring(game.JobId):sub(1, 12))
	pcall(function()
		store:UpdateAsync(key, function(old)
			old = old or {}
			for _, e in ipairs(payload) do
				old[#old + 1] = e
			end
			-- Bound the stored array; a single server shouldn't write unbounded data.
			while #old > 300 do table.remove(old, 1) end
			return old
		end)
	end)
end

function TelemetryService.Init()
	-- Server errors.
	ScriptContext.Error:Connect(function(message, trace, script)
		TelemetryService.Report("server", message, trace, script and script:GetFullName() or "?")
	end)

	-- Client errors, relayed over a remote. Rate limiting matters more here: the client
	-- is untrusted, so a modified client could spam this deliberately.
	local remote = RS.CritterRush.Remotes:FindFirstChild("ReportClientError")
	if remote then
		local lastReport = {} -- [userId] = os.clock()
		remote.OnServerEvent:Connect(function(player, message, trace, source)
			if typeof(message) ~= "string" then return end
			-- One report per player per second, max.
			local now = os.clock()
			if lastReport[player.UserId] and now - lastReport[player.UserId] < 1 then return end
			lastReport[player.UserId] = now
			TelemetryService.Report("client", message,
				typeof(trace) == "string" and trace or "",
				typeof(source) == "string" and source or "?",
				player.Name)
		end)
		Players.PlayerRemoving:Connect(function(player)
			lastReport[player.UserId] = nil
		end)
	end

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			pcall(TelemetryService.Flush)
		end
	end)

	-- Errors from a server's final seconds are the most valuable ones (they often
	-- explain WHY it shut down), so flush on close rather than losing the buffer.
	game:BindToClose(function()
		if RunService:IsStudio() then return end
		pcall(TelemetryService.Flush)
	end)

	print("[TelemetryService] error capture active")
end

-- Read-back for inspection: returns the current in-memory buffer.
function TelemetryService.GetBuffer()
	local out = {}
	for sig, e in pairs(buffer) do out[#out + 1] = { sig = sig, entry = e } end
	return out
end

return TelemetryService
