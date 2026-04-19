# Firefly Rust Combat Engine Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Rust combat engine from the Romance of Five Kingdoms game repo into the Firefly MUD engine so Firefly fights resolve via Rust (with Ruby fallback), including willpower dice, aggressive/defensive/quick tactics, and interactive battlemap elements.

**Architecture:** Three sequential phases. Phase 1 is a small Rust rename in the game repo that must land and parity-verify first. Phase 2 vendors `combat-engine/` into Firefly, ports the Ruby bridge with willpower/tactic adaptations, and ships a minimal parity suite. Phase 3 additively ports the 7-type interactive battlemap element system. `CombatResolutionService` stays alive in Firefly as the parity baseline and the opt-out escape hatch.

**Tech Stack:** Rust (combat-engine/combat-core, cargo workspace), Ruby 3.x, Sequel (NOT ActiveRecord), Roda, PostgreSQL, RSpec.

**Source of truth spec:** `backend/docs/superpowers/specs/2026-04-19-firefly-rust-combat-port-design.md`.

**Paths used throughout:**
- Game repo: `/home/beat6749/game/.worktrees/rust-combat-engine/` (abbreviated `$GAME`)
- Firefly repo: `/home/beat6749/orig/Firefly/` (abbreviated `$FF`)
- Firefly worktree: `$FF/.worktrees/rust-combat-engine/` (abbreviated `$FFW`)

The Firefly worktree is already created on branch `rust-combat-engine`.

---

## Phase 1 — Rust: rename qi_movement_bonus to tactic_movement_bonus *(lands in game repo)*

### Task 1: Generic movement-bonus rename

**Files:**
- Modify: `$GAME/combat-engine/combat-core/src/movement.rs:111, 120`
- Modify: `$GAME/combat-engine/combat-core/src/resolution.rs:46, 164, 171, 842, 867, 1108, 1132`

**DO NOT** modify `combat_resolution_service.rb`, `combat_round_logger.rb`, or their specs — those are the qi-specific Ruby fallback path and keep their names.

- [ ] **Step 1: Baseline — confirm all 9 sites exist before touching anything**

```bash
cd /home/beat6749/game/.worktrees/rust-combat-engine
grep -rn qi_movement_bonus combat-engine/
```

Expected output: exactly 9 lines (2 in movement.rs, 7 in resolution.rs). If the count differs, stop and re-read the spec before proceeding.

- [ ] **Step 2: Rename in movement.rs**

```bash
sed -i 's/qi_movement_bonus/tactic_movement_bonus/g' combat-engine/combat-core/src/movement.rs
```

- [ ] **Step 3: Rename in resolution.rs**

```bash
sed -i 's/qi_movement_bonus/tactic_movement_bonus/g' combat-engine/combat-core/src/resolution.rs
```

- [ ] **Step 4: Verify zero hits remain in combat-engine**

```bash
grep -rn qi_movement_bonus combat-engine/
```

Expected output: empty (exit code 1 from grep is fine).

- [ ] **Step 5: Cargo build**

```bash
~/.cargo/bin/cargo build --release -p combat-core --manifest-path combat-engine/Cargo.toml
```

Expected: clean compile, no warnings about the rename.

- [ ] **Step 6: Cargo test**

```bash
~/.cargo/bin/cargo test --release -p combat-core --manifest-path combat-engine/Cargo.toml 2>&1 | tail -5
```

Expected: `test result: ok. 382 passed` (or whatever the existing count is — must be unchanged).

- [ ] **Step 7: Targeted parity subset**

```bash
cd backend
bundle exec rspec spec/parity/single_seed_trace_spec.rb 2>&1 | tail -5
```

