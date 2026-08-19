--[[
	ClientMain.lua
	CREATURE RANCH -- client HUD and hatch cinematic.
	Builds its own GUI tree at runtime (kept in one file so the whole presentation
	layer is easy to iterate on together). Presentation is the #1 priority per the GDD.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Constants = require(RS.CritterRush.Modules.Constants)
local WorldsData = require(RS.CritterRush.Modules.WorldsData)
local remotes = RS.CritterRush.Remotes

-- ===== Palette (consistent, saturated, premium — no default Roblox colors) =====
local PALETTE = {
	bg = Color3.fromRGB(24, 22, 36),
	card = Color3.fromRGB(38, 34, 56),
	accentGold = Color3.fromRGB(255, 196, 60),
	accentPink = Color3.fromRGB(255, 90, 140),
	accentBlue = Color3.fromRGB(90, 190, 255),
	textMain = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(200, 195, 215),
	danger = Color3.fromRGB(255, 90, 90),
	-- Semantic roles added during the consistency pass. An audit found 85 distinct
	-- colours across the client with 87 near-duplicate pairs -- the same MEANING drawn
	-- in slightly different shades depending on which panel it landed in (success green
	-- appeared as 140,255,160 / 120,255,140 / 160,255,160 / 150,235,150).
	-- These give each role one definition so drift can't reappear.
	success = Color3.fromRGB(140, 255, 160),
	successDim = Color3.fromRGB(110, 180, 110),
	warning = Color3.fromRGB(255, 200, 90),
	locked = Color3.fromRGB(120, 120, 130),
	panelInset = Color3.fromRGB(30, 27, 44),
	rowAlt = Color3.fromRGB(46, 42, 66),
}

local FONT_HEAVY = Enum.Font.FredokaOne
local FONT_BODY = Enum.Font.GothamMedium

-- ===== Sound design =====
-- Uses Roblox's built-in local sound assets (rbxasset://) so every stinger is guaranteed
-- to exist with zero network dependency — reliable now, easy to swap for bespoke SFX later.
local SFX = {
	HatchShake = "rbxasset://sounds/electronicpingshort.wav",
	HatchCrack = "rbxasset://sounds/snap.mp3",
	HatchFanfare = "rbxasset://sounds/button.wav",
	UiTick = "rbxasset://sounds/switch.wav",
	-- Design-review fix (MEDIUM #8): orb collection and quest completion previously had
	-- either no distinct audio identity (orbs reused the generic UiTick -- the same sound
	-- as a settings toggle) or, for quest completion, NO sound at all (a real regression:
	-- it referenced a "ReclaimFanfare" entry that got cleaned up as unused during the
	-- steal-mechanic removal, without anyone noticing this call site still needed it --
	-- caught while scoping this exact fix). Both reuse assets ALREADY CONFIRMED working
	-- elsewhere in this project rather than risk an unverified new rbxasset:// path,
	-- which is exactly the class of bug that caused the regression being fixed here.
	OrbPickup = "rbxasset://sounds/electronicpingshort.wav",
	QuestComplete = "rbxasset://sounds/action_get_up.mp3",
	-- Creature voices. Every path below was LOAD-TESTED before use (IsLoaded + non-zero
	-- TimeLength) rather than assumed -- 3 of the 7 candidates I tried silently failed
	-- to load, which is the same class of bug that caused the QuestComplete regression
	-- noted above.
	CritterChirp = "rbxasset://sounds/clickfast.wav",        -- 0.29s, small/light
	CritterCall = "rbxasset://sounds/uuhhh.mp3",             -- 0.33s, mid/vocal
	CritterRumble = "rbxasset://sounds/impact_water.mp3",    -- 2.38s, big/deep
}

-- ===== Accessibility settings (P22) — session-only (not saved to DataStore; resets
-- on rejoin). Declared before every system it gates so each capture is a live upvalue,
-- not a snapshot — changing a value here is felt immediately everywhere it's read. =====
local Settings = {
	cameraShake = true,
	motionReduction = false, -- hard-disables shake AND FOV punches (vestibular safety)
	sfxVolume = 1.0,
	musicVolume = 1.0,
	lowGraphics = false,
	uiScale = 1.0,
}

-- ===== Camera shake (lightweight, no springs needed at this scale) =====
local function shakeCamera(intensity, duration)
	if Settings.motionReduction or not Settings.cameraShake then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	local elapsed = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			conn:Disconnect()
			return
		end
		local falloff = 1 - (elapsed / duration)
		local offset = Vector3.new(
			(math.random() - 0.5) * 2 * intensity * falloff,
			(math.random() - 0.5) * 2 * intensity * falloff,
			0
		)
		camera.CFrame = camera.CFrame * CFrame.new(offset)
	end)
end

-- ===== Camera FOV punch-zoom (Phase 12/13 polish) =====
-- A quick zoom-in during buildup followed by a snappy release on impact reads as
-- "camera punch" without needing a true timescale/slowmo system (Roblox has none
-- natively) -- slowing the animation cadence itself does the "time feels heavier"
-- job instead, applied separately per-rarity where it's used.
local DEFAULT_FOV = workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView or 70
local function tweenFOV(targetFov, duration, style, direction)
	if Settings.motionReduction then return end -- FOV punches are a motion trigger too
	local camera = workspace.CurrentCamera
	if not camera then return end
	TweenService:Create(camera, TweenInfo.new(duration, style or Enum.EasingStyle.Sine, direction or Enum.EasingDirection.Out),
		{ FieldOfView = targetFov }):Play()
end
-- Resets the FOV instantly (no tween) -- used as a safety net so an interrupted
-- cinematic (e.g. a second hatch firing before the first finishes) can never leave
-- the camera stuck zoomed in.
local function resetFOV()
	local camera = workspace.CurrentCamera
	if camera then camera.FieldOfView = DEFAULT_FOV end
end

local function playSound(soundId, volume, pitch)
	if Settings.sfxVolume <= 0 then return nil end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Volume = (volume or 0.6) * Settings.sfxVolume
	s.PlaybackSpeed = pitch or 1
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function() s:Destroy() end)
	-- Safety cleanup in case Ended never fires (e.g. asset failed to load)
	task.delay(6, function()
		if s and s.Parent then s:Destroy() end
	end)
	return s
end

-- ===== Panel open/close animation =====
-- Nine panels snapped in and out with a bare `.Visible = not .Visible`. A panel that
-- appears instantly reads as a screenshot dropped over the game; a quick scale+fade
-- makes it feel like part of the same interface.
--
-- Implemented as a wrapper on the EXISTING Visible pattern rather than a rewrite of
-- nine call sites: setPanelOpen(panel, true/false) is a drop-in, and panels that were
-- never converted keep working exactly as before.
local panelTweenTokens = {}
local function setPanelOpen(panel, open)
	if not panel then return end
	-- Token guards against a fast open/close/open leaving the panel mid-animation or
	-- hidden after the player asked for it to be visible.
	panelTweenTokens[panel] = (panelTweenTokens[panel] or 0) + 1
	local myToken = panelTweenTokens[panel]

	local scale = panel:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = panel
	end

	if open then
		panel.Visible = true
		scale.Scale = 0.86
		-- Motion reduction: vestibular safety setting must suppress the scale pop too,
		-- not just camera shake -- a panel springing at the player is exactly the kind
		-- of motion that setting exists to prevent.
		if Settings.motionReduction then
			scale.Scale = 1
			return
		end
		TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back,
			Enum.EasingDirection.Out), { Scale = 1 }):Play()
	else
		-- NOTE: these two lines set .Visible DIRECTLY and must never be rewritten to call
		-- setPanelOpen -- a blanket "X.Visible = false -> setPanelOpen(X, false)" pass
		-- did exactly that and made this function call itself forever. Motion-reduction
		-- users would have hit a stack overflow on every panel close.
		if Settings.motionReduction then
			panel.Visible = false
			return
		end
		TweenService:Create(scale, TweenInfo.new(0.14, Enum.EasingStyle.Quad,
			Enum.EasingDirection.In), { Scale = 0.9 }):Play()
		task.delay(0.14, function()
			-- Only hide if no newer open/close happened while this one was animating.
			if panelTweenTokens[panel] == myToken then
				panel.Visible = false
				scale.Scale = 1
			end
		end)
	end
end

-- ===== Ambient background music (looping, with a dynamic "chase intensity" boost) =====
local BGM_BASE_VOLUME = 0.32
local function currentBgmBaseVolume() return BGM_BASE_VOLUME * Settings.musicVolume end
local bgmTemplate = RS.CritterRush.Assets:FindFirstChild("BGM_RetroRadiance")
local bgm
if bgmTemplate then
	bgm = bgmTemplate:Clone()
	bgm.Name = "AmbientBGM"
	bgm.Looped = true
	bgm.Volume = currentBgmBaseVolume()
	bgm.Parent = SoundService
	bgm:Play()
end

local bgmBoostToken = 0
local function boostBgmIntensity()
	if not bgm then return end
	bgmBoostToken += 1
	local myToken = bgmBoostToken
	TweenService:Create(bgm, TweenInfo.new(0.25), { Volume = currentBgmBaseVolume() * 1.6, PlaybackSpeed = 1.08 }):Play()
	task.delay(3, function()
		if myToken == bgmBoostToken and bgm and bgm.Parent then
			TweenService:Create(bgm, TweenInfo.new(1.2), { Volume = currentBgmBaseVolume(), PlaybackSpeed = 1 }):Play()
		end
	end)
end

-- ===== Per-world music colouring =====
-- There is exactly ONE music asset in the project, and I can't author or source new
-- ones. Rather than leave every world sounding identical, the single track is RE-VOICED
-- per world with pitch and EQ: Snow reads thin and airy, Volcano dark and heavy, Sky
-- bright and open. It's a real audible difference, but it is NOT a substitute for
-- actual per-world tracks -- that needs a composer or licensed music.
do
	local worldEq = Instance.new("EqualizerSoundEffect")
	worldEq.Name = "WorldEQ"
	worldEq.Parent = bgm or SoundService

	-- pitch, low gain, mid gain, high gain
	local WORLD_VOICING = {
		StarterMeadow = { 1.00,  0, 0,  0 },
		Forest        = { 0.97,  2, 0, -3 },
		Beach         = { 1.04,  0, 0,  3 },
		Desert        = { 0.94,  3, 2, -6 },
		Snow          = { 1.08, -6, 0,  5 },
		CrystalCaves  = { 0.90,  4, -2, 2 },
		Volcano       = { 0.86,  6, 0, -8 },
		SkyIslands    = { 1.12, -4, 0,  6 },
	}

	local currentVoicing = nil
	local function applyVoicing(worldId)
		if not bgm then return end
		if currentVoicing == worldId then return end
		currentVoicing = worldId
		local v = WORLD_VOICING[worldId] or WORLD_VOICING.StarterMeadow
		-- Interpolated manually rather than with TweenService: EqualizerSoundEffect
		-- gains SILENTLY IGNORE tweens -- verified live, a direct set to 6 works while
		-- a tween to 6 leaves the value at 0. PlaybackSpeed tweens fine, but is stepped
		-- here too so pitch and EQ stay in sync through the transition.
		local fromPitch = bgm.PlaybackSpeed
		local fromLow, fromMid, fromHigh = worldEq.LowGain, worldEq.MidGain, worldEq.HighGain
		task.spawn(function()
			local steps = 30
			for i = 1, steps do
				-- Bail if the world changed mid-transition, so two overlapping fades
				-- can't fight over the same values.
				if currentVoicing ~= worldId then return end
				local t = i / steps
				bgm.PlaybackSpeed = fromPitch + (v[1] - fromPitch) * t
				worldEq.LowGain = fromLow + (v[2] - fromLow) * t
				worldEq.MidGain = fromMid + (v[3] - fromMid) * t
				worldEq.HighGain = fromHigh + (v[4] - fromHigh) * t
				task.wait(0.05)
			end
		end)
	end

	-- ===== Per-world atmosphere =====
	-- Lighting was identical in every world, so Volcano and Snow looked like the same
	-- place with different ground colours. Fog colour/density and a colour-correction
	-- tint do most of the work of making a world feel like somewhere.
	--
	-- Reuses the SAME world-detection loop as the music rather than adding a second one:
	-- two independent detectors would drift out of sync and double the cost.
	local Lighting = game:GetService("Lighting")
	local colorCorrection = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

	-- fogColor, fogEnd, tint, saturation
	local WORLD_ATMOSPHERE = {
		StarterMeadow = { Color3.fromRGB(200, 210, 230), 420, Color3.fromRGB(255, 255, 255), 0.00 },
		Forest        = { Color3.fromRGB(150, 190, 150), 300, Color3.fromRGB(225, 255, 220), 0.10 },
		Beach         = { Color3.fromRGB(220, 235, 250), 500, Color3.fromRGB(255, 250, 225), 0.05 },
		Desert        = { Color3.fromRGB(240, 220, 170), 380, Color3.fromRGB(255, 240, 200), -0.05 },
		Snow          = { Color3.fromRGB(235, 245, 255), 260, Color3.fromRGB(230, 245, 255), -0.20 },
		CrystalCaves  = { Color3.fromRGB(120, 100, 170), 200, Color3.fromRGB(215, 200, 255), 0.20 },
		Volcano       = { Color3.fromRGB(120, 70, 55), 240, Color3.fromRGB(255, 215, 200), 0.15 },
		SkyIslands    = { Color3.fromRGB(225, 240, 255), 600, Color3.fromRGB(245, 250, 255), 0.05 },
	}

	local currentAtmo = nil
	local function applyWorldLighting(worldId)
		if currentAtmo == worldId then return end
		currentAtmo = worldId
		local a = WORLD_ATMOSPHERE[worldId] or WORLD_ATMOSPHERE.StarterMeadow

		-- Lighting properties DO accept tweens (unlike EqualizerSoundEffect gains, which
		-- silently ignore them -- verified earlier in this project), so tween is safe here.
		TweenService:Create(Lighting, TweenInfo.new(2.0), {
			FogColor = a[1], FogEnd = a[2],
		}):Play()
		if colorCorrection then
			TweenService:Create(colorCorrection, TweenInfo.new(2.0), {
				TintColor = a[3], Saturation = a[4],
			}):Play()
		end
	end

	-- Which world is the player standing in? Nearest zone centre wins, with a generous
	-- radius so walking near a boundary doesn't flip the music back and forth.
	task.spawn(function()
		while true do
			task.wait(2)
			local char = LocalPlayer.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local nearest, nearestDist = "StarterMeadow", 500
				for _, w in ipairs(WorldsData.WORLDS) do
					if w.zonePosition then
						local d = (hrp.Position - w.zonePosition).Magnitude
						if d < nearestDist then nearest, nearestDist = w.id, d end
					end
				end
				applyVoicing(nearest)
				applyWorldLighting(nearest)
			end
		end
	end)
end

-- ===== Root ScreenGui =====
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SAC_HUD"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = PlayerGui

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 12)
	c.Parent = inst
	return c
end

local function stroke(inst, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or Color3.fromRGB(0, 0, 0)
	s.Thickness = thickness or 2
	s.Transparency = 0.4
	s.Parent = inst
	return s
end

local function shadow(inst)
	local img = Instance.new("ImageLabel")
	img.Name = "Shadow"
	img.BackgroundTransparency = 1
	img.Image = "rbxasset://textures/ui/TopBar/blurRight.png"
	img.ImageTransparency = 0.7
	img.ZIndex = inst.ZIndex - 1
	img.Size = UDim2.new(1, 12, 1, 12)
	img.Position = UDim2.new(0, -6, 0, -2)
	img.Parent = inst

end

-- Reusable hover/press feedback for ANY TextButton -- a UIScale modifier rather than
-- touching .Size directly, so this never interferes with UIListLayout or any other
-- layout system reading the button's real size. Applied broadly (main HUD buttons +
-- every dynamically-generated row builder) rather than hand-wiring each button
-- individually, since hand-wiring dozens of buttons the same way is exactly the kind
-- of repetitive work a shared helper exists to avoid.
local function addHoverFeedback(button)
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = button
	button.MouseEnter:Connect(function()
		TweenService:Create(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = 1.06 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		TweenService:Create(uiScale, TweenInfo.new(0.08, Enum.EasingStyle.Quad), { Scale = 0.94 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(uiScale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), { Scale = 1.06 }):Play()
	end)
	return uiScale
end

-- ================= HUD: Sparks counter (top-left) =================
local sparksCard = Instance.new("Frame")
sparksCard.Name = "SparksCard"
sparksCard.BackgroundColor3 = PALETTE.card
sparksCard.Size = UDim2.new(0, 190, 0, 56)
sparksCard.Position = UDim2.new(0, 20, 0, 20)
sparksCard.Parent = screenGui
corner(sparksCard, 16)
stroke(sparksCard, PALETTE.accentGold, 2)

local sparksIcon = Instance.new("TextLabel")
sparksIcon.BackgroundTransparency = 1
sparksIcon.Size = UDim2.new(0, 40, 1, 0)
sparksIcon.Position = UDim2.new(0, 6, 0, 0)
sparksIcon.Text = "\u{2728}"
sparksIcon.TextScaled = true
sparksIcon.Font = FONT_HEAVY
sparksIcon.Parent = sparksCard

local sparksLabel = Instance.new("TextLabel")
sparksLabel.Name = "SparksLabel"
sparksLabel.BackgroundTransparency = 1
sparksLabel.Size = UDim2.new(1, -50, 1, 0)
sparksLabel.Position = UDim2.new(0, 46, 0, 0)
sparksLabel.Text = "0"
sparksLabel.TextColor3 = PALETTE.textMain
sparksLabel.TextXAlignment = Enum.TextXAlignment.Left
sparksLabel.TextScaled = true
sparksLabel.Font = FONT_HEAVY
sparksLabel.Parent = sparksCard

-- ================= HUD: Critter portrait (bottom-left) =================
local critterCard = Instance.new("Frame")
critterCard.Name = "CritterCard"
critterCard.BackgroundColor3 = PALETTE.card
critterCard.Size = UDim2.new(0, 280, 0, 64) -- widened from 220: "Species -- Personality"
-- (added post-launch) runs noticeably longer than species-only names ever did
critterCard.AnchorPoint = Vector2.new(0, 1)
critterCard.Position = UDim2.new(0, 20, 1, -20)
critterCard.Parent = screenGui
corner(critterCard, 16)
stroke(critterCard, PALETTE.accentBlue, 2)

local critterNameLabel = Instance.new("TextLabel")
critterNameLabel.Name = "NameLabel"
critterNameLabel.BackgroundTransparency = 1
critterNameLabel.Size = UDim2.new(1, -85, 0, 26) -- leaves exactly slotsLabel's 70px + gap clear
critterNameLabel.Position = UDim2.new(0, 12, 0, 6)
critterNameLabel.Text = "No Critter"
critterNameLabel.TextColor3 = PALETTE.textMain
critterNameLabel.TextXAlignment = Enum.TextXAlignment.Left
critterNameLabel.TextScaled = true
critterNameLabel.Font = FONT_HEAVY
critterNameLabel.Parent = critterCard

local critterStateLabel = Instance.new("TextLabel")
critterStateLabel.Name = "StateLabel"
critterStateLabel.BackgroundTransparency = 1
critterStateLabel.Size = UDim2.new(1, -20, 0, 22)
critterStateLabel.Position = UDim2.new(0, 12, 0, 32)
critterStateLabel.Text = "\u{2728} Following"
critterStateLabel.TextColor3 = PALETTE.textDim
critterStateLabel.TextXAlignment = Enum.TextXAlignment.Left
critterStateLabel.TextScaled = true
critterStateLabel.Font = FONT_BODY
critterStateLabel.Parent = critterCard

-- Slot count (top-right of the critter card), driven by server-set player attributes
local slotsLabel = Instance.new("TextLabel")
slotsLabel.Name = "SlotsLabel"
slotsLabel.BackgroundTransparency = 1
slotsLabel.Size = UDim2.new(0, 70, 0, 20)
slotsLabel.AnchorPoint = Vector2.new(1, 0)
slotsLabel.Position = UDim2.new(1, -10, 0, 6)
slotsLabel.Text = ""
slotsLabel.TextColor3 = PALETTE.accentGold
slotsLabel.TextXAlignment = Enum.TextXAlignment.Right
slotsLabel.TextScaled = true
slotsLabel.Font = FONT_BODY
slotsLabel.Parent = critterCard

local function updateSlotsLabel()
	local used = LocalPlayer:GetAttribute("SAC_UsedSlots")
	local max = LocalPlayer:GetAttribute("SAC_MaxSlots")
	if used and max then
		slotsLabel.Text = string.format("\u{1F95A} %d/%d", used, max)
	end
end
LocalPlayer:GetAttributeChangedSignal("SAC_UsedSlots"):Connect(updateSlotsLabel)
LocalPlayer:GetAttributeChangedSignal("SAC_MaxSlots"):Connect(updateSlotsLabel)
updateSlotsLabel()

-- ================= Toast banner (server-wide announcements, quest/milestone popups) =================
-- Named grabBanner/showGrabBanner historically (from the old steal mechanic); kept as a
-- general-purpose toast since quest completion, collection milestones, and other
-- non-steal moments already reuse it -- renaming would touch every one of those call
-- sites for a cosmetic-only change, not worth it on its own.
local grabBanner = Instance.new("Frame")
grabBanner.Name = "GrabBanner"
grabBanner.BackgroundColor3 = PALETTE.danger
grabBanner.Size = UDim2.new(0, 460, 0, 60)
grabBanner.AnchorPoint = Vector2.new(0.5, 0)
grabBanner.Position = UDim2.new(0.5, 0, 0, -80) -- starts off-screen, tweens down
grabBanner.Parent = screenGui
corner(grabBanner, 14)
stroke(grabBanner, Color3.new(1, 1, 1), 2)

local grabBannerLabel = Instance.new("TextLabel")
grabBannerLabel.BackgroundTransparency = 1
grabBannerLabel.Size = UDim2.new(1, -20, 1, 0)
grabBannerLabel.Position = UDim2.new(0, 10, 0, 0)
grabBannerLabel.TextColor3 = Color3.new(1, 1, 1)
grabBannerLabel.TextScaled = true
grabBannerLabel.Font = FONT_HEAVY
grabBannerLabel.Text = ""
grabBannerLabel.Parent = grabBanner

local function hideGrabBanner()
	local tween = TweenService:Create(grabBanner, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Position = UDim2.new(0.5, 0, 0, -80) })
	tween:Play()
end

-- ===== Toast queue =====
-- 45 call sites across the client share this one banner. The previous implementation
-- overwrote the text and restarted a fixed 4s timer on every call, so a burst (an 8x
-- multi-hatch, a rebirth, a world unlock) destroyed its own messages -- measured live:
-- 6 overwrites in one hatch, of which the player could read one.
--
-- Queued instead, with three properties that matter:
--  * DEDUPE: identical consecutive messages collapse into "x3" rather than queueing
--    three separate 2s displays, which is what a multi-hatch actually produces.
--  * PRIORITY: rare events jump the queue. Seeing "MYTHIC hatched!" four seconds after
--    the fact, behind three Sparks toasts, is strictly worse than seeing it now.
--  * BOUNDED: the queue is capped, so a runaway loop can't build a minutes-long backlog
--    the player has to sit through.
local toastQueue = {}
local toastShowing = false
local TOAST_DISPLAY_SECONDS = 2.2
local TOAST_QUEUE_MAX = 6

local function processToastQueue()
	if toastShowing then return end
	local item = table.remove(toastQueue, 1)
	if not item then return end
	toastShowing = true

	grabBannerLabel.Text = item.count > 1
		and string.format("%s  x%d", item.text, item.count)
		or item.text

	local tween = TweenService:Create(grabBanner,
		TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, 24) })
	tween:Play()

	task.delay(TOAST_DISPLAY_SECONDS, function()
		hideGrabBanner()
		-- Wait out the hide animation before the next one slides in, or they overlap.
		task.delay(0.3, function()
			toastShowing = false
			processToastQueue()
		end)
	end)
end

-- priority: higher shows sooner. Default 0.
local function showGrabBanner(text, priority)
	priority = priority or 0

	-- Collapse an identical message already queued (or currently showing as the most
	-- recent entry) into a count instead of repeating it.
	for _, item in ipairs(toastQueue) do
		if item.text == text then
			item.count += 1
			return
		end
	end

	if #toastQueue >= TOAST_QUEUE_MAX then
		-- Drop the lowest-priority queued item rather than the new one, so a flood of
		-- low-value toasts can't lock out something important.
		local worstIdx, worstPri = nil, priority
		for i, item in ipairs(toastQueue) do
			if item.priority < worstPri then worstIdx, worstPri = i, item.priority end
		end
		if worstIdx then table.remove(toastQueue, worstIdx) else return end
	end

	local entry = { text = text, priority = priority, count = 1 }
	-- Insert by priority, keeping equal priorities in arrival order.
	local inserted = false
	for i, item in ipairs(toastQueue) do
		if priority > item.priority then
			table.insert(toastQueue, i, entry)
			inserted = true
			break
		end
	end
	if not inserted then table.insert(toastQueue, entry) end

	processToastQueue()
end
-- World Gate denial feedback -- the remote existed since the gate system was first
-- built, but had no client listener wired to it until now, so every "not enough
-- Sparks"/"need more Rebirths" denial was firing into the void with zero visible
-- feedback to the player. Reuses the same toast the rest of the game already uses.
local worldGateDeniedRemote = remotes:FindFirstChild("WorldGateDenied")
if worldGateDeniedRemote then
	worldGateDeniedRemote.OnClientEvent:Connect(function(message)
		showGrabBanner(message)
	end)
