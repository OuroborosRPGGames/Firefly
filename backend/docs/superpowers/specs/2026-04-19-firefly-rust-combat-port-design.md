# Firefly Rust Combat Engine Port — Design

**Date:** 2026-04-19
**Status:** Approved, ready for implementation plan.
**Target repo:** `/home/beat6749/orig/Firefly`
**Branch:** `rust-combat-engine`

## Context

The Rust combat engine developed in the sister game repo (Romance of Five Kingdoms, `/home/beat6749/game`) is now the production default there. This spec ports it to Firefly, the underlying MUD engine, so any game built on Firefly can resolve combat with the Rust engine instead of (or alongside) the Ruby `CombatResolutionService`.

Firefly's combat differs from the game repo's on three axes:

1. **Dice.** Firefly uses **willpower dice** — fixed `d8 exploding on 8`. The game repo uses **qi dice** with variable sides per character (d4/d6/d8/d10/d12). The Rust `dice::roll` is already parameterized on `sides`, so this is a serializer-level change only.
2. **Tactics.** Firefly has `aggressive`, `defensive`, `quick`, `guard`, `back_to_back`. The first three are simple numeric modifiers (±damage, ±movement). The game repo's tactic set (`area_denial`, `qi_aura`, `qi_lightness`, `break`, `detonate`, `ignite`, plus shared `guard`/`back_to_back`) is geometrically and mechanically richer. `guard`/`back_to_back` are shared between the two games.
3. **Interactive battlemap elements.** Both games share four element types (`water_barrel`, `oil_barrel`, `munitions_crate`, `vase`). The game repo also has three lore-flavored elements Firefly doesn't use (`cliff_edge` → "long drop", `toxic_mushrooms`, `lotus_pollen` → "lotus flower").

**Philosophy.** Firefly is an engine intended for downstream adoption. Features Firefly itself doesn't use should stay in the codebase as dormant, documented code so a downstream game can enable them without touching the engine. This shapes several decisions below.

## Approved decisions

1. **Distribution:** vendored copy of `combat-engine/` in Firefly as a sibling of `backend/`. Firefly becomes self-contained — `git clone && cargo build && bundle install` produces a runnable game.
2. **Tactic modifiers in Rust:** generic optional integer fields on `Participant` (`tactic_outgoing_damage_mod`, `tactic_incoming_damage_mod`, `tactic_movement_bonus`). Any game drives behavior from these; Rust never knows a tactic name it didn't already. Qi behavior unchanged when fields are zero.
3. **Interactives:** full 7-type port. The three lore-flavored types stay in the model's `ELEMENT_TYPES` array and the Rust resolver as dormant code. Firefly ships admin UI, templates, and asset prompts for only the four it uses.
4. **Workspace:** Firefly worktree at `Firefly/.worktrees/rust-combat-engine`, branch `rust-combat-engine`.
5. **Testing:** minimal Firefly-native parity suite (~8-10 seeds per scenario, ~6 spec files, runs in <15 minutes). Not a port of the game repo's 10-hour matrix.
6. **Execution:** three-phase branch stack (see below). Each phase verifiable on its own.

## Phase 1 — Rust: generic tactic-modifier fields

**Where it lands:** the game repo (`/home/beat6749/game`), worktree or branch of operator's choice. This phase is *not* a Firefly change — it's an upstream change to `combat-engine/combat-core/` that must be validated in the game repo's parity matrix before we snapshot for Firefly.

**Changes:**
- `combat-engine/combat-core/src/types/participant.rs` — add three fields to `Participant`:
  - `tactic_outgoing_damage_mod: i32` (default 0)
  - `tactic_incoming_damage_mod: i32` (default 0)
  - `tactic_movement_bonus: u32` (default 0)
  - All annotated `#[serde(default)]` so existing JSON wire format decodes unchanged.
- `combat-engine/combat-core/src/resolution.rs` — at the damage-summation site, add `attacker.tactic_outgoing_damage_mod + target.tactic_incoming_damage_mod` to the attack damage before the threshold check. Clamp damage ≥ 0. Qi participants leave both at 0 → behavior byte-identical.
- `combat-engine/combat-core/src/movement.rs` — movement budget `+= participant.tactic_movement_bonus`.
- Unit tests (3-4 new) in whichever test module exercises damage/movement: mods move results by the right amount; zeros no-op; negative outgoing_mod clamps.

**Gate to proceed to Phase 2:**
- `cargo test --release -p combat-core` green (382 existing + new).
- `bundle exec rspec spec/parity/` in the game repo — 48-50 existing pass count unchanged. If any parity spec drifts, the conditional is wrong — stop and fix before snapshotting.

**Commit:** `feat(combat-core): add generic tactic-modifier fields on participants`

## Phase 2 — Firefly bridge + willpower + aggressive/defensive/quick

**Vendor the engine.**
- Copy the entire post-Phase-1 `combat-engine/` tree from the game repo into `Firefly/combat-engine/`.
- Add `combat-engine/target/` to Firefly's `.gitignore`.
- `combat-engine/README.md` — short provenance note: vendored snapshot from the game repo as of the commit SHA of phase 1, with a pointer to the upstream for anyone wanting to contribute back.

