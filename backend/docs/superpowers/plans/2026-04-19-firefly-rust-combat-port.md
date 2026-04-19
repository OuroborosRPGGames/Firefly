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

- [ ] **Step 3: Replace qi Ruby method calls with willpower equivalents — JSON keys stay qi_***

**Key rule:** the Rust engine's serde field names on `Participant` are `qi_attack`, `qi_defense`, `qi_ability`, `qi_movement`, `qi_die_sides` — those stay as-is on the wire. The serializer reads Firefly's `willpower_*` columns and emits the same `qi_*` JSON keys Rust decodes.

So for lines like `'qi_attack' => p.qi_attack`, change **only the right-hand side**: `'qi_attack' => p.willpower_attack`.

Substitutions for Ruby method calls (left-hand `p.qi_*`):

| Game-repo call | Firefly replacement |
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

Do **not** rename JSON hash keys — they're the engine's wire contract.

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

### Task 6: Merge engine-mode, resolve_via_rust_engine!, and apply_rust_result! into Firefly's FightService

**Files:**
- Modify: `$FFW/backend/app/services/fight/fight_service.rb`

**Real method names and call sites in the game repo** (verified by grep):

| Game-repo location | Method | Kind |
|---|---|---|
| `:21` | `combat_engine_mode` | class method |
| `:35` | `rust_engine_active?` | class method |
| `:870` | `resolve_round!` | instance method (existing call site in Firefly too) |
| `:879-882` | Rust dispatch branch *inside* `resolve_round!` | inline, 4 lines |
| `:1059` | `resolve_via_rust_engine!` | instance (private) |
| `:1078` | `resolve_via_rust_engine_raw` | instance (private, compare-mode helper) |
| `:1088` | `apply_rust_result!` | instance (private) |

The Rust integration is **not** inside the class-method `try_advance_round`. It's inside the instance method `resolve_round!`, which is called from `try_advance_round` via `FightService.new(fight).resolve_round!`. Firefly's `FightService` also has a `resolve_round!` instance method — that's where the dispatch branch goes.

- [ ] **Step 1: Read both files' resolve_round! instance methods**

```bash
grep -n "def resolve_round" backend/app/services/fight/fight_service.rb
grep -n "def resolve_round" /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/fight/fight_service.rb
```

Open both and compare the method bodies.

- [ ] **Step 2: Copy `combat_engine_mode` and `rust_engine_active?` class methods**

Insert these two class methods into Firefly's `FightService` after the `attr_reader :fight` line (verbatim from game repo `:21-38`):

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

- [ ] **Step 3: Insert the Rust dispatch branch inside Firefly's `resolve_round!`**

Game-repo pattern at `:879-882` (verbatim — this is the inline 4-line dispatch):

```ruby
    engine_mode = self.class.combat_engine_mode
    if (engine_mode == 'rust' || engine_mode == 'auto') && CombatEngineClient.available?
      return resolve_via_rust_engine!
    end
```

Place this **after** any setup code that must run for both engines (logger creation, `apply_defaults!`, `fight.advance_to_resolution!`) but **before** the Ruby `CombatResolutionService.new(fight).resolve!` call. Grep for where Firefly's `resolve_round!` calls `CombatResolutionService`:

```bash
grep -n "CombatResolutionService" backend/app/services/fight/fight_service.rb
```

Insert the 4-line dispatch block immediately before that call.

Skip the `compare` mode (game repo `:884-890, 922-930`) — it's a dev-time A/B harness; Firefly's parity suite is its equivalent. Keeping it out of Firefly reduces surface area.

- [ ] **Step 4: Copy `resolve_via_rust_engine!` as a private instance method**

From game repo `:1059-1072`, copy verbatim into Firefly's `FightService` under a `private` section:

```ruby
  def resolve_via_rust_engine!
    serializer = Combat::FightStateSerializer.new(fight)
    engine_state = serializer.serialize
    actions = serializer.serialize_actions

    rust_result = CombatEngineClient.new.resolve_round(engine_state, actions)
    apply_rust_result!(rust_result)
  rescue CombatEngineClient::ConnectionError, CombatEngineClient::ProtocolError => e
    warn "[FightService] Rust engine failed, falling back to Ruby: #{e.message}"
    @last_resolution_service = CombatResolutionService.new(fight, logger: @combat_round_logger)
    result = @last_resolution_service.resolve!
    result = { events: result, roll_display: nil, damage_summary: nil, errors: [] } if result.is_a?(Array)
    process_ruby_result(result)
  end
```

