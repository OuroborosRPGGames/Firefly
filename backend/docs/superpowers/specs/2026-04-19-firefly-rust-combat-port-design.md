# Firefly Rust Combat Engine Port — Design

**Date:** 2026-04-19
**Status:** Approved, ready for implementation plan.
**Target repo:** `/home/beat6749/orig/Firefly`
**Branch:** `rust-combat-engine` (worktree at `.worktrees/rust-combat-engine`)

## Context

The Rust combat engine developed in the sister game repo (Romance of Five Kingdoms, `/home/beat6749/game`) is now the production default there. This spec ports it to Firefly, the underlying MUD engine, so any game built on Firefly can resolve combat with the Rust engine instead of (or alongside) the Ruby `CombatResolutionService`.

Firefly's combat differs from the game repo's on three axes:

1. **Dice.** Firefly uses **willpower dice** — fixed `d8 exploding on 8`. The game repo uses **qi dice** with variable sides per character (d4/d6/d8/d10/d12). The Rust `dice::roll` is already parameterized on `sides`, so this is a serializer-level change only.
2. **Tactics.** Firefly has `aggressive`, `defensive`, `quick`, `guard`, `back_to_back`. The first three are simple numeric modifiers (±damage, ±movement). The game repo's tactic set (`area_denial`, `qi_aura`, `qi_lightness`, `break`, `detonate`, `ignite`, plus shared `guard`/`back_to_back`) is geometrically and mechanically richer. `guard`/`back_to_back` are shared between the two games.
3. **Interactive battlemap elements.** Both games share four element types (`water_barrel`, `oil_barrel`, `munitions_crate`, `vase`). The game repo also has three lore-flavored elements Firefly doesn't use (`cliff_edge` → "long drop", `toxic_mushrooms`, `lotus_pollen` → "lotus flower").

**Philosophy.** Firefly is an engine intended for downstream adoption. Features Firefly itself doesn't use should stay in the codebase as dormant, documented code so a downstream game can enable them without touching the engine.

## Approved decisions

1. **Distribution:** vendored copy of `combat-engine/` in Firefly as a sibling of `backend/`. Firefly becomes self-contained.
2. **Tactic modifiers in Rust:** generic optional integer fields on `Participant`. Two of the three already exist (see Phase 1); the movement field needs to be generalized.
3. **Interactives:** full 7-type port. The three lore-flavored types stay dormant in Firefly — model accepts them, Rust resolves them, but Firefly admin UI and seed content only cover the four it uses.
4. **Workspace:** Firefly worktree at `.worktrees/rust-combat-engine`.
5. **Testing:** minimal Firefly-native parity suite (~6 spec files, 8-10 seeds per scenario, <15 minute runner).
6. **Execution:** three-phase branch stack.

## Source-of-truth file locations in the game repo

These are the real paths the bridge port draws from; the earlier draft of this spec had them wrong.

| Concern | Game-repo path |
|---|---|
| Socket client | `backend/app/services/combat_engine_client.rb` (flat, not under a `combat_engine/` subdirectory) |
| Serializer | `backend/app/services/combat/fight_state_serializer.rb` |
| Apply-result writeback | Private methods on `FightService` (`backend/app/services/fight/fight_service.rb`), not a separate class |
| Engine dispatch | `FightService.combat_engine_mode` + `resolve_with_rust!` in the same file |
| Error classes | `CombatEngineClient::ConnectionError`, `CombatEngineClient::ProtocolError` |
| Tactic modifier fields | `combat-engine/combat-core/src/types/participant.rs` — `tactic_outgoing_damage_modifier: i32`, `tactic_incoming_damage_modifier: i32` **already defined** |
| Movement bonus in Rust | `combat-engine/combat-core/src/movement.rs:111,120` — currently named `qi_movement_bonus: u32` |
| Scripts | `backend/scripts/run_parity_tests.rb`, `smoke_test_rust_combat.rb`, `build_combat_engine.sh` |

Firefly file locations will mirror these — same paths under `Firefly/backend/` and `Firefly/combat-engine/`.

## Phase 1 — Rust: make movement bonus generic (small) *(lands in game repo)*

**Scope is smaller than an earlier draft suggested.** `tactic_outgoing_damage_modifier` and `tactic_incoming_damage_modifier` already exist on `Participant` (`participant.rs:87-93`) and are already applied in `resolution.rs`. The only Rust-side work is the movement field.