Expected: 41 examples, 0 failures (the two flaky ones noted in memory are test-pollution, don't re-check them here).

- [ ] **Step 8: Commit the rename**

```bash
cd /home/beat6749/game/.worktrees/rust-combat-engine
git add combat-engine/combat-core/src/movement.rs combat-engine/combat-core/src/resolution.rs
git commit -m "$(cat <<'EOF'
refactor(combat-core): rename qi_movement_bonus to tactic_movement_bonus

Engine-neutral naming for the movement bonus field. Internal-only
rename across movement.rs and resolution.rs (9 sites). No wire-format
change (the value is computed inside Rust, never serialized). Ruby
fallback keeps qi_movement_bonus as that's the qi-specific resolver.

Prepares the Rust side for Firefly adoption via willpower dice.
EOF
)"
```

- [ ] **Step 9: Capture the SHA**

```bash
git rev-parse HEAD
```

Record this SHA. Phase 2's vendor step snapshots from exactly this commit.

---

## Phase 2 — Firefly bridge + willpower + aggressive/defensive/quick

All tasks in this phase work inside `$FFW` on branch `rust-combat-engine`.

### Task 2: Vendor combat-engine into Firefly

**Files:**
- Create: `$FFW/combat-engine/**` (vendored copy)
- Create: `$FFW/combat-engine/README.md`
- Modify: `$FFW/.gitignore`

- [ ] **Step 1: Copy the post-Phase-1 combat-engine tree**

```bash
cd /home/beat6749/orig/Firefly/.worktrees/rust-combat-engine
cp -R /home/beat6749/game/.worktrees/rust-combat-engine/combat-engine ./combat-engine
rm -rf combat-engine/target
```

- [ ] **Step 2: Add target/ to .gitignore**

```bash
echo "" >> .gitignore
echo "# Vendored Rust combat engine build output" >> .gitignore
echo "combat-engine/target/" >> .gitignore
```

- [ ] **Step 3: Write the provenance README**

Create `$FFW/combat-engine/README.md`:

```markdown
# combat-engine

Vendored copy of the Rust combat engine from the Romance of Five Kingdoms
game repo. This is a snapshot — contributing a fix here is fine for Firefly,
but upstream the change against the source repo so other downstream games
benefit.

Source commit: <PASTE THE SHA FROM PHASE 1 TASK 1 STEP 9>

Build:

    ~/.cargo/bin/cargo build --release --manifest-path combat-engine/Cargo.toml

Run the socket server (used by Firefly's backend):

    ~/.cargo/bin/cargo run --release -p combat-server --manifest-path combat-engine/Cargo.toml
```

Replace `<PASTE THE SHA...>` with the actual SHA.

- [ ] **Step 4: Verify it builds inside Firefly**

```bash
~/.cargo/bin/cargo build --release --manifest-path combat-engine/Cargo.toml 2>&1 | tail -5
```

Expected: clean build, produces `combat-engine/target/release/combat-server` and `libcombat_rng.so`.

- [ ] **Step 5: Commit the vendored copy**

```bash
git add combat-engine/ .gitignore
git commit -m "$(cat <<'EOF'
chore: vendor combat-engine/ from Romance of Five Kingdoms game repo

Full Rust combat engine copied as a sibling of backend/. Source commit
recorded in combat-engine/README.md. target/ ignored.
EOF
)"
```

### Task 3: Port the combat_engine_client.rb verbatim

**Files:**
- Create: `$FFW/backend/app/services/combat_engine_client.rb`

- [ ] **Step 1: Copy the file**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/combat_engine_client.rb backend/app/services/combat_engine_client.rb
```

- [ ] **Step 2: Read through to confirm no game-repo-specific imports**

```bash
grep -E "require|require_relative" backend/app/services/combat_engine_client.rb
```

Expected: only stdlib requires (`socket`, `json`, etc.). If any game-specific model is required, note it for the FightService task.

- [ ] **Step 3: Commit**

```bash
git add backend/app/services/combat_engine_client.rb
git commit -m "feat(bridge): add CombatEngineClient for Rust combat-server socket"
```

### Task 4: Port fight_state_serializer.rb with willpower adaptations

**Files:**
- Create: `$FFW/backend/app/services/combat/fight_state_serializer.rb`

**Adaptation summary:**
- qi column reads → willpower column reads (`qi_attack` → `willpower_attack`, etc.)
- `qi_die_sides` → hardcoded `8`
- Remove `qi_ability_roll`, `qi_movement_roll` callouts; use `willpower_*_roll` methods present on Firefly's `FightParticipant` (verified at `$FF/backend/app/models/fight_participant.rb:612,622,632,642`)

The tactic-modifier serialization is added in Task 5 — don't do it here.

- [ ] **Step 1: Copy the source file as a starting point**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/combat/fight_state_serializer.rb backend/app/services/combat/fight_state_serializer.rb
```

- [ ] **Step 2: Find all qi_ references**

```bash
grep -n "qi_" backend/app/services/combat/fight_state_serializer.rb
```

Save the line numbers. Expected: ~30-50 hits across method calls and serialized field names.

- [ ] **Step 3: Replace qi column/method names with willpower equivalents**

For each match from step 2, replace:

| Game-repo (qi) | Firefly (willpower) |
|---|---|
| `p.qi_attack` | `p.willpower_attack` |
| `p.qi_defense` | `p.willpower_defense` |
| `p.qi_ability` | `p.willpower_ability` |
| `p.qi_movement` | `p.willpower_movement` |
| `p.qi_attack_roll` | `p.willpower_attack_roll` |
| `p.qi_defense_roll` | `p.willpower_defense_roll` |
| `p.qi_ability_roll` | `p.willpower_ability_roll` |
| `p.qi_movement_roll` | `p.willpower_movement_roll` |
| `p.qi_die_sides` or `character_instance.qi_die_sides` | literal `8` |
| JSON field `qi_attack` | JSON field `willpower_attack` (same for the four columns and all roll fields) |

Use your editor's find-and-replace. After each substitution, spot-check that the JSON serialization keys the Rust engine expects still match — Rust Participant's serde field names are `qi_attack`, `qi_defense`, etc. (Rust is qi-flavored on the wire; rename only the Ruby-side method calls, not the JSON keys.)

**Important clarification:** The JSON wire format Rust accepts still uses `qi_attack`/`qi_defense` etc. as field names — the Ruby serializer should *read* Firefly's `willpower_*` columns but *emit* JSON with the same `qi_*` field names the Rust engine decodes. The serializer is the translation layer; Rust's schema doesn't change.

So the corrections above apply **only to the left-hand `p.qi_*` method calls**, not to the right-hand-side hash keys. For each line like `'qi_attack' => p.qi_attack`, change to `'qi_attack' => p.willpower_attack` (key stays, value source swaps).

- [ ] **Step 4: Replace die_sides call with hardcoded 8**

Grep for `qi_die_sides` specifically:

```bash
grep -n "qi_die_sides" backend/app/services/combat/fight_state_serializer.rb
```

Replace any expression that resolves to a per-character `qi_die_sides` with the literal integer `8`. Willpower is always d8.

- [ ] **Step 5: Smoke-parse the file**

```bash
cd backend && bundle exec ruby -c app/services/combat/fight_state_serializer.rb
```

Expected: `Syntax OK`.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/combat/fight_state_serializer.rb
git commit -m "$(cat <<'EOF'
feat(serializer): translate willpower dice for Rust combat engine

Ports the game-repo FightStateSerializer with the qi->willpower
method-call substitution. JSON wire format keeps qi_* keys so Rust
schema stays unchanged; the serializer reads Firefly's willpower_*
columns and Rust rolls d8-exploding-on-8 the same way qi d8 would.
EOF
)"
```

### Task 5: Extend the serializer with aggressive/defensive/quick modifiers

**Files:**
- Modify: `$FFW/backend/app/services/combat/fight_state_serializer.rb` (the block where `tactic_choice` is emitted)

- [ ] **Step 1: Locate the tactic_choice emission**

```bash
grep -n "tactic_choice\|tactic_outgoing_damage_modifier\|tactic_incoming_damage_modifier\|tactic_movement_bonus" backend/app/services/combat/fight_state_serializer.rb
```

In the game-repo version, the serializer already emits `tactic_outgoing_damage_modifier` and `tactic_incoming_damage_modifier` from `FightParticipant#tactic_*_damage_modifier`. Those methods already exist on Firefly's `FightParticipant` at `$FF/backend/app/models/fight_participant.rb:349-357` and read from `GameConfig::Tactics::OUTGOING_DAMAGE/INCOMING_DAMAGE`. So the existing emission logic should work unchanged.

