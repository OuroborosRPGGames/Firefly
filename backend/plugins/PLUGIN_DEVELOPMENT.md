# Plugin Development Guide

This guide covers everything you need to know about creating plugins for the Firefly MUD engine.

## Table of Contents

1. [Plugin Architecture](#plugin-architecture)
2. [Creating a Plugin](#creating-a-plugin)
3. [Command DSL Reference](#command-dsl-reference)
4. [Model Extensions](#model-extensions)
5. [Event Handlers](#event-handlers)
6. [Testing Plugins](#testing-plugins)
7. [Best Practices](#best-practices)

## Plugin Architecture

Plugins are self-contained modules that add functionality to Firefly. Each plugin can provide:

- **Commands** - Player-executable actions (`say`, `look`, `attack`)
- **Model Extensions** - Add methods to core models like Character or Room
- **Event Handlers** - React to game events (player login, room entry, combat)
- **Routes** - Custom HTTP endpoints

### Plugin Directory Structure

```
plugins/
├── core/                          # Core game plugins
│   ├── communication/             # say, emote, whisper
│   │   ├── commands/
│   │   │   ├── say.rb
│   │   │   └── emote.rb
│   │   └── plugin.rb
│   ├── navigation/                # look, move, exits
│   └── combat/                    # attack, defend, flee
├── examples/                      # Example/template plugins
│   └── greeting/                  # Simple greeting example
└── optional/                      # Optional features
```

### Auto-Discovery

When the server starts, it automatically:
1. Scans plugin directories for `plugin.rb` files
2. Loads plugins in dependency order
3. Discovers and registers commands from each plugin's `commands/` directory
4. Applies model extensions
5. Registers event handlers

## Creating a Plugin

### Step 1: Create Directory Structure

```bash
mkdir -p plugins/myplugin/commands
mkdir -p plugins/myplugin/models
mkdir -p plugins/myplugin/spec/commands
```

### Step 2: Create plugin.rb

```ruby
# plugins/myplugin/plugin.rb
# frozen_string_literal: true

require_relative '../../lib/firefly/plugin'

module Plugins
  module MyPlugin
    class Plugin < Firefly::Plugin
      # Required metadata
      name :myplugin
      version "1.0.0"
      description "A brief description of what this plugin does"

      # Optional: Declare dependencies (load order)
      depends_on :communication, :navigation

      # Optional: Configure auto-discovery paths (defaults shown)
      commands_path "commands"
      models_path "models"

      # Lifecycle hooks
      def self.on_enable
        puts "[MyPlugin] Enabled"
      end

      def self.on_disable
        puts "[MyPlugin] Disabled"
      end

      def self.on_reload
        puts "[MyPlugin] Reloaded"
        super  # Calls on_disable then on_enable
      end
    end
  end
end
```

### Step 3: Create Commands

Commands are the core of player interaction. Each command:
- Lives in its own file
- Inherits from `Commands::Base::Command`
- Registers itself with the command registry

```ruby
# plugins/myplugin/commands/mycommand.rb
# frozen_string_literal: true

module Commands
  module MyPlugin
    class MyCommand < Commands::Base::Command
      # === METADATA DSL ===

      command_name 'mycommand'        # Primary command name
      aliases 'mc', 'myc'             # Alternative names
      category :utility               # For help organization
      help_text 'Description shown in help'
      usage 'mycommand <target> [options]'
      examples 'mycommand foo', 'mycommand bar --verbose'

      # === REQUIREMENTS DSL ===

      # Character state requirements
      requires_alive                  # Character must be alive
      requires_conscious              # Not unconscious
      requires_standing               # Must be standing

      # Context requirements
      requires_combat                 # Must be in combat
      requires_room_type :water       # Must be in water room

      # Resource requirements
      requires_mana 10                # Needs 10+ mana
      requires_stamina 5              # Needs 5+ stamina

      # Custom requirements
      requires -> (cmd) {
        cmd.character.level >= 5
      }, message: "You must be level 5 or higher."

      protected

      # === MAIN IMPLEMENTATION ===

      def perform_command(parsed_input)
        # parsed_input contains:
        #   :command_word  - First word of input
        #   :args          - Array of remaining words
        #   :text          - Args joined as string
        #   :full_input    - Original complete input

        target = parsed_input[:text]

        if target.nil? || target.empty?
          return error_result("What would you like to target?")
        end

        # Do something with target...

        # Return success with dual-mode output
        success_result(
          "You did something to #{target}.",  # Human-readable message
          type: :action,                       # Structured type for agents
          data: {                              # Structured data for agents
            action: 'mycommand',
            target: target,
            success: true
          }
        )
      end
    end
  end
end

# IMPORTANT: Register the command
Commands::Base::Registry.register(Commands::MyPlugin::MyCommand)
```

## Command DSL Reference

### Metadata Methods

| Method | Description | Example |
|--------|-------------|---------|
| `command_name` | Primary command word | `command_name 'attack'` |
| `aliases` | Alternative names | `aliases 'att', 'a'` |
| `category` | Help category | `category :combat` |
| `help_text` | Short description | `help_text 'Attack a target'` |
| `usage` | Usage pattern | `usage 'attack <target>'` |
| `examples` | Usage examples | `examples 'attack goblin', 'attack 2'` |

### Context-Specific Aliases

Aliases can be context-dependent:

```ruby
# 'a' only works as 'attack' during combat
aliases { name: 'a', context: :combat }

# 'sw' always works for 'swim'
aliases 'sw'
```

### Requirement Methods

| Method | Condition | Default Message |
|--------|-----------|-----------------|
| `requires_alive` | Status not 'dead' | "You can't do that while dead." |
| `requires_conscious` | Status not 'unconscious' | "You can't do that while unconscious." |
| `requires_standing` | Position is 'standing' | "You need to be standing to do that." |
| `requires_combat` | In combat state | "You must be in combat to do that." |
| `requires_room_type(*types)` | Room type matches | "You can't do that here." |
| `requires_mana(n)` | Has n+ mana | "You don't have enough mana." |
| `requires_stamina(n)` | Has n+ stamina | "You're too exhausted." |
| `requires_weapon_equipped` | Has weapon | "You need a weapon equipped." |

### Custom Requirements

```ruby
# Lambda with custom message
requires -> (cmd) {
  cmd.character_instance.gold >= 100
}, message: "You need at least 100 gold."

# Check room flags
requires :room_flag, :safe, message: "This can only be done in safe areas."
requires :not_room_flag, :underwater

# Check character has item
requires :has_item, 'key'

# Check skill
requires :has_skill, :lockpicking
```

### Result Helpers

```ruby
# Success with message only
success_result("You did it!")

# Success with structured data for agents
success_result(
  "You moved north.",
  type: :movement,
  data: { direction: 'north', room_id: 123 }
)

# Error
error_result("You can't do that.")

# Room description (common pattern)
room_result(
  name: room.name,
  description: room.description,
  exits: room.exits.map(&:direction),
  characters: characters_here
)

# Message (say, emote, whisper)
message_result('say', character.name, "Hello world")
```

### Available Instance Variables

Inside `perform_command`:

| Variable | Type | Description |
|----------|------|-------------|
| `character_instance` | CharacterInstance | Current character's game instance |
| `character` | Character | The character record |
| `location` | Room | Current room |
| `request_env` | Hash | HTTP request environment (for agent detection) |

### Helper Methods

| Method | Description |
|--------|-------------|
| `find_character_by_name(name)` | Find character in room |
| `broadcast_to_room(msg)` | Send to all in room |
| `send_to_character(char, msg)` | Send to specific character |
| `log_roleplay(msg)` | Add to RP log |
| `process_punctuation(text)` | Add period if missing |
| `extract_adverb(text)` | Extract -ly adverb from text |
| `agent_mode?` | Check if request from LLM agent |

## Shared Helpers and Concerns

Use the correct location based on scope:

| Scope | Location | Module style | Include style |
|-------|----------|-------------|---------------|
| **Cross-plugin** (used by 2+ plugins or app-wide) | `app/helpers/foo_helper.rb` | Bare: `module FooHelper` | `include FooHelper` |
| **Plugin-local** (used only within one plugin's commands) | `plugins/core/<domain>/concerns/foo_concern.rb` | Nested: `module Commands::<Domain>::FooConcern` | `include Commands::<Domain>::FooConcern` |

**Examples:**
- `app/helpers/message_persistence_helper.rb` → `MessagePersistenceHelper` (used by say, emote, msg, etc.)
- `plugins/core/clothing/concerns/clothing_command_helper.rb` → `Commands::Clothing::ClothingCommandHelper` (only clothing commands)
- `plugins/core/communication/concerns/multi_target_helper.rb` → `Commands::Communication::MultiTargetHelper` (msg, ooc only)

**Do not:**
- Put plugin-local helpers in `app/helpers/` (pollutes the shared namespace)
- Create a 4th location like `plugins/core/<domain>/commands/concerns/` (use `concerns/` at domain level)
- Use bare module names for plugin-local concerns (makes origin ambiguous when grepping)

**Existing legacy violations (migrate when touching):**
- `plugins/core/combat/concerns/` — uses bare `module CombatInitiationConcern` (no `Commands::Combat::` wrapper)
- `plugins/core/consumption/concerns/` — same bare-name pattern
- `plugins/core/economy/concerns/` — same bare-name pattern
- `plugins/core/vehicles/commands/concerns/` — placed inside `commands/` subdirectory with an extra `Concerns::` nesting

When editing these files, move them to Pattern A (plugin-root `concerns/` + `module Commands::<Domain>::FooConcern`).

## Model Extensions

Plugins can add methods to core models:

```ruby
# plugins/myplugin/models/character_extensions.rb
module Plugins
  module MyPlugin
    module CharacterExtensions
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def find_by_nickname(nickname)
          where(Sequel.ilike(:nickname, "%#{nickname}%")).first
        end
      end

      # Instance methods
      def full_title
        "#{rank} #{full_name}"
      end

      def can_use_feature?
        level >= 10
      end
    end
  end
end
```

Register in plugin.rb:

```ruby
class Plugin < Firefly::Plugin
  extend_model Character, CharacterExtensions
end
```

## Event Handlers

React to game events:

```ruby
class Plugin < Firefly::Plugin
  # Character enters a room
  on_event :character_enters_room do |character_instance, room|
    if room.room_type == 'shop'
      # Send welcome message
    end
  end

  # Character logs in
  on_event :character_logged_in do |character_instance|
    # Welcome back message, check mail, etc.
  end

  # Character dies
  on_event :character_died do |character_instance, killer|
    # Handle death effects
  end

  # Combat started
  on_event :combat_started do |combatants|
    # Initialize combat state
  end

  # Custom events from other plugins
  on_event :item_crafted do |character, item|
    # React to crafting
  end
end
```

### Emitting Custom Events

```ruby
# In your command or model
Firefly::EventBus.emit(:my_custom_event, arg1, arg2)
```

## Testing Plugins

### Directory Structure

```
plugins/myplugin/
├── commands/
│   └── mycommand.rb
├── spec/
│   └── commands/
│       └── mycommand_spec.rb
└── plugin.rb
```

### Writing Command Tests

```ruby
# plugins/myplugin/spec/commands/mycommand_spec.rb
require 'spec_helper'

RSpec.describe Commands::MyPlugin::MyCommand do
  # Setup test fixtures
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           status: 'alive',
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  describe '#execute' do
    context 'with valid input' do
      it 'succeeds' do
        result = command.execute('mycommand target')

        expect(result[:success]).to be true
        expect(result[:message]).to include('target')
      end

      it 'returns structured data' do
        result = command.execute('mycommand target')

        expect(result[:type]).to eq(:action)
        expect(result[:data][:target]).to eq('target')
      end
    end

    context 'with missing target' do
      it 'returns error' do
        result = command.execute('mycommand')

        expect(result[:success]).to be false
        expect(result[:error]).to include('target')
      end
    end

    context 'when dead' do
      before { character_instance.update(status: 'dead') }

      it 'fails with requires_alive' do
        result = command.execute('mycommand target')

        expect(result[:success]).to be false
        expect(result[:error]).to include('dead')
      end
    end
  end

  describe '.metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('mycommand')
    end

    it 'has help text' do
      expect(described_class.help_text).to be_present
    end
  end
end
```

### Running Tests

```bash
# Run plugin tests only
bundle exec rspec plugins/myplugin/spec/

# Run with coverage
COVERAGE=true bundle exec rspec plugins/myplugin/spec/

# Run specific test file
bundle exec rspec plugins/myplugin/spec/commands/mycommand_spec.rb
```

### MCP Agent Testing

Test with AI agents using the MCP server:

```python
# Using MCP tools
mcp__firefly-test__execute_command(command: "mycommand target")

# Multi-agent testing
mcp__firefly-test__test_feature(
    objective="Test mycommand with various targets and edge cases",
    agent_count=2,
    max_steps_per_agent=10
)
```

## Best Practices

### 1. Keep Commands Focused

Each command should do one thing well:

```ruby
# Good: Separate commands
class Attack < Commands::Base::Command; end
class Defend < Commands::Base::Command; end
class Flee < Commands::Base::Command; end

# Avoid: Multi-purpose command
class Combat < Commands::Base::Command
  def perform_command(parsed_input)
    case parsed_input[:args].first
    when 'attack' then ...
    when 'defend' then ...
    end
  end
end
```

### 2. Use Structured Output

Always include structured data for agent consumption:

```ruby
# Good
success_result(
  "You picked up the sword.",
  type: :inventory,
  data: { action: 'get', item: 'sword', item_id: 123 }
)

# Avoid
success_result("You picked up the sword.")
```

### 3. Handle Edge Cases

```ruby
def perform_command(parsed_input)
  target_name = parsed_input[:text]&.strip

  # Empty input
  return error_result("Attack who?") if target_name.blank?

  # Target not found
  target = find_character_by_name(target_name)
  return error_result("You don't see #{target_name} here.") unless target

  # Can't target self
  return error_result("You can't attack yourself.") if target.id == character.id

  # Proceed with command...
end
```

### 4. Use Requirements DSL

Prefer declarative requirements over manual checks:

```ruby
# Good: Declarative
requires_alive
requires_standing
requires :room_type, :combat

# Avoid: Manual checks
def perform_command(parsed_input)
  return error_result("Dead") if character_instance.status == 'dead'
  return error_result("Sit") if character_instance.position != 'standing'
  # ...
end
```

### 5. Test Requirements

Always test that requirements block execution appropriately:

```ruby
context 'when not in combat room' do
  let(:room) { create(:room, room_type: 'safe') }

  it 'fails due to room type requirement' do
    result = command.execute('combat_command')
    expect(result[:success]).to be false
  end
end
```

### 6. Document Your Plugin

Create a README.md for your plugin:

```markdown
# MyPlugin

Brief description of what this plugin does.

## Commands

### mycommand

Usage: `mycommand <target>`

Description of the command.

**Examples:**
- `mycommand foo` - Does foo
- `mycommand bar` - Does bar

## Events

This plugin emits/handles these events:

- `my_event` - Fired when X happens
- `other_event` - Handled to do Y

## Configuration

Any configuration options.
```

### 7. Follow Naming Conventions

- Plugin module: `Plugins::MyPlugin`
- Plugin class: `Plugins::MyPlugin::Plugin`
- Commands: `Commands::MyPlugin::CommandName`
- Lowercase file names matching class: `my_command.rb`

### 8. Use Canonical Permission Guards

Use the correct guard pattern based on what you're protecting:

| Use case | Canonical guard |
|----------|----------------|
| Generic building/creation permission | `require_building_permission(error_message: "...")` |
| City-specific building (build_city, build_apartment) | `CityBuilderService.can_build?(character, :action_name)` |
| Staff/admin only | `require_staff` or `return error_result(...) unless character.user.admin?` |
| Custom permission strings | `character.user.can_manage_npcs?` (named predicate, not raw `has_permission?('string')`) |

```ruby
# Good: use the DSL helper
def perform_command(_parsed_input)
  error = require_building_permission(error_message: "You must be in creator mode to build.")
  return error if error
  # ...
end

# Good: city builder checks a specific capability
error = CityBuilderService.can_build?(character, :build_city)
return error_result(error) if error

# Avoid: raw string permission check inline
return error_result("No") unless user.has_permission?('can_build') || user.admin?
```

## Example: Complete Plugin

See `plugins/examples/greeting/` for a complete, well-documented example plugin that demonstrates all features.

## Troubleshooting

### Command Not Found

1. Check file is in correct location: `plugins/yourplugin/commands/`
2. Verify registration: `Commands::Base::Registry.register(YourCommand)`
3. Restart server to reload plugins

### Dependencies Not Satisfied

```
[Plugin] Cannot load myplugin: missing dependencies [:core]
```

Ensure dependent plugins exist and are spelled correctly in `depends_on`.

### Model Extension Not Applied

1. Check `extend_model` is called in plugin class
2. Verify extension module exists and is required
3. Check for require errors in plugin loading

### Tests Failing with "Factory Not Found"

Ensure factories exist in `spec/factories/` for all models you use.