end

-- "Species -- Personality" is the whole point of the personality system's legibility
-- bet: a player should be able to read this and immediately understand what kind of
-- individual they're looking at, the same way they already read a rarity tier. Falls
-- back to species-only for any creature without a recognized personality rather than
-- showing a broken "-- nil". FACTORED OUT as one shared function used by every place
-- that displays a critter's name (the state-change HUD reveal, the hatch cinematic's
-- own reveal, and the rapid-consecutive-hatch overlap banner) after discovering the
-- hard way that having each site format this independently meant the cinematic's own
-- copy silently clobbered this one moments after it correctly ran -- two copies of the
-- same formatting logic drifted out of sync the very first time one of them changed.
local function setCritterNameDisplay(label, species, personality)
	local personalityData = personality and Constants.PERSONALITIES[personality]
	if personalityData then
		label.Text = species .. " \u{2014} " .. personality
		label.TextColor3 = personalityData.color
	else
		label.Text = species
		label.TextColor3 = Color3.new(1, 1, 1)
	end
end

remotes.CritterStateChanged.OnClientEvent:Connect(function(uid, newState, extra)
	if extra and extra.ownerUserId == LocalPlayer.UserId then
		-- Returning players never see the hatch cinematic, so the first state event
		-- from their own critter is what reveals the HUD and fills in the name.
		if not sparksCard.Visible then
			sparksCard.Visible = true
			critterCard.Visible = true
			sparksCard.BackgroundTransparency = 0
			critterCard.BackgroundTransparency = 0
		end
		if extra.species then
			setCritterNameDisplay(critterNameLabel, extra.species, extra.personality)
		end
		critterStateLabel.Text = "\u{2728} Earning Sparks"
	end
end)

-- ================= Server-wide announcement banner (Legendary+ hatches) =================
local announceBanner = Instance.new("Frame")
announceBanner.Name = "AnnounceBanner"
announceBanner.BackgroundColor3 = PALETTE.accentGold
announceBanner.Size = UDim2.new(0, 560, 0, 70)
announceBanner.AnchorPoint = Vector2.new(0.5, 0)
announceBanner.Position = UDim2.new(0.5, 0, 0, -100)
announceBanner.Parent = screenGui
corner(announceBanner, 16)
stroke(announceBanner, Color3.new(1, 1, 1), 3)

local announceLabel = Instance.new("TextLabel")
announceLabel.BackgroundTransparency = 1
announceLabel.Size = UDim2.new(1, -20, 1, 0)
announceLabel.Position = UDim2.new(0, 10, 0, 0)
announceLabel.TextColor3 = Color3.fromRGB(40, 30, 10)
announceLabel.TextScaled = true
announceLabel.Font = FONT_HEAVY
announceLabel.Text = ""
announceLabel.Parent = announceBanner

remotes.ServerAnnouncement.OnClientEvent:Connect(function(text)
	announceLabel.Text = text
	local showTween = TweenService:Create(announceBanner,
		TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 0, 100) })
	showTween:Play()
	task.delay(4.5, function()
		local hideTween = TweenService:Create(announceBanner,
			TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Position = UDim2.new(0.5, 0, 0, -100) })
		hideTween:Play()
	end)
end)

-- ================= Sparks live counter =================
-- Two changes over "set the text and pulse":
--  * ROLL-UP: the number counts toward its new value instead of snapping. A snapping
--    digit reads as a variable changing; a rolling one reads as earning something.
--  * FLOATING GAINS: a "+N" rises off the card. Passive income is otherwise completely
--    invisible -- the whole loop is critters earning for you, and nothing showed it.
do
	local displayedSparks = nil       -- what the label currently shows
	local targetSparks = 0
	local rollConn = nil

	-- Roll-up is time-based, not step-based: a fixed step count makes small gains crawl
	-- and huge late-game gains (billions) still take the same time, which looks wrong at
	-- both ends. This closes a FRACTION of the remaining gap per frame, so it's fast
	-- when far and settles smoothly, regardless of magnitude.
	local function startRoll()
		if rollConn then return end
		rollConn = RunService.RenderStepped:Connect(function(dt)
			if displayedSparks == nil then
				displayedSparks = targetSparks
			end
			local gap = targetSparks - displayedSparks
			if math.abs(gap) < 1 then
				displayedSparks = targetSparks
				sparksLabel.Text = Constants.FormatNumber(math.floor(displayedSparks))
				rollConn:Disconnect()
				rollConn = nil
				return
			end
			-- 12/sec convergence; clamped so a single long frame can't overshoot.
			displayedSparks += gap * math.min(dt * 12, 1)
			sparksLabel.Text = Constants.FormatNumber(math.floor(displayedSparks))
		end)
	end

	-- Floating "+N" that rises and fades off the Sparks card.
	local floatCount = 0
	local FLOAT_MAX = 5   -- bounded: a burst must not spawn dozens of overlapping labels
	local function spawnFloatingGain(amount)
		if floatCount >= FLOAT_MAX then return end
		floatCount += 1

		local lbl = Instance.new("TextLabel")
		lbl.Name = "FloatingGain"
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.new(0, 130, 0, 26)
		lbl.AnchorPoint = Vector2.new(0, 0.5)
		-- Positioned RELATIVE TO THE CARD, not in absolute screen space. Absolute
		-- coordinates were being overwritten by the responsive layout pass every 2s,
		-- which cancelled the rise tween and left labels frozen mid-fade -- verified
		-- live: 5 stuck at transparency 0.74.
		lbl.Position = UDim2.new(1, 4, 0.5, 0)
		lbl.Text = "+" .. Constants.FormatNumber(amount)
		lbl.TextColor3 = Color3.fromRGB(255, 225, 120)
		lbl.Font = FONT_HEAVY
		lbl.TextScaled = true
		lbl.TextStrokeTransparency = 0.4
		lbl.ZIndex = 30
		lbl.Parent = sparksCard

		-- Slight horizontal scatter so rapid gains don't stack into one blur.
		local driftX = math.random(-14, 26)
		local rise = TweenService:Create(lbl,
			TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Position = UDim2.new(1, 4 + driftX, 0.5, -46), TextTransparency = 1,
			  TextStrokeTransparency = 1 })
		rise:Play()
		-- Cleanup is on a TIMER, not tween.Completed. Completed does not fire if the
		-- tween is interrupted or cancelled, and these were being left alive at
		-- transparency 0.98 -- verified live: 5 permanently stuck, and because
		-- floatCount never decremented, the cap then blocked all future floats.
		-- A timer always runs, so the label always dies and the count always frees.
		task.delay(1.3, function()
			if lbl.Parent then lbl:Destroy() end
			floatCount -= 1
		end)
	end

	remotes.SparksUpdated.OnClientEvent:Connect(function(newTotal)
		local previous = targetSparks
		targetSparks = newTotal
		-- First update of the session just sets the value; rolling up from 0 to a
		-- late-game balance would take ages and mean nothing.
		if displayedSparks == nil then
			displayedSparks = newTotal
			sparksLabel.Text = Constants.FormatNumber(newTotal)
			return
		end

		local gain = newTotal - previous
		if gain > 0 then spawnFloatingGain(gain) end
		startRoll()

		local pulse = TweenService:Create(sparksCard,
			TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
			{ Size = UDim2.new(0, 200, 0, 60) })
		pulse:Play()
	end)
end

-- Shared state (hoisted out of the hatch cinematic; Trade/Inventory/EggOdds read it).
local tradeIsActive = false
local pendingGiftUid = nil
local RARITY_COLORS_CINEMATIC = {
	Common = Color3.fromRGB(190, 190, 190),
	Rare = Color3.fromRGB(85, 170, 255),
	Epic = Color3.fromRGB(190, 85, 255),
	Legendary = Color3.fromRGB(255, 200, 40),
	Mythic = Color3.fromRGB(255, 60, 120),
	Limited = Color3.fromRGB(150, 190, 255),
}
-- Hatch cinematic extracted to HatchCinematicUI (ClientMain was at the 200k char cap).
require(script.Parent.HatchCinematicUI).init({
	RS = RS, TweenService = TweenService, RunService = RunService,
	Constants = Constants, remotes = remotes, PALETTE = PALETTE,
	FONT_HEAVY = FONT_HEAVY, SFX = SFX, shakeCamera = shakeCamera,
	DEFAULT_FOV = DEFAULT_FOV, tweenFOV = tweenFOV, resetFOV = resetFOV,
	playSound = playSound, screenGui = screenGui, corner = corner, stroke = stroke,
	setCritterNameDisplay = setCritterNameDisplay, critterNameLabel = critterNameLabel,
	sparksCard = sparksCard, critterCard = critterCard, showGrabBanner = showGrabBanner,
	RARITY_COLORS_CINEMATIC = RARITY_COLORS_CINEMATIC,
})
-- ================= World Event countdown banner =================
local eventBanner = Instance.new("Frame")
eventBanner.Name = "EventBanner"
eventBanner.BackgroundColor3 = PALETTE.accentGold
eventBanner.Size = UDim2.new(0, 260, 0, 44)
eventBanner.AnchorPoint = Vector2.new(0.5, 0)
eventBanner.Position = UDim2.new(0.5, 0, 0, 12)
eventBanner.Visible = false
eventBanner.Parent = screenGui
corner(eventBanner, 12)
stroke(eventBanner, Color3.new(1, 1, 1), 2)

local eventLabel = Instance.new("TextLabel")
eventLabel.BackgroundTransparency = 1
eventLabel.Size = UDim2.new(1, -16, 1, 0)
eventLabel.Position = UDim2.new(0, 8, 0, 0)
eventLabel.TextColor3 = Color3.fromRGB(40, 30, 10)
eventLabel.Font = FONT_HEAVY
eventLabel.TextScaled = true
eventLabel.Text = ""
eventLabel.Parent = eventBanner

local activeEventEndTime = nil
local activeEventTitle = nil

remotes.WorldEventStarted.OnClientEvent:Connect(function(eventId, title, duration)
	activeEventTitle = title
	activeEventEndTime = os.clock() + duration
	eventBanner.Visible = true
	boostBgmIntensity()
end)

remotes.WorldEventEnded.OnClientEvent:Connect(function()
	activeEventEndTime = nil
	activeEventTitle = nil
	eventBanner.Visible = false
end)

RunService.RenderStepped:Connect(function()
	if not activeEventEndTime then return end
	local remaining = math.max(0, math.ceil(activeEventEndTime - os.clock()))
	eventLabel.Text = string.format("%s  %d:%02d", activeEventTitle or "", remaining // 60, remaining % 60)
end)

-- ================= Daily Reward popup (Phase 6) =================
remotes.DailyRewardGranted.OnClientEvent:Connect(function(reward, streak, gotToken)
	local popup = Instance.new("Frame")
	popup.BackgroundColor3 = PALETTE.accentGold
	popup.Size = UDim2.new(0, 320, 0, 90)
	popup.AnchorPoint = Vector2.new(0.5, 0)
	popup.Position = UDim2.new(0.5, 0, 0, -110)
	popup.ZIndex = 30
	popup.Parent = screenGui
	corner(popup, 16)
	stroke(popup, Color3.new(1, 1, 1), 3)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -20, 0, 40)
	title.Position = UDim2.new(0, 10, 0, 8)
	title.Text = "\u{1F381} DAILY REWARD!"
	title.TextColor3 = Color3.fromRGB(40, 30, 10)
	title.Font = FONT_HEAVY
	title.TextScaled = true
	title.ZIndex = 31
	title.Parent = popup

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Size = UDim2.new(1, -20, 0, 32)
	detail.Position = UDim2.new(0, 10, 0, 50)
	detail.Text = gotToken
		and string.format("+%s Sparks  \u{2022}  \u{2B50} FREE LIMITED EGG!", Constants.FormatNumber(reward))
		or string.format("+%s Sparks  \u{2022}  Day %d streak", Constants.FormatNumber(reward), streak)
	detail.TextColor3 = Color3.fromRGB(70, 50, 15)
	detail.Font = FONT_BODY
	detail.TextScaled = true
	detail.ZIndex = 31
	detail.Parent = popup

	playSound(SFX.HatchFanfare, 0.5, 1.1)
	TweenService:Create(popup, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, 170) }):Play()
	task.delay(4, function()
		local hide = TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 0, -110) })
		hide:Play()
		hide.Completed:Connect(function() popup:Destroy() end)
	end)
end)

-- ================= Ancient Tree Elder Critter: dialogue popup =================
-- Bottom-center speech-style box, distinct from the achievement/reward popup language
-- (top-center, gold) so dialogue reads as its own category, not another reward burst.
local elderDialogueBox = Instance.new("Frame")
elderDialogueBox.Name = "ElderDialogueBox"
elderDialogueBox.BackgroundColor3 = Color3.fromRGB(35, 30, 45)
elderDialogueBox.Size = UDim2.new(0, 480, 0, 100)
elderDialogueBox.AnchorPoint = Vector2.new(0.5, 1)
elderDialogueBox.Position = UDim2.new(0.5, 0, 1, 40)
elderDialogueBox.Parent = screenGui
corner(elderDialogueBox, 16)
local elderDialogueStroke = stroke(elderDialogueBox, Color3.fromRGB(150, 220, 255), 2)

local elderNameLabel = Instance.new("TextLabel")
elderNameLabel.BackgroundTransparency = 1
elderNameLabel.Size = UDim2.new(1, -24, 0, 26)
elderNameLabel.Position = UDim2.new(0, 12, 0, 8)
elderNameLabel.Text = "\u{2728} Elder Mossbeard"
elderNameLabel.TextColor3 = Color3.fromRGB(150, 220, 255)
elderNameLabel.Font = FONT_HEAVY
elderNameLabel.TextScaled = true
elderNameLabel.TextXAlignment = Enum.TextXAlignment.Left
elderNameLabel.Parent = elderDialogueBox

local elderLineLabel = Instance.new("TextLabel")
elderLineLabel.BackgroundTransparency = 1
elderLineLabel.Size = UDim2.new(1, -24, 0, 60)
elderLineLabel.Position = UDim2.new(0, 12, 0, 34)
elderLineLabel.Text = ""
elderLineLabel.TextColor3 = Color3.new(1, 1, 1)
elderLineLabel.TextWrapped = true
elderLineLabel.Font = FONT_BODY
elderLineLabel.TextScaled = true
elderLineLabel.TextXAlignment = Enum.TextXAlignment.Left
elderLineLabel.TextYAlignment = Enum.TextYAlignment.Top
elderLineLabel.Parent = elderDialogueBox

local elderHideDelay = nil
remotes.ElderDialogue.OnClientEvent:Connect(function(line, isGift)
	elderLineLabel.Text = line
	-- Gift moments get a gold border + a soft chime instead of the default blue lore
	-- styling -- a real visual "something rewarding just happened" cue, distinct from
	-- ordinary dialogue, without needing a whole separate popup type.
	elderDialogueStroke.Color = isGift and Color3.fromRGB(255, 210, 100) or Color3.fromRGB(150, 220, 255)
	elderNameLabel.TextColor3 = isGift and Color3.fromRGB(255, 210, 100) or Color3.fromRGB(150, 220, 255)
	if isGift then
		playSound(SFX.HatchFanfare, 0.5, 1.2)
	end
	TweenService:Create(elderDialogueBox, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 1, -20) }):Play()
	if elderHideDelay then task.cancel(elderHideDelay) end
	elderHideDelay = task.delay(6, function()
		TweenService:Create(elderDialogueBox, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 1, 40) }):Play()
	end)
end)

-- ================= Collection Book (Phase 7) =================
-- Derived directly from Constants.CRITTER_SPECIES (rather than a second hardcoded
-- copy) so the Book can never silently drift out of sync with the real roster again
-- — that drift is exactly what happened here when the roster grew from 30 to 40.
local SPECIES_ORDER = {}
for _, rarityTier in ipairs(Constants.RARITIES) do
	for _, species in ipairs(Constants.CRITTER_SPECIES[rarityTier.id]) do
		table.insert(SPECIES_ORDER, { species, rarityTier.id })
	end
end
-- Hoisted OUT of the Collection Book's do...end block below. It was scoped inside it,
-- which is why the Inventory panel had its own second copy with DIFFERENT colours for
-- the same rarities -- an Epic rendered as two different purples depending on the panel.
-- One shared definition now; removing the second copy without hoisting this first was a
-- mistake that broke the client (the scoped one was never visible to Inventory at all).
local RARITY_COLORS = {
	Common = Color3.fromRGB(190, 190, 190), Rare = Color3.fromRGB(85, 170, 255),
	Epic = Color3.fromRGB(190, 85, 255), Legendary = Color3.fromRGB(255, 200, 40),
	Mythic = Color3.fromRGB(255, 60, 120),
}
do

local bookButton = Instance.new("TextButton")
bookButton.Name = "CollectionButton"
bookButton.Text = "\u{1F4D6} Book"
bookButton.Font = FONT_HEAVY
bookButton.TextScaled = true
bookButton.TextColor3 = Color3.new(1, 1, 1)
bookButton.BackgroundColor3 = PALETTE.accentBlue
bookButton.Size = UDim2.new(0, 110, 0, 44)
bookButton.AnchorPoint = Vector2.new(1, 0)
bookButton.Position = UDim2.new(1, -20, 0, 72)
bookButton.Parent = screenGui
addHoverFeedback(bookButton)
corner(bookButton, 12)
stroke(bookButton, Color3.new(1, 1, 1), 2)

local bookPanel = Instance.new("Frame")
bookPanel.Name = "CollectionPanel"
bookPanel.BackgroundColor3 = PALETTE.card
bookPanel.Size = UDim2.new(0, 360, 0.85, 0)
local bookSizeCap = Instance.new("UISizeConstraint")
bookSizeCap.MaxSize = Vector2.new(360, 430)
bookSizeCap.Parent = bookPanel
bookPanel.AnchorPoint = Vector2.new(0.5, 0.5)
bookPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
setPanelOpen(bookPanel, false)
bookPanel.ZIndex = 20
bookPanel.Parent = screenGui
corner(bookPanel, 18)
stroke(bookPanel, PALETTE.accentBlue, 3)