- [ ] **Step 2: Confirm movement bonus gets populated from Firefly's tactic_movement_modifier**

The game-repo serializer computes the movement bonus from `qi_movement_roll` dice. Firefly needs a **different source** — the `tactic_movement_modifier` method on FightParticipant (at `$FF/backend/app/models/fight_participant.rb:361-363`) reads from `GameConfig::Tactics::MOVEMENT` which gives `+2` for `quick`.

Find the JSON block where the serializer emits the Rust Participant struct. Add a key:

```ruby
'tactic_movement_bonus' => (p.tactic_movement_modifier || 0),
```

(If the game-repo serializer already emits `tactic_movement_bonus` from a different source, replace the value expression with `p.tactic_movement_modifier || 0`. Do not emit both.)

- [ ] **Step 3: Syntax check**

```bash
cd backend && bundle exec ruby -c app/services/combat/fight_state_serializer.rb
```

Expected: `Syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add backend/app/services/combat/fight_state_serializer.rb
git commit -m "$(cat <<'EOF'
feat(serializer): wire aggressive/defensive/quick tactic modifiers to Rust

Populates Rust Participant.tactic_{outgoing,incoming}_damage_modifier
from Firefly's existing FightParticipant#tactic_*_damage_modifier
helpers (backed by GameConfig::Tactics), and tactic_movement_bonus
from tactic_movement_modifier (quick tactic = +2 hex).
EOF
)"
```

### Task 6: Merge combat_engine_mode, resolve_with_rust!, and apply_rust_result! into Firefly's FightService

**Files:**
- Modify: `$FFW/backend/app/services/fight/fight_service.rb`

**Source:** `$GAME/backend/app/services/fight/fight_service.rb:16-38` (engine mode), `:879-1067` (Rust dispatch in `try_advance_round`), `:1088-1390` (writeback). These are the sections to merge in.

**Strategy:** Read Firefly's existing `FightService` end-to-end. Find the analogue of `try_advance_round` (at Firefly `:116`). Wrap the existing Ruby-path resolution with the same `engine_mode = combat_engine_mode` branch the game repo uses. Copy the `combat_engine_mode`, `rust_engine_active?`, `resolve_with_rust!`, and `apply_rust_result!` methods verbatim from the game repo, placing them alongside the existing class-level helpers near the top of the file.

- [ ] **Step 1: Open both files side-by-side and read**

Read `$FFW/backend/app/services/fight/fight_service.rb` in full (1344 lines) and `$GAME/backend/app/services/fight/fight_service.rb:16-38, 875-1100, 1085-1395` (the Rust-specific regions).

- [ ] **Step 2: Copy `combat_engine_mode` and `rust_engine_active?` class methods**

Insert the two class methods from game repo `:16-38` into Firefly's `FightService` after the `attr_reader :fight` line. Exact text (copy as-is):

```ruby
  # Resolve which combat engine to use. Honors the COMBAT_ENGINE env var when
  # set; otherwise defaults to 'auto' (Rust when the combat-server socket is
  # reachable, Ruby fallback when not). The 'use_rust_combat_engine' GameSetting
  # is an ops-side escape hatch: set it explicitly to false to force Ruby.
  def self.combat_engine_mode
    env_mode = ENV['COMBAT_ENGINE']
    return env_mode if env_mode && !env_mode.empty?

    setting = GameSetting.get('use_rust_combat_engine')
    return 'ruby' if setting == false || setting == 'false' || setting == '0'

    'auto'
  rescue StandardError
    env_mode || 'auto'
  end

  def self.rust_engine_active?
    mode = combat_engine_mode
    (mode == 'rust' || mode == 'auto') && CombatEngineClient.available?
  end
```

- [ ] **Step 3: Locate Firefly's round-resolution call site**

```bash
grep -n "CombatResolutionService\|resolve_round\|\.resolve\b" backend/app/services/fight/fight_service.rb | head -20
```

Find where Firefly calls `CombatResolutionService.new(fight).resolve_round` (or equivalent). This is the call that needs to be wrapped.

- [ ] **Step 4: Wrap the call with the engine branch**

The game-repo pattern (from `:875-1067`):

```ruby
engine_mode = self.class.combat_engine_mode
if engine_mode == 'rust' || (engine_mode == 'auto' && CombatEngineClient.available?)
  begin
    rust_result = resolve_with_rust!(fight)
    apply_rust_result!(rust_result)
  rescue CombatEngineClient::ConnectionError, CombatEngineClient::ProtocolError => e
    warn "[FightService] Rust combat engine unreachable, falling back to Ruby: #{e.message}"
    # fall through to Ruby path
    CombatResolutionService.new(fight).resolve_round
  end
else
  CombatResolutionService.new(fight).resolve_round
end
```

Adapt the exact method calls to whatever Firefly uses — the structure (rust-first with Ruby fallback on specific exceptions) is what matters.

- [ ] **Step 5: Copy `resolve_with_rust!` and `apply_rust_result!` private methods**

From game repo `:1085-1395`, copy `resolve_with_rust!`, `apply_rust_result!`, and any helpers those two call (e.g., event-conversion helpers). Place them in Firefly's `FightService` under a `private` section near the bottom of the class. These methods reference `FightStateSerializer` and `CombatEngineClient`, both of which now exist in Firefly from Tasks 3-5.

If any helper references a game-repo-only feature (e.g., a qi-state writeback), drop it — Firefly has no qi state to write back. Comment out rather than delete on first pass so the review is easier; final cleanup comes in step 7.

