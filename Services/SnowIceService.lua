--[[
	SnowIceService.lua
	World identity mechanic (item #7: "Snow: Slippery ice"): sets genuinely low
	CustomPhysicalProperties friction on the Snow zone's ground platform, so players
	standing/moving on it actually SLIDE -- real physics, not a scripted fake-slide.
	Deliberately a persistent environmental trait rather than a periodic event (unlike
	Forest/Beach/Desert), since "the ground itself behaves differently here" is its own
	distinct kind of world identity, not a fourth reskin of "catch/find/survive".
]]

local RS = game:GetService("ReplicatedStorage")

local SnowIceService = {}

-- Very low friction, weighted heavily so it dominates the Roblox friction-combination
-- formula regardless of whatever friction a player's own character parts have.
local ICE_FRICTION = 0.02
local ICE_FRICTION_WEIGHT = 100
local ICE_ELASTICITY = 0.05
local ICE_ELASTICITY_WEIGHT = 50

function SnowIceService.Init()
	-- Runs AFTER ZoneHatcheryService.Init() builds the ground -- must find a real,
	-- already-existing part, not create one itself (ground ownership stays with
	-- ZoneHatcheryService; this only modifies its physical properties).
	local zoneHatcheriesFolder = workspace:FindFirstChild("ZoneHatcheries")
	local ground = zoneHatcheriesFolder and zoneHatcheriesFolder:FindFirstChild("Ground_Snow")
	if not ground then
		warn("[SnowIceService] Ground_Snow not found -- ice mechanic not applied")
		return
	end
	ground.CustomPhysicalProperties = PhysicalProperties.new(
		ground.CustomPhysicalProperties and ground.CustomPhysicalProperties.Density or 1,
		ICE_FRICTION, ICE_ELASTICITY, ICE_FRICTION_WEIGHT, ICE_ELASTICITY_WEIGHT
	)
end

return SnowIceService