local bookTitle = Instance.new("TextLabel")
bookTitle.BackgroundTransparency = 1
bookTitle.Size = UDim2.new(1, -60, 0, 40)
bookTitle.Position = UDim2.new(0, 12, 0, 8)
bookTitle.Text = string.format("CRITTER BOOK  0/%d", #SPECIES_ORDER)
bookTitle.TextColor3 = Color3.new(1, 1, 1)
bookTitle.Font = FONT_HEAVY
bookTitle.TextScaled = true
bookTitle.TextXAlignment = Enum.TextXAlignment.Left
bookTitle.ZIndex = 21
bookTitle.Parent = bookPanel

local bookCloseButton = Instance.new("TextButton")
bookCloseButton.BackgroundColor3 = PALETTE.danger
bookCloseButton.Size = UDim2.new(0, 36, 0, 36)
bookCloseButton.AnchorPoint = Vector2.new(1, 0)
bookCloseButton.Position = UDim2.new(1, -8, 0, 8)
bookCloseButton.Text = "X"
bookCloseButton.Font = FONT_HEAVY
bookCloseButton.TextScaled = true
bookCloseButton.TextColor3 = Color3.new(1, 1, 1)
bookCloseButton.ZIndex = 21
bookCloseButton.Parent = bookPanel
addHoverFeedback(bookCloseButton)
corner(bookCloseButton, 10)

local bookList = Instance.new("ScrollingFrame")
bookList.BackgroundTransparency = 1
bookList.Size = UDim2.new(1, -20, 1, -60)
bookList.Position = UDim2.new(0, 10, 0, 52)
bookList.AutomaticCanvasSize = Enum.AutomaticSize.Y
bookList.CanvasSize = UDim2.new(0, 0, 0, 0)
bookList.ScrollBarThickness = 6
bookList.ZIndex = 21
bookList.Parent = bookPanel

local bookLayout = Instance.new("UIListLayout")
bookLayout.Padding = UDim.new(0, 6)
bookLayout.SortOrder = Enum.SortOrder.LayoutOrder
bookLayout.Parent = bookList

-- Progress-header widgets live in their own scope: ClientMain sits at Luau's hard
-- 200-local-register limit, and adding these at top level pushed it over, crashing the
-- entire HUD construction. Only renderCollectionProgress escapes.
local latestCollectionSummary = nil
local renderCollectionProgress
do

-- Progress header: overall %, per-world breakdown, and the next milestone's reward.
-- Pinned above the species list via LayoutOrder so it always reads first.
local bookProgress = Instance.new("Frame")
bookProgress.Name = "BookProgress"
bookProgress.BackgroundColor3 = PALETTE.bg
bookProgress.Size = UDim2.new(1, 0, 0, 116)
bookProgress.LayoutOrder = -100
bookProgress.ZIndex = 22
bookProgress.Parent = bookList
corner(bookProgress, 10)
stroke(bookProgress, PALETTE.accentGold, 2)

local bookTotalLabel = Instance.new("TextLabel")
bookTotalLabel.BackgroundTransparency = 1
bookTotalLabel.Size = UDim2.new(1, -16, 0, 22)
bookTotalLabel.Position = UDim2.new(0, 8, 0, 5)
bookTotalLabel.Text = "COLLECTION 0%"
bookTotalLabel.TextColor3 = PALETTE.accentGold
bookTotalLabel.Font = FONT_HEAVY
bookTotalLabel.TextScaled = true
bookTotalLabel.TextXAlignment = Enum.TextXAlignment.Left
bookTotalLabel.ZIndex = 23
bookTotalLabel.Parent = bookProgress

local bookBarBg = Instance.new("Frame")
bookBarBg.BackgroundColor3 = Color3.fromRGB(28, 26, 40)
bookBarBg.Size = UDim2.new(1, -16, 0, 10)
bookBarBg.Position = UDim2.new(0, 8, 0, 29)
bookBarBg.ZIndex = 23
bookBarBg.Parent = bookProgress
corner(bookBarBg, 5)

local bookBarFill = Instance.new("Frame")
bookBarFill.BackgroundColor3 = PALETTE.accentGold
bookBarFill.Size = UDim2.new(0, 0, 1, 0)
bookBarFill.BorderSizePixel = 0
bookBarFill.ZIndex = 24
bookBarFill.Parent = bookBarBg
corner(bookBarFill, 5)

local bookWorldsLabel = Instance.new("TextLabel")
bookWorldsLabel.BackgroundTransparency = 1
bookWorldsLabel.Size = UDim2.new(1, -16, 0, 26)
bookWorldsLabel.Position = UDim2.new(0, 8, 0, 43)
bookWorldsLabel.Text = ""
bookWorldsLabel.TextColor3 = PALETTE.textDim
bookWorldsLabel.Font = FONT_BODY
bookWorldsLabel.TextScaled = true
bookWorldsLabel.TextXAlignment = Enum.TextXAlignment.Left
bookWorldsLabel.TextWrapped = true
bookWorldsLabel.ZIndex = 23
bookWorldsLabel.Parent = bookProgress

local bookNextLabel = Instance.new("TextLabel")
bookNextLabel.BackgroundTransparency = 1
bookNextLabel.Size = UDim2.new(1, -16, 0, 20)
bookNextLabel.Position = UDim2.new(0, 8, 0, 72)
bookNextLabel.Text = ""
bookNextLabel.TextColor3 = PALETTE.success
bookNextLabel.Font = FONT_HEAVY
bookNextLabel.TextScaled = true
bookNextLabel.TextXAlignment = Enum.TextXAlignment.Left
bookNextLabel.ZIndex = 23
bookNextLabel.Parent = bookProgress

local bookBonusLabel = Instance.new("TextLabel")
bookBonusLabel.BackgroundTransparency = 1
bookBonusLabel.Size = UDim2.new(1, -16, 0, 18)
bookBonusLabel.Position = UDim2.new(0, 8, 0, 92)
bookBonusLabel.Text = ""
bookBonusLabel.TextColor3 = Color3.fromRGB(255, 205, 60)
bookBonusLabel.Font = FONT_BODY
bookBonusLabel.TextScaled = true
bookBonusLabel.TextXAlignment = Enum.TextXAlignment.Left
bookBonusLabel.TextWrapped = true
bookBonusLabel.Visible = false
bookBonusLabel.ZIndex = 23
bookBonusLabel.Parent = bookProgress

function renderCollectionProgress(summary)
	if not summary or not summary.worlds then return end
	bookTotalLabel.Text = string.format("COLLECTION %d%%  (%d/%d)",
		summary.totalPercent or 0, summary.totalOwned or 0, summary.totalSpecies or 0)
	local frac = (summary.totalSpecies or 0) > 0 and (summary.totalOwned / summary.totalSpecies) or 0
	TweenService:Create(bookBarFill, TweenInfo.new(0.35), { Size = UDim2.new(frac, 0, 1, 0) }):Play()

	local parts = {}
	for _, w in ipairs(summary.worlds) do
		parts[#parts + 1] = string.format("%s %d%%%s", w.displayName, w.percent, w.complete and " \u{2705}" or "")
	end
	bookWorldsLabel.Text = table.concat(parts, "   ")

	-- Show the NEXT unclaimed milestone and what it pays, so the bar has a stated goal.
	local nextMs
	for _, ms in ipairs(summary.milestones or {}) do
		if not ms.claimed then nextMs = ms break end
	end
	if nextMs then
		bookNextLabel.Text = string.format("Next: %d species \u{2192} +%s Sparks",
			nextMs.count, Constants.FormatNumber(nextMs.reward))
	else
		bookNextLabel.Text = "\u{1F3C6} All collection milestones claimed!"
	end

	-- Active world-completion bonuses. Shown as earned perks so completing a set reads
	-- as a permanent reward rather than just a checkmark.
	local bonuses = summary.completionBonuses or {}
	if #bonuses > 0 then
		local labels = {}
		for _, b in ipairs(bonuses) do labels[#labels + 1] = b.label end
		bookBonusLabel.Text = "\u{2B50} " .. table.concat(labels, "   \u{2022}   ")
		bookBonusLabel.Visible = true
	else
		bookBonusLabel.Visible = false
	end
end

end

local bookRows = {}
for i, entry in ipairs(SPECIES_ORDER) do
	local species, rarity = entry[1], entry[2]
	local row = Instance.new("Frame")
	row.BackgroundColor3 = PALETTE.bg
	row.Size = UDim2.new(1, 0, 0, 46)
	row.LayoutOrder = i
	row.ZIndex = 21
	row.Parent = bookList
	corner(row, 10)

	local rarityDot = Instance.new("Frame")
	rarityDot.BackgroundColor3 = RARITY_COLORS[rarity]
	rarityDot.Size = UDim2.new(0, 14, 0, 14)
	rarityDot.AnchorPoint = Vector2.new(0, 0.5)
	rarityDot.Position = UDim2.new(0, 10, 0.5, 0)
	rarityDot.ZIndex = 22
	rarityDot.Parent = row
	corner(rarityDot, 7)

	-- Colorblind-safe: rarity is NEVER color-only. A permanent letter tag rides on the
	-- dot itself (C/R/E/L/M) so the tier reads correctly regardless of color vision —
	-- this is always on, not a togglable setting, because color-as-the-only-signal is
	-- the actual accessibility bug, not something to make optional.
	local rarityLetter = Instance.new("TextLabel")
	rarityLetter.BackgroundTransparency = 1
	rarityLetter.Size = UDim2.new(1, 0, 1, 0)
	rarityLetter.Text = rarity:sub(1, 1)
	rarityLetter.TextColor3 = Color3.new(0, 0, 0)
	rarityLetter.TextTransparency = 0.35
	rarityLetter.Font = FONT_HEAVY
	rarityLetter.TextScaled = true
	rarityLetter.ZIndex = 23
	rarityLetter.Parent = rarityDot

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(0.55, 0, 1, 0)
	nameLabel.Position = UDim2.new(0, 32, 0, 0)
	nameLabel.Text = "???"
	nameLabel.TextColor3 = PALETTE.textDim
	nameLabel.Font = FONT_HEAVY
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.ZIndex = 22
	nameLabel.Parent = row

	local statusLabel = Instance.new("TextLabel")
	statusLabel.BackgroundTransparency = 1
	statusLabel.Size = UDim2.new(0.3, 0, 1, 0)
	statusLabel.AnchorPoint = Vector2.new(1, 0)
	statusLabel.Position = UDim2.new(1, -10, 0, 0)
	statusLabel.Text = "Missing"
	statusLabel.TextColor3 = PALETTE.textDim
	statusLabel.Font = FONT_BODY
	statusLabel.TextScaled = true
	statusLabel.TextXAlignment = Enum.TextXAlignment.Right
	statusLabel.ZIndex = 22
	statusLabel.Parent = row

	bookRows[species] = { name = nameLabel, status = statusLabel }
end

-- ===== World Relics section (inside the Collection Book) =====
-- Housed here rather than in a new panel: relics ARE a collection, and a fourth
-- rarely-opened window would work against the HUD-decluttering pass. Rendered above
-- the species list because relic progress changes far less often than species do,
-- so it reads as a summary rather than something to scroll past.
local relicRows = {}
do
	local header = Instance.new("TextLabel")
	header.Name = "RelicHeader"
	header.BackgroundColor3 = PALETTE.panelInset
	header.Size = UDim2.new(1, -6, 0, 30)
	header.LayoutOrder = -100
	header.Text = "\u{1F5FF} WORLD RELICS"
	header.TextColor3 = PALETTE.accentGold
	header.Font = FONT_HEAVY
	header.TextScaled = true
	header.ZIndex = 22
	header.Parent = bookList
	corner(header, 8)

	for i = 1, 7 do
		local row = Instance.new("TextLabel")
		row.Name = "RelicRow" .. i
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, -6, 0, 20)
		row.LayoutOrder = -99 + i
		row.Text = ""
		row.TextColor3 = PALETTE.textDim
		row.Font = FONT_BODY
		row.TextScaled = true
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.ZIndex = 22
		row.Parent = bookList
		relicRows[i] = row
	end

	local footer = Instance.new("TextLabel")
	footer.Name = "RelicFooter"
	footer.BackgroundTransparency = 1
	footer.Size = UDim2.new(1, -6, 0, 24)
	footer.LayoutOrder = -90
	footer.Text = ""
	footer.TextColor3 = PALETTE.success
	footer.Font = FONT_HEAVY
	footer.TextScaled = true
	footer.ZIndex = 22
	footer.Parent = bookList

	remotes.RelicState.OnClientEvent:Connect(function(state)
		for i, row in ipairs(relicRows) do
			local r = state.relics and state.relics[i]
			if r then
				row.Text = string.format("%s %s  \u{2014}  %d%s", tostring(r.icon), tostring(r.name),
					r.count, r.nextAt and (" / " .. r.nextAt) or "  MAX")
				-- Owned relics read brighter than ones still at zero, so progress is
				-- legible at a glance without reading every number.
				row.TextColor3 = (r.count > 0) and PALETTE.textMain or PALETTE.textDim
			else
				row.Text = ""
			end
		end
		footer.Text = string.format("Relic bonus: +%.0f%% Luck  \u{2022}  +%.0f%% Sparks",
			(state.luckBonus or 0) * 100, (state.incomeBonus or 0) * 100)
	end)
end

remotes.CollectionData.OnClientEvent:Connect(function(summary)
	-- Payload is now a summary table, not the bare collection. Tolerate both shapes so a
	-- client that somehow receives the old form still renders rather than erroring.
	local collection = (summary and summary.collection) or summary or {}
	latestCollectionSummary = summary
	renderCollectionProgress(summary)
	local ownedCount = 0
	for _, entry in ipairs(SPECIES_ORDER) do
		local species = entry[1]
		local row = bookRows[species]
		local status = collection[species]
		if status == "owned" then
			ownedCount += 1
			row.name.Text = species
			row.name.TextColor3 = Color3.new(1, 1, 1)
			row.status.Text = "\u{2705} Owned"
			row.status.TextColor3 = PALETTE.success
		elseif status == "seen" then
			row.name.Text = species
			row.name.TextColor3 = PALETTE.textDim
			row.status.Text = "\u{1F441} Seen"
			row.status.TextColor3 = PALETTE.accentBlue
		else
			row.name.Text = "???"
			row.name.TextColor3 = PALETTE.textDim
			row.status.Text = "Missing"
			row.status.TextColor3 = PALETTE.textDim
		end
	end
	bookTitle.Text = string.format("CRITTER BOOK  %d/%d", ownedCount, #SPECIES_ORDER)
end)

bookButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.4, 1.2)
	setPanelOpen(bookPanel, not bookPanel.Visible)
	if bookPanel.Visible then
		-- Pull relic state on open rather than pushing it constantly; it changes rarely.
		remotes.RequestRelicState:FireServer()
	end
end)
bookCloseButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.35, 0.85)
	setPanelOpen(bookPanel, false)
end)
end -- closes the Collection Book do-block opened at L627.
-- It previously ran all the way to L4336, swallowing ~3,400 lines of unrelated UI
-- (Shop, Settings, Sanctuary, Inventory...) into the Book's scope. That is why the
-- Inventory panel needed its own copy of RARITY_COLORS: the Book's was invisible to
-- everything outside this block, despite appearing to be file-level.

-- ================= HUD: Level / XP bar (P8 Progression, stacks under Sparks) =================
local levelCard = Instance.new("Frame")
levelCard.Name = "LevelCard"
levelCard.BackgroundColor3 = PALETTE.card
levelCard.Size = UDim2.new(0, 190, 0, 40)
levelCard.Position = UDim2.new(0, 20, 0, 84)
levelCard.Parent = screenGui
corner(levelCard, 14)
stroke(levelCard, PALETTE.accentBlue, 2)

local levelLabel = Instance.new("TextLabel")
levelLabel.Name = "LevelLabel"
levelLabel.BackgroundTransparency = 1
levelLabel.Size = UDim2.new(0, 52, 1, 0)
levelLabel.Position = UDim2.new(0, 8, 0, 0)
levelLabel.Text = "Lv 1"
levelLabel.TextColor3 = PALETTE.accentBlue
levelLabel.TextXAlignment = Enum.TextXAlignment.Left
levelLabel.TextScaled = true
levelLabel.Font = FONT_HEAVY
levelLabel.Parent = levelCard

local xpBarTrack = Instance.new("Frame")
xpBarTrack.Name = "XPBarTrack"
xpBarTrack.BackgroundColor3 = Color3.fromRGB(24, 22, 36)
xpBarTrack.Size = UDim2.new(1, -70, 0, 12)
xpBarTrack.Position = UDim2.new(0, 62, 0.5, -6)
xpBarTrack.Parent = levelCard
corner(xpBarTrack, 6)

local xpBarFill = Instance.new("Frame")
xpBarFill.Name = "XPBarFill"
xpBarFill.BackgroundColor3 = PALETTE.accentBlue
xpBarFill.Size = UDim2.new(0, 0, 1, 0)
xpBarFill.BorderSizePixel = 0
xpBarFill.Parent = xpBarTrack
corner(xpBarFill, 6)

-- Server pushes absolute (xp, level, xpIntoLevel, xpNeeded) on every award rather than
-- a delta, so the client never has to reconstruct level/progress state itself -- this
-- mirrors the same "server computes, client just renders" pattern as Sparks/slots.
remotes.XPUpdated.OnClientEvent:Connect(function(xp, level, xpIntoLevel, xpNeeded)
	levelLabel.Text = "Lv " .. level
	local alpha = xpNeeded > 0 and math.clamp(xpIntoLevel / xpNeeded, 0, 1) or 0
	TweenService:Create(xpBarFill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.new(alpha, 0, 1, 0) }):Play()
end)

-- ================= HUD: Next Egg indicator (design-review fix, MEDIUM #6) =================
-- Previously, the only place a player could see egg costs was physically at the
-- Hatchery -- "how close am I to my next egg" required walking back to check. This
-- surfaces it persistently, updating live off the same SparksUpdated stream everything
-- else already listens to (no new remote needed).
local nextEggCard = Instance.new("Frame")
nextEggCard.Name = "NextEggCard"
nextEggCard.BackgroundColor3 = PALETTE.card
nextEggCard.Size = UDim2.new(0, 190, 0, 34)
nextEggCard.Position = UDim2.new(0, 20, 0, 132)
nextEggCard.Parent = screenGui
corner(nextEggCard, 12)
stroke(nextEggCard, PALETTE.accentGold, 2)

local nextEggLabel = Instance.new("TextLabel")
nextEggLabel.Name = "NextEggLabel"
nextEggLabel.BackgroundTransparency = 1
nextEggLabel.Size = UDim2.new(1, -16, 1, 0)
nextEggLabel.Position = UDim2.new(0, 8, 0, 0)
nextEggLabel.TextColor3 = PALETTE.textDim
nextEggLabel.TextXAlignment = Enum.TextXAlignment.Left
nextEggLabel.TextScaled = true
nextEggLabel.Font = FONT_BODY
nextEggLabel.Text = ""
nextEggLabel.Parent = nextEggCard

-- Cheapest tier the player CAN'T yet afford, i.e. the meaningful next goal. If they can
-- already afford everything (a late-game/rebirthed player), show nothing rather than a
-- stale "next: Mythic" that isn't actually informative at that point.
local function updateNextEggLabel(currentSparks)
	local next_ = nil
	for _, tier in ipairs(Constants.RARITIES) do
		if tier.cost > 0 and tier.cost > currentSparks then
			if not next_ or tier.cost < next_.cost then
				next_ = tier
			end
		end
	end
	if next_ then
		local remaining = next_.cost - currentSparks
		nextEggLabel.Text = string.format("\u{1F95A} Next: %s (%s more)", next_.id, Constants.FormatNumber(remaining))
		nextEggCard.Visible = true
	else
		nextEggCard.Visible = false
	end
end
nextEggCard.Visible = false -- hidden until the first SparksUpdated tells us where we stand
remotes.SparksUpdated.OnClientEvent:Connect(updateNextEggLabel)

-- Level-up celebration: a brief scaling banner over the level card itself (not a
-- full-screen takeover like Rebirth -- level-ups happen far more often, so the payoff
-- needs to read as "nice" rather than "stop everything", matching how often it fires).
remotes.LevelUp.OnClientEvent:Connect(function(newLevel)
	playSound(SFX.HatchFanfare, 0.55, 1.2)
	local burst = Instance.new("TextLabel")
	burst.BackgroundTransparency = 1
	burst.Size = UDim2.new(0, 220, 0, 60)
	burst.AnchorPoint = Vector2.new(0, 0.5)
	burst.Position = UDim2.new(0, 20, 0.5, 0)
	burst.Text = "\u{2B06}\u{FE0F} LEVEL " .. newLevel .. "!"
	burst.TextColor3 = PALETTE.accentBlue
	burst.Font = FONT_HEAVY
	burst.TextScaled = true
	burst.TextTransparency = 1
	burst.TextStrokeTransparency = 0.4
	burst.ZIndex = 25
	burst.Parent = levelCard
	local popIn = TweenService:Create(burst, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ TextTransparency = 0, Position = UDim2.new(0, 20, 0.5, -34) })
	popIn:Play()
	task.delay(1.4, function()
		local fadeOut = TweenService:Create(burst, TweenInfo.new(0.4), { TextTransparency = 1 })
		fadeOut:Play()
		fadeOut.Completed:Connect(function() burst:Destroy() end)
	end)
end)

-- ================= Achievement Unlocked popup (P8) =================
-- Own dedicated popup rather than reusing the grab-banner toast: achievements are a
-- rarer, bigger deal than routine level-ups (each one only fires once, ever, per
-- player), so the payoff should read as more significant -- styled like the Daily
-- Reward popup (slides down from off-screen top, holds, slides back up) rather than
-- the levelCard's small in-place burst.
remotes.AchievementUnlocked.OnClientEvent:Connect(function(id, title, reward)
	playSound(SFX.HatchFanfare, 0.65, 1.0)
	task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.5, 1.6) end) -- layered chime, matches the Shiny-hatch treatment

	local popup = Instance.new("Frame")
	popup.BackgroundColor3 = PALETTE.accentGold
	popup.Size = UDim2.new(0, 340, 0, 90)
	popup.AnchorPoint = Vector2.new(0.5, 0)
	popup.Position = UDim2.new(0.5, 0, 0, -110)
	popup.ZIndex = 30
	popup.Parent = screenGui
	corner(popup, 16)
	stroke(popup, Color3.new(1, 1, 1), 3)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Size = UDim2.new(1, -20, 0, 32)
	titleLabel.Position = UDim2.new(0, 10, 0, 8)
	titleLabel.Text = "\u{1F3C6} ACHIEVEMENT UNLOCKED!"
	titleLabel.TextColor3 = Color3.fromRGB(40, 30, 10)
	titleLabel.Font = FONT_HEAVY
	titleLabel.TextScaled = true
	titleLabel.ZIndex = 31
	titleLabel.Parent = popup

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Size = UDim2.new(1, -20, 0, 40)
	detail.Position = UDim2.new(0, 10, 0, 42)
	detail.Text = string.format("%s  \u{2022}  +%s Sparks", title, Constants.FormatNumber(reward))
	detail.TextColor3 = Color3.fromRGB(70, 50, 15)
	detail.Font = FONT_BODY
	detail.TextScaled = true
	detail.ZIndex = 31
	detail.Parent = popup

	TweenService:Create(popup, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, 170) }):Play()
	task.delay(4, function()
		local hide = TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 0, -110) })
		hide:Play()
		hide.Completed:Connect(function() popup:Destroy() end)
	end)
end)

-- ================= Onboarding tip popup =================
-- Bottom-CENTER so it never collides with the left card stack or the right button
-- column. Auto-dismisses; a new tip replaces any tip still on screen rather than
-- queueing, since onboarding beats are sequential and the newest is always the
-- relevant one.
do
	local tipFrame = Instance.new("Frame")
	tipFrame.Name = "OnboardingTip"
	tipFrame.BackgroundColor3 = Color3.fromRGB(46, 42, 66)
	tipFrame.Size = UDim2.new(0, 340, 0, 62)
	tipFrame.AnchorPoint = Vector2.new(0.5, 1)
	tipFrame.Position = UDim2.new(0.5, 40, 1, 120) -- parked below screen
	tipFrame.ZIndex = 34
	tipFrame.Parent = screenGui
	corner(tipFrame, 14)
	stroke(tipFrame, Color3.fromRGB(255, 205, 60), 2)

	local tipTitle = Instance.new("TextLabel")
	tipTitle.BackgroundTransparency = 1
	tipTitle.Size = UDim2.new(1, -20, 0, 20)
	tipTitle.Position = UDim2.new(0, 10, 0, 5)
	tipTitle.Text = ""
	tipTitle.TextColor3 = Color3.fromRGB(255, 205, 60)
	tipTitle.Font = FONT_HEAVY
	tipTitle.TextScaled = true
	tipTitle.ZIndex = 35
	tipTitle.Parent = tipFrame

	local tipBody = Instance.new("TextLabel")
	tipBody.BackgroundTransparency = 1
	tipBody.Size = UDim2.new(1, -20, 0, 32)
	tipBody.Position = UDim2.new(0, 10, 0, 26)
	tipBody.Text = ""
	tipBody.TextColor3 = Color3.new(1, 1, 1)
	tipBody.Font = FONT_BODY
	tipBody.TextScaled = true
	tipBody.TextWrapped = true
	tipBody.ZIndex = 35
	tipBody.Parent = tipFrame

	local hideThread
	remotes.OnboardingTip.OnClientEvent:Connect(function(title, body)
		if hideThread then task.cancel(hideThread) end
		tipTitle.Text = title
		tipBody.Text = body
		playSound(SFX.UiTick, 0.45, 1.15)
		TweenService:Create(tipFrame, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 40, 1, -155) }):Play()
		hideThread = task.delay(7, function()
			TweenService:Create(tipFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 40, 1, 120) }):Play()
		end)
	end)
end

-- ================= Next Goal card =================
-- The always-visible "what should I do right now" answer. Distinct from the Quest card
-- (which rotates and resets) -- this is a single sequential ladder through the whole
-- game that only ever moves forward.
do
	local goalCard = Instance.new("Frame")
	goalCard.Name = "NextGoalCard"
	goalCard.BackgroundColor3 = PALETTE.card
	goalCard.Size = UDim2.new(0, 280, 0, 62)
	goalCard.AnchorPoint = Vector2.new(0, 1)
	goalCard.Position = UDim2.new(0, 12, 1, -12)
	goalCard.ZIndex = 14
	goalCard.Visible = false
	goalCard.Parent = screenGui
	corner(goalCard, 12)
	stroke(goalCard, Color3.fromRGB(255, 205, 60), 2)

	local header = Instance.new("TextLabel")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, -16, 0, 16)
	header.Position = UDim2.new(0, 8, 0, 4)
	header.Text = "\u{1F3AF} NEXT GOAL"
	header.TextColor3 = Color3.fromRGB(255, 205, 60)
	header.Font = FONT_HEAVY
	header.TextScaled = true
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.ZIndex = 15
	header.Parent = goalCard

	local titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Size = UDim2.new(1, -16, 0, 18)
	titleLabel.Position = UDim2.new(0, 8, 0, 21)
	titleLabel.Text = ""
	titleLabel.TextColor3 = Color3.new(1, 1, 1)
	titleLabel.Font = FONT_BODY
	titleLabel.TextScaled = true
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.ZIndex = 15
	titleLabel.Parent = goalCard

	local barBg = Instance.new("Frame")
	barBg.BackgroundColor3 = Color3.fromRGB(28, 26, 40)
	barBg.Size = UDim2.new(1, -76, 0, 10)
	barBg.Position = UDim2.new(0, 8, 0, 44)
	barBg.ZIndex = 15
	barBg.Parent = goalCard
	corner(barBg, 5)

	local barFill = Instance.new("Frame")
	barFill.BackgroundColor3 = Color3.fromRGB(255, 205, 60)
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BorderSizePixel = 0
	barFill.ZIndex = 16
	barFill.Parent = barBg
	corner(barFill, 5)

	local progLabel = Instance.new("TextLabel")
	progLabel.BackgroundTransparency = 1
	progLabel.Size = UDim2.new(0, 62, 0, 16)
	progLabel.AnchorPoint = Vector2.new(1, 0)
	progLabel.Position = UDim2.new(1, -8, 0, 41)
	progLabel.Text = ""
	progLabel.TextColor3 = PALETTE.textDim
	progLabel.Font = FONT_BODY
	progLabel.TextScaled = true
	progLabel.TextXAlignment = Enum.TextXAlignment.Right
	progLabel.ZIndex = 15
	progLabel.Parent = goalCard

	remotes.NextGoalUpdated.OnClientEvent:Connect(function(goal)
		if not goal then
			goalCard.Visible = false
			return
		end
		goalCard.Visible = true
		titleLabel.Text = goal.title
		progLabel.Text = string.format("%s/%s",
			Constants.FormatNumber(goal.current), Constants.FormatNumber(goal.target))
		local frac = goal.target > 0 and math.clamp(goal.current / goal.target, 0, 1) or 0
		TweenService:Create(barFill, TweenInfo.new(0.3), { Size = UDim2.new(frac, 0, 1, 0) }):Play()
	end)

	remotes.NextGoalCompleted.OnClientEvent:Connect(function(title, reward)
		playSound(SFX.HatchFanfare, 0.6, 1.05)
		task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.5, 1.5) end)
		showGrabBanner(string.format("\u{1F3AF} GOAL COMPLETE: %s  +%s Sparks",
			title, Constants.FormatNumber(reward)))
		local pulse = TweenService:Create(goalCard,
			TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 2, true),
			{ Size = UDim2.new(0, 296, 0, 66) })
		pulse:Play()
	end)

	task.delay(3, function() remotes.RequestNextGoal:FireServer() end)
end

-- ================= Quest Card (always-visible goal) =================

-- ================= Level Reward popup (item #5) =================
do
	remotes.LevelRewardGranted.OnClientEvent:Connect(function(level, label, rewardType)
		playSound(SFX.HatchFanfare, 0.6, 1.1)
		task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.5, 1.5) end)

		local icon = rewardType == "trail" and "\u{2728}" or rewardType == "aura" and "\u{1F31F}" or "\u{1F4B0}"

		local popup = Instance.new("Frame")
		popup.BackgroundColor3 = Color3.fromRGB(140, 100, 230)
		popup.Size = UDim2.new(0, 340, 0, 90)
		popup.AnchorPoint = Vector2.new(0.5, 0)
		popup.Position = UDim2.new(0.5, 0, 0, -110)
		popup.ZIndex = 30
		popup.Parent = screenGui
		corner(popup, 16)
		stroke(popup, Color3.new(1, 1, 1), 3)

		local titleLabel = Instance.new("TextLabel")
		titleLabel.BackgroundTransparency = 1
		titleLabel.Size = UDim2.new(1, -20, 0, 32)
		titleLabel.Position = UDim2.new(0, 10, 0, 8)
		titleLabel.Text = string.format("%s LEVEL %d REWARD!", icon, level)
		titleLabel.TextColor3 = Color3.new(1, 1, 1)
		titleLabel.Font = FONT_HEAVY
		titleLabel.TextScaled = true
		titleLabel.ZIndex = 31
		titleLabel.Parent = popup

		local detail = Instance.new("TextLabel")
		detail.BackgroundTransparency = 1
		detail.Size = UDim2.new(1, -20, 0, 40)
		detail.Position = UDim2.new(0, 10, 0, 42)
		detail.Text = "You unlocked: " .. label
		detail.TextColor3 = Color3.fromRGB(230, 220, 255)
		detail.Font = FONT_BODY
		detail.TextScaled = true
		detail.ZIndex = 31
		detail.Parent = popup

		TweenService:Create(popup, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Position = UDim2.new(0.5, 0, 0, 170) }):Play()
		task.delay(4, function()
			local hide = TweenService:Create(popup, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Position = UDim2.new(0.5, 0, 0, -110) })
			hide:Play()
			hide.Completed:Connect(function() popup:Destroy() end)
		end)
	end)
end

-- ================= Quest Card (always-visible goal) =================
local questCard = Instance.new("Frame")
questCard.Name = "QuestCard"
questCard.BackgroundColor3 = PALETTE.card
questCard.Size = UDim2.new(0, 280, 0, 64)
questCard.AnchorPoint = Vector2.new(0, 1)
questCard.Position = UDim2.new(0, 20, 1, -100)
questCard.Parent = screenGui
corner(questCard, 14)
stroke(questCard, PALETTE.success, 2)

