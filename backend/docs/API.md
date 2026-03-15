# Firefly MUD API Documentation

This document covers the REST API and WebSocket protocol for the Firefly MUD engine.

## Table of Contents

1. [Authentication](#authentication)
2. [Agent API (LLM Integration)](#agent-api)
3. [Web Client API](#web-client-api)
4. [WebSocket Protocol](#websocket-protocol)
5. [Dual-Mode Output](#dual-mode-output)
6. [Error Handling](#error-handling)

## Authentication

### API Token Authentication (Agents)

For LLM agents and automated clients, use Bearer token authentication:

```http
Authorization: Bearer <api_token>
```

Generate a token:

```bash
cd backend
bundle exec ruby scripts/create_test_agent.rb
# Outputs: API Token: af4823058e4479c027c470c34f4dba7cadefef8f...
```

### Session Authentication (Web Clients)

Web clients use cookie-based sessions after login:

```http
POST /login
Content-Type: application/x-www-form-urlencoded

email=user@example.com&password=yourpassword
```

## Agent API

All agent endpoints are under `/api/agent/` and require Bearer token authentication.

### POST /api/agent/command

Execute a game command.

**Request:**

```json
{
  "command": "look"
}
```

**Response (Success):**

```json
{
  "success": true,
  "type": "room",
  "description": "You look around the room.",
  "structured": {
    "room": {
      "id": 123,
      "name": "Town Square",
      "description": "A bustling town square...",
      "room_type": "safe"
    },
    "characters": [
      {"id": 1, "name": "John Doe", "short_desc": "A tall human"}
    ],
    "exits": ["north", "south", "east"]
  },
  "message": "You look around the room.",
  "timestamp": "2025-12-19T12:00:00Z"
}
```

**Response (Error):**

```json
{
  "success": false,
  "error": "You can't do that while dead.",
  "suggestions": ["revive", "respawn"]
}
```

### GET /api/agent/room

Get current room state.

**Response:**

```json
{
  "success": true,
  "room": {
    "id": 123,
    "name": "Town Square",
    "description": "A bustling town square with a fountain in the center.",
    "room_type": "safe"
  },
  "characters": [
    {
      "id": 456,
      "character_id": 789,
      "name": "John Doe",
      "short_desc": "A tall human wearing leather armor"
    }
  ],
  "objects": [
    {
      "id": 101,
      "name": "wooden bench",
      "description": "A weathered wooden bench"
    }
  ],
  "exits": [
    {
      "id": 1,
      "direction": "north",
      "display_name": "North Gate",
      "locked": false
    }
  ]
}
```

### GET /api/agent/commands

List available commands for the character.

**Response:**

```json
{
  "success": true,
  "commands": [
    {
      "name": "say",
      "aliases": [],
      "category": "communication",
      "help": "Speak to everyone present. Usage: say <message> or \"<message>"
    },
    {
      "name": "look",
      "aliases": ["l"],
      "category": "navigation",
      "help": "Look at your surroundings or a specific target"
    }
  ]
}
```

### GET /api/agent/status

Get character status.

**Response:**

```json
{
  "success": true,
  "character": {
    "id": 1,
    "name": "John Doe",
    "short_desc": "A tall human"
  },
  "instance": {
    "id": 456,
    "room_id": 123,
    "reality_id": 1,
    "status": "alive"
  }
}
```

### GET /api/agent/help

Get help information.

**Without topic (Table of Contents):**

```http
GET /api/agent/help
```

```json
{
  "success": true,
  "toc": {
    "categories": ["communication", "navigation", "combat"],
    "topics": [
      {"name": "say", "category": "communication"},
      {"name": "look", "category": "navigation"}
    ]
  }
}
```

**With topic:**

```http
GET /api/agent/help?topic=say
```

```json
{
  "success": true,
  "help": {
    "title": "say",
    "category": "communication",
    "description": "Speak to everyone present in the room.",
    "usage": "say <message>",
    "examples": ["say Hello everyone!", "\"Hello everyone!"]
  }
}
```

### GET /api/agent/help/search

Search help topics.

```http
GET /api/agent/help/search?q=attack&category=combat
```

```json
{
  "success": true,
  "results": [
    {
      "topic": "attack",
      "category": "combat",
      "relevance": 1.0,
      "snippet": "Attack a target..."
    }
  ]
}
```

### GET /api/agent/help/topics

List all help topics.

```http
GET /api/agent/help/topics?category=combat
```

```json
{
  "success": true,
  "topics": ["attack", "defend", "flee"]
}
```

### GET /api/agent/actions

Get active timed actions.

```json
{
  "success": true,
  "actions": [
    {
      "id": 1,
      "action_type": "crafting",
      "description": "Forging a sword",
      "progress_percent": 45,
      "remaining_seconds": 30,
      "cancellable": true
    }
  ]
}
```

### POST /api/agent/actions/:id/cancel

Cancel a timed action.

```json
{
  "success": true,
  "message": "Action cancelled"
}
```

### GET /api/agent/cooldowns

Get active cooldowns.

```json
{
  "success": true,
  "cooldowns": [
    {
      "action": "attack",
      "remaining_seconds": 3,
      "ready_at": "2025-12-19T12:00:03Z"
    }
  ]
}
```

### GET /api/agent/interactions

Get pending interactions (quickmenus, forms).

```json
{
  "success": true,
  "interactions": [
    {
      "id": "abc-123",
      "type": "quickmenu",
      "prompt": "What would you like to do?",
      "options": [
        {"key": "1", "label": "Attack", "description": "Strike the enemy"},
        {"key": "2", "label": "Defend", "description": "Raise your shield"}
      ]
    }
  ]
}
```

### POST /api/agent/interactions/:id/respond

Respond to an interaction.

**For quickmenu:**

```json
{
  "response": "1"
}
```

**For form:**

```json
{
  "response": {
    "name": "John",
    "class": "warrior"
  }
}
```

**Response:**

```json
{
  "success": true,
  "message": "Response accepted",
  "context": {}
}
```

### POST /api/agent/interactions/:id/cancel

Cancel/dismiss an interaction.

```json
{
  "success": true,
  "message": "Interaction cancelled"
}
```

## Web Client API

These endpoints use session authentication.

### POST /api/messages

Send a message/command from the web client.

**Request:**

```json
{
  "content": "say Hello world!"
}
```

**Response:**

```json
{
  "success": true,
  "message": {
    "content": "John says, 'Hello world!'",
    "message_type": "say",
    "created_at": "2025-12-19T12:00:00Z"
  }
}
```

### GET /api/messages

Get recent messages (polling).

**Parameters:**
- `after_id` - Only messages after this ID
- `limit` - Maximum messages (default: 50)

### GET /api/room/status

Get current room status for web client.

### GET /api/character/status

Get character status for web client.

### POST /api/settings

Save user settings.

```json
{
  "volume": 50,
  "show_full": true,
  "notify_message": true
}
```

### GET /api/settings

Get user settings.

## WebSocket Protocol

WebSocket connections are handled by AnyCable.

### Connection

```javascript
const ws = new WebSocket('wss://yourdomain.com/cable');

// Subscribe to room channel
ws.send(JSON.stringify({
  command: 'subscribe',
  identifier: JSON.stringify({
    channel: 'RoomChannel',
    room_id: 123
  })
}));
```

### Message Types

#### Room Events

**character_entered:**
```json
{
  "event": "character_entered",
  "data": {
    "character": {
      "id": 1,
      "name": "John Doe",
      "short_desc": "A tall human"
    }
  }
}
```

**character_left:**
```json
{
  "event": "character_left",
  "data": {
    "character_id": 1
  }
}
```

**say:**
```json
{
  "event": "say",
  "data": {
    "speaker": {
      "id": 1,
      "name": "John Doe"
    },
    "message": "Hello everyone!"
  }
}
```

**emote:**
```json
{
  "event": "emote",
  "data": {
    "actor": {
      "id": 1,
      "name": "John Doe"
    },
    "action": "waves at everyone"
  }
}
```

**room_update:**
```json
{
  "event": "room_update",
  "data": {
    "room": {
      "id": 123,
      "name": "Town Square"
    },
    "characters": [...],
    "objects": [...]
  }
}
```

#### Player Events

**private_message:**
```json
{
  "event": "private_message",
  "data": {
    "from": {
      "id": 1,
      "name": "John Doe"
    },
    "message": "Hey, are you there?"
  }
}
```

**notification:**
```json
{
  "event": "notification",
  "data": {
    "type": "info",
    "message": "You have been invited to a party."
  }
}
```

**error:**
```json
{
  "event": "error",
  "data": {
    "code": "ERR_001",
    "message": "You cannot do that here."
  }
}
```

### Channels

| Channel | Purpose | Subscription |
|---------|---------|--------------|
| RoomChannel | Room events, chat | `{ room_id: 123 }` |
| PlayerChannel | Personal notifications | `{ player_id: 456 }` |
| GlobalChannel | Server-wide announcements | `{}` |

## Dual-Mode Output

Firefly supports dual-mode output for both human and agent clients.

### Detection

Agent mode is detected by:

1. **Path prefix:** `/api/agent/*` routes always return structured data
2. **Header:** `X-Output-Mode: agent` on any request
3. **User-Agent:** Contains "Claude", "GPT", "Gemini", or "Agent"

### Output Structure

Commands return both human-readable and structured data:

```json
{
  "success": true,
  "message": "You attack the goblin for 15 damage!",
  "type": "combat",
  "data": {
    "action": "attack",
    "target": "goblin",
    "damage": 15,
    "target_health": 35,
    "attacker_health": 100
  },
  "timestamp": "2025-12-19T12:00:00Z"
}
```

### Type Reference

| Type | Description | Data Fields |
|------|-------------|-------------|
| `room` | Room description | `room`, `characters`, `objects`, `exits` |
| `message` | Chat message | `type`, `sender`, `content` |
| `movement` | Character movement | `direction`, `from_room`, `to_room` |
| `combat` | Combat action | `action`, `target`, `damage`, `effects` |
| `inventory` | Inventory change | `action`, `item`, `quantity` |
| `emote` | Emote/action | `action`, `target` |
| `error` | Error message | `code`, `message` |

## Panel Targeting

Commands return a `target_panel` field that specifies where output should be rendered. This enables both human webclient users and agentic MCP players to understand output context.

### Panel Reference

| Panel | Description | Agent Semantics |
|-------|-------------|-----------------|
| `left_main_feed` | OOC chat stream | Informational/meta messages |
| `right_main_feed` | RP content stream | In-world narrative |
| `left_observe_window` | Temp inspect (left) | Detailed OOC info |
| `right_observe_window` | Temp inspect (right) | Detailed in-world object/character |
| `left_status_bar` | Status (left) | Channel, connection status |
| `right_status_bar` | Status (right) | Health, location summary |
| `left_minimap` | Area map | Spatial awareness |
| `right_effect_dropdown` | Active effects | Buffs, debuffs, cooldowns |
| `popout_form` | Modal form | Requires user input |
| `imprint` | System banner | Critical notifications |

### Response Format

```json
{
  "success": true,
  "type": "message",
  "target_panel": "right_observe_window",
  "description": "You look at the sword...",
  "structured": {
    "display_type": "item",
    "name": "Rusty Sword",
    "description": "An old blade..."
  },
  "timestamp": "2025-12-21T12:00:00Z"
}
```

### Agent Usage

Agents should use `target_panel` to understand output context:

- `*_main_feed`: Append-only message streams, read for ongoing context
- `*_observe_window`: Temporary inspection results, detailed object/character info
- `*_status_*`: Current state summaries, quickly parseable
- `right_effect_dropdown`: Active effects, buffs, debuffs, cooldowns
- `popout_form`: Requires response via `respond_to_interaction` endpoint
- `imprint`: Critical system notifications requiring attention

### Default Panel Inference

If `target_panel` is not explicitly set, it's inferred from content type:

| Content Type | Default Panel |
|--------------|---------------|
| `say`, `emote`, `room`, `combat` | `right_main_feed` |
| `ooc`, `channel`, `tell`, `whisper` | `left_main_feed` |
| `character`, `item`, `decoration`, `place`, `exit` | `right_observe_window` |
| `quickmenu`, `form` | `popout_form` |
| `effect`, `buff`, `debuff` | `right_effect_dropdown` |
| `system` | `imprint` |

## Error Handling

### HTTP Status Codes

| Code | Meaning | Response |
|------|---------|----------|
| 200 | Success | `{ "success": true, ... }` |
| 400 | Bad Request | `{ "success": false, "error": "..." }` |
| 401 | Unauthorized | `{ "success": false, "error": "Unauthorized" }` |
| 404 | Not Found | `{ "success": false, "error": "Not found" }` |
| 429 | Rate Limited | `{ "success": false, "error": "rate_limit_exceeded", "retry_after": 5 }` |
| 500 | Server Error | `{ "success": false, "error": "Internal server error" }` |

### Rate Limits

| Endpoint | Limit | Period |
|----------|-------|--------|
| Web client commands | 15 | 1 second |
| Agent commands | 30 | 1 second |
| Login attempts | 5 | 1 minute |
| Registration | 3 | 1 hour |

### Error Response Format

```json
{
  "success": false,
  "error": "Human-readable error message",
  "code": "ERR_CODE",
  "suggestions": ["alternative1", "alternative2"],
  "retry_after": 5
}
```

## Rate Limiting Headers

When rate limited:

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
Retry-After: 5

{"success":false,"error":"rate_limit_exceeded","retry_after":5}
```

## Examples

### Python Agent Client

```python
import requests

class FireflyClient:
    def __init__(self, base_url, token):
        self.base_url = base_url
        self.headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json'
        }

    def execute_command(self, command):
        response = requests.post(
            f'{self.base_url}/api/agent/command',
            json={'command': command},
            headers=self.headers
        )
        return response.json()

    def get_room(self):
        response = requests.get(
            f'{self.base_url}/api/agent/room',
            headers=self.headers
        )
        return response.json()

# Usage
client = FireflyClient('http://localhost:3000', 'your-api-token')
result = client.execute_command('look')
print(result['message'])
```

### JavaScript WebSocket Client

```javascript
class FireflyWebSocket {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.handlers = {};

    this.ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      if (data.event && this.handlers[data.event]) {
        this.handlers[data.event](data.data);
      }
    };
  }

  subscribe(channel, params) {
    this.ws.send(JSON.stringify({
      command: 'subscribe',
      identifier: JSON.stringify({ channel, ...params })
    }));
  }

  on(event, handler) {
    this.handlers[event] = handler;
  }
}

// Usage
const client = new FireflyWebSocket('wss://localhost:3000/cable');
client.subscribe('RoomChannel', { room_id: 123 });

client.on('say', (data) => {
  console.log(`${data.speaker.name}: ${data.message}`);
});
```
