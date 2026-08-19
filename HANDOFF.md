# Creature Ranch — Handoff

**Experience ID:** 10627177281
**Place ID:** 91921095966840
**Status:** Public, 0 visits
**Genre:** Simulation / Incremental Simulator (locked for 3 months)
**Content rating:** Minimal, no descriptors

---

## 1. Read this first

Three things are true and worth knowing before touching anything.

**The game is functionally complete but commercially untested.** Every system works and has been verified in Studio. Nothing has been tested with more than one player.

**Trading and gifting have never run with two real clients.** Both move items between accounts. Every guard was verified by code path and by synthetic single-player session, but a two-client test was never done. This is the single highest-risk untested area — a duplication bug cannot be undone once players hold the items.

**The creature models are the known weak point.** They are assembled from Roblox primitives (spheres, wedges) in code. They function, they are rarity-coded and animated, but they will not compete visually with established pet simulators. This was identified as the biggest lever on player perception and remains unaddressed.

---

## 2. Architecture

### Server (`ServerScriptService`)

| File | Responsibility |
|---|---|
| `Main` | Bootstraps every service, owns all remote handlers (~63k chars) |
| `HatcheryController` | Builds egg stands and their ProximityPrompts for World 1 |
| `LeaderboardService` | Physical board cycling all-time / weekly / seasonal |
| `Services/PlayerDataService` | Profiles, saving, equip, sanctuary, relics, codes. The core data layer |
| `Services/CritterService` | Creature models, movement, income loop |
| `Services/HatchLogic` | Hatch resolution, rate limiting, slot sync |
| `Services/WorldService` | World unlocking and gating |
| `Services/ZoneHatcheryService` | Egg stands for worlds 2–8 |
| `Services/TradeService` | Two-player trading |
| `Services/GiftService` | One-way gifting |
| `Services/RanchService` | Plots, tiers, decorations, sanctuary rendering |
| `Services/DiscoveryService` | Sanctuary creature discoveries |
| `Services/TelemetryService` | Error capture to DataStore |
| `Services/BadgeAwardService` | Roblox badge awarding |
| `Services/AnalyticsService` | Batched analytics events |
| Per-world mechanic services | ForestSprite, BeachCrab, DesertSandstorm, SnowIce, CrystalExplosion, VolcanoMeteor, SkyUpdraft |

### Client (`StarterPlayerScripts`)

| File | Notes |
|---|---|
| `ClientMain` | ~180k chars. **Hard limits: 200,000 characters and 200 top-level locals.** Both have been hit before |
| `HatchCinematicUI` | Extracted hatch reveal |
| `InventoryUI` | Extracted inventory panel |
| `ShopUI` | Extracted shop **and the Codes/Credits panel** |

### Shared (`ReplicatedStorage/CritterRush/Modules`)

`Constants`, `WorldsData`, `RanchData`.

**`Constants` is ~68k characters and its `return Constants` must stay at the very end of the file.** It was previously ~18k characters early, silently stranding 40 constants that never executed — badges, promo codes, world relics and the group bonus were all dead despite looking correct. Anything appended after a `return` is invisible.

---

## 3. Core design

### Equip model

Only **equipped** creatures generate Sparks.

- **Inventory:** 500 slots. Hatching never destroys anything
- **Equipped:** 3 base, +1 per world unlocked (10 at World 8), plus passes and Ranch Power, hard cap 20
- **Sanctuary:** stored creatures give Ranch Power (luck, income, slots, discoveries)
- **Fusion:** 5 duplicates → next variant tier
- Only equipped creatures have a physical model in the world

This replaced an older model where every owned creature earned and the slot cap doubled as an inventory cap — hitting the cap **evicted** a creature, making the core action punishing.

`MigrateToEquipModel` auto-equips a returning player's best on first join under the new model. **This is one-way.** Without it, existing saves would log in with zero income.

### Progression

Worlds are gated by four requirements, all checked before spending: sequential order, rebirth count, species owned from the previous world, and Sparks cost.

Infinite systems: rebirths (generated past tier 5), achievement chains, quest scaling, levels.

### Economy multiplier chain

Income multiplies through: DoubleSparks → rebirth → collection completion → ranch power → group → relics → potions → events.

A dev account measured **196.5x income, 6.93x luck** with everything stacked.

---

## 4. Monetization

All IDs are live. Nothing is a placeholder.

### Passes