local questIcon = Instance.new("TextLabel")
questIcon.BackgroundTransparency = 1
questIcon.Size = UDim2.new(0, 34, 0, 34)
questIcon.Position = UDim2.new(0, 8, 0, 6)
questIcon.Text = "\u{1F3AF}"
questIcon.TextScaled = true
questIcon.Font = FONT_HEAVY
questIcon.Parent = questCard

local questText = Instance.new("TextLabel")
questText.BackgroundTransparency = 1
questText.Size = UDim2.new(1, -50, 0, 26)
questText.Position = UDim2.new(0, 46, 0, 4)
questText.Text = "Loading quest..."
questText.TextColor3 = Color3.new(1, 1, 1)
questText.Font = FONT_BODY
questText.TextScaled = true
questText.TextXAlignment = Enum.TextXAlignment.Left
questText.Parent = questCard

local questBarBg = Instance.new("Frame")
questBarBg.BackgroundColor3 = PALETTE.bg
questBarBg.Size = UDim2.new(1, -56, 0, 12)
questBarBg.Position = UDim2.new(0, 46, 0, 34)
questBarBg.Parent = questCard
corner(questBarBg, 6)

local questBarFill = Instance.new("Frame")
questBarFill.BackgroundColor3 = PALETTE.success
questBarFill.Size = UDim2.new(0, 0, 1, 0)
questBarFill.Parent = questBarBg
corner(questBarFill, 6)

remotes.QuestUpdated.OnClientEvent:Connect(function(text, progress, target, reward)
	questText.Text = text
	local frac = target > 0 and math.clamp(progress / target, 0, 1) or 0
	TweenService:Create(questBarFill, TweenInfo.new(0.3), { Size = UDim2.new(frac, 0, 1, 0) }):Play()
end)

remotes.QuestCompleted.OnClientEvent:Connect(function(reward)
	playSound(SFX.QuestComplete, 0.55, 1.1)
	local pulse = TweenService:Create(questCard, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 2, true),
		{ Size = UDim2.new(0, 296, 0, 68) })
	pulse:Play()
	showGrabBanner(string.format("\u{1F3AF} Quest Complete! +%s Sparks", Constants.FormatNumber(reward)))
end)
-- ================= Daily Quest Card (bigger goal, resets once per real day) =================
-- Positioned directly above the always-on Quest Card, gold-toned to read as a distinct,
-- more valuable category rather than a second copy of the same thing.
local dailyQuestCard = Instance.new("Frame")
dailyQuestCard.Name = "DailyQuestCard"
dailyQuestCard.BackgroundColor3 = PALETTE.card
dailyQuestCard.Size = UDim2.new(0, 280, 0, 64)
dailyQuestCard.AnchorPoint = Vector2.new(0, 1)
dailyQuestCard.Position = UDim2.new(0, 20, 1, -172)
dailyQuestCard.Parent = screenGui
corner(dailyQuestCard, 14)
local dailyQuestStroke = stroke(dailyQuestCard, PALETTE.accentGold, 2)

local dailyQuestIcon = Instance.new("TextLabel")
dailyQuestIcon.BackgroundTransparency = 1
dailyQuestIcon.Size = UDim2.new(0, 34, 0, 34)
dailyQuestIcon.Position = UDim2.new(0, 8, 0, 6)
dailyQuestIcon.Text = "\u{2B50}"
dailyQuestIcon.TextScaled = true
dailyQuestIcon.Font = FONT_HEAVY
dailyQuestIcon.Parent = dailyQuestCard

local dailyQuestText = Instance.new("TextLabel")
dailyQuestText.BackgroundTransparency = 1
dailyQuestText.Size = UDim2.new(1, -50, 0, 26)
dailyQuestText.Position = UDim2.new(0, 46, 0, 4)
dailyQuestText.Text = "Loading daily quest..."
dailyQuestText.TextColor3 = Color3.new(1, 1, 1)
dailyQuestText.Font = FONT_BODY
dailyQuestText.TextScaled = true
dailyQuestText.TextXAlignment = Enum.TextXAlignment.Left
dailyQuestText.Parent = dailyQuestCard

local dailyQuestBarBg = Instance.new("Frame")
dailyQuestBarBg.BackgroundColor3 = PALETTE.bg
dailyQuestBarBg.Size = UDim2.new(1, -56, 0, 12)
dailyQuestBarBg.Position = UDim2.new(0, 46, 0, 34)
dailyQuestBarBg.Parent = dailyQuestCard
corner(dailyQuestBarBg, 6)

local dailyQuestBarFill = Instance.new("Frame")
dailyQuestBarFill.BackgroundColor3 = PALETTE.accentGold
dailyQuestBarFill.Size = UDim2.new(0, 0, 1, 0)
dailyQuestBarFill.Parent = dailyQuestBarBg
corner(dailyQuestBarFill, 6)

remotes.DailyQuestUpdated.OnClientEvent:Connect(function(text, progress, target, reward, completed)
	if completed then
		dailyQuestText.Text = "\u{2705} Done! New quest tomorrow."
		dailyQuestIcon.Text = "\u{2705}"
		dailyQuestStroke.Color = PALETTE.success
	else
		dailyQuestText.Text = text
		dailyQuestIcon.Text = "\u{2B50}"
		dailyQuestStroke.Color = PALETTE.accentGold
	end
	local frac = target > 0 and math.clamp(progress / target, 0, 1) or 0
	TweenService:Create(dailyQuestBarFill, TweenInfo.new(0.3), { Size = UDim2.new(frac, 0, 1, 0) }):Play()
end)

remotes.DailyQuestCompleted.OnClientEvent:Connect(function(reward)
	playSound(SFX.QuestComplete, 0.6, 0.85)
	local pulse = TweenService:Create(dailyQuestCard, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 2, true),
		{ Size = UDim2.new(0, 296, 0, 68) })
	pulse:Play()
	showGrabBanner(string.format("\u{2B50} Daily Quest Complete! +%s Sparks", Constants.FormatNumber(reward)))
end)


-- ================= Orb collection VFX (Phase 12: Collect particles) =================
remotes.OrbCollected.OnClientEvent:Connect(function(value, position)
	if value then
		playSound(SFX.OrbPickup, 0.4, 1.5 + math.random() * 0.25)
	end

	-- Floating world-space "+N" text at the orb's last position, visible to everyone
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Position = position
	part.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 100, 0, 40)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Text = value and ("+" .. value .. " \u{2728}") or "\u{2728}"
	label.TextColor3 = PALETTE.success
	label.Font = FONT_HEAVY
	label.TextScaled = true
	label.TextStrokeTransparency = 0.3
	label.Parent = billboard

	TweenService:Create(part, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = position + Vector3.new(0, 4, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(0.9), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(1, function() part:Destroy() end)
end)

-- ================= Combo Counter =================
-- Real-time HUD feedback for the orb combo system: the whole point is making the
-- player FEEL the multiplier building, not just silently earn more Sparks. Fixed
-- screen position (not world-space like the +N text) since it needs to stay readable
-- while the player is actively running/moving between orbs.
do
local comboFrame = Instance.new("Frame")
comboFrame.Name = "ComboCounter"
comboFrame.BackgroundColor3 = Color3.fromRGB(255, 130, 40)
comboFrame.Size = UDim2.new(0, 240, 0, 56)
comboFrame.AnchorPoint = Vector2.new(0.5, 0)
comboFrame.Position = UDim2.new(0.5, 0, 0, -70) -- starts off-screen above
comboFrame.ZIndex = 25
comboFrame.Parent = screenGui
corner(comboFrame, 14)
stroke(comboFrame, Color3.new(1, 1, 1), 2)

local comboLabel = Instance.new("TextLabel")
comboLabel.BackgroundTransparency = 1
comboLabel.Size = UDim2.new(1, -10, 1, 0)
comboLabel.Text = ""
comboLabel.TextColor3 = Color3.new(1, 1, 1)
comboLabel.Font = FONT_HEAVY
comboLabel.TextScaled = true
comboLabel.TextStrokeTransparency = 0.2
comboLabel.ZIndex = 26
comboLabel.Parent = comboFrame

local comboHideThread = nil
local COMBO_WINDOW_CLIENT = 2.5 -- mirrors OrbService's COMBO_WINDOW, purely for the fade timer

local function hideCombo()
	local tween = TweenService:Create(comboFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
		{ Position = UDim2.new(0.5, 0, 0, -70) })
	tween:Play()
end

remotes.ComboUpdated.OnClientEvent:Connect(function(count, mult)
	if comboHideThread then task.cancel(comboHideThread) end

	if mult <= 1.0 then
		-- Combo reset to baseline -- just hide, no need for a flashy 1x display
		hideCombo()
		return
	end

	comboLabel.Text = string.format("\u{1F525} %dx COMBO \u{2022} %.1fx SPARKS!", count, mult)
	comboFrame.BackgroundColor3 = mult >= 2.0 and Color3.fromRGB(255, 60, 60)
		or mult >= 1.6 and Color3.fromRGB(255, 130, 40)
		or Color3.fromRGB(255, 190, 60)

	TweenService:Create(comboFrame, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, 16) }):Play()
	-- Pulse-scale on every increment so each new orb genuinely feels like it landed
	local pulse = TweenService:Create(comboFrame, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 1, true),
		{ Size = UDim2.new(0, 254, 0, 62) })
	pulse:Play()

	comboHideThread = task.delay(COMBO_WINDOW_CLIENT, hideCombo)
end)
end

-- ================= Hatch Comparison overlay (item #3: hatch excitement) =================
-- Deliberately a SEPARATE, independent popup from the hatch cinematic above rather than
-- edited into it -- the cinematic is complex and already working; this fires alongside
-- it via its own remote, zero risk of touching that code path.
do
local hatchCompareFrame = Instance.new("Frame")
hatchCompareFrame.Name = "HatchCompareBanner"
hatchCompareFrame.BackgroundColor3 = Color3.fromRGB(60, 56, 74)
hatchCompareFrame.Size = UDim2.new(0, 300, 0, 0)
hatchCompareFrame.AutomaticSize = Enum.AutomaticSize.Y
hatchCompareFrame.AnchorPoint = Vector2.new(0.5, 0)
hatchCompareFrame.Position = UDim2.new(0.5, 0, 0, -90)
hatchCompareFrame.ZIndex = 25
hatchCompareFrame.Parent = screenGui
corner(hatchCompareFrame, 14)
local hatchCompareStroke = stroke(hatchCompareFrame, Color3.new(1, 1, 1), 2)

local hatchCompareLayout = Instance.new("UIListLayout")
hatchCompareLayout.SortOrder = Enum.SortOrder.LayoutOrder
hatchCompareLayout.Padding = UDim.new(0, 2)
hatchCompareLayout.Parent = hatchCompareFrame

local hatchCompareNewLabel = Instance.new("TextLabel")
hatchCompareNewLabel.BackgroundTransparency = 1
hatchCompareNewLabel.Size = UDim2.new(1, -16, 0, 26)
hatchCompareNewLabel.Text = ""
hatchCompareNewLabel.TextColor3 = PALETTE.success
hatchCompareNewLabel.Font = FONT_HEAVY
hatchCompareNewLabel.TextScaled = true
hatchCompareNewLabel.LayoutOrder = 1
hatchCompareNewLabel.Parent = hatchCompareFrame

local hatchCompareDiffLabel = Instance.new("TextLabel")
hatchCompareDiffLabel.BackgroundTransparency = 1
hatchCompareDiffLabel.Size = UDim2.new(1, -16, 0, 24)
hatchCompareDiffLabel.Text = ""
hatchCompareDiffLabel.TextColor3 = Color3.new(1, 1, 1)
hatchCompareDiffLabel.Font = FONT_BODY
hatchCompareDiffLabel.TextScaled = true
hatchCompareDiffLabel.LayoutOrder = 2
hatchCompareDiffLabel.Parent = hatchCompareFrame

-- Top/bottom padding so AutomaticSize doesn't hug the text edge-to-edge
local hatchCompareTopPad = Instance.new("Frame")
hatchCompareTopPad.BackgroundTransparency = 1
hatchCompareTopPad.Size = UDim2.new(1, 0, 0, 8)
hatchCompareTopPad.LayoutOrder = 0
hatchCompareTopPad.Parent = hatchCompareFrame
local hatchCompareBotPad = Instance.new("Frame")
hatchCompareBotPad.BackgroundTransparency = 1
hatchCompareBotPad.Size = UDim2.new(1, 0, 0, 8)
hatchCompareBotPad.LayoutOrder = 3
hatchCompareBotPad.Parent = hatchCompareFrame

remotes.HatchComparison.OnClientEvent:Connect(function(isNewSpecies, isBetter, diff)
	hatchCompareNewLabel.Text = isNewSpecies and "\u{1F195} NEW SPECIES!" or ""
	hatchCompareNewLabel.Visible = isNewSpecies

	if diff ~= 0 then
		if isBetter then
			hatchCompareDiffLabel.Text = string.format("\u{2191} Better than your best by +%.1f/sec", diff)
			hatchCompareDiffLabel.TextColor3 = PALETTE.success
		else
			hatchCompareDiffLabel.Text = string.format("\u{2193} Weaker than your best by %.1f/sec", diff)
			hatchCompareDiffLabel.TextColor3 = Color3.fromRGB(255, 150, 150)
		end
		hatchCompareDiffLabel.Visible = true
	else
		hatchCompareDiffLabel.Visible = false
	end

	hatchCompareStroke.Color = isNewSpecies and PALETTE.success
		or (isBetter and PALETTE.success or Color3.fromRGB(255, 150, 150))

	TweenService:Create(hatchCompareFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 0, 300) }):Play()
	task.delay(3.5, function()
		TweenService:Create(hatchCompareFrame, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 0, -90) }):Play()
	end)
end)
end


remotes.CollectionMilestone.OnClientEvent:Connect(function(count, reward)
	playSound(SFX.HatchFanfare, 0.6, 1.1)
	showGrabBanner(string.format("\u{1F4D6} Book Milestone! %d Species \u{2014} +%s Sparks!", count, Constants.FormatNumber(reward)))
end)

print("[ClientMain] HUD constructed.")

do -- Rebirth Panel (scoped: frees 15 top-level locals)
local rebirthButton = Instance.new("TextButton")
rebirthButton.Name = "RebirthButton"
rebirthButton.Text = "\u{1F31F} Rebirth"
rebirthButton.Font = FONT_HEAVY
rebirthButton.TextScaled = true
rebirthButton.TextColor3 = Color3.new(1, 1, 1)
rebirthButton.BackgroundColor3 = Color3.fromRGB(150, 100, 230)
rebirthButton.Size = UDim2.new(0, 110, 0, 44)
rebirthButton.AnchorPoint = Vector2.new(1, 0)
rebirthButton.Position = UDim2.new(1, -20, 0, 124)
rebirthButton.Parent = screenGui
addHoverFeedback(rebirthButton)
corner(rebirthButton, 12)
stroke(rebirthButton, Color3.new(1, 1, 1), 2)

-- Design-review fix (LOW #9): the button used to be full-strength purple from second
-- one, competing for a new player's attention with things that are actually actionable
-- in their first session, while the feature itself (15,000 Sparks minimum) is nowhere
-- close to relevant yet. Starts dimmed, lights up with a one-time flourish exactly when
-- it becomes contextually relevant (Level 5, chosen to line up with the first real
-- level title -- "Critter Scout" -- rather than an arbitrary number).
local REBIRTH_ONBOARD_LEVEL = 5
local REBIRTH_DIM_COLOR = PALETTE.locked
local REBIRTH_LIT_COLOR = Color3.fromRGB(150, 100, 230)
rebirthButton.BackgroundColor3 = REBIRTH_DIM_COLOR
local rebirthButtonLit = false
local hasSyncedRebirthButton = false

local function updateRebirthButtonProminence(level)
	local shouldBeLit = level >= REBIRTH_ONBOARD_LEVEL
	if not hasSyncedRebirthButton then
		-- Initial join sync: snap directly to the correct state, no animation or sound --
		-- a returning Level 10+ player should just see the lit button immediately, not
		-- watch it "discover" it's allowed to be purple on every single join.
		hasSyncedRebirthButton = true
		rebirthButtonLit = shouldBeLit
		rebirthButton.BackgroundColor3 = shouldBeLit and REBIRTH_LIT_COLOR or REBIRTH_DIM_COLOR
		return
	end
	if shouldBeLit == rebirthButtonLit then return end
	rebirthButtonLit = shouldBeLit
	if shouldBeLit then
		TweenService:Create(rebirthButton, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ BackgroundColor3 = REBIRTH_LIT_COLOR, Size = UDim2.new(0, 122, 0, 48) }):Play()
		task.delay(0.4, function()
			TweenService:Create(rebirthButton, TweenInfo.new(0.25), { Size = UDim2.new(0, 110, 0, 44) }):Play()
		end)
		playSound(SFX.HatchFanfare, 0.5, 1.2)
	else
		rebirthButton.BackgroundColor3 = REBIRTH_DIM_COLOR
	end
end
remotes.XPUpdated.OnClientEvent:Connect(function(xp, level)
	updateRebirthButtonProminence(level)
end)

local rebirthPanel = Instance.new("Frame")
rebirthPanel.Name = "RebirthPanel"
rebirthPanel.BackgroundColor3 = PALETTE.card
rebirthPanel.Size = UDim2.new(0, 320, 0, 330)
rebirthPanel.AnchorPoint = Vector2.new(0.5, 0.5)
rebirthPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
setPanelOpen(rebirthPanel, false)
rebirthPanel.ZIndex = 20
rebirthPanel.Parent = screenGui
corner(rebirthPanel, 18)
stroke(rebirthPanel, Color3.fromRGB(150, 100, 230), 3)

local rebirthTitle = Instance.new("TextLabel")
rebirthTitle.BackgroundTransparency = 1
rebirthTitle.Size = UDim2.new(1, -60, 0, 40)
rebirthTitle.Position = UDim2.new(0, 12, 0, 8)
rebirthTitle.Text = "REBIRTH"
rebirthTitle.TextColor3 = Color3.new(1, 1, 1)
rebirthTitle.Font = FONT_HEAVY
rebirthTitle.TextScaled = true
rebirthTitle.TextXAlignment = Enum.TextXAlignment.Left
rebirthTitle.ZIndex = 21
rebirthTitle.Parent = rebirthPanel

local rebirthCloseButton = Instance.new("TextButton")
rebirthCloseButton.BackgroundColor3 = PALETTE.danger
rebirthCloseButton.Size = UDim2.new(0, 36, 0, 36)
rebirthCloseButton.AnchorPoint = Vector2.new(1, 0)
rebirthCloseButton.Position = UDim2.new(1, -8, 0, 8)
rebirthCloseButton.Text = "X"
rebirthCloseButton.Font = FONT_HEAVY
rebirthCloseButton.TextScaled = true
rebirthCloseButton.TextColor3 = Color3.new(1, 1, 1)
rebirthCloseButton.ZIndex = 21
rebirthCloseButton.Parent = rebirthPanel
addHoverFeedback(rebirthCloseButton)
corner(rebirthCloseButton, 10)

local rebirthDesc = Instance.new("TextLabel")
rebirthDesc.BackgroundTransparency = 1
rebirthDesc.Size = UDim2.new(1, -24, 0, 48)
rebirthDesc.Position = UDim2.new(0, 12, 0, 54)
rebirthDesc.Text = "Reset your Sparks and Critters for a PERMANENT income multiplier."
rebirthDesc.TextColor3 = PALETTE.textDim
rebirthDesc.Font = FONT_BODY
rebirthDesc.TextWrapped = true
rebirthDesc.TextScaled = true
rebirthDesc.ZIndex = 21
rebirthDesc.Parent = rebirthPanel

local rebirthStatus = Instance.new("TextLabel")
rebirthStatus.BackgroundTransparency = 1
rebirthStatus.Size = UDim2.new(1, -24, 0, 44)
rebirthStatus.Position = UDim2.new(0, 12, 0, 162)
rebirthStatus.Text = ""
rebirthStatus.TextColor3 = Color3.fromRGB(200, 170, 255)
rebirthStatus.Font = FONT_HEAVY
rebirthStatus.TextWrapped = true
rebirthStatus.TextScaled = true
rebirthStatus.ZIndex = 21
rebirthStatus.Parent = rebirthPanel

local rebirthConfirmButton = Instance.new("TextButton")
rebirthConfirmButton.BackgroundColor3 = Color3.fromRGB(150, 100, 230)
rebirthConfirmButton.Size = UDim2.new(1, -24, 0, 50)
rebirthConfirmButton.Position = UDim2.new(0, 12, 1, -62)
rebirthConfirmButton.Text = "Rebirth Now"
rebirthConfirmButton.Font = FONT_HEAVY
rebirthConfirmButton.TextScaled = true
rebirthConfirmButton.TextColor3 = Color3.new(1, 1, 1)
rebirthConfirmButton.ZIndex = 21
rebirthConfirmButton.Parent = rebirthPanel
corner(rebirthConfirmButton, 12)

-- (REBIRTH_TIERS_CLIENT removed: it aliased the raw 5-entry authored array, which is a
-- trap past R5 -- anything needing tier data must call Constants.GetRebirthTier so
-- generated tiers resolve. It was assigned but never read.)

-- Income projection label: the single most important part of this panel. Rebirth reads
-- as pure loss ("ALL Sparks + Critters reset") unless the gain is shown concretely, so
-- this displays real current income vs. projected post-rebirth income.
local rebirthProjection = Instance.new("TextLabel")
rebirthProjection.Name = "RebirthProjection"
rebirthProjection.BackgroundColor3 = Color3.fromRGB(40, 36, 56)
-- Compact layout: the responsive pass caps panel height to the viewport (279px on a
-- 361px screen), so this content must fit that budget rather than assuming the 330px
-- the Size property requests. Description shortened, projection and status tightened.
rebirthProjection.Size = UDim2.new(1, -24, 0, 50)
rebirthProjection.Position = UDim2.new(0, 12, 0, 108)
rebirthProjection.Text = ""
rebirthProjection.TextColor3 = Color3.new(1, 1, 1)
rebirthProjection.Font = FONT_HEAVY
rebirthProjection.TextScaled = true
rebirthProjection.ZIndex = 21
rebirthProjection.Visible = false
rebirthProjection.Parent = rebirthPanel
corner(rebirthProjection, 10)
stroke(rebirthProjection, Color3.fromRGB(150, 100, 230), 2)

remotes.RebirthPreviewData.OnClientEvent:Connect(function(currentRate, projectedRate, multiplier)
	if not projectedRate then
		rebirthProjection.Visible = false
		return
	end
	rebirthProjection.Visible = true
	rebirthProjection.Text = string.format("NOW: %s/sec\n\u{2193}\nAFTER: %s/sec",
		Constants.FormatNumber(currentRate), Constants.FormatNumber(projectedRate))
end)

local function refreshRebirthPanel()
	local count = LocalPlayer:GetAttribute("SAC_RebirthCount") or 0
	-- Uses the generator, not the raw table: rebirths are infinite now, so indexing
	-- REBIRTH_TIERS directly would falsely report MAX at tier 5.
	local nextTier = Constants.GetRebirthTier(count + 1)
	if not nextTier then
		rebirthStatus.Text = "MAX REBIRTH REACHED \u{1F451}"
		rebirthConfirmButton.Visible = false
		rebirthProjection.Visible = false
		return
	end
	rebirthConfirmButton.Visible = true
	rebirthStatus.Text = string.format("Next: \"%s\" \u{2014} %.1fx income\nCost: %s Sparks (ALL Sparks + Critters reset)",
		nextTier.title, nextTier.multiplier, Constants.FormatNumber(nextTier.cost))
end

LocalPlayer:GetAttributeChangedSignal("SAC_RebirthCount"):Connect(refreshRebirthPanel)
rebirthButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.4, 1.2)
	setPanelOpen(rebirthPanel, not rebirthPanel.Visible)
	if rebirthPanel.Visible then
		refreshRebirthPanel()
		remotes.RequestRebirthPreview:FireServer()
	end
end)
rebirthCloseButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.35, 0.85)
	setPanelOpen(rebirthPanel, false)
end)
rebirthConfirmButton.MouseButton1Click:Connect(function()
	remotes.RequestRebirth:FireServer()
	setPanelOpen(rebirthPanel, false)
end)

