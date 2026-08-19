# Creature Ranch (Roblox)

A creature-hatching and collection simulator built solo in Luau. Players hatch creatures across 8 worlds, raise and equip them, use a sanctuary system, and fuse creatures together into stronger forms. Full trading and gifting between players is supported, and the game is monetized with 8 game passes and 3 developer products, all live.

Full technical detail — systems breakdown, monetization, known risks, and next steps — is in [`HANDOFF.md`](./HANDOFF.md), written as a real engineering handoff document rather than a marketing summary.

## Systems

- **Hatching** — players unlock and hatch creatures across 8 distinct worlds, each with its own creature pool.
- **Equip / Sanctuary** — players manage an active roster of creatures and can place others into a sanctuary system.
- **Fusion economy** — creatures can be fused together, creating a progression sink and a reason to keep hatching.
- **Trading & gifting** — players can trade creatures with each other or gift them directly.
- **Error telemetry** — the game logs errors during play so bugs can be found and fixed from real usage data instead of guesswork.
- **Monetization** — 8 game passes and 3 developer products are live and integrated with the above systems.

## What I learned

- A silent `return` inside a nested function was swallowing values I expected to propagate up — the bug only showed up under specific player states, which made it hard to catch by just reading the code. It taught me to be much more deliberate about what every code path actually returns, especially in callback-heavy Luau.
- I learned to assert incoming data against an expected list/shape rather than trusting it, after a case where malformed or unexpected data reached a system that assumed it was always well-formed. Validating at the boundary instead of hoping the caller behaves has become a habit since.

## How it was built

Built solo, iteratively, directly in Roblox Studio — designing each system (hatching, fusion, trading), shipping it, then using in-game telemetry and playtesting to find and fix real bugs rather than trying to anticipate every edge case up front.