**Port the Ruby bridge from the game repo.** Direct copies unless noted:

- `backend/app/services/combat_engine/combat_engine_client.rb` — verbatim. Socket client, Firefly-agnostic.
- `backend/app/services/combat_engine/fight_state_serializer.rb` — port with **willpower + tactic adaptations**:
  - Replace qi column reads (`qi_attack`, `qi_defense`, `qi_ability`, `qi_movement`) with the corresponding `willpower_*` columns that already exist on Firefly's `FightParticipant`.
  - Replace `qi_die_sides` with hardcoded `dice_sides: 8`. (Willpower is always d8-exploding-on-8; no per-character variation.)
  - When serializing `tactic_choice`, also populate the three new generic modifier fields on the serialized participant from `GameConfig::Tactics::OUTGOING_DAMAGE`, `INCOMING_DAMAGE`, and `MOVEMENT`. For `guard`/`back_to_back`, modifiers are zero; `tactic_choice` still gets passed through as a string so the shared redirect logic (already in Rust) still fires.
  - Omit qi-specific fields Rust doesn't use on the Firefly path (no `qi_die_sides`, no `qi_dice`).
- `backend/app/services/combat_engine/apply_rust_result.rb` — port. Strip qi-state transitions from writeback; Firefly participants have no qi columns.
- `backend/app/services/fight/fight_service.rb` — merge the game-repo `combat_engine_mode` method + Rust dispatch branch into Firefly's existing `FightService`. Default `'auto'` (Rust when socket reachable, Ruby fallback when not). Opt-out via `GameSetting.get('use_rust_combat_engine') == false` or `COMBAT_ENGINE=ruby` env var.
- `backend/scripts/run_parity_tests.rb`, `backend/scripts/smoke_test_rust_combat.rb`, `backend/scripts/build_combat_engine.sh` — port.

**What stays in Firefly unchanged:**
- `CombatResolutionService` stays. It's the Ruby fallback path, the opt-out escape hatch, and the baseline for parity tests. Do not delete or rewrite it.

