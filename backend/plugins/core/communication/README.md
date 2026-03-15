# Communication Plugin

Core plugin providing character communication commands.

## Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `say` | `"` `'` | Speak to everyone in the room |
| `emote` | `pose` `act` `:` | Perform an action visible to the room |

## Usage

### Say
```
say Hello everyone!
"Hello everyone!
```

Output: `<Name> says, 'Hello everyone!'`

### Emote
```
emote waves hello
:waves hello
```

Output: `<Name> waves hello`

## Events

This plugin emits the following events:

- `character_says` - When a character speaks
- `character_emotes` - When a character performs an emote

## Configuration

No configuration required. This is a core plugin loaded automatically.

## Dependencies

None - this is a foundational plugin.
