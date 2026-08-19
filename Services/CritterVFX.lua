--[[
	CritterVFX.lua
	Particle language for CREATURE RANCH:
	  green sparkle = a Critter passively earning Sparks (the only state now -- the old
	  red/blue "stolen"/"loose" states were removed along with the steal mechanic)
	  gold burst = one-shot on hatch/rarity moments
	Server-side so effects replicate to everyone.
]]

local Players = game:GetService("Players")

local CritterVFX = {}

local STATE_COLORS = {
	Following = ColorSequence.new(Color3.fromRGB(120, 255, 140)),
}

local STATE_RATES = {
	Following = 2,
}

-- Creates (or reuses) the single state ParticleEmitter on a critter model
local function getEmitter(model)
	local root = model.PrimaryPart
	if not root then return nil end
	local emitter = root:FindFirstChild("StateParticles")
	if emitter then return emitter end

	emitter = Instance.new("ParticleEmitter")
	emitter.Name = "StateParticles"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Lifetime = NumberRange.new(0.6, 1.1)
	emitter.Speed = NumberRange.new(0.5, 1.5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.LightEmission = 0.7
	emitter.Parent = root
	return emitter
end

function CritterVFX.ApplyStateEffect(model, stateName)
	local emitter = getEmitter(model)
	if not emitter then return end
	emitter.Color = STATE_COLORS[stateName] or STATE_COLORS.Following
	emitter.Rate = STATE_RATES[stateName] or 2
	emitter.Enabled = true
end

-- VIP Sparkle Trail (gamepass cosmetic): persistent premium gold-white trail
-- distinct from the state particles — richer, denser, clearly "bought".
function CritterVFX.ApplyVipTrail(model)
	local root = model.PrimaryPart
	if not root then return end
	if root:FindFirstChild("VipTrail") then return end -- idempotent

	local trail = Instance.new("ParticleEmitter")
	trail.Name = "VipTrail"
	trail.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 230, 140)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 200, 90)),
	})
	trail.Rate = 10
	trail.Lifetime = NumberRange.new(0.8, 1.4)
	trail.Speed = NumberRange.new(0.3, 1)
	trail.SpreadAngle = Vector2.new(180, 180)
	trail.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.LightEmission = 1
	trail.Parent = root
end

-- Shiny aura: persistent rainbow-tinted sparkle, distinct from both the state
-- particles and the VIP trail, so a shiny always reads as shiny regardless of state.
function CritterVFX.ApplyShinyAura(model)
	local root = model.PrimaryPart
	if not root then return end
	if root:FindFirstChild("ShinyAura") then return end

	local aura = Instance.new("ParticleEmitter")
	aura.Name = "ShinyAura"
	aura.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	aura.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 120, 200)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 255, 140)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 200, 255)),
	})
	aura.Rate = 16
	aura.Lifetime = NumberRange.new(0.6, 1.0)
	aura.Speed = NumberRange.new(1, 2)
	aura.SpreadAngle = Vector2.new(180, 180)
	aura.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	aura.LightEmission = 1
	aura.Parent = root

	local light = Instance.new("PointLight")
	light.Name = "ShinyLight"
	light.Color = Color3.fromRGB(255, 220, 255)
	light.Range = 14
	light.Brightness = 2
	light.Parent = root
end

-- Rebirth aura: a steady colored ring particle keyed to the owner's rebirth tier —
-- visible prestige status, readable from a distance, distinct from shiny/VIP effects.
function CritterVFX.ApplyRebirthAura(model, color)
	local root = model.PrimaryPart
	if not root then return end
	local existing = root:FindFirstChild("RebirthAura")
	if existing then existing:Destroy() end

	local aura = Instance.new("ParticleEmitter")
	aura.Name = "RebirthAura"
	aura.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	aura.Color = ColorSequence.new(color)
	aura.Rate = 6
	aura.Lifetime = NumberRange.new(1.0, 1.6)
	aura.Speed = NumberRange.new(0.2, 0.5)
	aura.SpreadAngle = Vector2.new(180, 180)
	aura.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.9),
		NumberSequenceKeypoint.new(1, 0.3),
	})
	aura.LightEmission = 0.6
	aura.Parent = root
end