remotes.RebirthCompleted.OnClientEvent:Connect(function(rebirthCount, title, multiplier)
	playSound(SFX.HatchFanfare, 0.7, 0.7)
	task.delay(0.2, function() playSound(SFX.HatchFanfare, 0.7, 1.5) end)
	shakeCamera(0.6, 0.8)
	-- Rebirth is the game's biggest single moment: deepest zoom-in, longest settle
	tweenFOV(DEFAULT_FOV - 14, 0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	task.delay(0.4, function()
		tweenFOV(DEFAULT_FOV, 1.1, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
	end)
	boostBgmIntensity()

	local overlay = Instance.new("Frame")
	overlay.BackgroundColor3 = Color3.fromRGB(150, 100, 230)
	overlay.BackgroundTransparency = 1
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.ZIndex = 40
	overlay.Parent = screenGui

	local bigText = Instance.new("TextLabel")
	bigText.BackgroundTransparency = 1
	bigText.Size = UDim2.new(0, 600, 0, 100)
	bigText.AnchorPoint = Vector2.new(0.5, 0.5)
	bigText.Position = UDim2.new(0.5, 0, 0.5, 0)
	bigText.Text = string.format("\u{1F31F} %s \u{1F31F}\n%.1fx INCOME FOREVER", title:upper(), multiplier)
	bigText.TextColor3 = Color3.new(1, 1, 1)
	bigText.Font = FONT_HEAVY
	bigText.TextScaled = true
	bigText.TextTransparency = 1
	bigText.ZIndex = 41
	bigText.Parent = overlay

	TweenService:Create(overlay, TweenInfo.new(0.3), { BackgroundTransparency = 0.4 }):Play()
	TweenService:Create(bigText, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
	task.delay(2.2, function()
		TweenService:Create(overlay, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		local fadeText = TweenService:Create(bigText, TweenInfo.new(0.5), { TextTransparency = 1 })
		fadeText:Play()
		fadeText.Completed:Connect(function() overlay:Destroy() end)
	end)
end)
end
-- Shop extracted to ShopUI (ClientMain near the 200k source cap).
require(script.Parent.ShopUI).init({
	MarketplaceService = MarketplaceService, Constants = Constants, remotes = remotes,
	PALETTE = PALETTE, FONT_HEAVY = FONT_HEAVY, FONT_BODY = FONT_BODY, SFX = SFX,
	playSound = playSound, screenGui = screenGui, corner = corner, stroke = stroke,
	addHoverFeedback = addHoverFeedback, showGrabBanner = showGrabBanner,
	LocalPlayer = LocalPlayer,
})
-- ================= Worlds panel =================
-- Teleport between unlocked worlds, and see what's still locked and WHY. Previously the
-- only way to change world was walking to a physical gate -- a long trip across
-- thousands of studs that also hid progression: you couldn't see what came next without
-- travelling there.
do
	local worldsButton = Instance.new("TextButton")
	worldsButton.Name = "WorldsButton"
	worldsButton.Text = "\u{1F30D} Worlds"
	worldsButton.Font = FONT_HEAVY
	worldsButton.TextScaled = true
	worldsButton.TextColor3 = PALETTE.textMain
	worldsButton.BackgroundColor3 = PALETTE.accentBlue
	worldsButton.Size = UDim2.new(0, 110, 0, 44)
	worldsButton.AnchorPoint = Vector2.new(1, 0)
	worldsButton.Position = UDim2.new(1, -20, 0, 584)
	worldsButton.ZIndex = 12
	worldsButton.Parent = screenGui
	addHoverFeedback(worldsButton)
	corner(worldsButton, 12)
	stroke(worldsButton, PALETTE.textMain, 2)

	local panel = Instance.new("Frame")
	panel.Name = "WorldsPanel"
	panel.BackgroundColor3 = PALETTE.card
	panel.Size = UDim2.new(0, 380, 0, 430)
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(380, 430)
	cap.Parent = panel
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Visible = false
	panel.ZIndex = 20
	panel.Parent = screenGui
	corner(panel, 18)
	stroke(panel, PALETTE.accentBlue, 3)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -60, 0, 32)
	title.Position = UDim2.new(0, 12, 0, 8)
	title.Text = "\u{1F30D} WORLDS"
	title.TextColor3 = PALETTE.accentBlue
	title.Font = FONT_HEAVY
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 21
	title.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.BackgroundColor3 = PALETTE.danger
	closeBtn.Size = UDim2.new(0, 32, 0, 32)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 8)
	closeBtn.Text = "X"
	closeBtn.Font = FONT_HEAVY
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = PALETTE.textMain
	closeBtn.ZIndex = 21
	closeBtn.Parent = panel
	corner(closeBtn, 10)

	local worldsList = Instance.new("ScrollingFrame")
	worldsList.Name = "WorldsList"
	worldsList.BackgroundTransparency = 1
	worldsList.Size = UDim2.new(1, -20, 1, -54)
	worldsList.Position = UDim2.new(0, 10, 0, 46)
	worldsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	worldsList.CanvasSize = UDim2.new(0, 0, 0, 0)
	worldsList.ScrollBarThickness = 6
	worldsList.ZIndex = 21
	worldsList.Parent = panel
	local wlayout = Instance.new("UIListLayout")
	wlayout.Padding = UDim.new(0, 6)
	wlayout.SortOrder = Enum.SortOrder.LayoutOrder
	wlayout.Parent = worldsList

	local function renderWorlds(worlds, rebirths)
		worldsList:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 6)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = worldsList

		for _, w in ipairs(worlds) do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = w.unlocked and PALETTE.panelInset or PALETTE.bg
			row.Size = UDim2.new(1, -6, 0, 62)
			row.LayoutOrder = w.order
			row.ZIndex = 21
			row.Parent = worldsList
			corner(row, 10)
			if w.unlocked then stroke(row, PALETTE.success, 2) end

			local nm = Instance.new("TextLabel")
			nm.BackgroundTransparency = 1
			nm.Size = UDim2.new(1, -110, 0, 24)
			nm.Position = UDim2.new(0, 10, 0, 6)
			nm.Text = (w.unlocked and "" or "\u{1F512} ") .. tostring(w.name)
			nm.TextColor3 = w.unlocked and PALETTE.textMain or PALETTE.textDim
			nm.Font = FONT_HEAVY
			nm.TextScaled = true
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.ZIndex = 22
			nm.Parent = row

			-- Locked worlds spell out EXACTLY what's missing. A bare "Locked" tells the
			-- player nothing and makes progression feel arbitrary.
			local sub = Instance.new("TextLabel")
			sub.BackgroundTransparency = 1
			sub.Size = UDim2.new(1, -110, 0, 26)
			sub.Position = UDim2.new(0, 10, 0, 30)
			sub.TextColor3 = PALETTE.textDim
			sub.Font = FONT_BODY
			sub.TextScaled = true
			sub.TextXAlignment = Enum.TextXAlignment.Left
			sub.TextWrapped = true
			sub.ZIndex = 22
			sub.Parent = row

			if w.unlocked then
				sub.Text = "Unlocked \u{2014} tap Travel"
				sub.TextColor3 = PALETTE.success
			else
				local needs = {}
				if w.cost and w.cost > 0 then
					needs[#needs + 1] = Constants.FormatNumber(w.cost) .. " Sparks"
				end
				if w.requiredRebirths and w.requiredRebirths > (rebirths or 0) then
					needs[#needs + 1] = w.requiredRebirths .. " Rebirths"
				end
				if w.requiredPrevSpecies and w.prevOwned
					and w.prevOwned < w.requiredPrevSpecies then
					needs[#needs + 1] = string.format("%d/%d %s species",
						w.prevOwned, w.requiredPrevSpecies, tostring(w.prevName or "prev"))
				end
				sub.Text = #needs > 0 and ("Needs: " .. table.concat(needs, "  \u{2022}  "))
					or "Unlock at the world gate"
			end

			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(0, 90, 0, 34)
			btn.AnchorPoint = Vector2.new(1, 0.5)
			btn.Position = UDim2.new(1, -10, 0.5, 0)
			btn.Text = w.unlocked and "Travel" or "Locked"
			btn.Font = FONT_HEAVY
			btn.TextScaled = true
			btn.BackgroundColor3 = w.unlocked and PALETTE.accentBlue or PALETTE.locked
			btn.TextColor3 = PALETTE.textMain
			btn.ZIndex = 22
			btn.Parent = row
			corner(btn, 8)
			if w.unlocked then
				addHoverFeedback(btn)
				btn.MouseButton1Click:Connect(function()
					playSound(SFX.UiTick, 0.45, 1.3)
					remotes.RequestTeleportWorld:FireServer(w.id)
					setPanelOpen(panel, false)
				end)
			end
		end
	end

	remotes.WorldsData.OnClientEvent:Connect(renderWorlds)
	remotes.TeleportResult.OnClientEvent:Connect(function(ok, detail)
		if ok then
			showGrabBanner("\u{1F30D} Travelled to " .. tostring(detail))
		elseif detail == "Locked" then
			showGrabBanner("That world is still locked!")
		end
	end)

	worldsButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		setPanelOpen(panel, not panel.Visible)
		if panel.Visible then remotes.RequestWorldsData:FireServer() end
	end)
	closeBtn.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.35, 0.85)
		setPanelOpen(panel, false)
	end)
end

-- ================= Settings Panel (P22 Accessibility) =================
-- Session-only: not saved to DataStore, resets on rejoin. Defaults are the always-safe
-- state (shake+sound on, normal graphics), so a reset never surprises anyone; persisting
-- this is a reasonable follow-up if players ask, but adds a PlayerDataService schema
-- change this pass didn't need to take on.
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local uiScaler = Instance.new("UIScale")
uiScaler.Scale = 1
uiScaler.Parent = screenGui

local settingsButton = Instance.new("TextButton")
settingsButton.Name = "SettingsButton"
settingsButton.Text = "\u{2699}\u{FE0F} Settings"
settingsButton.Font = FONT_HEAVY
settingsButton.TextScaled = true
settingsButton.TextColor3 = Color3.new(1, 1, 1)
settingsButton.BackgroundColor3 = PALETTE.locked
settingsButton.Size = UDim2.new(0, 110, 0, 44)
settingsButton.AnchorPoint = Vector2.new(1, 0)
settingsButton.Position = UDim2.new(1, -20, 0, 176)
settingsButton.Parent = screenGui
addHoverFeedback(settingsButton)
corner(settingsButton, 12)
stroke(settingsButton, Color3.new(1, 1, 1), 2)

local settingsPanel = Instance.new("Frame")
settingsPanel.Name = "SettingsPanel"
settingsPanel.BackgroundColor3 = PALETTE.card
settingsPanel.Size = UDim2.new(0, 340, 0, 420)
settingsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
settingsPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
setPanelOpen(settingsPanel, false)
settingsPanel.ZIndex = 20
settingsPanel.Parent = screenGui
corner(settingsPanel, 18)
stroke(settingsPanel, PALETTE.locked, 3)

local settingsTitle = Instance.new("TextLabel")
settingsTitle.BackgroundTransparency = 1
settingsTitle.Size = UDim2.new(1, -60, 0, 40)
settingsTitle.Position = UDim2.new(0, 12, 0, 8)
settingsTitle.Text = "\u{2699}\u{FE0F} SETTINGS"
settingsTitle.TextColor3 = Color3.new(1, 1, 1)
settingsTitle.Font = FONT_HEAVY
settingsTitle.TextScaled = true
settingsTitle.TextXAlignment = Enum.TextXAlignment.Left
settingsTitle.ZIndex = 21
settingsTitle.Parent = settingsPanel

local settingsCloseButton = Instance.new("TextButton")
settingsCloseButton.BackgroundColor3 = PALETTE.danger
settingsCloseButton.Size = UDim2.new(0, 36, 0, 36)
settingsCloseButton.AnchorPoint = Vector2.new(1, 0)
settingsCloseButton.Position = UDim2.new(1, -8, 0, 8)
settingsCloseButton.Text = "X"
settingsCloseButton.Font = FONT_HEAVY
settingsCloseButton.TextScaled = true
settingsCloseButton.TextColor3 = Color3.new(1, 1, 1)
settingsCloseButton.ZIndex = 21
settingsCloseButton.Parent = settingsPanel
addHoverFeedback(settingsCloseButton)
corner(settingsCloseButton, 10)

local settingsList = Instance.new("ScrollingFrame")
settingsList.BackgroundTransparency = 1
settingsList.Size = UDim2.new(1, -20, 1, -60)
settingsList.Position = UDim2.new(0, 10, 0, 52)
settingsList.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsList.ScrollBarThickness = 6
settingsList.ZIndex = 21
settingsList.Parent = settingsPanel

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.Padding = UDim.new(0, 8)
settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder
settingsLayout.Parent = settingsList

-- ===== Low graphics sweep: purely client-local rendering toggles. Mutating a
-- replicated Instance's cosmetic properties (Enabled/etc.) from a LocalScript only
-- ever changes THIS client's own rendering -- it never reaches the server or other
-- players, so this is always safe regardless of who owns the instance. =====
local function applyLowGraphicsToInstance(inst)
	if inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam") then
		inst.Enabled = not Settings.lowGraphics
	elseif inst:IsA("PointLight") or inst:IsA("SpotLight") then
		inst.Enabled = not Settings.lowGraphics
	end
end
workspace.DescendantAdded:Connect(applyLowGraphicsToInstance)
local function sweepLowGraphics()
	for _, inst in ipairs(workspace:GetDescendants()) do
		applyLowGraphicsToInstance(inst)
	end
	for _, eff in ipairs(Lighting:GetChildren()) do
		if eff:IsA("PostEffect") then
			eff.Enabled = not Settings.lowGraphics
		end
	end
end

-- ---- Row builders ----
local settingsRowOrder = 0
local function newSettingsSection(title)
	settingsRowOrder += 1
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 22)
	label.LayoutOrder = settingsRowOrder
	label.Text = title
	label.TextColor3 = PALETTE.textDim
	label.Font = FONT_HEAVY
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.ZIndex = 21
	label.Parent = settingsList
end

local function newToggleRow(labelText, initial, onChanged)
	settingsRowOrder += 1
	local row = Instance.new("Frame")
	row.BackgroundColor3 = PALETTE.bg
	row.Size = UDim2.new(1, 0, 0, 50)
	row.LayoutOrder = settingsRowOrder
	row.ZIndex = 21
	row.Parent = settingsList
	corner(row, 10)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(0.65, 0, 1, 0)
	nameLabel.Position = UDim2.new(0, 12, 0, 0)
	nameLabel.Text = labelText
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.Font = FONT_BODY
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.ZIndex = 22
	nameLabel.Parent = row

	local toggleButton = Instance.new("TextButton")
	toggleButton.Size = UDim2.new(0, 64, 0, 32)
	toggleButton.AnchorPoint = Vector2.new(1, 0.5)
	toggleButton.Position = UDim2.new(1, -12, 0.5, 0)
	toggleButton.Text = ""
	toggleButton.ZIndex = 22
	toggleButton.Parent = row
	corner(toggleButton, 16)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 26, 0, 26)
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.Position = UDim2.new(0, 3, 0.5, 0)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.ZIndex = 23
	knob.Parent = toggleButton
	corner(knob, 13)

	local state = initial
	local function render(animate)
		toggleButton.BackgroundColor3 = state and PALETTE.accentBlue or Color3.fromRGB(70, 66, 84)
		local targetPos = state and UDim2.new(1, -29, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
		if animate then
			TweenService:Create(knob, TweenInfo.new(0.15, Enum.EasingStyle.Quad), { Position = targetPos }):Play()
		else
			knob.Position = targetPos
		end
	end
	render(false)

	toggleButton.MouseButton1Click:Connect(function()
		state = not state
		render(true)
		playSound(SFX.UiTick, 0.4, 1.3)
		onChanged(state)
	end)

	return { set = function(v) state = v; render(true) end }
end

local function newSliderRow(labelText, initial, min, max, onChanged)
	settingsRowOrder += 1
	local row = Instance.new("Frame")
	row.BackgroundColor3 = PALETTE.bg
	row.Size = UDim2.new(1, 0, 0, 56)
	row.LayoutOrder = settingsRowOrder
	row.ZIndex = 21
	row.Parent = settingsList
	corner(row, 10)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.new(0.6, 0, 0, 24)
	nameLabel.Position = UDim2.new(0, 12, 0, 4)
	nameLabel.Text = labelText
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.Font = FONT_BODY
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.ZIndex = 22
	nameLabel.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.BackgroundTransparency = 1
	valueLabel.Size = UDim2.new(0.3, 0, 0, 24)
	valueLabel.AnchorPoint = Vector2.new(1, 0)
	valueLabel.Position = UDim2.new(1, -12, 0, 4)
	valueLabel.Text = string.format("%d%%", math.round(initial * 100))
	valueLabel.TextColor3 = PALETTE.accentBlue
	valueLabel.Font = FONT_HEAVY
	valueLabel.TextScaled = true
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.ZIndex = 22
	valueLabel.Parent = row

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Color3.fromRGB(70, 66, 84)
	track.Size = UDim2.new(1, -24, 0, 10)
	track.Position = UDim2.new(0, 12, 0, 36)
	track.ZIndex = 22
	track.Parent = row
	corner(track, 5)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = PALETTE.accentBlue
	fill.Size = UDim2.new((initial - min) / (max - min), 0, 1, 0)
	fill.ZIndex = 23
	fill.Parent = track
	corner(fill, 5)

	local handle = Instance.new("Frame")
	handle.Size = UDim2.new(0, 18, 0, 18)
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.new((initial - min) / (max - min), 0, 0.5, 0)
	handle.BackgroundColor3 = Color3.new(1, 1, 1)
	handle.ZIndex = 24
	handle.Parent = track
	corner(handle, 9)

	local dragging = false
	local function setFromAlpha(alpha)
		alpha = math.clamp(alpha, 0, 1)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		handle.Position = UDim2.new(alpha, 0, 0.5, 0)
		local value = min + (max - min) * alpha
		valueLabel.Text = string.format("%d%%", math.round(value * 100))
		onChanged(value)
	end

	local function alphaFromInputX(inputX)
		return (inputX - track.AbsolutePosition.X) / track.AbsoluteSize.X
	end

	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromAlpha(alphaFromInputX(input.Position.X))
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromAlpha(alphaFromInputX(input.Position.X))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- Auto Hatch toggle. Shown to everyone so non-owners can see the pass exists, but
-- the server rejects the toggle unless they own it and replies with ok=false, which
-- flips the row back off and explains why -- rather than the row silently doing nothing.
newSettingsSection("\u{1F95A} Auto Hatch")
local autoHatchRow = newToggleRow("Auto Hatch (gamepass)", false, function(v)
	remotes.RequestToggleAutoHatch:FireServer(v)
end)
remotes.AutoHatchState.OnClientEvent:Connect(function(state, owned)
	if not owned then
		autoHatchRow.set(false)
		showGrabBanner("Auto Hatch requires the gamepass!")
	else
		autoHatchRow.set(state)
	end
end)

newSettingsSection("\u{1F4F7} Camera & Motion")
newToggleRow("Camera Shake", Settings.cameraShake, function(v) Settings.cameraShake = v end)
newToggleRow("Reduce Motion (disables shake + zoom punches)", Settings.motionReduction, function(v)
	Settings.motionReduction = v
	if v then resetFOV() end -- snap back immediately if a punch was mid-flight
end)

newSettingsSection("\u{1F50A} Audio")
newSliderRow("Music Volume", Settings.musicVolume, 0, 1.5, function(v)
	Settings.musicVolume = v
	if bgm then
		bgm.Volume = currentBgmBaseVolume()
	end
end)
newSliderRow("SFX Volume", Settings.sfxVolume, 0, 1.5, function(v) Settings.sfxVolume = v end)

newSettingsSection("\u{1F5A5}\u{FE0F} Display")
newSliderRow("UI Scale", Settings.uiScale, 0.8, 1.25, function(v)
	Settings.uiScale = v
	uiScaler.Scale = v
end)
newToggleRow("Low Graphics (fewer particles/effects)", Settings.lowGraphics, function(v)
	Settings.lowGraphics = v
	sweepLowGraphics()
end)

settingsButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.4, 1.2)
	setPanelOpen(settingsPanel, not settingsPanel.Visible)
end)
settingsCloseButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.35, 0.85)
	setPanelOpen(settingsPanel, false)
end)

-- ================= Achievements Panel (P8) =================
local achievementsButton = Instance.new("TextButton")
achievementsButton.Name = "AchievementsButton"
achievementsButton.Text = "\u{1F3C6} Achievements"
achievementsButton.Font = FONT_HEAVY
achievementsButton.TextScaled = true
achievementsButton.TextColor3 = Color3.new(1, 1, 1)
achievementsButton.BackgroundColor3 = PALETTE.accentGold
achievementsButton.Size = UDim2.new(0, 110, 0, 44)
achievementsButton.AnchorPoint = Vector2.new(1, 0)
achievementsButton.Position = UDim2.new(1, -20, 0, 228)
achievementsButton.Parent = screenGui
addHoverFeedback(achievementsButton)
corner(achievementsButton, 12)
stroke(achievementsButton, Color3.new(1, 1, 1), 2)

local achievementsPanel = Instance.new("Frame")
achievementsPanel.Name = "AchievementsPanel"
achievementsPanel.BackgroundColor3 = PALETTE.card
achievementsPanel.Size = UDim2.new(0, 360, 0.85, 0)
local achSizeCap = Instance.new("UISizeConstraint")
achSizeCap.MaxSize = Vector2.new(360, 460)
achSizeCap.Parent = achievementsPanel
achievementsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
achievementsPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
setPanelOpen(achievementsPanel, false)
achievementsPanel.ZIndex = 20
achievementsPanel.Parent = screenGui
corner(achievementsPanel, 18)
stroke(achievementsPanel, PALETTE.accentGold, 3)

local achTitle = Instance.new("TextLabel")
achTitle.BackgroundTransparency = 1
achTitle.Size = UDim2.new(1, -60, 0, 40)
achTitle.Position = UDim2.new(0, 12, 0, 8)
achTitle.Text = "\u{1F3C6} ACHIEVEMENTS"
achTitle.TextColor3 = Color3.new(1, 1, 1)
achTitle.Font = FONT_HEAVY
achTitle.TextScaled = true
achTitle.TextXAlignment = Enum.TextXAlignment.Left
achTitle.ZIndex = 21
achTitle.Parent = achievementsPanel

local achCloseButton = Instance.new("TextButton")
achCloseButton.BackgroundColor3 = PALETTE.danger
achCloseButton.Size = UDim2.new(0, 36, 0, 36)
achCloseButton.AnchorPoint = Vector2.new(1, 0)
achCloseButton.Position = UDim2.new(1, -8, 0, 8)
achCloseButton.Text = "X"
achCloseButton.Font = FONT_HEAVY
achCloseButton.TextScaled = true
achCloseButton.TextColor3 = Color3.new(1, 1, 1)
achCloseButton.ZIndex = 21
achCloseButton.Parent = achievementsPanel
addHoverFeedback(achCloseButton)
corner(achCloseButton, 10)

local achList = Instance.new("ScrollingFrame")
achList.BackgroundTransparency = 1
achList.Size = UDim2.new(1, -20, 1, -60)
achList.Position = UDim2.new(0, 10, 0, 52)
achList.AutomaticCanvasSize = Enum.AutomaticSize.Y
achList.CanvasSize = UDim2.new(0, 0, 0, 0)
achList.ScrollBarThickness = 6
achList.ZIndex = 21
achList.Parent = achievementsPanel

local achLayout = Instance.new("UIListLayout")
achLayout.Padding = UDim.new(0, 8)
achLayout.SortOrder = Enum.SortOrder.LayoutOrder
achLayout.Parent = achList

-- Rebuilds the full row list from scratch on every data refresh -- simpler and safer
-- than trying to diff/patch existing rows, and this panel is opened occasionally, not
-- every frame, so the rebuild cost is a non-issue.
local function renderAchievements(data)
	achList:ClearAllChildren()
	local relayout = Instance.new("UIListLayout")
	relayout.Padding = UDim.new(0, 8)
	relayout.SortOrder = Enum.SortOrder.LayoutOrder
	relayout.Parent = achList

	for i, ach in ipairs(data) do
		local row = Instance.new("Frame")
		row.BackgroundColor3 = PALETTE.bg
		row.Size = UDim2.new(1, 0, 0, 64)
		row.LayoutOrder = i
		row.ZIndex = 21
		row.Parent = achList
		corner(row, 10)
		if ach.unlocked then
			stroke(row, PALETTE.accentGold, 2)
		end

		local icon = Instance.new("TextLabel")
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.new(0, 40, 1, 0)
		icon.Text = ach.unlocked and "\u{1F3C6}" or "\u{1F512}"
		icon.TextScaled = true
		icon.Font = FONT_HEAVY
		icon.ZIndex = 22
		icon.Parent = row

		local nameLabel = Instance.new("TextLabel")
		nameLabel.BackgroundTransparency = 1
		nameLabel.Size = UDim2.new(1, -130, 0, 26)
		nameLabel.Position = UDim2.new(0, 42, 0, 6)
		nameLabel.Text = ach.title
		nameLabel.TextColor3 = ach.unlocked and PALETTE.accentGold or Color3.new(1, 1, 1)
		nameLabel.Font = FONT_HEAVY
		nameLabel.TextScaled = true
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.ZIndex = 22
		nameLabel.Parent = row

		local descLabel = Instance.new("TextLabel")
		descLabel.BackgroundTransparency = 1
		descLabel.Size = UDim2.new(1, -130, 0, 20)
		descLabel.Position = UDim2.new(0, 42, 0, 32)
		descLabel.Text = ach.unlocked and ("+" .. ach.reward .. " Sparks") or
			string.format("%s (%d/%d)", ach.desc, ach.current, ach.threshold)
		descLabel.TextColor3 = PALETTE.textDim
		descLabel.Font = FONT_BODY
		descLabel.TextScaled = true
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.ZIndex = 22
		descLabel.Parent = row

		local progressTrack = Instance.new("Frame")
		progressTrack.BackgroundColor3 = Color3.fromRGB(24, 22, 36)
		progressTrack.Size = UDim2.new(0, 70, 0, 8)
		progressTrack.AnchorPoint = Vector2.new(1, 0.5)
		progressTrack.Position = UDim2.new(1, -10, 0.5, 0)
		progressTrack.ZIndex = 22
		progressTrack.Parent = row
		corner(progressTrack, 4)

		local progressFill = Instance.new("Frame")
		progressFill.BackgroundColor3 = ach.unlocked and PALETTE.accentGold or PALETTE.accentBlue
		progressFill.Size = UDim2.new(ach.threshold > 0 and (ach.current / ach.threshold) or 0, 0, 1, 0)
		progressFill.BorderSizePixel = 0
		progressFill.ZIndex = 23
		progressFill.Parent = progressTrack
		corner(progressFill, 4)
	end
