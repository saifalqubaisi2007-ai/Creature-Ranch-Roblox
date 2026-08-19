--[[
	HatcheryController.server.lua
	Builds the Hatchery egg stands — ONE pedestal per rarity, each with its own single
	ProximityPrompt — and wires them at runtime so the connections exist in live servers.
	(The old approach stacked 5 prompts on one part and wired them from the editor
	command bar, which meant the connections never existed in an actual game session.)
]]

local RS = game:GetService("ReplicatedStorage")
local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local HatchLogic = require(script.Parent.Services.HatchLogic)

local hatchery = workspace.World.Landmarks.Hatchery
local counter = hatchery:FindFirstChild("HatchCounter")

-- Remove the old stacked prompts — replaced entirely by the stands below
if counter then
	for _, inst in ipairs(counter:GetChildren()) do
		if inst:IsA("ProximityPrompt") then inst:Destroy() end
	end
end

local oldStands = hatchery:FindFirstChild("EggStands")
if oldStands then oldStands:Destroy() end
local standsFolder = Instance.new("Folder")
standsFolder.Name = "EggStands"
standsFolder.Parent = hatchery

local hatcheryOrigin = Vector3.new(0, 7, -24)

-- Arc of stands on the plaza-facing side of the Hatchery, spaced ~7 studs apart
local PURCHASABLE = {}
for _, tier in ipairs(Constants.RARITIES) do
	if tier.cost > 0 then table.insert(PURCHASABLE, tier) end
end

local function buildStand(position, labelText, subText, eggColor, promptAction, promptObject, onTriggered)
	local stand = Instance.new("Model")
	stand.Parent = standsFolder

	local pedestal = Instance.new("Part")
	pedestal.Name = "Pedestal"
	pedestal.Shape = Enum.PartType.Cylinder
	pedestal.Size = Vector3.new(3, 4.5, 4.5)
	pedestal.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	pedestal.Anchored = true
	pedestal.Material = Enum.Material.Marble
	pedestal.Color = Color3.fromRGB(240, 232, 215)
	pedestal.Parent = stand

	local egg = Instance.new("Part")
	egg.Name = "Egg"
	egg.Shape = Enum.PartType.Ball
	egg.Size = Vector3.new(2.6, 3.3, 2.6)
	egg.CFrame = CFrame.new(position + Vector3.new(0, 3.2, 0))
	egg.Anchored = true
	egg.CanCollide = false
	egg.Material = Enum.Material.SmoothPlastic
	egg.Color = eggColor
	egg.Parent = stand

	local glow = Instance.new("PointLight")
	glow.Color = eggColor
	glow.Range = 8
	glow.Brightness = 1.2
	glow.Parent = egg

	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.new(0, 150, 0, 56)
	tag.StudsOffset = Vector3.new(0, 3, 0)
	tag.AlwaysOnTop = false
	tag.Parent = egg

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
	nameLabel.Text = labelText
	nameLabel.TextColor3 = eggColor
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.TextScaled = true
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.Parent = tag

	local priceLabel = Instance.new("TextLabel")
	priceLabel.BackgroundTransparency = 1
	priceLabel.Size = UDim2.new(1, 0, 0.45, 0)
	priceLabel.Position = UDim2.new(0, 0, 0.55, 0)
	priceLabel.Text = subText
	priceLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	priceLabel.Font = Enum.Font.GothamMedium
	priceLabel.TextScaled = true
	priceLabel.TextStrokeTransparency = 0.3
	priceLabel.Parent = tag

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = promptAction
	prompt.ObjectText = promptObject
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 7 -- tight: stands are ~7 apart, so only the nearest shows
	prompt.RequiresLineOfSight = false
	prompt.Parent = egg
	prompt.Triggered:Connect(onTriggered)

	return stand
end

-- Layout constants. Previously defined by the five-egg loop that lived here; the
-- themed egg replaced that loop, but the slot and rebirth stands below still position
-- themselves relative to these.
local spacing = 7.5
local startX = 0

