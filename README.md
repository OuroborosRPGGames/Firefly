# Firefly MUD Engine

A modern text-based RPG engine combining classic MUD mechanics with web interfaces.

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

## Features

It uses a web-based game client, there's no telnet option. That means the ability to delete miss-sent emotes/messages, see when someone else is writing an emote, use pop out forms, use temporary displays or windows to keep rp content clearer, render graphic and interactive maps and minimaps, use 16 mill html colors and with tools to create and easily apply your own color gradients, see character pictures nested into their description, set area background images, set items and descriptions with thumbnails visible when you look at someone, share youtube videos for DJing etc, share browser tabs for in game watch parties, movies and so on.

It is based on a spatial framework, so unlike in most MU*s where rooms are sort of ephemeral and connected via exits to specific other rooms, in Firefly everything has a location in the world. So you will generally start with creating a world, either generating one or importing earth. Either way it will map the topography into hexes, each about 3 miles wide. So for earth-sized worlds that's about 20 million hexes. You'll then get a globe you can view and spin around, and clicking on a point takes you into the hex map at that point where you can change terrain, add roads, rivers, cities, draw political/RP zones or create locations/towns.

Once you build a location or town you go about placing things in a graphical UI by either click and drag for rectangles or multi-click for polygons, placing down buildings, rooms, doors, windows, places/furniture, decoratations etc. You can infinitely nest rooms within each other so you could have one 'room' for the building, another for a floor within it, another for an apartment within that floor and another for a bathroom within that apartment. And doors etc all work spatially, so if you say this wall has a door in it going through it takes you to whatever room is on the other side of that, or outdoors etc.

This also facilitates long-distance pathing, so you can travel to the location on the other side of the city and the pathing will take you there, and just makes for a much nicer building experience to be able to see what you're building as you go.

The journey/world travel system handles moving between locations and will bring up the grid map of your surroundings, allowing you to scroll around to choose where you want to travel too and build your group before setting off. You'll be in a temporary travel room for the duration and there are a few tools to speed up travel. If you haven't rp'ed with anyone in a while you can use whatever time that was to get a head start, as if you set off earlier. You can also split that time in half and use half to travel there and half to travel back, although in this case while there you will be instanced. You can also backload travel to travel instantly but the trip back takes twice as long, this also instances you. These are to make it relatively easy for people to get around but without undermining reality.

For accessibility there's full ARIA tagging of all elements in the client for screen readers to latch onto, and shortcuts for playing most recent x number of messages etc. Players can select a character voice in chargen and the client's native TTS if setup will use those voices for those characters in narrative playback, with the option to have it auto-pause when you start typing. There are also high contrast modes, and dyslexia friendly font options.

There's a permissions system for handling things like content controls as well as permissions like if you'll autofollow someone.

There's a timelines system which allows people to play multiple instances of the same character at different points in time. So if you want to continue a scene you can run a command to save the state of the characters at that point into a little time pocket, then can resume that scene later while still playing your main character in another tab. You can also choose a location and a year and enter a time pocket for that location and year, only able to interact with others in that location and year pocket, playing as a separate instance to your main character.

There's a combat system which is a simultaneous round system. What that means is everyone puts in what they want to do at the same time, and then the round plays out with individual actions interleaving which is then turned into a short narrative paragraph. I like this approach since it still has the main advantages of turn-based combat, the ability to RP throughout and not requiring people to be super twitchy but doesn't drag in the same way, a 5 person fight is about as fast as a 2 person one still. The combat plays out on a hex map which will render into the left side of the web client when in combat with hexes having various properties like elevation, cover, hazard which affect combat. You can also upload images to serve as battlemaps and set the different appropriate parameters for the hexes. You can enter all combat actions through the hex map instead of through the main client if required, clicking on an enemy to select them as your target etc. As long as looking neat this can go a long way to helping people visualize a fight and understand what's going on.

Activities/Missions: Missions are pre-created adventures with branching paths made up of a series of discrete challengers, while other types of activities work as games or competitions.

There's an RNG Dungeon system called Delves, this builds a randomized dungeon of multiple levels with traps, puzzles, skill challenges, combat enemies and treasure. Each level gets harder but the rewards double. Characters only have 60 minutes in a delve to get their rewards and get out, but time doesn't tick down on it's own, instead every action has a specific time cost, with several actions that make things easier also having a cost. This means that delves can have a very high skill ceiling with people being able to try and push themselves to get deeper and deeper etc, but also don't require you to be twitchy, can be taken a break from in the middle of them, and can RP with other characters as you do them since RP doesn't take time off the clock.

There's a system for downloading details from character's you've made or areas you've built and then uploading them to a new game also using the same engine.

ML/LLM Modules:
There are also several features powered by LLMs/Machine Learning models, these are all optional and users can determine which if any they want to include.

Autohelp: If someone searches for a helpfile and nothing matches or they conclude their help statement with a question mark, an LLM will take their query and search helpfiles for them for the information they need, if it thinks the information is lacking it will automatically create a ticket.

Automoderate: If enabled watches new player's input into the game for their first variable hours and blocks and bans them if they try and send abuse or other trolling behaviour.

Semote: Processes an emote the same as a normal emote but also scans the non-verbal text for commands and runs them if found, so someone could do semote tosses an orange to Bob and it'd emote that then transfer the orange to bob.

Automatic Battlemap generation: Takes the description of the room and creates a battlemap based on it, then uses ML segmentation models to find the objects etc in the room and autotags all those hexes.

Additional Mission Rounds: Two mission round types can be included which use LLMs, a persuade type where characters need to persuade a LLM played NPC to progress the round. And a free-roll type where players choose entirely freeform how to tackle an obstacle and the LLM sets stats/difficulties.

Auto-triage: A script that can be run daily that will go through tickets and dispatch a claude code session to investigate them, updating helpfiles if it finds information is incorrect/missing and creating files of code patches for potential bugs to review. If setup with a GitHub repo it can create PRs to that repo with the fix for the bug.

Building tools: Almost any aspect in whole or in part can be delegated to an LLM if desired from getting it to write a single room description to getting it to design and build a whole town with shops, houses, npcs, shop inventories etc.

Mission creation: Harness for turning a free text description into a structured activity-driven mission.

NPC animation: Code for using LLMs to animate NPCs so they RP with PCs with their own memories and relationship trackers.

NPC encounters: Code for staff to setup specific encounters where the specified player can go to a location and run a command to get a scene with a specific NPC but with additional instructions provided by the staffer, with the staff sent a summary and the full log afterwards.

World Memory: System for summarizing all RP scenes and other major IC events and tagging them with locations, involved PCs/NPCs etc. Becomes a searchable index for staff.

RP triggers: Triggers that can be added to NPCs or world memories that notify staff or trigger events, e.g. a NPC noticing a crime triggers code to set someone as wanted.

AutoGM: A system for having an LLM driven GM lead a group of players through an adventure.

While each is modular these often do work best together, e.g. a staffer can search world memories for people noticing specific hooks, then set up an encounter with an NPC to further that plot, have a custom mission built based on that story for that player/group of players and then feed the result of the mission back into world memories.

As a reminder, this is a game engine not a game. It's designed for people to take the bits they like and change them in the ways they want and put them together in ways that make sense for their particular world/vision. The modules are meant to be a good starting place not a end-state feature.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT -- see [LICENSE](LICENSE) for details.