**What's NOT ported in this phase:**
- Interactive battlemap elements (Phase 3).
- Qi migrations, qi column definitions, qi-tactic code paths (Firefly doesn't have these).

**Parity suite for this phase** (`backend/spec/parity/`):
- `parity_helper.rb` — builds `Fight` fixture, captures Ruby events via `CombatResolutionService`, captures Rust events via `CombatEngineClient` against the same state, asserts equality on event sequences, KO timing, final HP, final positions.
- `single_seed_trace_spec.rb` — 4-5 base scenarios (1v1 melee, 1v1 ranged ability, 2v2 melee, aggressive-vs-defensive, quick-movement), single seed each.
- `multi_seed_parity_spec.rb` — same scenarios, 10 seeds each.
- `tactics_parity_spec.rb` — aggressive/defensive/quick modifier correctness at the event level.
- `spar_mode_parity_spec.rb` — touch-count path parity (the spar-defeat fix from the game repo needs to be present in both engines).

**Verification:**
- All parity specs green on a clean run.
- `backend/scripts/run_parity_tests.rb` completes in under 15 minutes.
- MCP smoke test on a live Firefly fight: start combat-server socket, create a test agent, execute `fight <target>`, confirm fight advances and emits events with zero protocol errors.
- Existing Firefly RSpec (non-combat) stays green.

**Commits (in order):**
1. `chore: vendor combat-engine/`
2. `feat(bridge): add CombatEngineClient + FightStateSerializer + ApplyRustResult`
3. `feat(fight): wire FightService to Rust engine with auto-fallback to Ruby`
4. `feat(serializer): translate willpower dice and aggressive/defensive/quick tactics`
5. `test: add Firefly parity suite and runner`

## Phase 3 — Firefly interactive battlemap elements

**Goal:** port the full 7-type `BattleMapElement` system additively on top of Phase 2. The three lore-specific types stay dormant in Firefly — model accepts them, Rust resolves them, but Firefly ships no admin templates, seed data, or asset prompts for them. A downstream game forking Firefly can just add a template and they work.

**Changes:**

- Migrations — port from game repo, Sequel syntax:
  - `*_create_battle_map_elements.rb`
  - `*_create_battle_map_element_assets.rb`
  - JSONB defaults via `Sequel.lit("'{}'::jsonb")` (not `Sequel.pg_json_wrap` — `pg_json` isn't loaded during migrations; see CLAUDE.md critical patterns).
- Models — `backend/app/models/battle_map_element.rb`, `battle_map_element_asset.rb`. `ELEMENT_TYPES` keeps all 7 values. Downstream code-in-place.
- Services — `backend/app/services/battlemap/fight_hex_effect_service.rb` and related event handlers. Adapt any qi-specific poisoning logic to Firefly's existing `StatusEffectService` vocabulary (the toxic-mushroom cluster handler is the likely adaptation point, even though Firefly won't ship a toxic-mushroom template).
- Admin UI — ERB + routes. Dropdown filtered to the four actively-used types in Firefly. The other three still work via API/DB for downstream adopters.
- Asset pipeline — `backend/scripts/generate_element_assets.rb` ported. Prune the three dormant types' prompt templates out of Firefly's `config/prompts.yml`.
- Bridge additions — extend `FightStateSerializer` with the interactive-element serialization block; extend `ApplyRustResult` with element event writeback.

**Parity additions:**
- `backend/spec/parity/interactive_elements_parity_spec.rb` — four active types, 8-10 seeds each. Scenarios: break barrel (water + oil), detonate crate, smash vase.
- Focused unit specs in `backend/spec/services/battlemap/` — element creation, barrel break, crate detonate, vase smash, water-hex-entry status application.

**Verification:**
- Parity specs green.
- MCP smoke: place a water barrel on a battlemap in Firefly, attack it, confirm water hex effect fires on the affected hexes.

**Commits (in order):**
1. `feat(db): add battle_map_elements and battle_map_element_assets tables`
2. `feat(models): BattleMapElement and BattleMapElementAsset models`
3. `feat(battlemap): fight hex effect service and event handlers`
4. `feat(admin): battle map element CRUD UI`
5. `feat(bridge): serialize interactive elements; writeback element events`
6. `test: interactive element parity and unit specs`

## Error handling / fallback

Mirror the game repo:
- `CombatEngineClient` wraps socket operations. On connect failure, read timeout, or socket close it raises `::CombatEngine::UnreachableError`. All other exceptions bubble unmasked — do not rescue `StandardError` in the client, that's how real Rust bugs get hidden.
- `FightService` rescues `::CombatEngine::UnreachableError` specifically and falls back to `CombatResolutionService`. A `warn "[FightService] Rust combat engine unreachable, falling back to Ruby: #{e.message}"` log line marks every fallback so ops can see it in `log/puma_error.log`.
- Engine selection precedence: `COMBAT_ENGINE` env var (if set and non-empty) > `GameSetting.get('use_rust_combat_engine') == false` (forces ruby) > default `'auto'`.

## Files at a glance

| File | Phase | Change |
|---|---|---|
| `game:combat-engine/combat-core/src/types/participant.rs` | 1 | +3 optional modifier fields |
| `game:combat-engine/combat-core/src/resolution.rs` | 1 | Apply outgoing/incoming mods |
| `game:combat-engine/combat-core/src/movement.rs` | 1 | Apply movement bonus |
| `firefly:combat-engine/**` | 2 | Vendored copy |
| `firefly:backend/app/services/combat_engine/combat_engine_client.rb` | 2 | Port verbatim |
| `firefly:backend/app/services/combat_engine/fight_state_serializer.rb` | 2 | Port + willpower/tactic adaptation |
| `firefly:backend/app/services/combat_engine/apply_rust_result.rb` | 2 | Port minus qi-state writeback |
| `firefly:backend/app/services/fight/fight_service.rb` | 2 | Rust dispatch, default `'auto'` |
| `firefly:backend/scripts/run_parity_tests.rb` + helpers | 2 | Port |
| `firefly:backend/spec/parity/*.rb` | 2 | New parity suite (Phase 2 scenarios) |
| `firefly:backend/spec/parity/interactive_elements_parity_spec.rb` | 3 | Parity for 4 active elements |
| `firefly:backend/db/migrate/*battle_map_element*.rb` | 3 | Migrations |
| `firefly:backend/app/models/battle_map_element*.rb` | 3 | Models (all 7 types in `ELEMENT_TYPES`) |
| `firefly:backend/app/services/battlemap/fight_hex_effect_service.rb` | 3 | Service + handlers, qi-poison adapted to StatusEffectService |
| `firefly:backend/app/services/combat_engine/fight_state_serializer.rb` | 3 | Add element serialization |
| `firefly:backend/app/services/combat_engine/apply_rust_result.rb` | 3 | Add element event writeback |
| `firefly:config/prompts.yml` | 3 | Asset prompts for the 4 active types only |

## Out of scope

- Removing `CombatResolutionService` from Firefly. Keep it — it's the parity baseline and the operational escape hatch.
- Porting the game-repo's full 30-50-seeds-per-scenario matrix. Firefly's smaller suite is intentional.
- Content parity with the game repo (xianxia flavor, world lore). Firefly is an engine; content is the downstream game's concern.
- Unifying `combat-engine/` into a shared upstream repo. If drift becomes a maintenance burden later, that's a separate refactor — this spec deliberately picks vendored-copy for self-containment today.

## Success criteria

- A clean checkout of `Firefly/rust-combat-engine` branch, with no external services running, can: `cargo build --release -p combat-server`, boot Puma, `COMBAT_ENGINE=auto` start a fight, play it end-to-end with the Rust engine.
- `backend/scripts/run_parity_tests.rb` green in under 15 minutes.
- Toggling `GameSetting use_rust_combat_engine=false` reverts to the Ruby path without other changes.
- Firefly's existing non-combat test suite stays green end-to-end.
- All 7 `ELEMENT_TYPES` values remain valid model inputs even though Firefly admin UI shows only 4 — a downstream game can add a `cliff_edge` template without touching the engine.
