# Greeting Plugin

A complete example plugin demonstrating all Firefly plugin features.

Use this as a template when creating new plugins.

## Features Demonstrated

- **Commands**: The `greet` command with aliases and requirements
- **Plugin Metadata**: Name, version, description, dependencies
- **Event Handlers**: Responding to game events
- **Model Extensions**: Adding methods to core models (commented example)
- **Plugin Helpers**: Shared methods for commands to use
- **Testing**: Complete RSpec test suite

## Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `greet` | `wave` `hello` `hi` | Greet another character or everyone in the room |

## Usage

### Greet a specific character
```
greet John
wave Maria
hello Alice
```

### Greet everyone
```
greet everyone
greet all
greet
```

## Events

### Events this plugin listens to:
- `character_enters_room` - Could auto-greet arrivals
- `character_logged_in` - Could send welcome message

### Events this plugin emits:
- `greeting_performed` - Emitted when a greeting occurs

## Configuration

No configuration required.

## Directory Structure

```
greeting/
├── plugin.rb              # Plugin definition and metadata
├── commands/
│   └── greet.rb          # Greet command implementation
├── models/
│   └── (empty)           # Model extensions would go here
├── spec/
│   └── commands/
│       └── greet_spec.rb # Command tests
└── README.md             # This file
```

## Creating Your Own Plugin

1. Copy this plugin as a starting point:
   ```bash
   cp -r plugins/examples/greeting plugins/optional/my_plugin
   ```

2. Or use the generator:
   ```bash
   bin/firefly generate plugin my_plugin
   bin/firefly generate command my_plugin my_command
   ```

3. Update `plugin.rb`:
   - Change `name`, `version`, `description`
   - Add dependencies if needed
   - Implement lifecycle hooks

4. Add commands in `commands/` directory

5. Add tests in `spec/` directory

6. Run tests:
   ```bash
   bundle exec rspec plugins/optional/my_plugin/spec/
   ```

## Plugin API Reference

### Metadata DSL

```ruby
class Plugin < Firefly::Plugin
  name :my_plugin           # Plugin identifier (symbol)
  version "1.0.0"           # Semantic version
  description "What it does"

  depends_on :other_plugin  # Dependencies (loaded first)

  commands_path "commands"  # Relative path to commands
  models_path "models"      # Relative path to model extensions
end
```

### Lifecycle Hooks

```ruby
def self.on_enable
  # Called when plugin is loaded
end

def self.on_disable
  # Called when plugin is unloaded
end

def self.on_reload
  # Called on hot-reload (development)
end
```

### Event Handlers

```ruby
on_event :event_name do |arg1, arg2|
  # Handle the event
end
```

### Model Extensions

```ruby
module MyExtensions
  def custom_method
    # Added to target model
  end
end

extend_model Character, MyExtensions
```

## Dependencies

None - this is a standalone example plugin.