-- Themed egg stand. ONE egg per world rolling across every rarity by weight, rather
-- than five separate rarity eggs. This is what makes a world memorable ("I got the
-- Leviathan from the Beach Egg") and restores genuine hatch randomness -- which in turn
-- makes the posted odds table meaningful instead of a formality.
do
	local world = WorldsData.GetWorld(WorldsData.DEFAULT_WORLD_ID)
	local themed = world.themedEgg
	local pos = hatcheryOrigin + Vector3.new(0, -1.5, 11)
	local stand = buildStand(
		pos,
		themed.name,
		Constants.FormatNumber(themed.cost) .. " \u{2728}",
		Color3.fromRGB(255, 215, 120),
		"Hatch",
		themed.name,
		function(player)
			HatchLogic.PerformThemedHatch(player, WorldsData.DEFAULT_WORLD_ID)
		end
	)

	local egg = stand and stand:FindFirstChild("Egg")



	if egg then
		-- Full odds table. Now genuinely meaningful: the egg really does roll across
		-- all five rarities, so these percentages describe a real gamble.
		local tag = egg:FindFirstChildOfClass("BillboardGui")
		if tag then
			tag.Size = UDim2.new(0, 190, 0, 132)
			for _, lbl in ipairs(tag:GetChildren()) do
				if lbl:IsA("TextLabel") then
					lbl.Size = UDim2.new(1, 0, 0.17, 0)
					lbl.Position = UDim2.new(0, 0, lbl.Position.Y.Scale * 0.34, 0)
				end
			end
			local totalWeight = 0
			for _, t in ipairs(world.rarities) do totalWeight += (t.weight or 0) end
			local y = 0.34
			for _, t in ipairs(world.rarities) do
				local row = Instance.new("TextLabel")
				row.Name = "Odds_" .. t.id
				row.BackgroundTransparency = 1
				row.Size = UDim2.new(1, 0, 0.132, 0)
				row.Position = UDim2.new(0, 0, y, 0)
				row.Text = string.format("%s  %.1f%%", t.id, (t.weight / totalWeight) * 100)
				row.TextColor3 = t.auraColor
				row.Font = Enum.Font.GothamMedium
				row.TextScaled = true
				row.TextStrokeTransparency = 0.4
				row.Parent = tag
				y = y + 0.132
			end
			local shinyRow = Instance.new("TextLabel")
			shinyRow.Name = "ShinyOddsLabel"
			shinyRow.BackgroundTransparency = 1
			shinyRow.Size = UDim2.new(1, 0, 0.132, 0)
			shinyRow.Position = UDim2.new(0, 0, y, 0)
			shinyRow.Text = string.format("\u{2728} Shiny: %.1f%%", Constants.SHINY_CHANCE * 100)
			shinyRow.TextColor3 = Color3.fromRGB(255, 220, 120)
			shinyRow.Font = Enum.Font.GothamMedium
			shinyRow.TextScaled = true
			shinyRow.TextStrokeTransparency = 0.4
			shinyRow.Parent = tag
		end

		local keys = { [3] = Enum.KeyCode.F, [8] = Enum.KeyCode.G, [25] = Enum.KeyCode.H }
		for _, count in ipairs(Constants.MULTI_HATCH_TIERS) do
			if count > 1 then
				local p = Instance.new("ProximityPrompt")
				p.Name = "MultiHatch_x" .. count
				p.ActionText = "Hatch x" .. count
				p.ObjectText = string.format("%s (%s \u{2728})", themed.name,
					Constants.FormatNumber(themed.cost * count))
				p.KeyboardKeyCode = keys[count] or Enum.KeyCode.F
				p.HoldDuration = 0.25
				p.MaxActivationDistance = 7
				p.RequiresLineOfSight = false
				p.Parent = egg
				p.Triggered:Connect(function(player)
					for _ = 1, count do
						HatchLogic.PerformThemedHatch(player, WorldsData.DEFAULT_WORLD_ID)
					end
				end)
			end
		end
	end
end

-- Slot stand: off to the side
buildStand(
	hatcheryOrigin + Vector3.new(startX - spacing, -1.5, 11),
	"Extra Slot",
	"Own 2 Critters",
	Color3.fromRGB(140, 220, 160),
	"Buy Slot",
	"Critter Slot",
	function(player)
		HatchLogic.PerformBuySlot(player)
	end
)

print("[HatcheryController] " .. (#PURCHASABLE + 1) .. " egg stands built and wired")