- [ ] **Step 6: Syntax and load check**

```bash
cd backend && bundle exec ruby -c app/services/fight/fight_service.rb
```

Expected: `Syntax OK`.

```bash
bundle exec ruby -e "require_relative 'config/application'; puts FightService.combat_engine_mode"
```

Expected output: `auto` (or `ruby` if `GameSetting use_rust_combat_engine=false`). No `NoMethodError` or `NameError`.

- [ ] **Step 7: Remove any dead commented-out qi-state writeback from step 5**

Grep for `# qi_` or `# TODO` lines added during step 5 and delete dead blocks.

- [ ] **Step 8: Commit**

```bash
git add backend/app/services/fight/fight_service.rb
git commit -m "$(cat <<'EOF'
feat(fight): wire FightService to Rust engine with auto-fallback to Ruby

Adds combat_engine_mode, rust_engine_active?, resolve_with_rust!, and
apply_rust_result! to Firefly's FightService. Default mode is 'auto':
Rust when the combat-server socket is reachable, Ruby when not.
CombatEngineClient ConnectionError/ProtocolError trigger a warn-logged
fallback to CombatResolutionService so ops can see it in the puma log.
Overrides: COMBAT_ENGINE=ruby env var or GameSetting use_rust_combat_engine=false.
EOF
)"
```

### Task 7: Port parity and smoke-test scripts

**Files:**
- Create: `$FFW/backend/scripts/run_parity_tests.rb`
- Create: `$FFW/backend/scripts/smoke_test_rust_combat.rb`
- Create: `$FFW/backend/scripts/build_combat_engine.sh` (if present in game repo)

- [ ] **Step 1: Copy the scripts**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/scripts/run_parity_tests.rb backend/scripts/
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/scripts/smoke_test_rust_combat.rb backend/scripts/
test -f /home/beat6749/game/.worktrees/rust-combat-engine/backend/scripts/build_combat_engine.sh && cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/scripts/build_combat_engine.sh backend/scripts/ || echo "No build_combat_engine.sh in game repo - skipping"
```

- [ ] **Step 2: Fix up paths in run_parity_tests.rb**

```bash
grep -n "COMBAT_ENGINE_DIR\|expand_path" backend/scripts/run_parity_tests.rb
```

The game-repo script uses `File.expand_path('../../combat-engine', __dir__)` which resolves to `backend/../combat-engine` = sibling directory. Firefly's layout matches (combat-engine is a sibling of backend), so **no path change should be needed**. Verify by running with `--dry-run` or inspecting the path output.

- [ ] **Step 3: Ensure executable bits**

```bash
chmod +x backend/scripts/run_parity_tests.rb backend/scripts/smoke_test_rust_combat.rb
[ -f backend/scripts/build_combat_engine.sh ] && chmod +x backend/scripts/build_combat_engine.sh
```

- [ ] **Step 4: Commit**

```bash
git add backend/scripts/run_parity_tests.rb backend/scripts/smoke_test_rust_combat.rb
git add backend/scripts/build_combat_engine.sh 2>/dev/null || true
git commit -m "chore(scripts): port run_parity_tests.rb and smoke_test_rust_combat.rb"
```

### Task 8: Port and adapt parity_helpers.rb

**Files:**
- Create: `$FFW/backend/spec/parity/parity_helpers.rb`

The game-repo helper is `$GAME/backend/spec/parity/parity_helpers.rb` (~892 lines). It builds `Fight` fixtures, captures Ruby events via `CombatResolutionService`, captures Rust events via `CombatEngineClient`, and exposes assertion helpers.

**Adaptations needed:**
- Wherever the helper sets qi fields on fixtures (`fp.qi_attack = N`, `fp.qi_die_sides = 8`), swap to `fp.willpower_attack = N` etc.
- Wherever it builds test `character_instance` fixtures with qi attributes, swap to willpower.
- Leave the core event-capture / diff-compare logic unchanged.

- [ ] **Step 1: Copy the helper file**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/spec/parity/parity_helpers.rb backend/spec/parity/parity_helpers.rb
```

- [ ] **Step 2: Grep for qi fixture assignments**

```bash
grep -n "qi_attack\|qi_defense\|qi_ability\|qi_movement\|qi_dice\|qi_die_sides" backend/spec/parity/parity_helpers.rb
```

- [ ] **Step 3: Replace fixture assignments**

For each hit:
- `qi_attack` → `willpower_attack`
- `qi_defense` → `willpower_defense`
- `qi_ability` → `willpower_ability`
- `qi_movement` → `willpower_movement`
- `qi_dice` → **delete** (Firefly has no running qi pool; willpower dice are allocated per-round from a flat pool; Firefly uses `max_willpower_dice` differently — see `$FF/backend/app/models/fight_participant.rb` for the willpower-allocation methods)
- `qi_die_sides` → **delete** (always 8 in Firefly)

If a fixture relies on `qi_dice` as a pool size, replace with `max_willpower_dice = <same value>` — this is the Firefly analogue.

- [ ] **Step 4: Syntax check**

```bash
cd backend && bundle exec ruby -c spec/parity/parity_helpers.rb
```

Expected: `Syntax OK`.

- [ ] **Step 5: Commit**

```bash
git add backend/spec/parity/parity_helpers.rb
git commit -m "test(parity): port parity_helpers with willpower fixture adaptations"
```

### Task 9: Port single_seed_trace_spec.rb with Firefly scenarios

**Files:**
- Create: `$FFW/backend/spec/parity/single_seed_trace_spec.rb`

The game-repo spec has 41 scenarios. Firefly only needs 4-5 covering: 1v1 melee, 1v1 ranged ability, 2v2 melee, aggressive-vs-defensive, quick movement. Qi-specific scenarios (area_denial, qi_aura, qi_lightness, break/detonate/ignite) don't apply.

