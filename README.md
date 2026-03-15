# Firefly MUD Engine

A modern text-based RPG engine combining classic MUD mechanics with web interfaces and AI integration.

## What is Firefly?

Firefly is an open-source MUD (Multi-User Dungeon) engine built for the modern web. It pairs traditional MUD gameplay -- room-based exploration, real-time combat, crafting, and social interaction -- with AI-powered NPCs, procedural dungeon generation, an AI dungeon master, battle map rendering with WebGL effects, and a full web UI. The engine is organized into 29 plugin systems, making it straightforward to extend or customize. Firefly is built on Roda, Sequel, and PostgreSQL -- it is **not** a Rails application.

## Features

**Core Gameplay**
- Room-based navigation with spatial adjacency (polygon geometry, not manual exit linking)
- Communication: say, emote, whisper, channels, and message personalization per viewer
- Damage threshold combat system (raw damage converted to HP loss via thresholds, not direct subtraction)
- Character customization with physical descriptions, clothing, and wardrobe

**World Building**
- Building and room editor with polygon-based layouts
- Economy system with shops, currency, and trading
- Inventory management and item system
- Clothing and wardrobe with layered outfit support

**Adventure**
- Delve: procedural dungeon generation with scaling difficulty
- Auto-GM: AI-driven dungeon master that runs dynamic adventures
- Activities: structured gameplay events (heists, investigations, etc.)
- Events system for world-level happenings

**Social**
- Clans with ranks and management
- Social interaction commands (wave, bow, hug, etc.)
- Timeline and scene system for narrative moments

**Technical**
- AI-powered NPCs with memory, reputation, and personality
- Battle map generation from images with hex grid classification
- WebGL overlay effects (water, fire, foliage, lighting) on battle maps
- Hex-based tactical combat with line of sight and pathfinding
- Plugin architecture with auto-discovery and command registration DSL

## Tech Stack

| Component | Technology |
|-----------|------------|
| Web framework | [Roda](https://roda.jeremyevans.net/) |
| ORM | [Sequel](https://sequel.jeremyevans.net/) |
| Database | PostgreSQL |
| Background jobs | Sidekiq + Redis |
| Frontend | Tailwind CSS v4 + DaisyUI 4.12 |
| AI integration | Anthropic Claude, Google Gemini, OpenAI |

This is **not** a Rails application. There is no ActiveRecord, no ActionView, no `rails` CLI.

## Requirements

- Ruby 3.3.1+
- PostgreSQL 14+
- Redis 7+
- Python 3.10+ (optional -- used for computer vision scripts and MCP test server)

## Quick Start

```bash
git clone <repo-url> && cd firefly/backend
bin/setup        # creates database, runs migrations, seeds data
bin/dev          # starts puma + tailwind --watch
```

Open http://localhost:3000 and click "Login as Test Account" to start playing.

### Manual Setup

```bash
cd backend
bundle install
createdb firefly
bundle exec rake db:migrate
bundle exec rake db:seed
bundle exec puma -p 3000
```

## Runtime Dependencies

| Service | Required? | Purpose |
|---------|-----------|---------|
| PostgreSQL | Yes | Primary database |
| Redis | Yes | Session storage, Sidekiq queue |
| Sidekiq | Optional in dev | Background jobs (NPC behavior, combat rounds, events) |

Start Sidekiq when you need background processing:

```bash
bundle exec sidekiq
```

## Optional Setup

**AI Features** require API keys in a `.env` file at `backend/.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
GEMINI_API_KEY=...
OPENAI_API_KEY=sk-...
```

Without these keys, AI-dependent features (NPC conversations, Auto-GM, battle map generation) will be unavailable. Core gameplay works without them.

**MCP Test Server** provides development testing tools for running game commands, verifying room state, and automated feature testing. See `backend/mcp_servers/` for setup.

## Project Structure

```
backend/
  app.rb                  # Main Roda application entry point
  app/
    commands/             # Game command base classes
    models/               # Sequel ORM models
    routes/               # Roda route handlers
    services/             # Business logic services
    views/                # ERB templates
  config/
    game_config.rb        # Centralized game constants
    prompts.yml           # All LLM prompts
  db/
    migrations/           # Sequel migrations
  lib/                    # Utility libraries (hex grid, CV tools)
  plugins/
    core/                 # 29 plugin systems (navigation, combat, economy, etc.)
    PLUGIN_DEVELOPMENT.md # Plugin authoring guide
  spec/                   # RSpec test suite
  scripts/                # CLI utilities (command generator, test agent setup)
```

## Testing

```bash
cd backend

# Create the test database
createdb firefly_test

# Run the full test suite
bundle exec rspec

# Run a specific test file
bundle exec rspec spec/commands/social/wave_spec.rb

# Run tests for a category
bundle exec rspec spec/commands/
```

The full test suite has approximately 15,000 tests and takes around 1.5 hours. For faster feedback, run targeted specs.

**MCP Testing** (requires the MCP test server running):

The MCP server exposes tools for executing game commands, inspecting room state, and running automated multi-agent tests. This is useful for integration testing beyond what RSpec covers.

## Documentation

- [CLAUDE.md](CLAUDE.md) -- Development patterns and critical rules
- [backend/GETTING_STARTED.md](backend/GETTING_STARTED.md) -- Setup tutorial and first command walkthrough
- [backend/docs/](backend/docs/) -- API reference, model map, helper index, solution guides
- [backend/plugins/PLUGIN_DEVELOPMENT.md](backend/plugins/PLUGIN_DEVELOPMENT.md) -- How to build new plugins

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT -- see [LICENSE](LICENSE) for details.