**Two caveats:**
- `Combat::FightStateSerializer` is namespaced under the `Combat` module (verified in `backend/app/services/combat/fight_state_serializer.rb:3`). The serializer port in Task 4 should have preserved that `module Combat ... end` wrapping.
- The rescue block calls `process_ruby_result(result)` — a helper in the game-repo `FightService`. Grep for it (`grep -n "def process_ruby_result" $GAME/backend/app/services/fight/fight_service.rb`). Port whatever it does, or inline its body directly into the rescue branch if it's small. Firefly's existing `resolve_round!` post-processing (update `round_events`, `advance_to_narrative!`, etc.) may already cover this — if so, the rescue block should produce the same shape of return value the outer `resolve_round!` expects.

- [ ] **Step 5: Copy `apply_rust_result!` as a private instance method**

From game repo `:1088-1390`, copy verbatim. The method converts Rust's `{next_state, events, knockouts, fight_ended}` hash into Firefly DB updates and the same `{events:, roll_display:, damage_summary:, errors:}` hash shape `resolve_round!` returns.

Walk through the method body — flag any Ruby call that references a method Firefly's `FightParticipant` or `Fight` models don't have (qi-specific writeback, etc.) and comment it with `# TODO(firefly): qi-specific, no-op` rather than deleting. Final cleanup in step 7.

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

Adds combat_engine_mode, rust_engine_active?, resolve_via_rust_engine!,
and apply_rust_result! to Firefly's FightService. Default mode is 'auto':
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

These handlers apply status effects for the three dormant element types. Firefly's status effects are **DB-backed** (rows in the `status_effects` table), not hardcoded in the service. The verification query:

```bash
psql postgres://prom_user:prom_password@localhost/firefly -tc "SELECT name FROM status_effects WHERE name IN ('poisoned', 'intoxicated', 'on_fire', 'burning');"
```

Expected output: `poisoned`, `intoxicated`, and `on_fire` all present (confirmed as of 2026-04-19). `burning` is the game-repo name; Firefly uses `on_fire` — if the handler references `burning`, change it to `on_fire`:

```bash
grep -n "'burning'\|\"burning\"" backend/app/services/battlemap/fight_hex_effect_service.rb
```

Replace `burning` with `on_fire` at every hit. Leave `poisoned` and `intoxicated` references alone — they work as-is in Firefly.

If any other status name appears that Firefly's `status_effects` table doesn't have, stub that specific branch with a no-op comment (`# TODO(firefly): <name> status not yet in status_effects table`) rather than deleting — downstream games can enable the effect by seeding the row.

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

### Task 15: Port placement service and integrate into existing placement call sites

**Spec-vs-source reconciliation:** the spec calls for an "admin UI for CRUD", but the game repo has **no dedicated CRUD admin UI** for `BattleMapElement` (verified by `grep -rln BattleMapElement backend/app/views backend/app/routes` returning empty). In the game repo, elements are placed automatically during map generation by three services: `battle_map_element_placement_service.rb` (procedural), `ai_battle_map_generator_service.rb` (LLM-driven), and interacted with in-fight via `combat_quickmenu_handler.rb`. That's the real upstream — port those, skip building net-new admin UI.

**Files:**
- Create: `$FFW/backend/app/services/battlemap/battle_map_element_placement_service.rb`
- Modify: `$FFW/backend/app/services/battlemap/ai_battle_map_generator_service.rb` (if Firefly has this service; verify first)
- Modify: `$FFW/backend/app/handlers/combat_quickmenu_handler.rb` (if Firefly has this handler; verify)

- [ ] **Step 1: Copy the procedural placement service**

```bash
cp /home/beat6749/game/.worktrees/rust-combat-engine/backend/app/services/battlemap/battle_map_element_placement_service.rb backend/app/services/battlemap/
```

- [ ] **Step 2: Gate the service to active types only**

Near the top of the copied service, grep for where `ELEMENT_TYPES` or per-type cases branch:

```bash
grep -n "ELEMENT_TYPES\|water_barrel\|oil_barrel\|munitions_crate\|vase\|cliff_edge\|toxic_mushrooms\|lotus_pollen" backend/app/services/battlemap/battle_map_element_placement_service.rb
```

Identify any constant or case statement that iterates all types. Introduce or replace with:

```ruby
ACTIVE_TYPES = %w[water_barrel oil_barrel munitions_crate vase].freeze
```

…and have the placement logic iterate `ACTIVE_TYPES` rather than the full `BattleMapElement::ELEMENT_TYPES`. Firefly's procedural generator won't place dormant types; a downstream game can override `ACTIVE_TYPES` or call the service with an explicit type list.