- [ ] **Step 1: Copy the source file**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/spec/parity/single_seed_trace_spec.rb backend/spec/parity/single_seed_trace_spec.rb
```

- [ ] **Step 2: Prune non-Firefly scenarios**

Open the file. Each `context` or `describe` block is one scenario. Delete any block whose setup references:
- `tactic_choice: 'area_denial'`
- `tactic_choice: 'qi_aura'`
- `tactic_choice: 'qi_lightness'`
- `tactic_choice: 'break'`
- `tactic_choice: 'detonate'`
- `tactic_choice: 'ignite'`
- Interactive elements (`BattleMapElement`) — those are Phase 3.
- Hazard tiles — Firefly doesn't have those as tile types.
- Mount mechanics — skip if Firefly doesn't have mounts in combat (check; if it does have them, keep one mount scenario).

Keep the 4-5 scenarios mapping to the Firefly-relevant cases. If the needed scenarios aren't in the game-repo file (e.g., no explicit aggressive-vs-defensive), write a new one — the existing scenarios are templates.

- [ ] **Step 3: Adapt remaining fixtures to willpower**

Apply the same qi → willpower substitutions from Task 8 Step 3 to any inline setup in the spec.

- [ ] **Step 4: Run the spec with combat-server running**

Start combat-server:

```bash
cd /home/beat6749/orig/Firefly/.worktrees/rust-combat-engine
COMBAT_ENGINE_FORMAT=json COMBAT_ENGINE_SOCKET=/tmp/combat-engine-firefly.sock \
  combat-engine/target/release/combat-server &
SERVER_PID=$!
sleep 1
```

Run:

```bash
cd backend
COMBAT_ENGINE_SOCKET=/tmp/combat-engine-firefly.sock bundle exec rspec spec/parity/single_seed_trace_spec.rb 2>&1 | tail -10
```

Expected: all remaining scenarios pass (however many you kept — likely 4-5).

Clean up:

```bash
kill $SERVER_PID 2>/dev/null
rm -f /tmp/combat-engine-firefly.sock
```

- [ ] **Step 5: Commit**

```bash
git add backend/spec/parity/single_seed_trace_spec.rb
git commit -m "test(parity): add single_seed_trace_spec for Firefly scenarios"
```

### Task 10: Write Firefly-specific parity specs

**Files:**
- Create: `$FFW/backend/spec/parity/tactics_parity_spec.rb`
- Create: `$FFW/backend/spec/parity/spar_mode_parity_spec.rb`
- Create: `$FFW/backend/spec/parity/multi_seed_parity_spec.rb`

**Approach:** These three specs are Firefly-native (no game-repo analogue that cleanly maps). Use `parity_helpers.rb` as the building block. Keep each spec focused:

- `tactics_parity_spec.rb` — ~5 examples: aggressive attacker vs defensive target (confirm +2/-2 mods apply once each), quick mover (confirm +2 movement budget), guard redirect (shared behavior — should work), back-to-back redirect (shared).
- `spar_mode_parity_spec.rb` — ~3 examples: touch-out behavior matches (no simultaneous KOs due to the fix from the game repo), fight ends on first touch-out.
- `multi_seed_parity_spec.rb` — 4-5 scenarios (the single-seed scenarios from Task 9), each run over 10 seeds, asserting event sequences match across all seeds.

- [ ] **Step 1: Write tactics_parity_spec.rb**

Structure:

```ruby
# frozen_string_literal: true

require_relative 'parity_helpers'

RSpec.describe 'Tactics parity', type: :parity do
  include ParityHelpers

  it 'aggressive attacker deals +2, defensive target takes -2' do
    fight = build_parity_fixture(
      side1_tactic: 'aggressive',
      side2_tactic: 'defensive'
    )
    ruby_events = resolve_ruby(fight, seed: 12345)
    rust_events = resolve_rust(fight, seed: 12345)
    expect_parity(ruby_events, rust_events)
  end

  it 'quick tactic adds +2 to movement budget' do
    # ...
  end

  # guard redirect, back_to_back redirect
end
```

Fill in the helper method names based on what's actually in the ported `parity_helpers.rb` — the above is a sketch.

- [ ] **Step 2: Write spar_mode_parity_spec.rb**

Similar structure; scenarios use `mode: 'spar'` on the Fight fixture. Assert that once `touch_count >= max_hp` on one participant, the fight ends and no further hits land that round.

- [ ] **Step 3: Write multi_seed_parity_spec.rb**

For each of the 4-5 scenarios from Task 9, loop seeds 1..10 and call `expect_parity(ruby, rust)` each iteration.

- [ ] **Step 4: Run all three specs against combat-server**

```bash
# (start combat-server as in Task 9 Step 4)
cd backend
COMBAT_ENGINE_SOCKET=/tmp/combat-engine-firefly.sock \
  bundle exec rspec spec/parity/tactics_parity_spec.rb spec/parity/spar_mode_parity_spec.rb spec/parity/multi_seed_parity_spec.rb 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 5: Commit each spec separately**

```bash
git add backend/spec/parity/tactics_parity_spec.rb
git commit -m "test(parity): tactics_parity_spec for aggressive/defensive/quick/guard"

git add backend/spec/parity/spar_mode_parity_spec.rb
git commit -m "test(parity): spar_mode_parity_spec for touch-count path"

git add backend/spec/parity/multi_seed_parity_spec.rb
git commit -m "test(parity): multi_seed_parity_spec for seed-stability"
```

### Task 11: End-to-end verification of Phase 2

- [ ] **Step 1: Full parity runner**

```bash
cd backend
bundle exec ruby scripts/run_parity_tests.rb 2>&1 | tail -20
```

Expected: all specs pass in under 15 minutes.

- [ ] **Step 2: Targeted Firefly RSpec directories**

```bash
cd backend
bundle exec rspec spec/services/fight/ spec/services/combat/ spec/models/fight_participant_spec.rb spec/models/fight_spec.rb 2>&1 | tail -5
```

Expected: green. If any fail, inspect — pre-existing failures unrelated to the port are acceptable (flag them to the user); new failures from the port must be fixed before merge.

