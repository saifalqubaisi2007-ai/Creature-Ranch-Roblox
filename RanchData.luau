--[[
	RanchData.lua
	Data-driven definition of the Ranch Expansion system: a private, per-player plot
	that visibly transforms as the player levels up. Previously completely missing --
	the ranch looked identical forever regardless of progress. Mirrors WorldsData's
	architecture exactly: pure data + a position formula here, all building/gating logic
	lives in RanchService.

	Tiers are gated on PLAYER LEVEL (already tracked, already the natural signal for
	"how much has this player actually engaged with the game" -- no new economy needed).
	Each tier is ADDITIVE: reaching a new tier adds decorations on top of everything
	already built, rather than replacing the plot wholesale, so a tier-up never looks
	like something was taken away.
]]

local RanchData = {}

-- Plots live far from the main island in a simple deterministic grid, keyed off UserId.
-- (Known simplification: userId % 2500 into a 50-wide grid means two different UserIds
-- COULD theoretically collide on the same plot slot -- astronomically unlikely for real
-- Roblox UserIds in a dev/prototype context, but worth fixing properly -- e.g. an
-- incrementing DataStore-backed counter -- before this ever needs to hold a large
-- concurrent population.)
RanchData.PLOTS_PER_ROW = 50
RanchData.PLOT_SPACING = 150
RanchData.PLOT_ORIGIN = Vector3.new(5000, 10, 5000)

function RanchData.GetPlotPosition(userId)
	local index = userId % 2500
	local col = index % RanchData.PLOTS_PER_ROW
	local row = math.floor(index / RanchData.PLOTS_PER_ROW)
	return RanchData.PLOT_ORIGIN + Vector3.new(col * RanchData.PLOT_SPACING, 0, row * RanchData.PLOT_SPACING)
end

-- order matters (ascending). Tier 1 always applies (level 1 is everyone's floor).
-- 7 tiers matching the exact spec: 1/10/20/30/50/75/100. Tiers 1-2 (Homestead, Growing
-- Ranch) already had real built geometry BEFORE this spec change and are UNCHANGED --
-- their level thresholds already matched exactly. Tiers 3-7 are new/renumbered, data
-- only for now (no geometry yet), same "data exists, content follows" scoping already
-- used successfully for the original Tier 3-5 stub and for Forest's placeholder
-- species -- the generic EnsureTier/SyncPlotToLevel loop in RanchService needed ZERO
-- logic changes to support this, only this data table changed, which is the entire
-- point of building it data-driven in the first place.
RanchData.TIERS = {
	{ order = 1, level = 1, name = "Homestead" }, -- tiny fence, dirt (built)
	{ order = 2, level = 10, name = "Growing Ranch" }, -- flowers, stone path, pond (built)
	{ order = 3, level = 20, name = "Blooming Ranch" }, -- pond centerpiece
	{ order = 4, level = 30, name = "Windmill Ranch" }, -- windmill
	{ order = 5, level = 50, name = "Flourishing Ranch" }, -- waterfall
	{ order = 6, level = 75, name = "Crystal Ranch" }, -- crystal cave
	{ order = 7, level = 100, name = "Mythic Ranch" }, -- magic tree, the final tier
}

function RanchData.GetTierForLevel(level)
	local best = RanchData.TIERS[1]
	for _, tier in ipairs(RanchData.TIERS) do
		if level >= tier.level then best = tier end
	end
	return best
end

return RanchData