- [ ] **Step 3: Check whether Firefly has the other two integration sites**

```bash
ls backend/app/services/battlemap/ai_battle_map_generator_service.rb 2>&1
ls backend/app/handlers/combat_quickmenu_handler.rb 2>&1
```

- If **both exist** in Firefly: grep each for where the game-repo version calls `BattleMapElement` and port those integration points (likely a call to `BattleMapElementPlacementService.new(battle_map).place_random!` during generation, and element-interaction branches in the quickmenu handler).
- If **neither exists**: Firefly generates maps without this surface today. Skip those edits for this task; add a TODO comment in `battle_map_element_placement_service.rb` noting that nothing calls it yet in Firefly, and wiring is a downstream concern. The service itself is already useful as a building block.
- If **one exists but not the other**: port only that one.

- [ ] **Step 4: Syntax check**

```bash
cd backend && bundle exec ruby -c app/services/battlemap/battle_map_element_placement_service.rb
```

- [ ] **Step 5: Commit**

```bash
git add backend/app/services/battlemap/battle_map_element_placement_service.rb
git add backend/app/services/battlemap/ai_battle_map_generator_service.rb 2>/dev/null || true
git add backend/app/handlers/combat_quickmenu_handler.rb 2>/dev/null || true
git commit -m "$(cat <<'EOF'
feat(battlemap): port BattleMapElementPlacementService with active-type gate

Procedural element placement gated to the 4 active types
(water_barrel, oil_barrel, munitions_crate, vase). The dormant 3
(cliff_edge, toxic_mushrooms, lotus_pollen) stay valid model inputs
so a downstream game can opt in by overriding ACTIVE_TYPES or calling
the placer with an explicit type list.

Integration into map-generation and quickmenu-handler is wired in
where the corresponding Firefly services exist; left as TODO where
they don't (no admin UI in upstream game repo either).
EOF
)"
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
- ✅ All 7 ELEMENT_TYPES remain valid model inputs; placement service gates to 4 active types

- [ ] **Step 3: Memory update for future sessions**

Append to `/home/beat6749/.claude/projects/-home-beat6749-game/memory/project_rust_combat_engine.md` (or create a new `project_firefly_rust_combat_port.md`): a brief note that Firefly has the Rust combat engine ported on branch `rust-combat-engine`, with willpower dice, aggressive/defensive/quick tactics, and the 7-type interactive element system (with 3 types dormant in Firefly for downstream adopters).

---

## Rollback plan

If anything goes badly wrong in a phase:

- Phase 1 (game repo): `git revert` the rename commit. The rename is mechanical and fully reversible.
- Phase 2 (Firefly): `COMBAT_ENGINE=ruby` or `GameSetting use_rust_combat_engine=false` reverts every Firefly fight to the Ruby path without changing code. If the bridge itself is broken (syntax error, import failure), `git revert` the problem commit — earlier phases stand on their own.
- Phase 3 (Firefly): element tables have no FK'd consumers yet, so rollback is `bundle exec sequel -m db/migrations -M 25 ...` to undo the two migrations and `git revert` the code commits.

## Risks and open questions

- **Firefly status-effect vocabulary** (Task 14): Firefly's `status_effects` table has `poisoned`, `intoxicated`, and `on_fire`. The main known gap vs. game repo is `burning` → `on_fire`; Task 14 Step 2 handles it with a targeted grep+rename. Any other game-repo status name the handler references that's absent in Firefly gets a stub with a TODO comment rather than being deleted.
- **Placement integration call sites** (Task 15): if Firefly has neither `ai_battle_map_generator_service.rb` nor `combat_quickmenu_handler.rb`, the ported `BattleMapElementPlacementService` will be dead code until a downstream game wires it in. That's acceptable — the service and model are still usable building blocks. Task 15 Step 3 surfaces the gap with explicit conditional checks.
- **`CombatResolutionService` drift** between game repo and Firefly: Firefly's `CombatResolutionService` is 3301 lines vs. the game repo's 3848. Some methods that exist in the game-repo's writeback helpers may call into game-repo-only resolution code. Flag this early — if `apply_rust_result!` references a method Firefly doesn't have, either port the method or stub it.
- **Vendored Rust copy drift from upstream**: as the game repo's `combat-engine/` evolves, Firefly's vendored copy will need periodic refresh. Out of scope for this plan; future refresh is a separate task (`git diff` the source dir and apply cleanly, or re-vendor wholesale).