- [ ] **Step 3: MCP live smoke test**

Start puma:

```bash
cd backend && bundle exec puma -p 3000 &
```

With a test agent (see `CLAUDE.md` MCP Testing section for setup), start a PvE fight and play through one round. Check `log/puma_error.log` for `[FightService] Rust combat engine unreachable` — should **not** appear (combat-server is up). Fight should advance without errors.

Kill puma and combat-server when done.

- [ ] **Step 4: Phase 2 is now complete**

No additional commit — all Phase 2 work is already committed from Tasks 2-10.

---

## Phase 3 — Firefly interactive battlemap elements

### Task 12: Migrations for battle_map_elements and battle_map_element_assets

**Files:**
- Create: `$FFW/backend/db/migrations/026_create_battle_map_elements.rb`
- Create: `$FFW/backend/db/migrations/027_create_battle_map_element_assets.rb`

Firefly's migration numbering starts at 001 and the latest is 025. Use 026 and 027.

- [ ] **Step 1: Copy the source migration**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/db/migrations/017_create_battle_map_elements.rb \
   backend/db/migrations/026_create_battle_map_elements.rb
```

Find the element_assets migration in the game repo:

```bash
ls /home/beat6749/game/.worktrees/rust-combat-engine/backend/db/migrations/ | grep element_asset
```

Copy it to `backend/db/migrations/027_create_battle_map_element_assets.rb`, adjusting the number.

- [ ] **Step 2: Sanity-check the JSONB default pattern**

Open both migration files. Confirm any JSONB column default uses `Sequel.lit("'{}'::jsonb")`, not `Sequel.pg_json_wrap({})`. See CLAUDE.md critical pattern #3 — `pg_json` isn't loaded during migrations and the pg_json_wrap form will crash.

Fix any violations before running the migration.

- [ ] **Step 3: Run the migrations**

```bash
cd backend
bundle exec sequel -m db/migrations -M 27 postgres://prom_user:prom_password@localhost/firefly
```

Expected: "up" messages for 026 and 027, no errors.

- [ ] **Step 4: Confirm tables exist**

```bash
psql postgres://prom_user:prom_password@localhost/firefly -c "\dt" | grep battle_map_element
```

Expected two rows: `battle_map_elements` and `battle_map_element_assets`.

- [ ] **Step 5: Commit**

```bash
git add backend/db/migrations/026_create_battle_map_elements.rb backend/db/migrations/027_create_battle_map_element_assets.rb
git commit -m "feat(db): add battle_map_elements and battle_map_element_assets tables"
```

### Task 13: Port BattleMapElement and BattleMapElementAsset models

**Files:**
- Create: `$FFW/backend/app/models/battle_map_element.rb`
- Create: `$FFW/backend/app/models/battle_map_element_asset.rb`

- [ ] **Step 1: Copy the models**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/models/battle_map_element.rb backend/app/models/
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/models/battle_map_element_asset.rb backend/app/models/
```

- [ ] **Step 2: Verify ELEMENT_TYPES keeps all 7 values**

```bash
grep "ELEMENT_TYPES" backend/app/models/battle_map_element.rb
```

Expected: includes all 7 types including `cliff_edge`, `toxic_mushrooms`, `lotus_pollen`. Those three are **dormant in Firefly** but kept in the array for downstream adopters.

- [ ] **Step 3: Smoke-load the models**

```bash
cd backend
bundle exec ruby -e "require_relative 'config/application'; puts BattleMapElement::ELEMENT_TYPES.inspect"
```

Expected: array of 7 strings.

- [ ] **Step 4: Commit**

```bash
git add backend/app/models/battle_map_element.rb backend/app/models/battle_map_element_asset.rb
git commit -m "feat(models): add BattleMapElement and BattleMapElementAsset models"
```

### Task 14: Port FightHexEffectService with status effect adaptations

**Files:**
- Create: `$FFW/backend/app/services/battlemap/fight_hex_effect_service.rb`

The service is 463 lines in the game repo. It applies element effects — water wets, oil slickens, smoke blinds, and (for the three dormant types) cliff-drop damage, mushroom poison, pollen intoxication. The poison/intoxication handlers reference game-repo-specific status effects that may or may not exist in Firefly.

- [ ] **Step 1: Copy the source service**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/battlemap/fight_hex_effect_service.rb backend/app/services/battlemap/
```

- [ ] **Step 2: Check the poison/intoxication handlers**

```bash
grep -nE "poisoned|intoxicated|StatusEffectService" backend/app/services/battlemap/fight_hex_effect_service.rb
```

These handlers apply status effects for the three dormant element types. Verify Firefly's `StatusEffectService` supports `poisoned` and `intoxicated` (or whatever the game-repo calls them):

```bash
grep -n "poisoned\|intoxicated" /home/beat6749/orig/Firefly/backend/app/services/status_effect_service.rb 2>&1 | head -5
```

- If Firefly supports these status names, leave the handlers as-is.
- If Firefly uses different names (likely), adapt the handlers to Firefly's vocabulary. The three types are dormant so real users won't trigger these paths often, but keeping the code compilable and adapted is needed.
- If Firefly has no equivalent status effect, stub the handler to `no-op with a comment` (so a downstream game can enable its own status later) — don't delete, per the "code in place" philosophy.

- [ ] **Step 3: Syntax check**

```bash
cd backend && bundle exec ruby -c app/services/battlemap/fight_hex_effect_service.rb
```

Expected: `Syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add backend/app/services/battlemap/fight_hex_effect_service.rb
git commit -m "$(cat <<'EOF'
feat(battlemap): port FightHexEffectService for element hex effects

