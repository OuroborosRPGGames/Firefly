# FIREFLY MUD ENGINE

A modern text-based RPG combining MUD mechanics with web interfaces and AI integration.

**Tech Stack: Roda + Sequel + PostgreSQL** (NOT Rails)

## Quick Start

```bash
cd backend && bin/dev    # starts puma + tailwind --watch
```
Login at `http://localhost:3000`. For puma only (no CSS rebuild): `bundle exec puma -p 3000`.

---

## CRITICAL PATTERNS

These patterns have caused repeated bugs. Follow them exactly.

### 1. Command Registration (REQUIRED)

Every command file MUST end with this line or the command **silently fails**:
```ruby
Commands::Base::Registry.register(Commands::<Plugin>::<Command>)
```

Registration must be **outside** all modules, at the bottom of the file. Wrong module paths (e.g., `Commands::Core::Social::Wave` instead of `Commands::Social::Wave`) also cause silent failure.

```ruby
module Commands
  module Social
    class Wave < Commands::Base::Command
      command_name 'wave'
      # ...
    end
  end
end

# MUST be last line, outside modules
Commands::Base::Registry.register(Commands::Social::Wave)
```

### 2. Roda Routing (REQUIRED)

Use `r.is` to wrap HTTP verbs when you have sub-routes, or child routes get blocked. Roda matches sequentially -- a bare `r.post` after `r.on Integer` catches `/id/anything`, blocking sub-routes.

```ruby
# WRONG - r.on 'stats' is unreachable
r.on Integer do |id|
  r.post do ... end
  r.on 'stats' do ... end  # Never reached!
end

# CORRECT - r.is limits match to exact path
r.on Integer do |id|
  r.is do
    r.post { ... }
  end
  r.on 'stats' do ... end  # Works!
end
```

| Scenario | Use |
|----------|-----|
| Leaf route (no children) | Bare HTTP verb |
| Parent with HTTP handlers + children | `r.is { r.post { ... } }` |
| Parent with only children | Just `r.on` |

### 3. JSONB in Migrations (REQUIRED)

Migrations run without the `pg_json` extension. Use `Sequel.lit()` for schema defaults, `Sequel.pg_json_wrap()` in app code.

```ruby
# MIGRATION - use Sequel.lit()
column :data, :jsonb, default: Sequel.lit("'{}'::jsonb")

# APP CODE - use pg_json_wrap()
item.update(properties: Sequel.pg_json_wrap({ key: 'value' }))

# WRONG - crashes in migrations (pg_json not loaded)
column :data, :jsonb, default: Sequel.pg_json_wrap({})
```

**Sequel JSONB dirty-tracking gotcha:** Modifying a JSONB hash in-place then calling `update()` is a no-op (Sequel sees same reference). Always deep-dup first:
```ruby
state = JSON.parse(record.world_state.to_json)
state['key'] = 'new_value'
record.update(world_state: Sequel.pg_jsonb_wrap(state))
```

### 4. No Rails Methods (REQUIRED)

This is Roda + Sequel, NOT Rails:
```ruby
# WRONG              # CORRECT
value.present?      # !value.nil? && !value.to_s.strip.empty?
value.blank?        # value.nil? || value.to_s.strip.empty?
Time.current        # Time.now
1.hour.ago          # Time.now - 3600
Rails.logger.error  # warn "[ServiceName] Error: #{e.message}"
```

### 5. Error Handling (REQUIRED)

Always log errors with context. Never swallow exceptions silently:
```ruby
rescue StandardError => e
  warn "[ServiceName] Action failed: #{e.message}"
  nil
end
```

---

## Check Existing Helpers

Before writing new code, check:
- **[docs/HELPERS.md](backend/docs/HELPERS.md)** - Services, handlers, utilities
- **[config/game_config.rb](backend/config/game_config.rb)** - Combat thresholds, AI weights, balance values
- **[config/prompts.yml](backend/config/prompts.yml)** - All LLM prompts

## LLM Prompts

All prompts centralized in `config/prompts.yml`. Never hardcode prompt strings.

```ruby
prompt = GamePrompts.get('combat.prose_enhancement', paragraph: text)
prompt = GamePrompts.get('npc_generation.personality', name: 'Bob', role: 'guard')
GamePrompts.get_safe('path', ...)    # Returns nil instead of raising
GamePrompts.exists?('path.to.prompt')
```

**Categories:** `abuse_detection`, `combat`, `triggers`, `npc_generation`, `room_generation`, `missions`, `auto_gm`, `activities`, `ability_generation`, `reputation`, `memory`

## API/Webclient Parity

Commands must include structured data. The webclient checks for `type`/`data` fields to select client-side renderers:

```ruby
# CORRECT
success_result(message, type: :room, data: room_data)

# WRONG - strips structured data, causes rendering divergence
response_data = { success: true, message: result[:message] }
```

**Required exit fields:** `direction`, `to_room_name`, `distance`, `direction_arrow`

---

## Command DSL

```ruby
# frozen_string_literal: true

module Commands
  module Social
    class Wave < Commands::Base::Command
      command_name 'wave'
      aliases 'wav'
      category :social
      help_text 'Wave at someone'
      usage 'wave [target]'
      examples 'wave', 'wave Bob'

      def execute(args, context)
        # Implementation
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Social::Wave)
```

Generate new commands: `bundle exec ruby scripts/generate_command.rb core/social wave`

