# Ride or Die — Roblox bicycle-parkour game

**Status:** playable, in play-testing · **Built by:** Saif Alqubaisi (design, direction, testing) with AI-assisted Lua (Claude, working inside Roblox Studio)

You ride a bicycle through a parkour course and try to beat your own best run. A **ghost rider** replays your previous best run beside you in real time, and after a certain stage the **floor starts collapsing behind you** — so hesitation costs you the run.

## Features
- **Ghost replay** — the game records the player's position every frame during a run; on the next run it replays that recording as a translucent ghost with a BEST marker and a live pace delta (e.g. "-65 m behind").
- **Procedurally generated track** — `regenerate()` builds a ~9,800-stud track from 15 section types (gaps, lava, step-ups, splits, canyons…), rotating them so no two runs feel identical.
- **Momentum tiers** — speed builds through tiers; a momentum bar with tier ticks shows where you are.
- **Collapsing floors** — later sections break away behind the rider.
- **Live leaderboard and milestone gates** (500 m, 1,000 m…).

## Engineering notes (what I learned)
- **Performance:** a "cleaner road" pass I asked for was placing 583 centre-line dashes — 43% of all parts. Fixed by spacing dashes 14 → 26 studs and skipping slabs under 24 studs. Total parts 1,358 → 1,101.
- **Fairness check:** I sample the whole rideable corridor and take the best lane at every point (a gap only matters if *every* lane is missing). Result: 33 gaps, worst 58 studs, zero beyond the tier-2 jump capability — all fair.
- **Motion blur bug:** blur ramped to size 12 above 55% of max speed, which at tier 4–5 was almost always. Now engages only in the top 12% of the speed range and peaks at 3.5.
- **HUD bug:** the coin counter was cut off at the top of the screen. Measured instead of guessing: the HUD root sat at y = −58 because of the safe-inset setting; fixed at the source so it persists.
- **Measurement lesson:** a part-count check compared floats with `==` and reported 0 dashes when there were 280. I re-measured rather than trusting the number — same discipline that found the 43% overspend.

## How it was built
I direct the design and every decision (what to build, what feels wrong, what to cut), test in Play mode, and give feedback; the Lua is written with AI assistance. Every feature above was verified in a live session, not assumed.

## What's here
- `DSRServer.luau` — main server loop: world setup, track generation (`regenerate`, `buildSections`, `ensureReachable`), bike build, run/crash/finish logic, slab collapse (`armSlab`)
- `DSRClient.luau` — client: bike simulation, camera, HUD, momentum bar, ghost/pace display (2,100+ lines)
- `DSRConfig.luau` — all tunable game settings
- `DSRData.luau` — player data, autosave, bind-to-close
- `DSRChallenges.luau` — challenge/goal system
- `DSRLeaderboard.luau` — global leaderboard
- `DSRMonetization.luau` — shop and receipts
- `DSRAnalytics.luau` — lifecycle/analytics events
- `DSRSelfTest.luau` — automated self-checks
- Working title in the code: "Don't Stop Riding" (the `DSR` prefix)