**Changes in game repo:**
- Rename `qi_movement_bonus` → `tactic_movement_bonus` across **9 call sites in 2 files**:
  - `combat-engine/combat-core/src/movement.rs:111,120` (parameter + usage).
  - `combat-engine/combat-core/src/resolution.rs:46, 164, 171, 842, 867, 1108, 1132` (parameter, read, write, computed-from-dice assignment, struct-field pass-through, per-round-result read, per-round-result write).
- The authoritative check: `grep -rn qi_movement_bonus combat-engine/` should return zero hits after the rename.
- **No change needed in `participant.rs`** — the identifier is local to movement.rs/resolution.rs; it does not appear on the `Participant` struct.
- **No change needed in the Ruby engine-bridge serializer** (`backend/app/services/combat/fight_state_serializer.rb`). The serializer emits `qi_movement` (the dice count); the *bonus* is computed inside Rust at `resolution.rs:842-857` from `dice::roll(action.qi_movement, …) / 2` and lives internal to Rust. It never hits the JSON wire, so no wire-format change accompanies the rename.
- **Ruby fallback path (`backend/app/services/combat/combat_resolution_service.rb`, `combat_round_logger.rb`, and their specs)** keeps `qi_movement_bonus` unchanged — that code path is the qi-specific Ruby resolver and will never talk to Firefly. Leaving it as-is keeps the diff minimal and the intent clear.
- Unit tests: the rename is purely mechanical; no new tests needed. If any existing test asserts the identifier name via string match (unlikely), update alongside the rename.

**Do not introduce a damage clamp.** Earlier draft called for clamping damage ≥ 0 at the modifier site. Don't — the parity gate requires qi behavior to stay byte-identical, and adding a clamp that didn't exist before would silently change behavior any time a large `tactic_incoming_damage_modifier` would have pushed damage negative. Leave clamping to the threshold pipeline where it already lives.

**Gate to proceed to Phase 2:**
- `cargo test --release -p combat-core` — existing green count unchanged.
- Targeted parity subset: `bundle exec rspec spec/parity/single_seed_trace_spec.rb spec/parity/tactics_parity_spec.rb` (if it exists) green. **Do not block on the full 10-hour multi-seed matrix** — targeted subset is enough to catch a rename mistake, and the full matrix can run separately in the background.
- The resulting commit SHA is the snapshot Phase 2 vendors.

**Commit:** `refactor(combat-core): rename qi_movement_bonus to tactic_movement_bonus for engine-neutral naming`

## Phase 2 — Firefly bridge + willpower + aggressive/defensive/quick