| Name | ID | Price |
|---|---|---|
| VIP | 1939392366 | 449 |
| 2x Luck | 1935615103 | 249 |
| +5 Equip Slots | 1935052463 | 299 |
| Auto Hatch | 1937712727 | 199 |
| 2x Offline Earnings | 1935316238 | 199 |
| 2x Sparks | 1933875962 | 149 |
| Extra Critter Slot | 1932200382 | 99 |
| VIP Sparkle Trail | 1933365951 | 79 |

### Developer products

| Name | ID | Price | Grants |
|---|---|---|---|
| Starter Pack | 3629305144 | 99 | 25,000 Sparks + 2 slots + 1 Limited Egg token |
| Spark Pack (Large) | 3613109304 | 199 | 500,000 Sparks |
| Spark Pack (Small) | 3613109342 | 49 | 50,000 Sparks |

**Starter Pack is one-time and 24-hour limited, enforced in code** (`starterPackBought`, `firstJoinAt`). Roblox itself will happily sell it twice — that guard matters.

### Promo codes

`LAUNCH`, `WELCOME`, `SANCTUARY`, `SKYISLANDS`, `THANKYOU` — all live. Add more in `Constants.PROMO_CODES`.

---

## 5. Outstanding work

### Blocking / high risk

**Two-player trade and gift test.** Never done. Highest risk item in the project.

**Server size is 50.** Should be 12–15. VFX load caused client script timeouts at 83 critters on a *single* player. That was fixed (97% fewer active lights via distance-and-count culling in `CritterVFX`), but never tested under real concurrency.

**Description promises a group bonus that does not exist.** `Constants.GROUP_ID = 0`, so the +10% Sparks never applies. Either create the group and set the ID, or remove the line.

**No mobile hardware test.** Layout is responsive and verified at 749×361 in Studio, but Studio is not a phone.

### Not done

- **Creature art.** The known weak point
- **Badges.** 10 defined in `Constants.BADGES`, all `id = 0`. First five per day are free to create. Service boots silently at `active (0/10 badges configured)`
- **Per-world music.** One music asset exists, re-voiced per world via pitch and EQ. Real per-world tracks need a composer
- **Creature audio.** Three stock sounds re-pitched by rarity

### Known cosmetic gaps

- Two dead profile fields (`createdAt`, `firstSessionDone`) — harmless, left alone to avoid touching the save schema pre-launch
- Analytics has no rate limit on non-economy events

---

## 6. Hard-won lessons

These cost real debugging time. Worth knowing before editing.

**Code after a `return` is invisible.** Constants had 40 stranded definitions. Always check the return is last.

**Isolated `require()` in `execute_luau` returns a fresh module instance with an empty profiles table.** It will report working code as broken. Test through a real remote instead. This produced at least four false bug reports during development.

**Find code boundaries with the compiler, not line arithmetic.** A one-line error during an extraction moved an enclosing block's `end` into a module and broke the entire client. Validate both files with `loadstring` before writing either.

**Assert against an expected list, not what exists.** A panel disappeared and the regression check passed, because it only inspected panels that were present. Checking what's there cannot detect a deletion.

**`EqualizerSoundEffect` gains silently ignore TweenService.** Direct assignment works; tweens leave the value at 0.

**Verify `rbxasset://` sound paths load.** Three of seven candidates failed silently with `IsLoaded = false`.

**Tween `Completed` does not fire if the tween is interrupted.** Floating-number labels leaked permanently because of this. Use a timer for cleanup.

**Scaling a model's part sizes without scaling their offsets breaks it.** Use `Model:ScaleTo`.

**Attributes set but never read are a real bug class.** Ranch Power perks and sanctuary rendering were both dead on join because their sync functions were only called inside event handlers.

---

## 7. Getting players

There is no organic discovery for a game with zero visits. Roblox surfaces experiences based on play data; with none, there is nothing to surface.

The first hundred players always come from outside Roblox: friends, Discord, TikTok or YouTube Shorts clips. Roblox Ads work but are only worth spending on once the game retains people.

**Watch Analytics → Retention.** Day-1 return rate is the number that matters. If it is low, more traffic will not help — and that points back at the creature art.

---

## 8. Debugging in production

`TelemetryService` captures server and client errors to a DataStore keyed by day and JobId. Errors are deduplicated by message signature (line numbers stripped) and counted, so a hot loop shows as one entry with a count rather than thousands of rows.

Read it via `DataStoreService:GetDataStore("SAC_ErrorLog")`.

Every call is `pcall`-wrapped and rate-limited. An error reporter that itself errors is worse than none.