Poisoned/intoxicated handlers for the three dormant element types
(cliff_edge, toxic_mushrooms, lotus_pollen) are adapted to Firefly's
StatusEffectService vocabulary (or stubbed if no equivalent exists).
Active handlers (water/oil/smoke/fire from barrels and crates) work
as-is.
EOF
)"
```

### Task 15: Port placement service and admin UI

**Files:**
- Create: `$FFW/backend/app/services/battlemap/battle_map_element_placement_service.rb`
- Create: Admin route + ERB files for CRUD (paths TBD based on Firefly's admin routing convention)

- [ ] **Step 1: Copy placement service**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/battlemap/battle_map_element_placement_service.rb backend/app/services/battlemap/
```

- [ ] **Step 2: Find the game-repo admin route and views**

```bash
find /home/beat6749/game/.worktrees/rust-combat-engine/backend -path "*admin*battle_map_element*" 2>&1
```

Copy every file under matching paths to the corresponding Firefly path.

- [ ] **Step 3: Filter the admin dropdown to active types**

In the admin ERB (wherever `ELEMENT_TYPES` is rendered as a `<select>`), replace with an explicit array of the four active types in Firefly:

```erb
<% active_types = %w[water_barrel oil_barrel munitions_crate vase] %>
<select name="element_type">
  <% active_types.each do |t| %>
    <option value="<%= t %>"><%= t.tr('_', ' ').capitalize %></option>
  <% end %>
</select>
```

The model's `ELEMENT_TYPES` constant still includes all 7, so a downstream game can add dropdown entries by extending the ERB without touching the model.

- [ ] **Step 4: Syntax check the Ruby**

```bash
cd backend && bundle exec ruby -c app/services/battlemap/battle_map_element_placement_service.rb
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/battlemap/battle_map_element_placement_service.rb backend/app/views/admin/ backend/app/routes/
git commit -m "feat(admin): battle map element CRUD UI, filtered to 4 active types"
```

### Task 16: Port asset generation script and prune prompts

**Files:**
- Create: `$FFW/backend/scripts/generate_element_assets.rb`
- Modify: `$FFW/backend/config/prompts.yml`

- [ ] **Step 1: Copy asset generation script**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/scripts/generate_element_assets.rb backend/scripts/
chmod +x backend/scripts/generate_element_assets.rb
```

- [ ] **Step 2: Find the source prompts block**

```bash
grep -n "element_assets\|water_barrel\|oil_barrel\|munitions_crate\|vase\|cliff_edge\|toxic_mushrooms\|lotus_pollen" /home/beat6749/game/.worktrees/rust-combat-engine/backend/config/prompts.yml | head -30
```

- [ ] **Step 3: Port the 4 active-type prompts to Firefly's prompts.yml**

Copy the prompt blocks for `water_barrel`, `oil_barrel`, `munitions_crate`, `vase` from game-repo prompts.yml to Firefly's prompts.yml. **Skip** the three dormant types — they reference xianxia flavor and don't fit Firefly's setting-neutral engine. A downstream game can add their own prompt blocks.

- [ ] **Step 4: Verify GamePrompts can read the new entries**

```bash
cd backend
bundle exec ruby -e "require_relative 'config/application'; puts GamePrompts.exists?('element_assets.water_barrel')"
```

(Adapt the exact key path based on how prompts.yml is structured.)

Expected: `true`.

- [ ] **Step 5: Commit**

```bash
git add backend/scripts/generate_element_assets.rb backend/config/prompts.yml
git commit -m "feat(assets): port element asset generation for 4 active types"
```

### Task 17: Extend serializer and writeback with element events

**Files:**
- Modify: `$FFW/backend/app/services/combat/fight_state_serializer.rb`
- Modify: `$FFW/backend/app/services/fight/fight_service.rb`

- [ ] **Step 1: Port the serializer's element block**

In the game-repo serializer, find the block that serializes interactive elements. Grep:

```bash
grep -n "interactive_elements\|battle_map_element\|BattleMapElement" /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/combat/fight_state_serializer.rb
```

Copy that block into Firefly's serializer at the equivalent location in the state hash. No adaptation — element IDs, types, states, positions all pass through as-is.

- [ ] **Step 2: Port the writeback helper**

In the game-repo FightService, find element event writeback:

```bash
grep -n "battle_map_element\|element_broken\|element_detonated" /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/fight/fight_service.rb | head -20
```

Copy the relevant event-handler branches into Firefly's `apply_rust_result!` private method.

- [ ] **Step 3: Syntax check**

```bash
cd backend
bundle exec ruby -c app/services/combat/fight_state_serializer.rb app/services/fight/fight_service.rb
```

- [ ] **Step 4: Commit**

```bash
git add backend/app/services/combat/fight_state_serializer.rb backend/app/services/fight/fight_service.rb
git commit -m "feat(bridge): serialize interactive elements and write back element events"
```

### Task 18: Interactive element parity spec

**Files:**
- Create: `$FFW/backend/spec/parity/interactive_elements_parity_spec.rb`

- [ ] **Step 1: Use game-repo element parity specs as templates**

```bash
ls /home/beat6749/game/.worktrees/rust-combat-engine/backend/spec/parity/ | grep element
```

The game repo has multiple element parity specs. Firefly consolidates into one spec with 4 contexts — one per active type.

- [ ] **Step 2: Write the spec**

Skeleton:

```ruby
# frozen_string_literal: true

require_relative 'parity_helpers'

RSpec.describe 'Interactive elements parity', type: :parity do
  include ParityHelpers

  %w[water_barrel oil_barrel munitions_crate vase].each do |element_type|
    context element_type do
      10.times do |i|
        it "matches Ruby for seed #{i}" do
          fight = build_parity_fixture_with_element(element_type: element_type)
          ruby_events = resolve_ruby(fight, seed: i)
          rust_events = resolve_rust(fight, seed: i)
          expect_parity(ruby_events, rust_events)
        end
      end
    end
  end
end
```

Add `build_parity_fixture_with_element` to `parity_helpers.rb` if it doesn't already exist — it should create a `BattleMapElement` record with the given type at a predictable position near the participants.

- [ ] **Step 3: Run against combat-server**

```bash
cd backend
COMBAT_ENGINE_SOCKET=/tmp/combat-engine-firefly.sock \
  bundle exec rspec spec/parity/interactive_elements_parity_spec.rb 2>&1 | tail -10
