# Getting Started with Firefly MUD Engine

This guide will help you set up a development environment and create your first command in under 30 minutes.

## Prerequisites

Before starting, ensure you have:

- **Ruby 3.3.1** (via [rbenv](https://github.com/rbenv/rbenv) or [asdf](https://asdf-vm.com/))
- **PostgreSQL 14+** (running on localhost:5432)
- **Redis 7+** (running on localhost:6379)
- **Git** for version control

### Quick Check

```bash
ruby --version    # Should show ruby 3.3.1 or higher
psql --version    # Should show psql 14.x or higher
redis-cli ping    # Should respond PONG
```

## Quick Start (5 minutes)

### 1. Clone and Install

```bash
git clone <your-fork-url>
cd firefly/backend
bundle install
```

### 2. Automated Setup (Recommended)

The fastest way to get running:

```bash
cd backend
bin/setup
```

This will:
- Install Ruby dependencies
- Create the PostgreSQL user and database
- Run the consolidated database migration
- Load seed data

**Default database credentials:** `prom_user` / `prom_password` (matching `.env.example`).

### 2b. Manual Database Setup (Alternative)

If you prefer to set up the database manually:

**Create PostgreSQL User and Database:**

```bash
# Create the database user (if not exists)
sudo -u postgres createuser -P prom_user
# Enter password: prom_password

# Create the database
createdb -O prom_user firefly

# Alternative: Use psql directly
psql -U postgres -c "CREATE USER prom_user WITH PASSWORD 'prom_password';"
psql -U postgres -c "CREATE DATABASE firefly OWNER prom_user;"
```

**Run the Migration:**

The database schema is defined in a single consolidated migration (`db/migrations/001_initial_schema.rb`):

```bash
# Apply the database migration
bundle exec sequel -m db/migrations postgres://prom_user:prom_password@localhost/firefly

# Or using DATABASE_URL from .env
bundle exec ruby -r './config/database' -e 'Sequel::Migrator.run(DB, "db/migrations")'
```

**Seed Initial Data:**

```bash
# Load seed data (creates test user, starting room, reality)
bundle exec ruby db/seeds.rb

# Verify seed data loaded correctly
bundle exec ruby -r './config/database' -e 'puts "Rooms: #{DB[:rooms].count}, Users: #{DB[:users].count}"'
```

### 3. Earth Import Setup

Earth imports require a pre-computed terrain lookup file generated from satellite data.

**One-time setup:**

1. Install Python dependencies:
   ```bash
   pip install -r scripts/requirements-terrain.txt
   ```

2. Authenticate with Google Earth Engine (requires Google account):
   ```bash
   earthengine authenticate
   ```

3. Generate the terrain lookup (~30-60 minutes):
   ```bash
   python scripts/generate_terrain_lookup.py
   ```

This creates `backend/data/terrain_lookup.bin` (~150MB).

**Note:** The lookup file is not committed to git due to its size. Each developer must generate it locally, or download from releases (if available).

### 4. Configure Environment

Copy the example environment file:

```bash
cp .env.example .env
```

The defaults work for local development. See [Environment Variables](#environment-variables) for customization.

### 5. Start the Server

```bash
bundle exec puma -p 3000
```

### 6. Verify Installation

```bash
# Check health endpoint
curl http://localhost:3000/health

# Expected response:
# {"status":"ok","timestamp":"..."}
```

Congratulations! The server is running.

## Your First Command

Let's create a `wave` command that waves at other characters.

### Step 1: Create the Plugin Directory Structure

```bash
mkdir -p plugins/examples/wave/commands
mkdir -p plugins/examples/wave/spec/commands
```

### Step 2: Create the Plugin Definition

Create `plugins/examples/wave/plugin.rb`:

```ruby
# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Wave
    class Plugin < Firefly::Plugin
      name :wave
      version "1.0.0"
      description "Simple wave command for greeting others"

      commands_path "commands"
    end
  end
end
```

### Step 3: Create the Command

Create `plugins/examples/wave/commands/wave.rb`:

```ruby
# frozen_string_literal: true

module Commands
  module Wave
    class Wave < Commands::Base::Command
      command_name 'wave'
      aliases 'wav'
      category :social
      help_text 'Wave at someone or everyone in the room'
      usage 'wave [target]'
      examples 'wave', 'wave John'

      requires_alive

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]&.strip

        if target_name.nil? || target_name.empty?
          wave_to_all
        else
          wave_to_target(target_name)
        end
      end

      private

      def wave_to_all
        message = "#{character.full_name} waves to everyone."
        broadcast_to_room(message, exclude_character: character_instance)

        success_result(
          "You wave to everyone.",
          type: :emote,
          data: { action: 'wave', target: 'everyone' }
        )
      end

      def wave_to_target(target_name)
        target = find_character_by_name(target_name)

        unless target
          return error_result("You don't see anyone named '#{target_name}' here.")
        end

        message = "#{character.full_name} waves at #{target.full_name}."
        broadcast_to_room(message, exclude_character: character_instance)

        success_result(
          "You wave at #{target.full_name}.",
          type: :emote,
          data: { action: 'wave', target: target.full_name }
        )
      end
    end
  end
end

# Register the command with the system
Commands::Base::Registry.register(Commands::Wave::Wave)
```

### Step 4: Create the Test

Create `plugins/examples/wave/spec/commands/wave_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Wave::Wave do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  describe '#execute' do
    context 'when waving to everyone' do
      it 'succeeds with no target' do
        result = command.execute('wave')
        expect(result[:success]).to be true
        expect(result[:message]).to include('wave to everyone')
      end
    end

    context 'when waving to a specific person' do
      let(:target_character) { create(:character, forename: 'John', surname: 'Doe') }
      let!(:target_instance) do
        create(:character_instance,
               character: target_character,
               current_room: room,
               reality: reality,
               online: true,
               status: 'alive')
      end

      it 'succeeds with valid target' do
        result = command.execute('wave John')
        expect(result[:success]).to be true
        expect(result[:message]).to include('John')
      end

      it 'fails with invalid target' do
        result = command.execute('wave Nobody')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't see anyone")
      end
    end
  end
end
```

### Step 5: Run the Test

```bash
bundle exec rspec plugins/examples/wave/spec/commands/wave_spec.rb
```

### Step 6: Restart and Test

Restart the server to load the new plugin:

```bash
bundle exec puma -p 3000
```

Your command is now available in the game!

## Testing with MCP Agents

The Firefly project includes AI-powered testing tools. Here's how to use them:

### Setup MCP Testing

1. Create a test agent:

```bash
cd backend
bundle exec ruby scripts/create_test_agent.rb
# Note the API token that's output
```

2. Configure `.mcp.json` in the project root with the token.

3. Use the MCP tools to test your command:

```
# Execute your command
mcp__firefly-test__execute_command(command: "wave")

# Check room state
mcp__firefly-test__get_room_state()

# Run multi-agent testing
mcp__firefly-test__test_feature(
  objective: "Test the wave command by having agents greet each other",
  agent_count: 2,
  max_steps_per_agent: 10
)
```

## Project Structure

```
backend/
├── app/
│   ├── commands/base/      # Command framework
│   ├── models/             # Sequel models
│   ├── routes/             # Roda routes
│   ├── helpers/            # Output helpers
│   └── middleware/         # Agent mode detection
├── plugins/
│   ├── core/               # Core game plugins
│   │   ├── communication/  # say, emote
│   │   ├── navigation/     # look, move, directions
│   │   ├── combat/         # attack
│   │   └── environment/    # swim, rest
│   └── examples/           # Example plugins
├── config/
│   ├── database.rb         # Database connection
│   └── rack_attack.rb      # Rate limiting
├── db/
│   ├── migrate/            # Database migrations
│   └── seeds.rb            # Seed data
├── lib/
│   └── firefly/            # Core framework
├── mcp_servers/            # MCP testing server
└── spec/                   # Test files
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgres://prom_user:prom_password@localhost/firefly` | PostgreSQL connection |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis for sessions/cache |
| `ANYCABLE_REDIS_URL` | `redis://localhost:6379/1` | Redis for WebSockets |
| `RACK_ENV` | `development` | Environment (development/test/production) |
| `PORT` | `3000` | Server port |
| `FEATURE_RATE_LIMITING` | `false` | Enable rate limiting |
| `FEATURE_DUAL_OUTPUT` | `true` | Enable agent/human dual output |

## Running Tests

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/models/room_spec.rb

# Run tests with coverage
COVERAGE=true bundle exec rspec
```

## Common Tasks

### Create a New Migration

```bash
# Create migration file
touch db/migrate/$(date +%Y%m%d%H%M%S)_create_your_table.rb

# Run migrations
bundle exec sequel -m db/migrate postgres://localhost/firefly
```

### Check Database Connection

```bash
bundle exec ruby -e "require './config/database'; puts DB.tables"
```

### Start Rails Console (Sequel REPL)

```bash
bundle exec ruby -r ./config/boot -e "require './app'; binding.irb"
```

## Next Steps

1. Read the [Plugin Development Guide](plugins/PLUGIN_DEVELOPMENT.md) for advanced features
2. Check [API Documentation](docs/API.md) for REST/WebSocket endpoints
3. Review [Security Best Practices](docs/SECURITY.md) before production
4. See [CLAUDE.md](../CLAUDE.md) for project architecture overview

## Troubleshooting

### "Could not connect to database"

```bash
# Ensure PostgreSQL is running
sudo systemctl start postgresql

# Check if database exists
psql -l | grep firefly

# Check user exists and can connect
psql -U prom_user -d firefly -c "SELECT 1;"

# If user doesn't exist, create it
sudo -u postgres createuser -P prom_user
```

### "Role does not exist" or "Authentication failed"

```bash
# Check PostgreSQL authentication method in pg_hba.conf
sudo nano /etc/postgresql/*/main/pg_hba.conf

# Change 'peer' to 'md5' for local connections:
# local   all   all   md5

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### "Redis connection failed"

```bash
# Ensure Redis is running
sudo systemctl start redis

# Test connection
redis-cli ping

# The server works without Redis (rate limiting and caching disabled)
# Set FEATURE_RATE_LIMITING=false in .env to run without Redis
```

### "Migrations not found" or "Table doesn't exist"

```bash
# Ensure migrations are in the correct directory
ls db/migrations/

# Run migrations explicitly
bundle exec sequel -m db/migrations postgres://prom_user:prom_password@localhost/firefly

# Check which migrations have run
psql -U prom_user -d firefly -c "SELECT * FROM schema_migrations;"
```

### "Command not found" after creating

1. **Check file location**: Command must be in `plugins/[category]/[plugin]/commands/`
2. **Check module path**: Module must match directory structure
3. **Verify registration**: File must end with `Commands::Base::Registry.register(YourCommand)`
4. **Restart server**: New files require server restart

```bash
# Verify your command is registered
bundle exec ruby -r './app' -e 'puts Commands::Base::Registry.all_commands.keys.sort'
```

### Tests fail with "factory not registered"

```bash
# Check that factory files exist
ls spec/factories/

# Verify factory loading in spec_helper
grep -r "FactoryBot" spec/spec_helper.rb

# Run a specific test to see full error
bundle exec rspec spec/models/character_spec.rb -f d
```

### "Frozen string modification" errors

The codebase uses `frozen_string_literal: true`. If you get errors about modifying frozen strings:

```ruby
# Wrong
str = "hello"
str << " world"  # FrozenError!

# Correct
str = +"hello"   # Mutable string
str << " world"

# Or
str = "hello".dup
str << " world"
```

### Database connection pool exhaustion

If you see connection timeout errors under load:

```bash
# Check current connections
psql -U prom_user -d firefly -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'firefly';"

# Increase pool size in .env
DB_POOL_SIZE=50
```

## Getting Help

- Check existing commands in `plugins/core/` for patterns
- Review the [CONTRIBUTING.md](../CONTRIBUTING.md) guide
- Open an issue on GitHub for bugs
