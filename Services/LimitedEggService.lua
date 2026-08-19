--[[
	LimitedEggService.lua
	Weekly-rotating Limited Egg: exclusive species that never return once the week ends.
	The strongest Day-7 retention lever available -- urgency that permanent content
	can't replicate.

	Deliberately does NOT go through WorldsData: limited species must never appear in
	the normal world species pools (they'd stop being exclusive), and the egg has no
	gate/zone/unlock of its own. It builds a single physical stand near the main
	Hatchery and hatches through its own path.
]]

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Constants = require(RS.CritterRush.Modules.Constants)
local PlayerDataService = require(script.Parent.PlayerDataService)
local CritterService = require(script.Parent.CritterService)
local QuestService = require(script.Parent.QuestService)
local AnalyticsService = require(script.Parent.AnalyticsService)
local HatchLogic = require(script.Parent.HatchLogic)

local remotes = RS.CritterRush.Remotes

local LimitedEggService = {}

-- Hatches one Limited Egg. Mirrors HatchLogic.PerformHatch's guard order deliberately
-- (charge -> evict -> spawn -> refund on failure) so it can't drift into a different
-- set of rules than the main hatch path.
function LimitedEggService.PerformLimitedHatch(player)
	local profile = PlayerDataService.Get(player)
	if not profile then return false, "NoProfile" end

	local rotation = Constants.GetCurrentLimitedEgg()
	if not rotation then return false, "NoRotation" end

	local cost = Constants.LIMITED_EGG_COST
	-- Day 7 login-streak tokens grant a FREE limited hatch. Consumed before charging
	-- Sparks, and tracked separately so a refund on a later failure returns the token
	-- rather than wrongly paying out Sparks the player never spent.
	local usedToken = false
	if (profile.limitedEggTokens or 0) > 0 then
		profile.limitedEggTokens -= 1
		usedToken = true
	elseif not PlayerDataService.TrySpendSparks(player, cost) then
		remotes.HatchDenied:FireClient(player, "Not enough Sparks for the Limited Egg!")
		return false, "InsufficientSparks"
	end

	-- Single refund path used by every failure below, so a token-funded hatch can never
	-- silently convert into Sparks.
	local function refund()
		if usedToken then
			profile.limitedEggTokens = (profile.limitedEggTokens or 0) + 1
		else
			PlayerDataService.AddSparks(player, cost)
		end
	end

	-- Slot-cap eviction, same locked-critter protection as the normal hatch path.
	local maxSlots = PlayerDataService.GetMaxSlots(player, profile)
	if #profile.ownedCritters >= maxSlots then
		local oldest = PlayerDataService.FindEvictionTarget(player)
		if not oldest then
			refund()
			remotes.HatchDenied:FireClient(player, "All your Critter slots are locked!")
			return false, "AllLocked"
		end
		CritterService.RemoveCritter(oldest.uid)
		PlayerDataService.RemoveOwnedCritter(player, oldest.uid)
	end

	local species = rotation.species[math.random(1, #rotation.species)]
	-- Synthetic tier: limited creatures aren't part of any world's rarity table, so
	-- the tier is constructed here from the rotation's own stats.
	local tier = {
		id = "Limited",
		sparksPerSecond = rotation.sparksPerSecond,
		sizeScale = 1.4,
		auraColor = rotation.auraColor,
		cost = cost,
		serverAnnounce = true,
	}

	local record = CritterService.SpawnForPlayer(player, tier, species, Constants.LIMITED_WORLD_ID or "Limited")
	if not record then
		refund() -- covers both the Sparks and token-funded cases
		return false, "SpawnFailed"
	end

	remotes.SparksUpdated:FireClient(player, PlayerDataService.Get(player).sparks)
	remotes.HatchResult:FireClient(player, true, "Limited", species, record.uid, record.isShiny, record.personality)
	HatchLogic.SyncSlotAttributes(player)
	QuestService.ReportProgress(player, "hatch", 1)
	AnalyticsService.LogHatchPurchase(player, cost, PlayerDataService.Get(player).sparks, "Limited", rotation.id)

	remotes.ServerAnnouncement:FireAllClients(string.format(
		"\u{1F31F} %s hatched a LIMITED %s!", player.DisplayName:upper(), species))

	return true, species
end

function LimitedEggService.Init()
	local rotation = Constants.GetCurrentLimitedEgg()
	if not rotation then
		warn("[LimitedEggService] no rotation resolved -- limited egg not built")
		return
	end

	local folder = workspace:FindFirstChild("LimitedEgg")
	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = "LimitedEgg"
	folder.Parent = workspace

	-- Positioned beside the main Hatchery plaza so players encounter it naturally.
	-- Y=13 puts the egg comfortably above this area's real terrain height (confirmed
	-- via raycast at Y=9) -- an earlier Y=4.5 buried the whole stand inside the ground.
	local pos = Vector3.new(-22, 13, 11)

	local pedestal = Instance.new("Part")
	pedestal.Name = "LimitedPedestal"
	pedestal.Size = Vector3.new(6, 1, 6)
	pedestal.Position = pos - Vector3.new(0, 2.5, 0)
	pedestal.Anchored = true
	pedestal.Material = Enum.Material.Marble
	pedestal.Color = Color3.fromRGB(60, 55, 80)
	pedestal.Parent = folder

	local egg = Instance.new("Part")
	egg.Name = "Egg"
	egg.Shape = Enum.PartType.Ball
	egg.Size = Vector3.new(4.5, 5.5, 4.5)
	egg.Position = pos
	egg.Anchored = true
	egg.CanCollide = false
	egg.Material = Enum.Material.Neon
	egg.Color = rotation.auraColor
	egg.Parent = folder

	local light = Instance.new("PointLight")
	light.Color = rotation.auraColor
	light.Range = 18
	light.Brightness = 3
	light.Parent = egg

	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(rotation.auraColor)
	sparkle.Rate = 20
	sparkle.Lifetime = NumberRange.new(0.6, 1.2)
	sparkle.Speed = NumberRange.new(0.5, 1.5)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.LightEmission = 1
	sparkle.Parent = egg

	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.new(0, 260, 0, 90)
	tag.StudsOffset = Vector3.new(0, 4.5, 0)
	tag.AlwaysOnTop = true
	tag.Parent = egg

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.36, 0)
	title.Text = "\u{2B50} LIMITED: " .. rotation.displayName
	title.TextColor3 = rotation.auraColor
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextStrokeTransparency = 0.3
	title.Parent = tag

	local priceLabel = Instance.new("TextLabel")
	priceLabel.BackgroundTransparency = 1
	priceLabel.Size = UDim2.new(1, 0, 0.3, 0)
	priceLabel.Position = UDim2.new(0, 0, 0.36, 0)
	priceLabel.Text = Constants.FormatNumber(Constants.LIMITED_EGG_COST) .. " \u{2728}"
	priceLabel.TextColor3 = Color3.new(1, 1, 1)
	priceLabel.Font = Enum.Font.GothamMedium
	priceLabel.TextScaled = true
	priceLabel.TextStrokeTransparency = 0.3
	priceLabel.Parent = tag

	local timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "TimerLabel"
	timerLabel.BackgroundTransparency = 1
	timerLabel.Size = UDim2.new(1, 0, 0.3, 0)
	timerLabel.Position = UDim2.new(0, 0, 0.68, 0)
	timerLabel.TextColor3 = Color3.fromRGB(255, 170, 170)
	timerLabel.Font = Enum.Font.GothamMedium
	timerLabel.TextScaled = true
	timerLabel.TextStrokeTransparency = 0.3
	timerLabel.Parent = tag

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Hatch Limited"
	prompt.ObjectText = rotation.displayName
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = egg
	prompt.Triggered:Connect(function(player)
		LimitedEggService.PerformLimitedHatch(player)
	end)

	-- Live countdown so the urgency is visible, not just implied.
	task.spawn(function()
		while folder.Parent do
			local _, remaining = Constants.GetCurrentLimitedEgg()
			local d = math.floor(remaining / 86400)
			local h = math.floor((remaining % 86400) / 3600)
			local m = math.floor((remaining % 3600) / 60)
			if d > 0 then
				timerLabel.Text = string.format("Gone in %dd %dh", d, h)
			else
				timerLabel.Text = string.format("Gone in %dh %dm", h, m)
			end
			task.wait(30)
		end
	end)

	print("[LimitedEggService] " .. rotation.displayName .. " active (" .. #rotation.species .. " exclusive species)")
end

return LimitedEggService