**Worktree:** `cd /home/beat6749/orig/Firefly && git worktree add .worktrees/rust-combat-engine -b rust-combat-engine` *(already done as of this spec's commit)*.

**Vendor the engine.**
- Copy the entire post-Phase-1 `combat-engine/` tree from the game repo into `Firefly/combat-engine/`.
- Add `combat-engine/target/` to Firefly's `.gitignore`.
- `combat-engine/README.md` — short provenance note: vendored snapshot from the game repo at the Phase 1 commit SHA, with a pointer to the upstream for anyone wanting to contribute back.

**Port the Ruby bridge from the game repo.** Paths mirror the game repo exactly:

- **`backend/app/services/combat_engine_client.rb`** — verbatim copy. Socket client, Firefly-agnostic. Error classes `ConnectionError` and `ProtocolError` keep their names — do not rename.
- **`backend/app/services/combat/fight_state_serializer.rb`** — port with **willpower + tactic adaptations**:
  - Replace qi column reads (`qi_attack`, `qi_defense`, `qi_ability`, `qi_movement`) with the corresponding `willpower_*` columns that already exist on Firefly's `FightParticipant` (verified in `Firefly/backend/app/models/fight_participant.rb:612,622,632,642`).
  - Replace per-character `qi_die_sides` with hardcoded `8`. Willpower is always d8-exploding-on-8; no per-character variation.
  - When serializing `tactic_choice`, also populate `tactic_outgoing_damage_modifier`, `tactic_incoming_damage_modifier`, and `tactic_movement_bonus` on the serialized participant from `GameConfig::Tactics::OUTGOING_DAMAGE`, `INCOMING_DAMAGE`, and `MOVEMENT` (verified in `Firefly/backend/config/game_config.rb:497-513`). For `guard`/`back_to_back`, modifiers are zero; `tactic_choice` still gets passed through as a string so the shared redirect logic in Rust still fires.
- **`backend/app/services/fight/fight_service.rb`** — merge the game-repo `combat_engine_mode` method, `resolve_with_rust!`, and the private `apply_rust_result!` / related writeback helpers into Firefly's existing `FightService`. There is **no separate `ApplyRustResult` class** — the logic lives as private methods on `FightService`. Keep that structure to match upstream. Default `combat_engine_mode` to `'auto'`; opt-out via `GameSetting.get('use_rust_combat_engine') == false` (verified `GameSetting` exists in Firefly — grep confirms) or `COMBAT_ENGINE=ruby` env var.
- **`backend/scripts/run_parity_tests.rb`**, **`smoke_test_rust_combat.rb`**, **`build_combat_engine.sh`** — port as-is.

**What stays in Firefly unchanged:**
- `CombatResolutionService` — stays as the Ruby fallback path, the opt-out escape hatch, and the baseline for parity tests. Do not delete.

**What's NOT ported in this phase:**
- Interactive battlemap elements (Phase 3).
- Qi migrations, qi column definitions, qi-tactic code paths.

**Parity suite for this phase** (`backend/spec/parity/`):
- `parity_helper.rb` — builds `Fight` fixture, captures Ruby events via `CombatResolutionService`, captures Rust events via `CombatEngineClient` against the same state, asserts equality on event sequences, KO timing, final HP, final positions.
- `single_seed_trace_spec.rb` — 4-5 base scenarios (1v1 melee, 1v1 ranged ability, 2v2 melee, aggressive-vs-defensive, quick-movement), single seed each.
- `multi_seed_parity_spec.rb` — same scenarios, 10 seeds each.
- `tactics_parity_spec.rb` — aggressive/defensive/quick modifier correctness at the event level; guard/back-to-back redirect correctness.
- `spar_mode_parity_spec.rb` — touch-count path parity.

**Verification for Phase 2:**
- Parity specs green; `backend/scripts/run_parity_tests.rb` completes in under 15 minutes.
- MCP smoke test: start combat-server socket, boot puma, create test agent, run `fight <target>` in Firefly, confirm fight advances with zero protocol errors.
- Targeted Firefly RSpec stays green. Specifically: `backend/spec/services/fight/`, `backend/spec/services/combat/` (non-parity), `backend/spec/models/fight_participant_spec.rb`, `backend/spec/models/fight_spec.rb`. These are the directories whose outcomes could be affected by a bridge/engine swap. The full Firefly suite is explicitly out of scope (runs too long; memory note preserves that).

**Commits (in order):**
1. `chore: vendor combat-engine/` *(the Rust tree copy)*
2. `feat(bridge): add combat_engine_client.rb and fight_state_serializer.rb`
3. `feat(fight): wire FightService to Rust engine with auto-fallback to Ruby`
4. `feat(serializer): translate willpower dice and aggressive/defensive/quick tactics`
5. `test: add Firefly parity suite and runner`

## Phase 3 — Firefly interactive battlemap elements

**Goal:** port the full 7-type `BattleMapElement` system additively on top of Phase 2. The three lore-specific types stay dormant — model accepts them, Rust resolves them, but Firefly ships no admin templates, seed data, or asset prompts for them.

**Changes:**
- Migrations — port from game repo, Sequel syntax:
  - `*_create_battle_map_elements.rb`
  - `*_create_battle_map_element_assets.rb`
  - JSONB defaults via `Sequel.lit("'{}'::jsonb")` (not `Sequel.pg_json_wrap` — `pg_json` isn't loaded during migrations; see CLAUDE.md critical patterns).
- Models — `backend/app/models/battle_map_element.rb`, `battle_map_element_asset.rb`. `ELEMENT_TYPES` keeps all 7 values.
- Services — `backend/app/services/battlemap/fight_hex_effect_service.rb` and related event handlers. Adapt any qi-specific poisoning logic to Firefly's existing `StatusEffectService` vocabulary (Firefly's status effect system is verified present; the toxic-mushroom handler is the likely adaptation point even though Firefly ships no toxic-mushroom template).
- Admin UI — ERB + routes. Dropdown filtered to the four actively-used types in Firefly; the other three still work via API/DB for downstream adopters.
- Asset pipeline — `backend/scripts/generate_element_assets.rb` ported. Prune the three dormant types' prompt templates out of Firefly's `config/prompts.yml`.
- Bridge additions — extend `FightStateSerializer` with the interactive-element serialization block; extend the `apply_rust_result!` private method on `FightService` with element event writeback.

**Parity additions:**
- `backend/spec/parity/interactive_elements_parity_spec.rb` — four active types, 8-10 seeds each.
- Focused unit specs in `backend/spec/services/battlemap/` — element creation, barrel break, crate detonate, vase smash, water-hex-entry status application.

**Verification for Phase 3:**
- Parity specs green.
- MCP smoke: place a water barrel on a Firefly battlemap, attack it, confirm water hex effect fires.

**Commits (in order):**
1. `feat(db): add battle_map_elements and battle_map_element_assets tables`
2. `feat(models): BattleMapElement and BattleMapElementAsset models`
3. `feat(battlemap): fight hex effect service and event handlers`
4. `feat(admin): battle map element CRUD UI`
5. `feat(bridge): serialize interactive elements and write back element events`
6. `test: interactive element parity and unit specs`

## Error handling / fallback

Mirror the game repo:
- `CombatEngineClient` raises `CombatEngineClient::ConnectionError` on socket-connect failures and `CombatEngineClient::ProtocolError` on malformed responses. All other exceptions bubble unmasked — do not rescue `StandardError` in the client; that's how real Rust bugs get hidden.
- `FightService` rescues both classes specifically and falls back to `CombatResolutionService`. A `warn "[FightService] Rust combat engine unreachable, falling back to Ruby: #{e.message}"` log line marks every fallback so ops can see it in `log/puma_error.log`.
- Engine selection precedence: `COMBAT_ENGINE` env var (if set and non-empty) > `GameSetting.get('use_rust_combat_engine') == false` (forces ruby) > default `'auto'`.

## Files at a glance

| File | Phase | Change |
|---|---|---|
| `game:combat-engine/combat-core/src/movement.rs` | 1 | Rename `qi_movement_bonus` → `tactic_movement_bonus` (2 sites) |
| `game:combat-engine/combat-core/src/resolution.rs` | 1 | Rename `qi_movement_bonus` → `tactic_movement_bonus` (7 sites) |
| `firefly:combat-engine/**` | 2 | Vendored copy of Phase 1 snapshot |
| `firefly:backend/app/services/combat_engine_client.rb` | 2 | Port verbatim |
| `firefly:backend/app/services/combat/fight_state_serializer.rb` | 2 | Port with willpower/tactic adaptation |
| `firefly:backend/app/services/fight/fight_service.rb` | 2 | Merge `combat_engine_mode`, `resolve_with_rust!`, `apply_rust_result!` helpers into existing FightService |
| `firefly:backend/scripts/run_parity_tests.rb` + helpers | 2 | Port |
| `firefly:backend/spec/parity/*.rb` | 2 | New parity suite (Phase 2 scenarios) |
| `firefly:backend/spec/parity/interactive_elements_parity_spec.rb` | 3 | Parity for 4 active elements |
| `firefly:backend/db/migrate/*battle_map_element*.rb` | 3 | Migrations |
| `firefly:backend/app/models/battle_map_element*.rb` | 3 | Models (all 7 types in `ELEMENT_TYPES`) |
| `firefly:backend/app/services/battlemap/fight_hex_effect_service.rb` | 3 | Service + handlers; qi-poison adapted to StatusEffectService |
| `firefly:backend/app/services/combat/fight_state_serializer.rb` | 3 | Add element serialization block |
| `firefly:backend/app/services/fight/fight_service.rb` | 3 | Extend `apply_rust_result!` with element event writeback |
| `firefly:config/prompts.yml` | 3 | Asset prompts for the 4 active types only |

## Out of scope

- Removing `CombatResolutionService` from Firefly. Keep it — it's the parity baseline and the operational escape hatch.
- Porting the game repo's full 30-50-seeds-per-scenario matrix. Firefly's smaller suite is intentional.
- Content parity with the game repo (xianxia flavor, world lore). Firefly is an engine; content is the downstream game's concern.
- Unifying `combat-engine/` into a shared upstream repo. If drift becomes a maintenance burden later, that's a separate refactor.
- Running Firefly's full RSpec suite as verification. Per persistent memory, that suite is too slow; targeted spec directories (listed in Phase 2 verification) are the coverage.

## Success criteria

- A clean checkout of `Firefly/rust-combat-engine` branch, with no external services initially running, can: `cargo build --release -p combat-server`, boot Puma, start a fight with `COMBAT_ENGINE=auto`, play it end-to-end with the Rust engine.
- `backend/scripts/run_parity_tests.rb` green in under 15 minutes.
- Toggling `GameSetting use_rust_combat_engine=false` reverts to the Ruby path without other changes.
- Targeted Firefly test dirs green after each phase: `backend/spec/services/fight/`, `backend/spec/services/combat/` (non-parity), `backend/spec/models/fight_participant_spec.rb`, `backend/spec/models/fight_spec.rb`, and after Phase 3 also `backend/spec/services/battlemap/`.
- All 7 `ELEMENT_TYPES` values remain valid model inputs even though Firefly admin UI shows only 4 — a downstream game can add a `cliff_edge` template via API/DB without touching the engine.