end

remotes.AchievementsData.OnClientEvent:Connect(renderAchievements)

achievementsButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.4, 1.2)
	setPanelOpen(achievementsPanel, not achievementsPanel.Visible)
	if achievementsPanel.Visible then
		remotes.RequestAchievementsData:FireServer()
	end
end)
achCloseButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.35, 0.85)
	setPanelOpen(achievementsPanel, false)
end)
-- ================= "My Ranch" button + Ranch Tier-Up celebration =================
local myRanchButton = Instance.new("TextButton")
myRanchButton.Name = "MyRanchButton"
myRanchButton.Text = "\u{1F3E1} My Ranch"
myRanchButton.Font = FONT_HEAVY
myRanchButton.TextScaled = true
myRanchButton.TextColor3 = Color3.new(1, 1, 1)
myRanchButton.BackgroundColor3 = PALETTE.successDim
myRanchButton.Size = UDim2.new(0, 110, 0, 44)
myRanchButton.AnchorPoint = Vector2.new(1, 0)
myRanchButton.Position = UDim2.new(1, -20, 0, 280)
myRanchButton.Parent = screenGui
addHoverFeedback(myRanchButton)
corner(myRanchButton, 12)
stroke(myRanchButton, Color3.new(1, 1, 1), 2)

myRanchButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.4, 1.2)
	remotes.RequestGoToRanch:FireServer()
end)

local ranchGoingSound = false
remotes.GoToRanchResult.OnClientEvent:Connect(function()
	playSound(SFX.HatchShake, 0.4, 0.9)
	shakeCamera(0.15, 0.3)
end)
-- ================= "Visit Ranch" button + player-picker panel =================
-- Read-only social travel: pick any other player currently in this server, teleport to
-- THEIR Ranch plot to see their progression. No plot mutation, no trading, no scam
-- surface -- genuinely just "come see what I've built", using the exact same
-- RanchService.GetPlotPosition the My Ranch button already relies on for your own plot.
do
local visitRanchButton = Instance.new("TextButton")
visitRanchButton.Name = "VisitRanchButton"
visitRanchButton.Text = "\u{1F465} Visit Ranch"
visitRanchButton.Font = FONT_HEAVY
visitRanchButton.TextScaled = true
visitRanchButton.TextColor3 = Color3.new(1, 1, 1)
visitRanchButton.BackgroundColor3 = Color3.fromRGB(90, 150, 190)
visitRanchButton.Size = UDim2.new(0, 110, 0, 44)
visitRanchButton.AnchorPoint = Vector2.new(1, 0)
visitRanchButton.Position = UDim2.new(1, -20, 0, 332)
visitRanchButton.Parent = screenGui
addHoverFeedback(visitRanchButton)
corner(visitRanchButton, 12)
stroke(visitRanchButton, Color3.new(1, 1, 1), 2)

local visitPanel = Instance.new("Frame")
visitPanel.Name = "VisitRanchPanel"
visitPanel.BackgroundColor3 = PALETTE.card
visitPanel.Size = UDim2.new(0, 300, 0, 360)
local visitSizeCap = Instance.new("UISizeConstraint")
visitSizeCap.MaxSize = Vector2.new(300, 420)
visitSizeCap.Parent = visitPanel
visitPanel.AnchorPoint = Vector2.new(0.5, 0.5)
visitPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
setPanelOpen(visitPanel, false)
visitPanel.ZIndex = 20
visitPanel.Parent = screenGui
corner(visitPanel, 18)
stroke(visitPanel, Color3.fromRGB(90, 150, 190), 3)

local visitTitle = Instance.new("TextLabel")
visitTitle.BackgroundTransparency = 1
visitTitle.Size = UDim2.new(1, -60, 0, 40)
visitTitle.Position = UDim2.new(0, 12, 0, 8)
visitTitle.Text = "\u{1F465} VISIT A RANCH"
visitTitle.TextColor3 = Color3.new(1, 1, 1)
visitTitle.Font = FONT_HEAVY
visitTitle.TextScaled = true
visitTitle.TextXAlignment = Enum.TextXAlignment.Left
visitTitle.ZIndex = 21
visitTitle.Parent = visitPanel

local visitCloseButton = Instance.new("TextButton")
visitCloseButton.BackgroundColor3 = PALETTE.danger
visitCloseButton.Size = UDim2.new(0, 36, 0, 36)
visitCloseButton.AnchorPoint = Vector2.new(1, 0)
visitCloseButton.Position = UDim2.new(1, -8, 0, 8)
visitCloseButton.Text = "X"
visitCloseButton.Font = FONT_HEAVY
visitCloseButton.TextScaled = true
visitCloseButton.TextColor3 = Color3.new(1, 1, 1)
visitCloseButton.ZIndex = 21
visitCloseButton.Parent = visitPanel
corner(visitCloseButton, 10)

local visitList = Instance.new("ScrollingFrame")
visitList.BackgroundTransparency = 1
visitList.Size = UDim2.new(1, -20, 1, -60)
visitList.Position = UDim2.new(0, 10, 0, 52)
visitList.CanvasSize = UDim2.new(0, 0, 0, 0)
visitList.AutomaticCanvasSize = Enum.AutomaticSize.Y
visitList.ScrollBarThickness = 6
visitList.ZIndex = 21
visitList.Parent = visitPanel

local visitListLayout = Instance.new("UIListLayout")
visitListLayout.Padding = UDim.new(0, 8)
visitListLayout.SortOrder = Enum.SortOrder.LayoutOrder
visitListLayout.Parent = visitList

local visitEmptyLabel = Instance.new("TextLabel")
visitEmptyLabel.BackgroundTransparency = 1
visitEmptyLabel.Size = UDim2.new(1, 0, 0, 60)
visitEmptyLabel.Text = "No one else is here right now."
visitEmptyLabel.TextColor3 = PALETTE.textDim
visitEmptyLabel.Font = FONT_BODY
visitEmptyLabel.TextScaled = true
visitEmptyLabel.TextWrapped = true
visitEmptyLabel.LayoutOrder = 999
visitEmptyLabel.ZIndex = 21
visitEmptyLabel.Parent = visitList

-- Forward-declared so the FriendsInServerData handler (registered after the function
-- body below) can call it. Declaring the handler ABOVE the function would capture a nil
-- upvalue permanently -- the panel would never refresh when friend data arrived.
local latestFriendsData = nil
local renderVisitList

function renderVisitList()
	visitList:ClearAllChildren()
	local relayout = Instance.new("UIListLayout")
	relayout.Padding = UDim.new(0, 8)
	relayout.SortOrder = Enum.SortOrder.LayoutOrder
	relayout.Parent = visitList

	-- Rows come from the SERVER now (friend status can't be resolved client-side without
	-- a yielding, rate-limited web call per player). Falls back to the raw player list if
	-- the server data hasn't arrived yet, so the panel is never empty on first open.
	local others = latestFriendsData
	if not others then
		others = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LocalPlayer then
				table.insert(others, { userId = p.UserId, displayName = p.DisplayName, isFriend = false })
			end
		end
	end

	if #others == 0 then
		local emptyLabel = visitEmptyLabel:Clone()
		emptyLabel.Parent = visitList
		return
	end

	for i, p in ipairs(others) do
		local row = Instance.new("Frame")
		row.BackgroundColor3 = PALETTE.bg
		row.Size = UDim2.new(1, 0, 0, 56)
		row.LayoutOrder = i
		row.ZIndex = 21
		row.Parent = visitList
		corner(row, 12)

		local nameLabel = Instance.new("TextLabel")
		nameLabel.BackgroundTransparency = 1
		nameLabel.Size = UDim2.new(1, -222, 1, 0)
		nameLabel.Position = UDim2.new(0, 10, 0, 0)
		-- Friends are marked and tinted so they're findable at a glance in a full server.
		nameLabel.Text = (p.isFriend and "\u{2B50} " or "") .. p.displayName
		nameLabel.TextColor3 = p.isFriend and PALETTE.success or Color3.new(1, 1, 1)
		nameLabel.Font = FONT_BODY
		nameLabel.TextScaled = true
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.ZIndex = 21
		nameLabel.Parent = row

		local visitButton = Instance.new("TextButton")
		visitButton.Size = UDim2.new(0, 76, 0, 40)
		visitButton.AnchorPoint = Vector2.new(1, 0.5)
		visitButton.Position = UDim2.new(1, -8, 0.5, 0)
		visitButton.Text = pendingGiftUid and "\u{1F381} Gift" or "Visit"
		visitButton.Font = FONT_HEAVY
		visitButton.TextScaled = true
		visitButton.BackgroundColor3 = Color3.fromRGB(90, 150, 190)
		visitButton.TextColor3 = Color3.new(1, 1, 1)
		visitButton.ZIndex = 21
		visitButton.Parent = row
		corner(visitButton, 10)
		addHoverFeedback(visitButton)

		visitButton.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.4, 1.2)
			if pendingGiftUid then
				-- A gift is awaiting a recipient: this tap sends it rather than teleporting.
				remotes.RequestGift:FireServer(p.userId, pendingGiftUid)
				pendingGiftUid = nil
			else
				remotes.RequestVisitRanch:FireServer(p.userId)
			end
			setPanelOpen(visitPanel, false)
		end)

		-- Like button. Sits left of Visit; shows the target's current like count so the
		-- number is visible without having to visit them first.
		local likeButton = Instance.new("TextButton")
		likeButton.Name = "LikeButton"
		likeButton.Size = UDim2.new(0, 64, 0, 40)
		likeButton.AnchorPoint = Vector2.new(1, 0.5)
		likeButton.Position = UDim2.new(1, -90, 0.5, 0)
		likeButton.Font = FONT_HEAVY
		likeButton.TextScaled = true
		likeButton.TextColor3 = Color3.new(1, 1, 1)
		likeButton.ZIndex = 21
		likeButton.Parent = row
		corner(likeButton, 10)
		addHoverFeedback(likeButton)

		local liked = p.alreadyLiked == true
		local function renderLike(count, isLiked)
			likeButton.Text = (isLiked and "\u{2764}\u{FE0F} " or "\u{1F90D} ") .. tostring(count or 0)
			likeButton.BackgroundColor3 = isLiked and Color3.fromRGB(200, 70, 110)
				or Color3.fromRGB(90, 90, 110)
		end
		renderLike(p.likes or 0, liked)

		likeButton.MouseButton1Click:Connect(function()
			if liked then return end -- one like per player; server enforces this too
			playSound(SFX.UiTick, 0.4, 1.4)
			remotes.RequestLikeRanch:FireServer(p.userId)
			-- Optimistic local update; the server's RanchLikeResult corrects it if the
			-- like was actually rejected.
			liked = true
			renderLike((p.likes or 0) + 1, true)
		end)

		-- Trade request button. Server enforces proximity, so this can be tapped from
		-- the list and will simply tell the player to get closer if they're too far.
		local tradeBtn = Instance.new("TextButton")
		tradeBtn.Size = UDim2.new(0, 58, 0, 40)
		tradeBtn.AnchorPoint = Vector2.new(1, 0.5)
		tradeBtn.Position = UDim2.new(1, -158, 0.5, 0)
		tradeBtn.Text = "\u{1F91D}"
		tradeBtn.Font = FONT_HEAVY
		tradeBtn.TextScaled = true
		tradeBtn.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
		tradeBtn.TextColor3 = Color3.fromRGB(20, 40, 60)
		tradeBtn.ZIndex = 21
		tradeBtn.Parent = row
		corner(tradeBtn, 10)
		addHoverFeedback(tradeBtn)
		tradeBtn.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.4, 1.2)
			remotes.RequestTrade:FireServer(p.userId)
			setPanelOpen(visitPanel, false)
		end)
	end
end

remotes.FriendsInServerData.OnClientEvent:Connect(function(data)
	latestFriendsData = data
	if visitPanel.Visible then renderVisitList() end
end)

visitRanchButton.MouseButton1Click:Connect(function()
	playSound(SFX.UiTick, 0.4, 1.2)
	setPanelOpen(visitPanel, not visitPanel.Visible)
	if visitPanel.Visible then
		renderVisitList()
		remotes.RequestFriendsInServer:FireServer()
	end
end)
visitCloseButton.MouseButton1Click:Connect(function()
	setPanelOpen(visitPanel, false)
	-- Abandon any pending gift: leaving the picker without choosing means the player
	-- changed their mind, and a uid left dangling would fire on their next unrelated
	-- visit tap.
	pendingGiftUid = nil
end)
end

remotes.VisitRanchResult.OnClientEvent:Connect(function(ok, nameOrReason, hostName)
	if hostName then
		-- This fire is the HOST-side notice (someone else visited MY ranch)
		showGrabBanner(string.format("\u{1F465} %s is visiting your ranch!", hostName))
		return
	end
	if ok then
		playSound(SFX.HatchShake, 0.4, 0.9)
		shakeCamera(0.15, 0.3)
		showGrabBanner(string.format("\u{1F465} Visiting %s's ranch!", nameOrReason))
	else
		showGrabBanner(nameOrReason)
	end
end)
-- ================= World mechanic + creature interaction toasts =================
-- Every one of these server systems was built and verified server-side, but had NO
-- client handler -- meaning players got zero feedback for Treasure Finds, Forest
-- Sprites, Beach Crabs, Sandstorm survival, or Critter Pats. Found during the Critter
-- Pat build; fixed for all five together here rather than one at a time.
do
	-- Creature voices scale with rarity: small ones chirp high and quick, big ones
	-- rumble low and slow. Same three verified assets, re-pitched -- one sound file
	-- per creature isn't possible here, so pitch carries the size difference.
	local CRITTER_VOICE = {
		Common    = { "CritterChirp",  1.55 },
		Rare      = { "CritterChirp",  1.30 },
		Epic      = { "CritterCall",   1.20 },
		Legendary = { "CritterCall",   0.95 },
		Mythic    = { "CritterRumble", 0.85 },
	}
	remotes.CritterPatted.OnClientEvent:Connect(function(reward, rarity)
		local voice = CRITTER_VOICE[rarity] or CRITTER_VOICE.Common
		playSound(SFX[voice[1]], 0.45, voice[2])
		showGrabBanner(string.format("\u{1F49B} Your critter loved that! +%s Sparks", Constants.FormatNumber(reward)))
	end)

	remotes.TreasureFound.OnClientEvent:Connect(function(species, reward)
		playSound(SFX.QuestComplete, 0.5, 1.2)
		showGrabBanner(string.format("\u{1F48E} %s found treasure! +%s Sparks", species, Constants.FormatNumber(reward)))
	end)

	remotes.ForestSpriteFound.OnClientEvent:Connect(function(reward)
		playSound(SFX.QuestComplete, 0.5, 1.3)
		showGrabBanner(string.format("\u{1F33F} You found a Forest Sprite! +%s Sparks", Constants.FormatNumber(reward)))
	end)

	remotes.BeachCrabResult.OnClientEvent:Connect(function(caught, amount)
		if caught then
			playSound(SFX.QuestComplete, 0.5, 1.2)
			showGrabBanner(string.format("\u{1F980} Caught the crab! +%s Sparks", Constants.FormatNumber(amount)))
		else
			playSound(SFX.UiTick, 0.4, 0.7)
			showGrabBanner(string.format("\u{1F980} A crab escaped with %s Sparks!", Constants.FormatNumber(amount)))
		end
	end)

	remotes.SandstormSurvived.OnClientEvent:Connect(function(reward)
		playSound(SFX.QuestComplete, 0.5, 1.1)
		showGrabBanner(string.format("\u{1F4A8} You weathered the sandstorm! +%s Sparks", Constants.FormatNumber(reward)))
	end)

	remotes.FeedRanchResult.OnClientEvent:Connect(function(ok, detail)
		if ok then
			playSound(SFX.QuestComplete, 0.5, 1.3)
			showGrabBanner(string.format("\u{1F34E} Fed their creatures! +%s Sparks",
				Constants.FormatNumber(detail)))
		elseif detail == "AlreadyFedToday" then
			showGrabBanner("You already fed that ranch today!")
		elseif detail == "NoCreatures" then
			showGrabBanner("That ranch has no creatures to feed.")
		end
	end)

	remotes.RanchFedNotice.OnClientEvent:Connect(function(visitorName, happiness)
		playSound(SFX.UiTick, 0.45, 1.4)
		showGrabBanner(string.format("\u{1F34E} %s fed your creatures! Happiness %d",
			tostring(visitorName), tonumber(happiness) or 0))
	end)

	-- Sanctuary discovery. Names the finder so the ranch creatures feel like they're
	-- doing something rather than a faceless timer paying out.
	remotes.DiscoveryFound.OnClientEvent:Connect(function(finder, kind, detail)
		playSound(SFX.QuestComplete, 0.55, 1.25)
		local text
		if kind == "sparks" then
			text = string.format("\u{1F50D} %s dug up %s Sparks!", tostring(finder),
				Constants.FormatNumber(detail))
		elseif kind == "potion" then
			text = string.format("\u{1F50D} %s found a %s!", tostring(finder), tostring(detail))
		elseif kind == "limitedEgg" then
			text = string.format("\u{1F50D} %s found a LIMITED EGG TOKEN!", tostring(finder))
		else
			text = string.format("\u{1F50D} %s found something!", tostring(finder))
		end
		showGrabBanner(text)
	end)

	-- Relic find. Priority 3: these are rare and permanent, so burying one behind
	-- routine Sparks toasts would waste the moment entirely.
	-- Badge awards. Priority 3: a Roblox badge is permanent and public, so it should
	-- not be buried behind routine Sparks toasts.
	remotes.BadgeAwarded.OnClientEvent:Connect(function(name, desc)
		playSound(SFX.HatchFanfare, 0.6, 1.15)
		showGrabBanner(string.format("\u{1F3C5} BADGE EARNED: %s", tostring(name)), 3)
	end)

	remotes.RelicFound.OnClientEvent:Connect(function(icon, name, count)
		playSound(SFX.HatchFanfare, 0.55, 1.2)
		showGrabBanner(string.format("%s RELIC FOUND: %s  (x%d)", tostring(icon), tostring(name),
			tonumber(count) or 1), 3)
	end)

	remotes.WindCrystalCollected.OnClientEvent:Connect(function(reward)
		playSound(SFX.QuestComplete, 0.5, 1.4)
		showGrabBanner(string.format("\u{1F32C}\u{FE0F} Wind Crystal! +%s Sparks", Constants.FormatNumber(reward)))
	end)

	remotes.MoltenOreCollected.OnClientEvent:Connect(function(reward)
		playSound(SFX.QuestComplete, 0.5, 0.9)
		showGrabBanner(string.format("\u{2604}\u{FE0F} Molten ore collected! +%s Sparks", Constants.FormatNumber(reward)))
	end)

	remotes.WeeklyRewardGranted.OnClientEvent:Connect(function(rank, sparks, label)
		playSound(SFX.HatchFanfare, 0.6, 1.0)
		task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.5, 1.5) end)
		showGrabBanner(string.format("\u{1F3C6} %s last week! +%s Sparks",
			tostring(label), Constants.FormatNumber(sparks), 3))
	end)

	remotes.VipDailyGranted.OnClientEvent:Connect(function(sparks)
		playSound(SFX.HatchFanfare, 0.55, 1.0)
		showGrabBanner(string.format("\u{1F451} VIP Daily Bonus! +%s Sparks", Constants.FormatNumber(sparks), 2))
	end)

	remotes.StarterPackPurchased.OnClientEvent:Connect(function(sparks, slots, tokens)
		playSound(SFX.HatchFanfare, 0.6, 1.0)
		showGrabBanner(string.format("\u{1F381} Starter Pack! +%s Sparks, +%d slots, +%d Limited Egg",
			Constants.FormatNumber(sparks), slots, tokens), 3)
	end)

	remotes.PlaytimeReward.OnClientEvent:Connect(function(minutes, sparks)
		playSound(SFX.HatchFanfare, 0.55, 1.1)
		showGrabBanner(string.format("\u{23F1}\u{FE0F} %d minutes played! +%s Sparks",
			minutes, Constants.FormatNumber(sparks)))
	end)

	-- Offline earnings "Welcome Back" popup. A full centered panel rather than a toast:
	-- this is the first thing a returning player sees and the single strongest reason
	-- to come back tomorrow, so it earns real screen presence.
	remotes.OfflineEarnings.OnClientEvent:Connect(function(amount, secondsAway)
		playSound(SFX.HatchFanfare, 0.6, 1.0)
		task.delay(0.15, function() playSound(SFX.HatchFanfare, 0.5, 1.5) end)

		local hours = math.floor(secondsAway / 3600)
		local mins = math.floor((secondsAway % 3600) / 60)
		local awayText
		if hours > 0 then
			awayText = string.format("You were away for %dh %dm", hours, mins)
		else
			awayText = string.format("You were away for %dm", mins)
		end

		local popup = Instance.new("Frame")
		popup.Name = "OfflineEarningsPopup"
		popup.BackgroundColor3 = PALETTE.card
		popup.Size = UDim2.new(0, 320, 0, 170)
		popup.AnchorPoint = Vector2.new(0.5, 0.5)
		popup.Position = UDim2.new(0.5, 0, 0.5, 0)
		popup.ZIndex = 40
		popup.Parent = screenGui
		corner(popup, 18)
		stroke(popup, PALETTE.accentGold, 3)

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -20, 0, 34)
		title.Position = UDim2.new(0, 10, 0, 12)
		title.Text = "\u{1F44B} WELCOME BACK!"
		title.TextColor3 = PALETTE.accentGold
		title.Font = FONT_HEAVY
		title.TextScaled = true
		title.ZIndex = 41
		title.Parent = popup

		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Size = UDim2.new(1, -20, 0, 20)
		sub.Position = UDim2.new(0, 10, 0, 48)
		sub.Text = awayText
		sub.TextColor3 = PALETTE.textDim
		sub.Font = FONT_BODY
		sub.TextScaled = true
		sub.ZIndex = 41
		sub.Parent = popup

		local earned = Instance.new("TextLabel")
		earned.BackgroundTransparency = 1
		earned.Size = UDim2.new(1, -20, 0, 44)
		earned.Position = UDim2.new(0, 10, 0, 74)
		earned.Text = "+" .. Constants.FormatNumber(amount) .. " \u{2728}"
		earned.TextColor3 = PALETTE.success
		earned.Font = FONT_HEAVY
		earned.TextScaled = true
		earned.ZIndex = 41
		earned.Parent = popup

		local note = Instance.new("TextLabel")
		note.BackgroundTransparency = 1
		note.Size = UDim2.new(1, -20, 0, 18)
		note.Position = UDim2.new(0, 10, 0, 118)
		note.Text = "Your critters kept earning while you were gone!"
		note.TextColor3 = PALETTE.textDim
		note.Font = FONT_BODY
		note.TextScaled = true
		note.ZIndex = 41
		note.Parent = popup

		local okBtn = Instance.new("TextButton")
		okBtn.Size = UDim2.new(0, 120, 0, 32)
		okBtn.AnchorPoint = Vector2.new(0.5, 1)
		okBtn.Position = UDim2.new(0.5, 0, 1, -8)
		okBtn.Text = "Nice!"
		okBtn.Font = FONT_HEAVY
		okBtn.TextScaled = true
		okBtn.BackgroundColor3 = PALETTE.accentGold
		okBtn.TextColor3 = Color3.fromRGB(40, 30, 10)
		okBtn.ZIndex = 41
		okBtn.Parent = popup
		corner(okBtn, 10)
		addHoverFeedback(okBtn)
		okBtn.MouseButton1Click:Connect(function()
			playSound(SFX.UiTick, 0.4, 1.2)
			popup:Destroy()
		end)

		-- Auto-dismiss as a safety net so it can never block the screen permanently.
		task.delay(12, function()
			if popup and popup.Parent then popup:Destroy() end
		end)
	end)

	-- Multi-hatch summary. Only shown when the batch was CUT SHORT (ran out of Sparks
	-- or hit locked slots) -- a successful full batch already produced N hatch reveals,
	-- so an extra "you hatched 8/8" toast on top of that is pure noise.
	remotes.MultiHatchSummary.OnClientEvent:Connect(function(succeeded, requested)
		if succeeded < requested then
			showGrabBanner(string.format("Hatched %d of %d \u{2014} ran out of Sparks!", succeeded, requested))
		end
	end)
end