```

Expected: 40 examples green (4 types × 10 seeds).

- [ ] **Step 4: Commit**

```bash
git add backend/spec/parity/parity_helpers.rb backend/spec/parity/interactive_elements_parity_spec.rb
git commit -m "test(parity): interactive elements parity across 4 active types"
```

### Task 19: Focused unit specs for element services

**Files:**
- Create: `$FFW/backend/spec/services/battlemap/fight_hex_effect_service_spec.rb`
- Create: `$FFW/backend/spec/services/battlemap/battle_map_element_placement_service_spec.rb`
- Create: `$FFW/backend/spec/models/battle_map_element_spec.rb`

- [ ] **Step 1: Port the spec files from game repo**

```bash
find /home/beat6749/game/.worktrees/rust-combat-engine/backend/spec -name "*battle_map_element*" -o -name "*fight_hex_effect*" 2>&1
```

Copy the matching spec files to Firefly. Adapt fixtures from qi to willpower (Task 8 Step 3 patterns) and prune examples that exercise dormant element types.

- [ ] **Step 2: Run the specs**

```bash
cd backend
bundle exec rspec spec/services/battlemap/ spec/models/battle_map_element_spec.rb 2>&1 | tail -10
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add backend/spec/services/battlemap/ backend/spec/models/battle_map_element_spec.rb
git commit -m "test: unit specs for BattleMapElement model and battlemap services"
```

### Task 20: End-to-end verification of Phase 3

- [ ] **Step 1: Full parity suite**

```bash
cd backend
bundle exec ruby scripts/run_parity_tests.rb 2>&1 | tail -20
```

Expected: all parity specs including interactive_elements_parity_spec green.

- [ ] **Step 2: Targeted spec dirs**

```bash
bundle exec rspec spec/services/fight/ spec/services/combat/ spec/services/battlemap/ spec/models/fight_participant_spec.rb spec/models/fight_spec.rb spec/models/battle_map_element_spec.rb 2>&1 | tail -5
```

Expected: green (pre-existing unrelated failures acceptable; new failures from the port are not).

- [ ] **Step 3: MCP smoke test for elements**

Start puma + combat-server. Via MCP or API, place a `water_barrel` on a battlemap, execute an attack on it, confirm `element_broken` event fires and the adjacent hexes get the water effect applied. Verify in `log/puma_error.log` that there are no serialization errors.

- [ ] **Step 4: Phase 3 complete**

All work is already committed.

---

## Final verification

- [ ] **Step 1: Log of commits on the branch**

```bash
cd /home/beat6749/orig/Firefly/.worktrees/rust-combat-engine
git log --oneline main..HEAD
```

Expected: ~18-20 commits covering the spec (3 revisions), vendored engine, bridge, serializer (willpower + tactics + elements), FightService wiring, scripts, parity suite, migrations, models, battlemap services, admin UI, asset prompts, parity spec, and unit specs.

- [ ] **Step 2: Success criteria from spec**

Walk through each criterion in the spec's "Success criteria" section and confirm:

- ✅ Clean checkout + `cargo build --release -p combat-server` + puma + `COMBAT_ENGINE=auto` fight plays end-to-end on Rust
- ✅ `scripts/run_parity_tests.rb` green under 15 minutes
- ✅ `GameSetting use_rust_combat_engine=false` reverts to Ruby path
- ✅ Targeted spec dirs green after each phase (fight, combat non-parity, fight_participant_spec, fight_spec, and after Phase 3 also battlemap services/models)
- ✅ All 7 ELEMENT_TYPES remain valid model inputs; admin UI shows 4

- [ ] **Step 3: Memory update for future sessions**

Append to `/home/beat6749/.claude/projects/-home-beat6749-game/memory/project_rust_combat_engine.md` (or create a new `project_firefly_rust_combat_port.md`): a brief note that Firefly has the Rust combat engine ported on branch `rust-combat-engine`, with willpower dice, aggressive/defensive/quick tactics, and the 7-type interactive element system (with 3 types dormant in Firefly for downstream adopters).

---

## Rollback plan

If anything goes badly wrong in a phase:

- Phase 1 (game repo): `git revert` the rename commit. The rename is mechanical and fully reversible.
- Phase 2 (Firefly): `COMBAT_ENGINE=ruby` or `GameSetting use_rust_combat_engine=false` reverts every Firefly fight to the Ruby path without changing code. If the bridge itself is broken (syntax error, import failure), `git revert` the problem commit — earlier phases stand on their own.
- Phase 3 (Firefly): element tables have no FK'd consumers yet, so rollback is `bundle exec sequel -m db/migrations -M 25 ...` to undo the two migrations and `git revert` the code commits.

## Risks and open questions

- **Firefly `StatusEffectService` vocabulary mismatch** (Task 14): if Firefly has no `poisoned`/`intoxicated` effects, the three dormant element types need stub handlers. Surface this in Task 14 review rather than silently masking; downstream games that care can add their own status effects.
- **Firefly admin-routing convention differs from game repo** (Task 15): the game repo's admin routes use a specific Roda pattern; Firefly may route differently. If the route paths diverge, the porter should follow Firefly's existing admin-route pattern and note the divergence in the commit message.
- **`CombatResolutionService` drift** between game repo and Firefly: Firefly's `CombatResolutionService` is 3301 lines vs. the game repo's 3848. Some methods that exist in the game-repo's writeback helpers may call into game-repo-only resolution code. Flag this early — if `apply_rust_result!` references a method Firefly doesn't have, either port the method or stub it.
- **Vendored Rust copy drift from upstream**: as the game repo's `combat-engine/` evolves, Firefly's vendored copy will need periodic refresh. Out of scope for this plan; future refresh is a separate task (`git diff` the source dir and apply cleanly, or re-vendor wholesale).