-- One-shot gold burst for hatch / celebration moments
function CritterVFX.PlayGoldBurst(model)
	local root = model.PrimaryPart
	if not root then return end
	local burst = Instance.new("ParticleEmitter")
	burst.Name = "GoldBurst"
	burst.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burst.Color = ColorSequence.new(Color3.fromRGB(255, 210, 80))
	burst.Lifetime = NumberRange.new(0.5, 1.0)
	burst.Speed = NumberRange.new(4, 9)
	burst.SpreadAngle = Vector2.new(180, 180)
	burst.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	burst.LightEmission = 1
	burst.Rate = 0
	burst.Parent = root
	burst:Emit(40)
	task.delay(2, function()
		if burst.Parent then burst:Destroy() end
	end)
end

-- ===== VFX culling =====
-- Every critter carries several effects (StateParticles, ShinyAura, ShinyLight,
-- RebirthAura, VipTrail, plus the rarity glow/sparkle/beam). With a large collection
-- that compounds fast: measured live at 83 owned critters, 38 PointLights and 286
-- ParticleEmitters were active at once and the CLIENT HIT SCRIPT TIMEOUTS. Roblox's
-- practical ceiling for dynamic lights is well under 20.
--
-- Culling by DISTANCE rather than a global count, because a count can't decide WHICH
-- critters matter -- and the ones that matter are the ones you can see. Effects on the
-- nearest few stay on; everything further away is disabled (not destroyed, so it comes
-- straight back when the player walks over).
--
-- Runs on a slow sweep rather than per-frame: this is visibility housekeeping, not
-- gameplay, and at 2s the pop-in is unnoticeable while the cost is negligible.
local VFX_LIGHT_RADIUS = 60      -- lights are the expensive one, so the tightest radius
local VFX_PARTICLE_RADIUS = 120
local VFX_MAX_LIGHTS = 10
local VFX_MAX_PARTICLE_CRITTERS = 12  -- critters allowed to keep emitters, nearest first        -- hard ceiling even inside the radius
local CULL_INTERVAL = 2

function CritterVFX.StartCulling(getCritterModels)
	task.spawn(function()
		while true do
			task.wait(CULL_INTERVAL)
			local ok, err = pcall(function()
				local players = Players:GetPlayers()
				if #players == 0 then return end

				-- Distance to the NEAREST player, so a critter visible to anyone stays
				-- lit rather than only mattering to its owner.
				local models = getCritterModels()
				local scored = {}
				for _, model in ipairs(models) do
					local root = model.PrimaryPart
					if root then
						local best = math.huge
						for _, plr in ipairs(players) do
							local char = plr.Character
							local hrp = char and char:FindFirstChild("HumanoidRootPart")
							if hrp then
								local d = (hrp.Position - root.Position).Magnitude
								if d < best then best = d end
							end
						end
						scored[#scored + 1] = { model = model, dist = best }
					end
				end
				table.sort(scored, function(a, b) return a.dist < b.dist end)

				-- COUNT caps, not just radius. Critters all FOLLOW their owner, so they
				-- sit 6-23 studs away regardless of how many you own -- measured live.
				-- Distance alone therefore can't discriminate between 5 critters and 83;
				-- the nearest-first ordering above decides WHICH ones keep effects, and
				-- these counts decide HOW MANY.
				local lightsOn, particlesOn = 0, 0
				for _, entry in ipairs(scored) do
					local wantLight = entry.dist <= VFX_LIGHT_RADIUS and lightsOn < VFX_MAX_LIGHTS
					local wantParticles = entry.dist <= VFX_PARTICLE_RADIUS
						and particlesOn < VFX_MAX_PARTICLE_CRITTERS
					local usedLight = false
					for _, d in ipairs(entry.model:GetDescendants()) do
						if d:IsA("PointLight") then
							d.Enabled = wantLight
							if wantLight then usedLight = true end
						elseif d:IsA("ParticleEmitter") then
							d.Enabled = wantParticles
						end
					end
					if usedLight then lightsOn += 1 end
					if wantParticles then particlesOn += 1 end
				end
			end)
			if not ok then warn("[CritterVFX] cull failed:", err) end
		end
	end)
end

return CritterVFX