-- ================= Egg Odds panel =================
-- Shows what each egg actually gives: guaranteed tier, income, species pool size, and
-- the player's LIVE shiny chance (which moves with rebirth luck and Lucky Hour).
-- Trust matters more than spectacle here -- players notice invented odds.
do
	local oddsButton = Instance.new("TextButton")
	oddsButton.Name = "EggOddsButton"
	oddsButton.Text = "\u{1F4CA} Odds"
	oddsButton.Font = FONT_HEAVY
	oddsButton.TextScaled = true
	oddsButton.TextColor3 = Color3.new(1, 1, 1)
	oddsButton.BackgroundColor3 = Color3.fromRGB(80, 140, 180)
	oddsButton.Size = UDim2.new(0, 110, 0, 44)
	oddsButton.AnchorPoint = Vector2.new(1, 0)
	oddsButton.Position = UDim2.new(1, -20, 0, 488)
	oddsButton.Parent = screenGui
	addHoverFeedback(oddsButton)
	corner(oddsButton, 12)
	stroke(oddsButton, Color3.new(1, 1, 1), 2)

	local oddsPanel = Instance.new("Frame")
	oddsPanel.Name = "EggOddsPanel"
	oddsPanel.BackgroundColor3 = PALETTE.card
	oddsPanel.Size = UDim2.new(0, 340, 0, 300)
	oddsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	oddsPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	setPanelOpen(oddsPanel, false)
	oddsPanel.ZIndex = 20
	oddsPanel.Parent = screenGui
	corner(oddsPanel, 18)
	stroke(oddsPanel, Color3.fromRGB(80, 140, 180), 3)

	local oddsTitle = Instance.new("TextLabel")
	oddsTitle.BackgroundTransparency = 1
	oddsTitle.Size = UDim2.new(1, -60, 0, 32)
	oddsTitle.Position = UDim2.new(0, 12, 0, 8)
	oddsTitle.Text = "\u{1F4CA} EGG ODDS"
	oddsTitle.TextColor3 = Color3.new(1, 1, 1)
	oddsTitle.Font = FONT_HEAVY
	oddsTitle.TextScaled = true
	oddsTitle.TextXAlignment = Enum.TextXAlignment.Left
	oddsTitle.ZIndex = 21
	oddsTitle.Parent = oddsPanel

	local oddsClose = Instance.new("TextButton")
	oddsClose.BackgroundColor3 = PALETTE.danger
	oddsClose.Size = UDim2.new(0, 32, 0, 32)
	oddsClose.AnchorPoint = Vector2.new(1, 0)
	oddsClose.Position = UDim2.new(1, -8, 0, 8)
	oddsClose.Text = "X"
	oddsClose.Font = FONT_HEAVY
	oddsClose.TextScaled = true
	oddsClose.TextColor3 = Color3.new(1, 1, 1)
	oddsClose.ZIndex = 21
	oddsClose.Parent = oddsPanel
	corner(oddsClose, 10)

	local shinyLabel = Instance.new("TextLabel")
	shinyLabel.BackgroundColor3 = Color3.fromRGB(40, 36, 56)
	shinyLabel.Size = UDim2.new(1, -24, 0, 34)
	shinyLabel.Position = UDim2.new(0, 12, 0, 44)
	shinyLabel.Text = ""
	shinyLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	shinyLabel.Font = FONT_HEAVY
	shinyLabel.TextScaled = true
	shinyLabel.ZIndex = 21
	shinyLabel.Parent = oddsPanel
	corner(shinyLabel, 8)

	local oddsList = Instance.new("ScrollingFrame")
	oddsList.BackgroundTransparency = 1
	oddsList.Size = UDim2.new(1, -20, 1, -92)
	oddsList.Position = UDim2.new(0, 10, 0, 84)
	oddsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	oddsList.CanvasSize = UDim2.new(0, 0, 0, 0)
	oddsList.ScrollBarThickness = 6
	oddsList.ZIndex = 21
	oddsList.Parent = oddsPanel
	local oddsLayout = Instance.new("UIListLayout")
	oddsLayout.Padding = UDim.new(0, 6)
	oddsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	oddsLayout.Parent = oddsList

	remotes.EggOddsData.OnClientEvent:Connect(function(rows, shinyChance, luckyActive)
		shinyLabel.Text = string.format("\u{2728} Shiny chance: %.1f%%%s",
			shinyChance * 100, luckyActive and "  (LUCKY HOUR!)" or "")
		shinyLabel.TextColor3 = luckyActive and PALETTE.success or Color3.fromRGB(255, 220, 120)

		oddsList:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 6)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = oddsList

		for i, r in ipairs(rows) do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = PALETTE.bg
			row.Size = UDim2.new(1, 0, 0, 52)
			row.LayoutOrder = i
			row.ZIndex = 21
			row.Parent = oddsList
			corner(row, 10)
			stroke(row, RARITY_COLORS_CINEMATIC[r.id] or PALETTE.locked, 2)

			local name = Instance.new("TextLabel")
			name.BackgroundTransparency = 1
			name.Size = UDim2.new(1, -20, 0, 22)
			name.Position = UDim2.new(0, 10, 0, 4)
			name.Text = string.format("%s Egg \u{2014} %s \u{2728}", r.id, Constants.FormatNumber(r.cost))
			name.TextColor3 = RARITY_COLORS_CINEMATIC[r.id] or Color3.new(1, 1, 1)
			name.Font = FONT_HEAVY
			name.TextScaled = true
			name.TextXAlignment = Enum.TextXAlignment.Left
			name.ZIndex = 22
			name.Parent = row

			local detail = Instance.new("TextLabel")
			detail.BackgroundTransparency = 1
			detail.Size = UDim2.new(1, -20, 0, 20)
			detail.Position = UDim2.new(0, 10, 0, 27)
			detail.Text = string.format("100%% %s \u{2022} %d species \u{2022} +%s/sec",
				r.id, r.speciesCount, Constants.FormatNumber(r.rate))
			detail.TextColor3 = PALETTE.textDim
			detail.Font = FONT_BODY
			detail.TextScaled = true
			detail.TextXAlignment = Enum.TextXAlignment.Left
			detail.ZIndex = 22
			detail.Parent = row
		end
	end)

	oddsButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		setPanelOpen(oddsPanel, not oddsPanel.Visible)
		if oddsPanel.Visible then remotes.RequestEggOdds:FireServer("StarterMeadow") end
	end)
	oddsClose.MouseButton1Click:Connect(function()
		setPanelOpen(oddsPanel, false)
	end)
end

-- ================= Creature Sanctuary panel =================
-- Assign spare creatures to live at the ranch. Shows Ranch Power, the active perk, and
-- happiness. Wrapped in do...end because ClientMain sits near Luau's 200-local limit.
do
	local sanctuaryButton = Instance.new("TextButton")
	sanctuaryButton.Name = "SanctuaryButton"
	sanctuaryButton.Text = "\u{1F3E1} Sanctuary"
	sanctuaryButton.Font = FONT_HEAVY
	sanctuaryButton.TextScaled = true
	sanctuaryButton.TextColor3 = Color3.new(1, 1, 1)
	sanctuaryButton.BackgroundColor3 = PALETTE.successDim
	sanctuaryButton.Size = UDim2.new(0, 110, 0, 44)
	sanctuaryButton.AnchorPoint = Vector2.new(1, 0)
	sanctuaryButton.Position = UDim2.new(1, -20, 0, 488)
	sanctuaryButton.ZIndex = 12
	sanctuaryButton.Parent = screenGui
	addHoverFeedback(sanctuaryButton)
	corner(sanctuaryButton, 12)
	stroke(sanctuaryButton, Color3.new(1, 1, 1), 2)

	local panel = Instance.new("Frame")
	panel.Name = "SanctuaryPanel"
	panel.BackgroundColor3 = PALETTE.card
	panel.Size = UDim2.new(0, 380, 0.85, 0)
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(380, 460)
	cap.Parent = panel
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	setPanelOpen(panel, false)
	panel.ZIndex = 20
	panel.Parent = screenGui
	corner(panel, 18)
	stroke(panel, PALETTE.successDim, 3)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -60, 0, 34)
	title.Position = UDim2.new(0, 12, 0, 8)
	title.Text = "\u{1F3E1} CREATURE SANCTUARY"
	title.TextColor3 = PALETTE.success
	title.Font = FONT_HEAVY
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 21
	title.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.BackgroundColor3 = PALETTE.danger
	closeBtn.Size = UDim2.new(0, 34, 0, 34)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.Position = UDim2.new(1, -8, 0, 8)
	closeBtn.Text = "X"
	closeBtn.Font = FONT_HEAVY
	closeBtn.TextScaled = true
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.ZIndex = 21
	closeBtn.Parent = panel
	corner(closeBtn, 10)

	local summary = Instance.new("TextLabel")
	summary.Name = "SanctuarySummary"
	summary.BackgroundColor3 = Color3.fromRGB(38, 46, 38)
	summary.Size = UDim2.new(1, -24, 0, 56)
	summary.Position = UDim2.new(0, 12, 0, 46)
	summary.Text = ""
	summary.TextColor3 = Color3.new(1, 1, 1)
	summary.Font = FONT_BODY
	summary.TextScaled = true
	summary.ZIndex = 21
	summary.Parent = panel
	corner(summary, 10)

	local list = Instance.new("ScrollingFrame")
	list.Name = "SanctuaryList"
	list.BackgroundTransparency = 1
	list.Size = UDim2.new(1, -20, 1, -114)
	list.Position = UDim2.new(0, 10, 0, 108)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.ScrollBarThickness = 6
	list.ZIndex = 21
	list.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local latestSanctuary, latestInv = nil, nil

	local function render()
		if not latestSanctuary then return end
		local s = latestSanctuary
		summary.Text = string.format(
			"Power %s   \u{2022}   %d/%d housed   \u{2022}   Happiness %d/%d\n%s",
			Constants.FormatNumber(s.power or 0), #(s.assigned or {}), s.capacity or 0,
			s.happiness or 0, s.happinessMax or 100,
			(s.perks and s.perks.label) and ("Active: " .. s.perks.label) or "No perk yet")

		list:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 6)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = list

		-- Assigned creatures first (removable), then unassigned ones (addable). Showing
		-- both in one list means the player never has to switch views to make a swap,
		-- which is the actual decision the capacity cap creates.
		local assignedUids = {}
		for _, a in ipairs(s.assigned or {}) do assignedUids[a.uid] = true end

		local order = 0
		for _, a in ipairs(s.assigned or {}) do
			order += 1
			local row = Instance.new("Frame")
			row.BackgroundColor3 = Color3.fromRGB(44, 58, 44)
			row.Size = UDim2.new(1, 0, 0, 46)
			row.LayoutOrder = order
			row.ZIndex = 21
			row.Parent = list
			corner(row, 8)

			local nm = Instance.new("TextLabel")
			nm.BackgroundTransparency = 1
			nm.Size = UDim2.new(1, -96, 0, 22)
			nm.Position = UDim2.new(0, 10, 0, 3)
			nm.Text = ((a.variant ~= "Normal") and (a.variant .. " ") or "") ..
				(a.isShiny and "\u{2728} " or "") .. a.species
			nm.TextColor3 = Color3.new(1, 1, 1)
			nm.Font = FONT_HEAVY
			nm.TextScaled = true
			nm.TextXAlignment = Enum.TextXAlignment.Left
			nm.ZIndex = 22
			nm.Parent = row

			local sub = Instance.new("TextLabel")
			sub.BackgroundTransparency = 1
			sub.Size = UDim2.new(1, -96, 0, 17)
			sub.Position = UDim2.new(0, 10, 0, 25)
			sub.Text = string.format("%s  \u{2022}  %s power", a.rarity, Constants.FormatNumber(a.power))
			sub.TextColor3 = PALETTE.textDim
			sub.Font = FONT_BODY
			sub.TextScaled = true
			sub.TextXAlignment = Enum.TextXAlignment.Left
			sub.ZIndex = 22
			sub.Parent = row

			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(0, 78, 0, 32)
			btn.AnchorPoint = Vector2.new(1, 0.5)
			btn.Position = UDim2.new(1, -8, 0.5, 0)
			btn.Text = "Remove"
			btn.Font = FONT_HEAVY
			btn.TextScaled = true
			btn.BackgroundColor3 = PALETTE.danger
			btn.TextColor3 = Color3.new(1, 1, 1)
			btn.ZIndex = 22
			btn.Parent = row
			corner(btn, 8)
			addHoverFeedback(btn)
			btn.MouseButton1Click:Connect(function()
				playSound(SFX.UiTick, 0.4, 0.9)
				remotes.RequestUnassignSanctuary:FireServer(a.uid)
			end)
		end

		if latestInv and latestInv.critters then
			for _, c in ipairs(latestInv.critters) do
				if not assignedUids[c.uid] then
					order += 1
					local row = Instance.new("Frame")
					row.BackgroundColor3 = PALETTE.bg
					row.Size = UDim2.new(1, 0, 0, 46)
					row.LayoutOrder = 1000 + order
					row.ZIndex = 21
					row.Parent = list
					corner(row, 8)

					local nm = Instance.new("TextLabel")
					nm.BackgroundTransparency = 1
					nm.Size = UDim2.new(1, -96, 0, 22)
					nm.Position = UDim2.new(0, 10, 0, 3)
					nm.Text = ((c.variant and c.variant ~= "Normal") and (c.variant .. " ") or "") ..
						(c.isShiny and "\u{2728} " or "") .. c.species
					nm.TextColor3 = PALETTE.textDim
					nm.Font = FONT_HEAVY
					nm.TextScaled = true
					nm.TextXAlignment = Enum.TextXAlignment.Left
					nm.ZIndex = 22
					nm.Parent = row

					local sub = Instance.new("TextLabel")
					sub.BackgroundTransparency = 1
					sub.Size = UDim2.new(1, -96, 0, 17)
					sub.Position = UDim2.new(0, 10, 0, 25)
					sub.Text = tostring(c.rarity) .. "  \u{2022}  not housed"
					sub.TextColor3 = PALETTE.textDim
					sub.Font = FONT_BODY
					sub.TextScaled = true
					sub.TextXAlignment = Enum.TextXAlignment.Left
					sub.ZIndex = 22
					sub.Parent = row

					local btn = Instance.new("TextButton")
					btn.Size = UDim2.new(0, 78, 0, 32)
					btn.AnchorPoint = Vector2.new(1, 0.5)
					btn.Position = UDim2.new(1, -8, 0.5, 0)
					btn.Text = "House"
					btn.Font = FONT_HEAVY
					btn.TextScaled = true
					btn.BackgroundColor3 = PALETTE.successDim
					btn.TextColor3 = Color3.new(1, 1, 1)
					btn.ZIndex = 22
					btn.Parent = row
					corner(btn, 8)
					addHoverFeedback(btn)
					btn.MouseButton1Click:Connect(function()
						playSound(SFX.UiTick, 0.4, 1.2)
						remotes.RequestAssignSanctuary:FireServer(c.uid)
					end)
				end
			end
		end
	end

	remotes.SanctuaryState.OnClientEvent:Connect(function(s)
		latestSanctuary = s
		render()
	end)
	remotes.InventoryData.OnClientEvent:Connect(function(d)
		latestInv = d
		if panel.Visible then render() end
	end)
	remotes.SanctuaryResult.OnClientEvent:Connect(function(ok, reason)
		if not ok then
			if reason == "SanctuaryFull" then
				showGrabBanner("Sanctuary is full \u{2014} upgrade your ranch for more room!")
			elseif reason == "AlreadyAssigned" then
				showGrabBanner("That creature already lives there.")
			end
		end
	end)

	sanctuaryButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		setPanelOpen(panel, not panel.Visible)
		if panel.Visible then
			remotes.RequestSanctuaryState:FireServer()
			remotes.RequestInventoryData:FireServer()
			remotes.RequestRelicState:FireServer()
		end
	end)
	closeBtn.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.35, 0.85)
		setPanelOpen(panel, false)
	end)
end

-- ================= Long-Term Goals panel (item #11) =================
do
	local goalsButton = Instance.new("TextButton")
	goalsButton.Name = "GoalsButton"
	goalsButton.Text = "\u{1F3C1} Goals"
	goalsButton.Font = FONT_HEAVY
	goalsButton.TextScaled = true
	goalsButton.TextColor3 = Color3.new(1, 1, 1)
	goalsButton.BackgroundColor3 = Color3.fromRGB(90, 200, 160)
	goalsButton.Size = UDim2.new(0, 110, 0, 44)
	goalsButton.AnchorPoint = Vector2.new(1, 0)
	goalsButton.Position = UDim2.new(1, -20, 0, 436)
	goalsButton.Parent = screenGui
	addHoverFeedback(goalsButton)
	corner(goalsButton, 12)
	stroke(goalsButton, Color3.new(1, 1, 1), 2)

	local goalsPanel = Instance.new("Frame")
	goalsPanel.Name = "GoalsPanel"
	goalsPanel.BackgroundColor3 = PALETTE.card
	goalsPanel.Size = UDim2.new(0, 360, 0.85, 0)
	local goalsSizeCap = Instance.new("UISizeConstraint")
	goalsSizeCap.MaxSize = Vector2.new(360, 460)
	goalsSizeCap.Parent = goalsPanel
	goalsPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	goalsPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	setPanelOpen(goalsPanel, false)
	goalsPanel.ZIndex = 20
	goalsPanel.Parent = screenGui
	corner(goalsPanel, 18)
	stroke(goalsPanel, Color3.fromRGB(90, 200, 160), 3)

	local goalsTitle = Instance.new("TextLabel")
	goalsTitle.BackgroundTransparency = 1
	goalsTitle.Size = UDim2.new(1, -60, 0, 40)
	goalsTitle.Position = UDim2.new(0, 12, 0, 8)
	goalsTitle.Text = "\u{1F3C1} LONG-TERM GOALS"
	goalsTitle.TextColor3 = Color3.new(1, 1, 1)
	goalsTitle.Font = FONT_HEAVY
	goalsTitle.TextScaled = true
	goalsTitle.TextXAlignment = Enum.TextXAlignment.Left
	goalsTitle.ZIndex = 21
	goalsTitle.Parent = goalsPanel

	local goalsCloseButton = Instance.new("TextButton")
	goalsCloseButton.BackgroundColor3 = PALETTE.danger
	goalsCloseButton.Size = UDim2.new(0, 36, 0, 36)
	goalsCloseButton.AnchorPoint = Vector2.new(1, 0)
	goalsCloseButton.Position = UDim2.new(1, -8, 0, 8)
	goalsCloseButton.Text = "X"
	goalsCloseButton.Font = FONT_HEAVY
	goalsCloseButton.TextScaled = true
	goalsCloseButton.TextColor3 = Color3.new(1, 1, 1)
	goalsCloseButton.ZIndex = 21
	goalsCloseButton.Parent = goalsPanel
	corner(goalsCloseButton, 10)

	local goalsList = Instance.new("ScrollingFrame")
	goalsList.BackgroundTransparency = 1
	goalsList.Size = UDim2.new(1, -20, 1, -60)
	goalsList.Position = UDim2.new(0, 10, 0, 52)
	goalsList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	goalsList.CanvasSize = UDim2.new(0, 0, 0, 0)
	goalsList.ScrollBarThickness = 6
	goalsList.ZIndex = 21
	goalsList.Parent = goalsPanel

	local goalsLayout = Instance.new("UIListLayout")
	goalsLayout.Padding = UDim.new(0, 8)
	goalsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	goalsLayout.Parent = goalsList

	local function renderGoals(data)
		goalsList:ClearAllChildren()
		local relayout = Instance.new("UIListLayout")
		relayout.Padding = UDim.new(0, 8)
		relayout.SortOrder = Enum.SortOrder.LayoutOrder
		relayout.Parent = goalsList

		for i, g in ipairs(data) do
			local row = Instance.new("Frame")
			row.BackgroundColor3 = PALETTE.bg
			row.Size = UDim2.new(1, 0, 0, 64)
			row.LayoutOrder = i
			row.ZIndex = 21
			row.Parent = goalsList
			corner(row, 10)
			if g.completed then stroke(row, Color3.fromRGB(90, 200, 160), 2) end

			local icon = Instance.new("TextLabel")
			icon.BackgroundTransparency = 1
			icon.Size = UDim2.new(0, 36, 1, 0)
			icon.Text = g.completed and "\u{2705}" or "\u{1F3C1}"
			icon.TextScaled = true
			icon.Font = FONT_HEAVY
			icon.ZIndex = 22
			icon.Parent = row

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Size = UDim2.new(1, -110, 0, 26)
			nameLabel.Position = UDim2.new(0, 40, 0, 6)
			nameLabel.Text = g.title
			nameLabel.TextColor3 = g.completed and Color3.fromRGB(90, 200, 160) or Color3.new(1, 1, 1)
			nameLabel.Font = FONT_HEAVY
			nameLabel.TextScaled = true
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.ZIndex = 22
			nameLabel.Parent = row

			local progLabel = Instance.new("TextLabel")
			progLabel.BackgroundTransparency = 1
			progLabel.Size = UDim2.new(1, -110, 0, 20)
			progLabel.Position = UDim2.new(0, 40, 0, 32)
			progLabel.Text = string.format("%d / %d", g.current, g.threshold)
			progLabel.TextColor3 = PALETTE.textDim
			progLabel.Font = FONT_BODY
			progLabel.TextScaled = true
			progLabel.TextXAlignment = Enum.TextXAlignment.Left
			progLabel.ZIndex = 22
			progLabel.Parent = row

			local barBg = Instance.new("Frame")
			barBg.BackgroundColor3 = Color3.fromRGB(24, 22, 36)
			barBg.Size = UDim2.new(0, 70, 0, 8)
			barBg.AnchorPoint = Vector2.new(1, 0.5)
			barBg.Position = UDim2.new(1, -10, 0.5, 0)
			barBg.ZIndex = 22
			barBg.Parent = row
			corner(barBg, 4)

			local barFill = Instance.new("Frame")
			barFill.BackgroundColor3 = g.completed and Color3.fromRGB(90, 200, 160) or PALETTE.accentBlue
			barFill.Size = UDim2.new(g.threshold > 0 and (g.current / g.threshold) or 0, 0, 1, 0)
			barFill.BorderSizePixel = 0
			barFill.ZIndex = 23
			barFill.Parent = barBg
			corner(barFill, 4)
		end
	end

	remotes.GoalsData.OnClientEvent:Connect(renderGoals)

	goalsButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		setPanelOpen(goalsPanel, not goalsPanel.Visible)
		if goalsPanel.Visible then
			remotes.RequestGoalsData:FireServer()
		end
	end)
	goalsCloseButton.MouseButton1Click:Connect(function()
		setPanelOpen(goalsPanel, false)
	end)
end

