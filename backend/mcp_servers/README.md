# Firefly MCP Test Server

MCP server for testing the Firefly MUD game, including autonomous multi-agent testing with Claude.

## Setup

### 1. Start the game server

```bash
cd backend
bundle exec puma -p 3000
```

### 2. Create test agent and get API token

```bash
cd backend
bundle exec ruby scripts/create_test_agent.rb
```

This creates a test user/character and outputs an API token. Copy the token.

### 3. Install Python dependencies

```bash
cd backend/mcp_servers
pip install -r requirements.txt
```

### 4. Configure Claude Code

Edit `.mcp.json` in the project root (use absolute path):

```json
{
  "mcpServers": {
    "firefly-test": {
      "command": "python3",
      "args": ["/absolute/path/to/firefly/backend/mcp_servers/firefly_test_server.py"],
      "env": {
        "FIREFLY_BASE_URL": "http://localhost:3000",
        "FIREFLY_API_TOKEN": "your-token-here"
      }
    }
  }
}
```

### 5. Add Anthropic API key for multi-agent testing

Claude Code filters API keys from env vars for security, so store it in a file:

```bash
echo "sk-ant-api03-your-key-here" > backend/mcp_servers/.agent_key
```

The `.agent_key` file is gitignored.

### 6. Restart Claude Code

```bash
/exit
claude
```

Verify with `/mcp` - you should see `firefly-test` connected.

## Tools

### execute_command

Execute a game command and get structured results.

```
execute_command(command: "look")
execute_command(command: "north")
execute_command(command: "say Hello world")
```

Returns:
- `success`: boolean
- `command`: the command that was executed
- `type`: "room", "message", "error", or "status"
- `output`: human-readable description
- `structured`: parsed data (room info, exits, etc.)

### get_room_state

Get current room state with characters, objects, and exits.

```
get_room_state()
```

Returns:
- `room`: {id, name, description, room_type}
- `characters`: [{id, character_id, name, short_desc}]
- `objects`: list of objects in room
- `exits`: [{id, direction, display_name, locked}]

### get_character_status

Get current character's health, location, and state.

```
get_character_status()
```

### list_available_commands

Get all commands available to the current character.

```
list_available_commands()
```

### test_feature (Multi-Agent Testing)

Run autonomous multi-agent testing. Agents use Claude to decide what commands to execute based on your objective.

```
test_feature(
    objective: "Explore the game world and test navigation",
    agent_count: 2,
    max_steps_per_agent: 10,
    timeout_seconds: 60,
    model: "haiku"
)
```

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `objective` | required | What to test - be specific |
| `agent_count` | 2 | Number of agents (1-5) |
| `max_steps_per_agent` | 30 | Max commands per agent |
| `timeout_seconds` | 120 | Overall timeout |
| `model` | "haiku" | `"haiku"` (fast) or `"opus"` (thorough) |

**Returns:**
- `test_id`: Unique test identifier
- `duration_seconds`: How long the test took
- `total_commands`: Commands executed across all agents
- `errors`: List of errors encountered
- `agent_logs`: Detailed log of each agent's actions and reasoning

**Example Objectives:**

Quick exploration:
```
test_feature(objective: "Look around and explore nearby rooms", agent_count: 1, max_steps_per_agent: 5)
```

Thorough testing with Opus:
```
test_feature(
    objective: "Thoroughly test the movement system. Try all cardinal directions, test invalid exits, document error messages",
    agent_count: 1,
    max_steps_per_agent: 20,
    model: "opus"
)
```

Multi-agent interaction:
```
test_feature(
    objective: "Have agents meet in the town square and interact using say and emote commands",
    agent_count: 3,
    max_steps_per_agent: 15
)
```

Edge case testing:
```
test_feature(
    objective: "Test combat edge cases: attack self, attack non-existent targets, attack while dead",
    agent_count: 1,
    max_steps_per_agent: 10,
    model: "opus"
)
```

### debug_env

Debug tool to verify environment configuration.

```
debug_env()
```

Returns which config values are set (without exposing secrets).

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `FIREFLY_BASE_URL` | No | Game server URL (default: `http://localhost:3000`) |
| `FIREFLY_API_TOKEN` | Yes | API token from `create_test_agent.rb` |

The Anthropic API key is read from `.agent_key` file (not env vars).

## Troubleshooting

### MCP server not appearing in `/mcp`

1. Use absolute path in `.mcp.json`
2. Restart Claude Code completely (`/exit` then `claude`)
3. Check `.mcp.json` syntax (valid JSON)

### "ANTHROPIC_API_KEY not set" error

Create the `.agent_key` file:
```bash
echo "sk-ant-api03-your-key" > backend/mcp_servers/.agent_key
```
Then restart Claude Code.

### "No API token configured" or 401 errors

The token is invalid. Regenerate:
```bash
cd backend && bundle exec ruby scripts/create_test_agent.rb
```
Update `.mcp.json` with the new token.

### API returns 302 redirect

The API routes may be inside a login-protected block. Check `backend/app.rb` to ensure `/api/agent` routes are outside `require_login!`.

### Agents not executing commands

- Check game server is running: `curl http://localhost:3000/api/agent/room -H "Authorization: Bearer YOUR_TOKEN"`
- Verify test agent character exists in database
- Check server logs for errors