## Project Structure

**This is NOT a Rails app.** Uses Roda (routing), Sequel (ORM), ERB (views).

```
/backend              - Main codebase
  /app.rb             - Main Roda application
  /app/commands       - Game commands (one per file)
  /app/models         - Sequel ORM models (NOT ActiveRecord)
  /app/services       - Business logic services
  /app/routes         - Roda route handlers
  /plugins            - Plugin system with auto-discovery
  /spec               - RSpec tests
```

| Doc | Purpose |
|-----|---------|
| [docs/MODEL_MAP.md](backend/docs/MODEL_MAP.md) | Model naming guide |
| [docs/HELPERS.md](backend/docs/HELPERS.md) | Reusable helpers |
| [docs/API.md](backend/docs/API.md) | REST API reference |

---

## Combat System

Uses a **damage threshold system**, NOT direct HP damage.

| Raw Damage | HP Lost |
|------------|---------|
| 0-9 | 0 (miss) |
| 10-17 | 1 HP |
| 18-29 | 2 HP |
| 30-99 | 3 HP |
| 100-199 | 4 HP |
| 200-299 | 5 HP |
| 300+ | 6+ HP (100 bands) |

**Wound penalty** shifts all thresholds down by 1 per HP lost. At 4/6 HP (penalty=2): miss threshold drops to 7, so 8 damage now deals 1 HP.

```ruby
# WRONG - Don't subtract damage directly
participant.current_hp -= damage

# CORRECT - Use the threshold system
hp_lost = participant.take_damage(damage)
```

**Key files:** `config/game_config.rb` (DAMAGE_THRESHOLDS), `app/models/fight_participant.rb` (damage_thresholds, take_damage, wound_penalty), `app/services/combat/combat_round_logger.rb`

---

## Hex Systems (Two Scales)

| System | Scale | Model | Library | Purpose |
|--------|-------|-------|---------|---------|
| **World** | ~3 miles/hex | `WorldHex` | `WorldHexGrid` | Terrain, overland travel |
| **Room/Combat** | 4 feet/hex | `RoomHex` | `HexGrid` | Battle maps, tactical combat |

Both use **offset coordinates** from `HexGrid`: Y must be even (0,2,4...), X parity alternates by row.

**Key files:** `app/lib/hex_grid.rb`, `app/lib/world_hex_grid.rb`, `app/models/world_hex.rb`, `app/models/room_hex.rb`, `app/services/hex_pathfinding_service.rb`

---

## Spatial Navigation

Rooms connect based on **polygon adjacency**, NOT manual exit records. If two rooms share an edge, players can move between them (if passable).

| Service | Purpose |
|---------|---------|
| `RoomAdjacencyService.adjacent_rooms(room)` | `{ north: [rooms], ... }` |
| `RoomAdjacencyService.resolve_direction_movement(room, :north)` | Destination room or nil |
| `RoomPassabilityService.can_pass?(from, to, direction)` | Check passage allowed |

**Passage rules:** No wall = always passable. Wall = blocked unless opening. Door/Gate = only if `is_open: true`. Archway/Opening = always passable. Outdoor rooms = always passable to each other.

---

## Message Personalization

**Two-stage architecture:** Services generate text using `full_name`. The personalization pipeline substitutes viewer-appropriate names on broadcast.

```ruby
# CORRECT - use full_name, personalization handles the rest
broadcast_to_room("#{character.full_name} waves at #{target.full_name}.")

# WRONG - display_name_for is viewer-specific, don't use in generated text
narrative = "#{character.display_name_for(some_viewer)} attacks."
```

For one specific viewer (private message): use `display_name_for(viewer)`.

---

## Database

```
postgres://prom_user:prom_password@localhost/firefly
```

## Frontend Stack

**DaisyUI 4.12.14 + Tailwind CSS v4**. No Node.js -- uses Tailwind standalone CLI. CSS is compiled locally, **NOT loaded from CDN**.

```bash
# Rebuild after changing Tailwind classes (or use bin/dev for --watch)
bin/tailwindcss -i app/assets/css/input.css -o public/css/tailwind.css --minify
```

| File | Purpose |
|------|---------|
| `app/assets/css/input.css` | Source + theme config (Tailwind v4 CSS-first) |
| `public/css/tailwind.css` | Compiled output (committed) |
| `public/css/daisyui.css` | Vendored DaisyUI 4.12.14 (committed) |

Also available: Bootstrap Icons (`bi-*` classes), Animate.css. Uses Tailwind 12-column grid (not Bootstrap).

---

## MCP Testing

Key tools for verifying changes:

| Tool | Purpose |
|------|---------|
| `mcp__firefly-test__execute_command` | Run game commands |
| `mcp__firefly-test__get_room_state` | Check room/character state |
| `mcp__firefly-test__test_feature` | Multi-agent autonomous testing |
| `mcp__firefly-test__test_commands` | Command regression testing with baselines |

```
test_commands()                        # All commands vs baselines
test_commands(commands="look,score")   # Specific commands
test_commands(setup_group="combat")    # By group: neutral/social/combat/delve/economy
test_commands(failures_only=True)      # Only non-passing results
```

**Setup:** Start server (`cd backend && bundle exec puma -p 3000`), create test agent (`bundle exec ruby scripts/create_test_agent.rb`), add token to `.env` as `FIREFLY_API_TOKEN`.