-- Creature Inventory extracted to InventoryUI (ClientMain near the 200k source cap).
-- tradeIsActive / pendingGiftUid pass as accessors: they're mutable shared state, so
-- a by-value pass would give the module a stale copy and drop its writes.
require(script.Parent.InventoryUI).init({
	TweenService = TweenService, Constants = Constants, WorldsData = WorldsData,
	remotes = remotes, PALETTE = PALETTE, FONT_HEAVY = FONT_HEAVY, FONT_BODY = FONT_BODY,
	SFX = SFX, playSound = playSound, screenGui = screenGui, corner = corner,
	stroke = stroke, addHoverFeedback = addHoverFeedback, showGrabBanner = showGrabBanner,
	RARITY_COLORS = RARITY_COLORS,
	getTradeActive = function() return tradeIsActive end,
	setPendingGift = function(uid) pendingGiftUid = uid end,
})
-- ================= HUD Button Dock (consolidation pass) =================
-- Nine identical 110x44 buttons were stacked down the right edge spanning 460px of
-- vertical space -- real clutter, and on a phone that column would dominate the screen.
-- This keeps the three highest-frequency actions always visible and collapses the other
-- six behind a single Menu toggle.
--
-- Deliberately done by NAME LOOKUP on the ScreenGui rather than by editing each button's
-- original creation code: two of them (Goals, Inventory) live inside do...end blocks and
-- aren't reachable by variable name from here. Re-parenting by name is also far less
-- risky than nine separate edits scattered across a 130k-character file.
do
	local PRIMARY = { "ShopButton", "RebirthButton", "MyRanchButton" }
	local COLLAPSED = {
		"InventoryButton", "SanctuaryButton", "WorldsButton", "CodesButton", "CollectionButton", "GoalsButton", "EggOddsButton",
		"AchievementsButton", "VisitRanchButton", "SettingsButton",
	}

	-- Wait for every button to exist before rearranging -- some are created late in
	-- this script and inside nested scopes, so a plain immediate pass could miss them.
	local function findButton(name)
		return screenGui:FindFirstChild(name)
	end

	-- Reposition the three primary buttons into a tight top-right stack.
	for i, name in ipairs(PRIMARY) do
		local btn = findButton(name)
		if btn then
			btn.Position = UDim2.new(1, -20, 0, 20 + (i - 1) * 52)
		end
	end

	-- The Menu toggle sits directly below the primary stack.
	local menuButton = Instance.new("TextButton")
	menuButton.Name = "MenuToggleButton"
	menuButton.Text = "\u{2630} Menu"
	menuButton.Font = FONT_HEAVY
	menuButton.TextScaled = true
	menuButton.TextColor3 = Color3.new(1, 1, 1)
	menuButton.BackgroundColor3 = Color3.fromRGB(90, 86, 110)
	menuButton.Size = UDim2.new(0, 110, 0, 44)
	menuButton.AnchorPoint = Vector2.new(1, 0)
	menuButton.Position = UDim2.new(1, -20, 0, 20 + #PRIMARY * 52)
	menuButton.ZIndex = 12
	menuButton.Parent = screenGui
	addHoverFeedback(menuButton)
	corner(menuButton, 12)
	stroke(menuButton, Color3.new(1, 1, 1), 2)

	-- Container the collapsed buttons get re-parented into. Starts hidden.
	local menuPanel = Instance.new("Frame")
	menuPanel.Name = "MenuPanel"
	menuPanel.BackgroundColor3 = PALETTE.card
	menuPanel.Size = UDim2.new(0, 126, 0, #COLLAPSED * 52 + 12)
	menuPanel.AnchorPoint = Vector2.new(1, 0)
	menuPanel.Position = UDim2.new(1, -20, 0, 20 + (#PRIMARY + 1) * 52)
	setPanelOpen(menuPanel, false)
	menuPanel.ZIndex = 11
	menuPanel.Parent = screenGui
	corner(menuPanel, 14)
	stroke(menuPanel, Color3.fromRGB(120, 116, 145), 2)

	-- Re-parent each collapsed button into the panel, converting its absolute screen
	-- position into a position relative to the panel.
	for i, name in ipairs(COLLAPSED) do
		local btn = findButton(name)
		if btn then
			btn.Parent = menuPanel
			btn.AnchorPoint = Vector2.new(0.5, 0)
			btn.Position = UDim2.new(0.5, 0, 0, 6 + (i - 1) * 52)
			btn.ZIndex = 13
		end
	end

	menuButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		setPanelOpen(menuPanel, not menuPanel.Visible)
		menuButton.Text = menuPanel.Visible and "\u{2715} Close" or "\u{2630} Menu"
	end)
end

-- ================= RESPONSIVE LAYOUT PASS =================
-- Driven by real measurements taken on a 749x361 viewport, where the HUD was genuinely
-- broken: the Sparks counter and Shop button were drawing at y=-38 (behind Roblox's
-- 58px topbar), the Menu panel's bottom edge landed at y=494 on a 361px-tall screen
-- (cutting off the Goals button), the Elder dialogue box overlapped the Critter card,
-- and every centered panel was taller than the screen itself.
--
-- Runs LAST so it authoritatively corrects earlier absolute positioning, and re-runs on
-- every viewport change so it stays correct on resize / rotate / different devices.
do
	local GuiService = game:GetService("GuiService")
	local camera = workspace.CurrentCamera

	local BTN_W, BTN_H, BTN_GAP = 110, 44, 8
	local EDGE = 12

	local function layout()
		local viewport = camera.ViewportSize
		local screenW, screenH = viewport.X, viewport.Y
		local topInset = GuiService:GetGuiInset().Y

		-- ===== TOP-LEFT STACK: Sparks -> Level -> NextEgg =====
		-- All pushed below the topbar inset. This is the fix for the unreadable
		-- Sparks counter -- the ScreenGui has IgnoreGuiInset=true, so nothing
		-- accounts for the topbar unless we do it explicitly here.
        local y = topInset + EDGE
		-- Uses each element's ACTUAL rendered height (AbsoluteSize.Y) rather than a
		-- hardcoded guess -- an earlier version of this pass assumed heights that were
		-- 4-8px smaller than reality, which made every card in the stack overlap the
		-- next one. Measured, not assumed.
		local function placeLeft(name)
			local el = screenGui:FindFirstChild(name)
			if el and el.Visible ~= false then
				el.AnchorPoint = Vector2.new(0, 0)
				el.Position = UDim2.new(0, EDGE, 0, y)
				y = y + el.AbsoluteSize.Y + 8
			end
			return el
		end
		placeLeft("SparksCard")
		placeLeft("FriendBonusBadge")
		placeLeft("LevelCard")
		placeLeft("NextEggCard")

		-- ===== BOTTOM-LEFT STACK: quest cards + critter card =====
		-- Anchored to the BOTTOM edge and built upward, so they can never collide
		-- with the top stack regardless of screen height. Same measured-height approach.
		local by = screenH - EDGE
		-- topStackBottom is where the top-left column ended. On a short screen the two
		-- stacks genuinely compete for the same space, so the bottom stack HIDES its
		-- lowest-priority cards rather than overlapping the top stack. Measured on a
		-- 361px-tall viewport, where LevelCard and DailyQuestCard were colliding.
		local topStackBottom = y
		local function placeBottomLeft(name)
			local el = screenGui:FindFirstChild(name)
			if el then
				local h = el.AbsoluteSize.Y
				if by - h < topStackBottom then
					-- No room left without overlapping the top stack.
					el.Visible = false
				else
					el.Visible = true
					el.AnchorPoint = Vector2.new(0, 1)
					el.Position = UDim2.new(0, EDGE, 0, by)
					by = by - h - 8
				end
			end
		end
		placeBottomLeft("NextGoalCard")
		placeBottomLeft("CritterCard")
		placeBottomLeft("QuestCard")
		placeBottomLeft("DailyQuestCard")

		-- ===== RIGHT BUTTON COLUMN =====
		local ry = topInset + EDGE
		for _, name in ipairs({ "ShopButton", "RebirthButton", "MyRanchButton", "MenuToggleButton" }) do
			local btn = screenGui:FindFirstChild(name)
			if btn then
				btn.AnchorPoint = Vector2.new(1, 0)
				btn.Size = UDim2.new(0, BTN_W, 0, BTN_H)
				btn.Position = UDim2.new(1, -EDGE, 0, ry)
				ry = ry + BTN_H + BTN_GAP
			end
		end

		-- ===== MENU PANEL: must fit on screen =====
		-- Previously a fixed 324px tall starting at y=170 -> bottom edge at 494 on a
		-- 361px screen. Now height-capped to the actual remaining space, and scrollable
		-- if the buttons don't fit.
		local menuPanel = screenGui:FindFirstChild("MenuPanel")
		if menuPanel then
			local available = screenH - ry - EDGE
			-- Derived from the real button count rather than hardcoded -- adding an entry to
			-- COLLAPSED used to silently leave the panel one row too short.
			local menuCount = 0
			for _, ch in ipairs(menuPanel:GetDescendants()) do
				if ch:IsA("TextButton") then menuCount += 1 end
			end
			local desired = math.max(menuCount, 1) * (BTN_H + BTN_GAP) + 8
			menuPanel.AnchorPoint = Vector2.new(1, 0)
			menuPanel.Position = UDim2.new(1, -EDGE, 0, ry)
			menuPanel.Size = UDim2.new(0, BTN_W + 16, 0, math.min(desired, math.max(available, 80)))

			-- On a short screen the six buttons (312px) can't fit the available space, so
			-- the panel becomes SCROLLABLE rather than silently clipping them -- measured
			-- on a 361px viewport where 4 of 6 buttons were rendering past the panel edge.
			-- A ScrollingFrame is inserted once and reused on later layout passes.
			local scroller = menuPanel:FindFirstChild("MenuScroll")
			if not scroller then
				scroller = Instance.new("ScrollingFrame")
				scroller.Name = "MenuScroll"
				scroller.BackgroundTransparency = 1
				scroller.BorderSizePixel = 0
				scroller.ScrollBarThickness = 4
				scroller.ZIndex = 12
				scroller.Parent = menuPanel
				-- Move any already-parented buttons into the scroller.
				for _, child in ipairs(menuPanel:GetChildren()) do
					if child:IsA("TextButton") then child.Parent = scroller end
				end
			end
			scroller.Position = UDim2.new(0, 0, 0, 4)
			scroller.Size = UDim2.new(1, 0, 1, -8)

			local iy = 0
			for _, child in ipairs(scroller:GetChildren()) do
				if child:IsA("TextButton") then
					child.AnchorPoint = Vector2.new(0.5, 0)
					child.Size = UDim2.new(0, BTN_W, 0, BTN_H)
					child.Position = UDim2.new(0.5, 0, 0, iy)
					child.ZIndex = 13
					iy = iy + BTN_H + BTN_GAP
				end
			end
			scroller.CanvasSize = UDim2.new(0, 0, 0, math.max(0, iy - BTN_GAP))
		end

		-- ===== CENTERED PANELS: never taller/wider than the screen =====
		-- Every panel was authored at a fixed size (up to 420px tall) with no regard
		-- for the actual viewport, so on a short screen they overflowed top and bottom.
		local maxW = math.max(240, screenW - 2 * EDGE)
		local maxH = math.max(200, screenH - topInset - 2 * EDGE)
		for _, name in ipairs({
			"ShopPanel", "AchievementsPanel", "CollectionPanel", "GoalsPanel",
			"InventoryPanel", "SettingsPanel", "RebirthPanel", "VisitRanchPanel", "SanctuaryPanel", "WorldsPanel", "CodesPanel",
			"EggOddsPanel",
		}) do
			local panel = screenGui:FindFirstChild(name)
			if panel then
				local cap = panel:FindFirstChildOfClass("UISizeConstraint")
				if not cap then
					cap = Instance.new("UISizeConstraint")
					cap.Parent = panel
				end
				cap.MaxSize = Vector2.new(math.min(380, maxW), maxH)
				panel.AnchorPoint = Vector2.new(0.5, 0.5)
				panel.Position = UDim2.new(0.5, 0, 0.5, topInset / 2)
			end
		end

		-- ===== BANNERS: scale to screen, stay clear of the topbar =====
		local announce = screenGui:FindFirstChild("AnnounceBanner")
		if announce then
			announce.AnchorPoint = Vector2.new(0.5, 0)
			announce.Size = UDim2.new(0, math.min(460, screenW - 140), 0, 56)
		end
		local grab = screenGui:FindFirstChild("GrabBanner")
		if grab then
			grab.AnchorPoint = Vector2.new(0.5, 0)
			grab.Size = UDim2.new(0, math.min(380, screenW - 160), 0, 48)
		end

		-- ===== ELDER DIALOGUE: was overlapping the bottom-left card stack =====
		-- Positioned in the horizontal gap BETWEEN the left card column (ends at x=292)
		-- and the right button column (starts at x=627), then vertically placed above the
		-- tallest left card so it can't collide even when that gap is narrow. Measured
		-- overlaps against CritterCard/QuestCard/MenuToggleButton drove these numbers.
		local elder = screenGui:FindFirstChild("ElderDialogueBox")
		if elder then
			local leftEdge = EDGE + 280 + 10        -- left card column right edge + gap
			local rightEdge = screenW - EDGE - BTN_W - 10 -- right button column left edge - gap
			local availableW = math.max(200, rightEdge - leftEdge)
			elder.AnchorPoint = Vector2.new(0, 1)
			elder.Size = UDim2.new(0, availableW, 0, 76)
			elder.Position = UDim2.new(0, leftEdge, 1, -EDGE)
		end
	end

	layout()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(layout)
	-- Panels/cards toggle visibility constantly; re-running on menu toggle keeps the
	-- left stacks correctly packed when a card appears or disappears.
	task.spawn(function()
		while true do
			task.wait(2)
			layout()
		end
	end)
end

-- ================= Friend proximity bonus indicator =================
-- Small badge under the Sparks card showing the active friend bonus. Attribute-driven,
-- so it appears and disappears exactly when the server's proximity sweep decides --
-- no separate remote needed.
do
	local badge = Instance.new("TextLabel")
	badge.Name = "FriendBonusBadge"
	badge.BackgroundColor3 = Color3.fromRGB(60, 140, 90)
	badge.Size = UDim2.new(0, 150, 0, 22)
	badge.AnchorPoint = Vector2.new(0, 0)
	badge.Text = ""
	badge.TextColor3 = Color3.fromRGB(200, 255, 210)
	badge.Font = FONT_HEAVY
	badge.TextScaled = true
	badge.Visible = false
	badge.ZIndex = 14
	badge.Parent = screenGui
	corner(badge, 8)
	stroke(badge, PALETTE.success, 2)

	local function refresh()
		local bonus = LocalPlayer:GetAttribute("SAC_FriendBonus")
		local count = LocalPlayer:GetAttribute("SAC_NearbyFriends") or 0
		if bonus and bonus > 0 then
			badge.Text = string.format("\u{1F465} +%d%% (%d friend%s)",
				math.floor(bonus * 100 + 0.5), count, count == 1 and "" or "s")
			badge.Visible = true
		else
			badge.Visible = false
		end
	end

	LocalPlayer:GetAttributeChangedSignal("SAC_FriendBonus"):Connect(refresh)
	LocalPlayer:GetAttributeChangedSignal("SAC_NearbyFriends"):Connect(refresh)
	refresh()

	-- Positioned by the responsive layout pass alongside the other left-column cards;
	-- this just keeps it tucked under the Sparks card if that pass hasn't run yet.
	badge.Position = UDim2.new(0, 12, 0, 76)
end

-- ================= Ranch Likes feedback =================
do
	remotes.RanchLikeResult.OnClientEvent:Connect(function(ok, result)
		if ok then
			playSound(SFX.QuestComplete, 0.5, 1.3)
			showGrabBanner("\u{2764}\u{FE0F} Liked their ranch!")
		elseif result == "AlreadyLiked" then
			showGrabBanner("You already liked that ranch!")
		elseif result == "SelfLike" then
			showGrabBanner("You can't like your own ranch!")
		end
	end)

	-- Owner-side: someone liked YOUR ranch. This is the moment the feature exists for,
	-- so it gets a real celebration rather than a silent counter tick.
	remotes.RanchLikesUpdated.OnClientEvent:Connect(function(total, likerName)
		playSound(SFX.HatchFanfare, 0.55, 1.2)
		showGrabBanner(string.format("\u{2764}\u{FE0F} %s liked your ranch! (%s total)",
			tostring(likerName), Constants.FormatNumber(total)))
	end)
end

-- ================= Trade UI =================
-- Entire panel scoped in do...end: ClientMain sits at Luau's hard 200-local ceiling and
-- adding this many names at top level would crash HUD construction outright.
do
	local tradePanel = Instance.new("Frame")
	tradePanel.Name = "TradePanel"
	tradePanel.BackgroundColor3 = PALETTE.card
	tradePanel.Size = UDim2.new(0, 360, 0, 300)
	tradePanel.AnchorPoint = Vector2.new(0.5, 0.5)
	tradePanel.Position = UDim2.new(0.5, 0, 0.5, 0)
	setPanelOpen(tradePanel, false)
	tradePanel.ZIndex = 40
	tradePanel.Parent = screenGui
	corner(tradePanel, 16)
	stroke(tradePanel, Color3.fromRGB(120, 200, 255), 3)

	local tradeTitle = Instance.new("TextLabel")
	tradeTitle.BackgroundTransparency = 1
	tradeTitle.Size = UDim2.new(1, -60, 0, 30)
	tradeTitle.Position = UDim2.new(0, 12, 0, 6)
	tradeTitle.Text = "\u{1F91D} TRADE"
	tradeTitle.TextColor3 = Color3.fromRGB(120, 200, 255)
	tradeTitle.Font = FONT_HEAVY
	tradeTitle.TextScaled = true
	tradeTitle.TextXAlignment = Enum.TextXAlignment.Left
	tradeTitle.ZIndex = 41
	tradeTitle.Parent = tradePanel

	local tradeClose = Instance.new("TextButton")
	tradeClose.BackgroundColor3 = PALETTE.danger
	tradeClose.Size = UDim2.new(0, 30, 0, 30)
	tradeClose.AnchorPoint = Vector2.new(1, 0)
	tradeClose.Position = UDim2.new(1, -8, 0, 6)
	tradeClose.Text = "X"
	tradeClose.Font = FONT_HEAVY
	tradeClose.TextScaled = true
	tradeClose.TextColor3 = Color3.new(1, 1, 1)
	tradeClose.ZIndex = 41
	tradeClose.Parent = tradePanel
	corner(tradeClose, 8)

	-- Two offer columns, mine on the left.
	local function makeColumn(xScale, headerText)
		local col = Instance.new("Frame")
		col.BackgroundColor3 = PALETTE.bg
		col.Size = UDim2.new(0.47, 0, 0, 150)
		col.Position = UDim2.new(xScale, 0, 0, 42)
		col.ZIndex = 41
		col.Parent = tradePanel
		corner(col, 10)

		local header = Instance.new("TextLabel")
		header.BackgroundTransparency = 1
		header.Size = UDim2.new(1, -8, 0, 20)
		header.Position = UDim2.new(0, 4, 0, 3)
		header.Text = headerText
		header.TextColor3 = PALETTE.textDim
		header.Font = FONT_HEAVY
		header.TextScaled = true
		header.ZIndex = 42
		header.Parent = col

		local list = Instance.new("ScrollingFrame")
		list.Name = "List"
		list.BackgroundTransparency = 1
		list.Size = UDim2.new(1, -8, 1, -28)
		list.Position = UDim2.new(0, 4, 0, 24)
		list.CanvasSize = UDim2.new(0, 0, 0, 0)
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.ScrollBarThickness = 4
		list.ZIndex = 42
		list.Parent = col

		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 3)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list
		return col, list, header
	end

	local myCol, myList, myHeader = makeColumn(0.03, "YOUR OFFER")
	local theirCol, theirList, theirHeader = makeColumn(0.50, "THEIR OFFER")

	local tradeStatus = Instance.new("TextLabel")
	tradeStatus.BackgroundTransparency = 1
	tradeStatus.Size = UDim2.new(1, -24, 0, 24)
	tradeStatus.Position = UDim2.new(0, 12, 0, 198)
	tradeStatus.Text = ""
	tradeStatus.TextColor3 = Color3.new(1, 1, 1)
	tradeStatus.Font = FONT_BODY
	tradeStatus.TextScaled = true
	tradeStatus.ZIndex = 41
	tradeStatus.Parent = tradePanel

	local acceptButton = Instance.new("TextButton")
	acceptButton.Size = UDim2.new(0.45, 0, 0, 42)
	acceptButton.Position = UDim2.new(0.03, 0, 1, -50)
	acceptButton.Text = "ACCEPT"
	acceptButton.Font = FONT_HEAVY
	acceptButton.TextScaled = true
	acceptButton.BackgroundColor3 = Color3.fromRGB(80, 180, 110)
	acceptButton.TextColor3 = Color3.new(1, 1, 1)
	acceptButton.ZIndex = 41
	acceptButton.Parent = tradePanel
	corner(acceptButton, 10)
	addHoverFeedback(acceptButton)

	local cancelButton = Instance.new("TextButton")
	cancelButton.Size = UDim2.new(0.45, 0, 0, 42)
	cancelButton.Position = UDim2.new(0.52, 0, 1, -50)
	cancelButton.Text = "CANCEL"
	cancelButton.Font = FONT_HEAVY
	cancelButton.TextScaled = true
	cancelButton.BackgroundColor3 = PALETTE.danger
	cancelButton.TextColor3 = Color3.new(1, 1, 1)
	cancelButton.ZIndex = 41
	cancelButton.Parent = tradePanel
	corner(cancelButton, 10)
	addHoverFeedback(cancelButton)

	local myAccepted = false

	local function renderOffer(list, offer)
		list:ClearAllChildren()
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 3)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list
		for i, entry in ipairs(offer or {}) do
			local row = Instance.new("TextLabel")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 22)
			row.LayoutOrder = i
			local prefix = entry.isShiny and "\u{2728}" or ""
			local variant = (entry.variant and entry.variant ~= "Normal") and (entry.variant .. " ") or ""
			row.Text = string.format("%s%s%s", prefix, variant, entry.species or "?")
			row.TextColor3 = Color3.new(1, 1, 1)
			row.Font = FONT_BODY
			row.TextScaled = true
			row.TextXAlignment = Enum.TextXAlignment.Left
			row.ZIndex = 43
			row.Parent = list
		end
	end

	remotes.TradeState.OnClientEvent:Connect(function(state)
		tradeIsActive = true
		tradePanel.Visible = true
		tradeTitle.Text = "\u{1F91D} TRADE with " .. tostring(state.otherName)
		renderOffer(myList, state.myOffer)
		renderOffer(theirList, state.theirOffer)
		myAccepted = state.myAccepted

		myHeader.Text = state.myAccepted and "YOUR OFFER \u{2705}" or "YOUR OFFER"
		theirHeader.Text = state.theirAccepted and "THEIR OFFER \u{2705}" or "THEIR OFFER"

		if state.locked then
			-- Anti-scam confirmation window: offers are frozen and re-shown. Buttons are
			-- disabled so neither side can alter anything during the countdown.
			tradeStatus.Text = string.format("\u{1F512} Confirming in %ds -- check the offers!",
				state.lockRemaining or 0)
			tradeStatus.TextColor3 = Color3.fromRGB(255, 205, 60)
			acceptButton.Text = "LOCKED"
			acceptButton.BackgroundColor3 = Color3.fromRGB(90, 90, 100)
		else
			tradeStatus.Text = state.myAccepted and "Waiting for them to accept..."
				or "Tap creatures in your Inventory to offer them."
			tradeStatus.TextColor3 = PALETTE.textDim
			acceptButton.Text = state.myAccepted and "UNACCEPT" or "ACCEPT"
			acceptButton.BackgroundColor3 = state.myAccepted
				and Color3.fromRGB(160, 140, 60) or Color3.fromRGB(80, 180, 110)
		end
	end)

	remotes.TradeEnded.OnClientEvent:Connect(function(reason)
		tradeIsActive = false
		setPanelOpen(tradePanel, false)
		if reason then showGrabBanner(tostring(reason)) end
	end)

	remotes.TradeError.OnClientEvent:Connect(function(err)
		if err then showGrabBanner(tostring(err)) end
	end)

	remotes.TradeCompleted.OnClientEvent:Connect(function(received, gave)
		tradeIsActive = false
		setPanelOpen(tradePanel, false)
		playSound(SFX.HatchFanfare, 0.6, 1.1)
		showGrabBanner(string.format("\u{1F91D} Trade complete! Gave %d, received %d.",
			gave or 0, received or 0))
	end)

	-- Incoming request prompt.
	remotes.TradeRequestReceived.OnClientEvent:Connect(function(fromUserId, fromName)
		playSound(SFX.UiTick, 0.5, 1.3)
		local prompt = Instance.new("Frame")
		prompt.BackgroundColor3 = PALETTE.card
		prompt.Size = UDim2.new(0, 300, 0, 96)
		prompt.AnchorPoint = Vector2.new(0.5, 0)
		prompt.Position = UDim2.new(0.5, 0, 0, 70)
		prompt.ZIndex = 45
		prompt.Parent = screenGui
		corner(prompt, 12)
		stroke(prompt, Color3.fromRGB(120, 200, 255), 2)

		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -16, 0, 36)
		label.Position = UDim2.new(0, 8, 0, 6)
		label.Text = tostring(fromName) .. " wants to trade!"
		label.TextColor3 = Color3.new(1, 1, 1)
		label.Font = FONT_HEAVY
		label.TextScaled = true
		label.ZIndex = 46
		label.Parent = prompt

		local yes = Instance.new("TextButton")
		yes.Size = UDim2.new(0.44, 0, 0, 38)
		yes.Position = UDim2.new(0.03, 0, 1, -44)
		yes.Text = "Accept"
		yes.Font = FONT_HEAVY
		yes.TextScaled = true
		yes.BackgroundColor3 = Color3.fromRGB(80, 180, 110)
		yes.TextColor3 = Color3.new(1, 1, 1)
		yes.ZIndex = 46
		yes.Parent = prompt
		corner(yes, 8)

		local no = Instance.new("TextButton")
		no.Size = UDim2.new(0.44, 0, 0, 38)
		no.Position = UDim2.new(0.53, 0, 1, -44)
		no.Text = "Decline"
		no.Font = FONT_HEAVY
		no.TextScaled = true
		no.BackgroundColor3 = PALETTE.danger
		no.TextColor3 = Color3.new(1, 1, 1)
		no.ZIndex = 46
		no.Parent = prompt
		corner(no, 8)

		yes.MouseButton1Click:Connect(function()
			remotes.RequestTradeAccept:FireServer(fromUserId)
			prompt:Destroy()
		end)
		no.MouseButton1Click:Connect(function() prompt:Destroy() end)
		-- Auto-dismiss so a declined request can't linger over the HUD forever.
		task.delay(Constants.TRADE_REQUEST_TIMEOUT, function()
			if prompt and prompt.Parent then prompt:Destroy() end
		end)
	end)

	acceptButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 1.2)
		remotes.RequestTradeSetAccept:FireServer(not myAccepted)
	end)
	cancelButton.MouseButton1Click:Connect(function()
		playSound(SFX.UiTick, 0.4, 0.9)
		remotes.RequestTradeCancel:FireServer()
	end)
	tradeClose.MouseButton1Click:Connect(function()
		remotes.RequestTradeCancel:FireServer()
	end)
end

-- ================= Gifting feedback =================
do
	remotes.GiftResult.OnClientEvent:Connect(function(ok, a, b, remaining)
		if ok then
			playSound(SFX.HatchFanfare, 0.55, 1.2)
			showGrabBanner(string.format("\u{1F381} Gifted your %s to %s! (%d left today)",
				tostring(a), tostring(b), remaining or 0))
		else
			showGrabBanner(tostring(a))
		end
	end)

	remotes.GiftReceived.OnClientEvent:Connect(function(species, fromName)
		playSound(SFX.HatchFanfare, 0.6, 1.0)
		showGrabBanner(string.format("\u{1F381} %s gifted you a %s!", tostring(fromName), tostring(species)))
	end)
end

-- ================= Client error reporting =================
-- Relays client-side script errors to TelemetryService. Without this, a bug that only
-- reproduces on real hardware (mobile, low memory, specific input) is completely
-- invisible -- the only person who ever sees it is the player it breaks for.
--
-- Wrapped in pcall and rate-limited server-side; a reporter that itself errors, or that
-- floods, would be worse than no reporter at all.
do
	local ScriptContext = game:GetService("ScriptContext")
	local reportRemote = remotes:FindFirstChild("ReportClientError")
	if reportRemote then
		local lastSent = 0
		ScriptContext.Error:Connect(function(message, trace, script)
			-- Client-side throttle as well as the server's, so a hot loop doesn't
			-- saturate the player's own network traffic.
			local now = os.clock()
			if now - lastSent < 1 then return end
			lastSent = now
			pcall(function()
				reportRemote:FireServer(
					tostring(message):sub(1, 300),
					tostring(trace):sub(1, 300),
					script and script:GetFullName() or "?"
				)
			end)
		end)
	end
end
