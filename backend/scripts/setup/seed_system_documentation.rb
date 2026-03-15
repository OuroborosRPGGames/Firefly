# frozen_string_literal: true

# Seed comprehensive system documentation for all game systems
# Run with: bundle exec ruby scripts/setup/seed_system_documentation.rb

require_relative '../../config/application'

# Helper to update or create a HelpSystem with documentation
def seed_system(name, attrs)
  system = HelpSystem.find_by_name(name)
  if system
    system.update(attrs)
    puts "  Updated: #{name}"
  else
    HelpSystem.create(attrs.merge(name: name))
    puts "  Created: #{name}"
  end
end

puts "Seeding comprehensive system documentation..."
puts "=" * 60

# =============================================================================
# NAVIGATION SYSTEM
# =============================================================================

NAVIGATION_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Navigation System is your gateway to exploring the game world. Whether you're walking through city streets, following a friend to a secret location, or embarking on a long journey to a distant land, navigation commands help you move through and understand the spaces around you.

  The game world is organized into **Areas** (large regions like cities or wilderness), **Locations** (specific places within areas), and **Rooms** (individual spaces where you can interact with others). Within rooms, you may find **Places** (like "by the fireplace" or "at the bar") where you can position yourself.

  ## Key Concepts

  - **Rooms**: Individual spaces where characters interact. Each room has exits leading to other rooms.
  - **Exits**: Connections between rooms. Some exits may be locked or hidden.
  - **Places**: Named spots within a room (furniture, areas) where you can sit or stand.
  - **Following**: You can follow another character as they move, automatically traveling with them.
  - **Timed Movement**: Walking takes time based on distance. Running is faster, crawling is slower.
  - **World Travel**: Long-distance journeys between cities use a separate hex-grid travel system.

  ## Getting Started

  When you first enter the game, use these basic commands:

  1. **`look`** - See your surroundings, who's here, and available exits
  2. **`exits`** - List all available exits from your current room
  3. **`north`** (or `n`) - Move in a direction (north, south, east, west, up, down, etc.)
  4. **`walk <destination>`** - Walk to a specific room, character, or place

  ## Movement Commands

  ### Basic Directions

  Move in any cardinal or ordinal direction:

  | Command | Aliases | Description |
  |---------|---------|-------------|
  | `north` | `n` | Move north |
  | `south` | `s` | Move south |
  | `east` | `e` | Move east |
  | `west` | `w` | Move west |
  | `up` | `u` | Move up (stairs, ladders) |
  | `down` | `d` | Move down |
  | `northeast` | `ne` | Move northeast |
  | `northwest` | `nw` | Move northwest |
  | `southeast` | `se` | Move southeast |
  | `southwest` | `sw` | Move southwest |
  | `in` | `enter` | Enter a building or room |
  | `out` | `exit`, `leave` | Exit to outside |

  ### Walking with Style

  The `walk` command (and its aliases) lets you move toward any target with style:

  ```
  walk <target>      - Walk at normal speed
  run <target>       - Move quickly (0.5x travel time)
  sprint <target>    - Very fast movement (0.3x travel time)
  sneak <target>     - Move stealthily but slowly (2x travel time)
  crawl <target>     - Very slow movement (5x travel time)
  stroll <target>    - Leisurely pace (1.3x travel time)
  ```

  **Targets can be:**
  - A direction: `walk north`
  - A room name: `walk to tavern`
  - A character: `walk to John`
  - A place in the room: `walk to fireplace`

  ## Looking Around

  ### The Look Command

  `look` is your most important command for understanding your environment:

  ```
  look                  - See the full room description
  look <object>         - Examine an object in the room
  look <character>      - Look at another character
  look <exit>           - Look through an exit to see what's beyond
  look John's sword     - Look at an item someone is carrying
  ```

  ### Information Commands

  | Command | Aliases | Description |
  |---------|---------|-------------|
  | `exits` | - | List all exits with destinations |
  | `places` | `furniture`, `spots` | Show available places to sit/stand |
  | `map` | `roommap` | Display a visual map of the room |
  | `minimap` | `togglemap` | Toggle persistent minimap display |
  | `citymap` | `areamap` | View the larger city/area map |
  | `landmarks` | `public`, `locations` | List public places you can walk to |

  ## Following Others

  You can follow another character, automatically moving with them:

  ```
  follow <character>    - Start following someone
  stop following        - Stop following
  stop                  - Stop any current movement or following
  ```

  **Leading others:**
  ```
  lead                  - See who's following you
  lead <character>      - Allow someone to follow you
  lead stop <name>      - Revoke follow permission
  ```

  ## Fast Travel

  ### Taxi Service

  In most eras, taxi service is available for quick travel:

  ```
  taxi                  - Hail a taxi to your location
  taxi to <destination> - Travel directly to a destination
  ```

  The type of taxi varies by era:
  - **Gaslight Era**: Horse-drawn carriage
  - **Modern Era**: Rideshare (like Uber/Lyft)
  - **Near-Future**: Autocab (self-driving)
  - **Sci-Fi**: Hovertaxi

  ### World Travel (Long Distance)

  For travel between cities or distant locations:

  ```
  journey to <city>     - Begin a long-distance journey
  eta                   - Check your estimated arrival time
  passengers            - See who's traveling with you
  disembark             - Leave your journey early (ends in wilderness)
  ```

  ## Property & Access

  If you own property, you can control who enters:

  ```
  properties            - List all properties you own
  lock doors            - Lock your property to visitors
  unlock doors          - Open your property (optionally timed: unlock doors 30)
  grant access <name>   - Give someone permanent access
  revoke access <name>  - Remove someone's access
  access list           - See all access permissions
  ```

  For individual rooms within your property:
  ```
  lock room             - Lock the current room
  unlock room           - Unlock the current room
  grant room <name>     - Grant access to this specific room
  ```

  ## Examples

  **Exploring a new area:**
  ```
  > look
  [Room description appears]

  > exits
  North: Town Square
  East: Market Street
  South: City Gate

  > walk north
  You walk north toward Town Square...
  [After a moment, you arrive]
  ```

  **Following a friend:**
  ```
  > follow Sarah
  You begin following Sarah.

  [When Sarah moves, you automatically follow]
  Sarah walks east. You follow.
  ```

  **Taking a taxi:**
  ```
  > taxi to Central Park
  A rideshare arrives. You climb in and head toward Central Park.
  The driver takes Main Street, turning onto Park Avenue...
  You arrive at Central Park.
  ```

  ## Tips & Tricks

  1. **Use abbreviations**: `n` for north, `l` for look, `ex` for exits
  2. **Walk to characters**: Instead of memorizing room names, `walk to John` finds the shortest path
  3. **Check landmarks first**: Use `landmarks` to see public destinations you can walk to
  4. **Toggle minimap**: Keep `minimap` on for constant awareness of exits
  5. **Use run for urgency**: When you need to get somewhere fast, `run` or `sprint`
  6. **Sneak when needed**: `sneak` is slower but may help you move unnoticed

  ## Related Systems

  - **Combat**: Movement is restricted during combat
  - **Events**: Event rooms may have special access rules
  - **Vehicles**: Some navigation occurs inside vehicles
MARKDOWN

NAVIGATION_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Navigation System is implemented through a layered service architecture that handles three scales of movement:

  1. **Room-to-Room** (MovementService) - Timed movement within connected rooms
  2. **Smart Navigation** (SmartNavigationService) - Cross-building routing with taxi integration
  3. **World Travel** (WorldTravelService) - Hex-grid based long-distance journeys

  Movement commands are defined in the `plugins/core/navigation/` plugin and delegate to these services.

  ## Key Files

  | File | Purpose |
  |------|---------|
  | `app/services/movement_service.rb` | Core movement logic, follow/lead mechanics |
  | `app/services/pathfinding_service.rb` | BFS pathfinding between rooms |
  | `app/services/distance_service.rb` | 3D coordinate distance calculations |
  | `app/services/taxi_service.rb` | Era-appropriate taxi system |
  | `app/services/smart_navigation_service.rb` | Cross-building routing |
  | `app/services/world_travel_service.rb` | Long-distance hex journeys |
  | `app/services/hex_pathfinding_service.rb` | A* pathfinding on world hex grid |
  | `app/services/building_navigation_service.rb` | Indoor/outdoor detection |
  | `app/handlers/movement_handler.rb` | Timed action completion handler |
  | `config/movement.rb` | Movement configuration and verb conjugations |

  ## Important Constants

  ### Movement Timing (MovementConfig)

  | Constant | Value | Purpose |
  |----------|-------|---------|
  | `BASE_ROOM_TIME_MS` | 3000 | Default transition time when no coordinates |
  | `MIN_TRANSITION_TIME_MS` | 500 | Minimum transition time (floor) |
  | `BASE_MS_PER_UNIT` | 100 | Milliseconds per coordinate unit (DistanceService) |

  ### Speed Multipliers

  | Verb | Multiplier | Effective Speed |
  |------|-----------|-----------------|
  | `fly` | 0.05 | 20x faster |
  | `sprint` | 0.3 | 3.3x faster |
  | `run` | 0.5 | 2x faster |
  | `jog` | 0.6 | 1.7x faster |
  | `walk` | 1.0 | **Normal speed** |
  | `stroll` | 1.3 | 0.77x slower |
  | `meander` | 1.5 | 0.67x slower |
  | `sneak` | 2.0 | 0.5x slower |
  | `limp` | 2.0 | 0.5x slower |
  | `crawl` | 5.0 | 0.2x slower |

  ### Pathfinding Limits

  | Constant | Value | Location | Purpose |
  |----------|-------|----------|---------|
  | `MAX_PATH_LENGTH` | 50 | PathfindingService | Max rooms to search |
  | `MAX_DIRECT_WALK_DISTANCE` | 15 | SmartNavigationService | Before suggesting taxi |
  | `MAX_BUILDING_PATH` | 20 | SmartNavigationService | Max rooms for building exit/entry |
  | `MAX_PATH_LENGTH` | 500 | HexPathfindingService | Max world hexes to search |

  ### Taxi Configuration (by Era)

  | Era | Type | Wait Time | Base Fare |
  |-----|------|-----------|-----------|
  | Medieval | None | N/A | N/A |
  | Gaslight | Carriage | 300s | 5 coins |
  | Modern | Rideshare | 180s | 10 coins |
  | Near-Future | Autocab | 60s | 15 coins |
  | Sci-Fi | Hovertaxi | 30s | 25 coins |

  Fare formula: `base_fare + (distance_in_rooms * 0.5).round`

  ### World Hex Movement Costs

  | Terrain | Cost | Notes |
  |---------|------|-------|
  | ocean, lake | 10+ | Requires boat/swimming |
  | mountain | 4 | Difficult terrain |
  | swamp, ice | 3 | Slowing |
  | forest, hill, desert | 2 | Moderate |
  | urban, road, plain | 1 | Easy travel |

  ## Data Flow

  ### Standard Movement Flow
  ```
  Command (walk/run/etc)
      ↓
  MovementService.start_movement()
      ↓
  TargetResolverService (resolve target)
      ↓
  PathfindingService (find route)
      ↓
  DistanceService (calculate timing)
      ↓
  TimedAction.start_delayed()
      ↓
  [Time passes...]
      ↓
  MovementHandler.call()
      ↓
  MovementService.complete_room_transition()
      ↓
  BroadcastService (announce departure/arrival)
  ```

  ### Smart Navigation Flow
  ```
  MovementService.use_smart_navigation()
      ↓
  SmartNavigationService.navigate_to()
      ↓
  BuildingNavigationService.path_to_street() [if indoor]
      ↓
  TaxiService.travel_with_experience() [if distant]
      ↓
  BuildingNavigationService.path_into_building() [if destination indoor]
  ```

  ## Configuration Options

  ### Room Types Affecting Navigation

  **Outdoor types** (for taxi pickup, building exit detection):
  `street, avenue, intersection, boulevard, sidewalk, park, plaza, outdoor`

  **Indoor types** (require building exit logic):
  `building, hallway, apartment, residence, office, commercial, shop, guild, temple`

  ### Room Fields That Affect Movement

  - `inside_room_id`: Nesting for building hierarchy
  - `is_outdoor`: Boolean override for outdoor detection
  - `owner_id`: Property ownership for access control
  - `private_mode`: Excludes from staff vision broadcasts
  - `publicity`: `secluded | semi_public | public`

  ### Exit Fields That Affect Movement

  - `passable`: Whether exit can be used
  - `lock_type`: `none | key | code | biometric`
  - `blocked`: Temporary obstruction
  - `hidden`: Not visible until discovered

  ## Common Modifications

  ### Changing Movement Speed

  Edit `config/movement.rb` SPEED_MULTIPLIERS hash:
  ```ruby
  SPEED_MULTIPLIERS = {
    'walk' => 1.0,
    'run' => 0.5,  # Change this to make running faster/slower
    # ...
  }
  ```

  ### Adding New Movement Verbs

  1. Add to SPEED_MULTIPLIERS with desired multiplier
  2. Add conjugations to VERB_CONJUGATIONS:
     ```ruby
     'dash' => { present: 'dashes', past: 'dashed', continuous: 'dashing' }
     ```
  3. Add as alias in walk.rb command

  ### Adjusting Taxi Availability

  In `TaxiService`, modify `TAXI_CONFIG`:
  ```ruby
  TAXI_CONFIG = {
    'modern' => { type: 'rideshare', wait_time: 180, base_fare: 10 },
    # Modify values or add new eras
  }
  ```

  ### Changing Pathfinding Depth

  In `PathfindingService`:
  ```ruby
  MAX_PATH_LENGTH = 50  # Increase for larger areas
  ```

  ## Debugging Tips

  ### Movement Not Working

  1. Check if character is in combat: `character_instance.active_fight`
  2. Check if already moving: `MovementService.moving?(character_instance)`
  3. Verify exit exists and is passable: `room.exits.select(&:passable?)`
  4. Check for locks: `exit.locked?`

  ### Pathfinding Returns Nil

  1. Verify rooms are connected (no isolated rooms)
  2. Check MAX_PATH_LENGTH is sufficient
  3. Ensure exits are passable and not blocked
  4. Use `PathfindingService.reachable?(from, to)` to test

  ### Follow Not Working

  1. Check relationship permissions: `Relationship.can_follow?(follower, leader)`
  2. Verify leader has granted permission: `lead <follower>`
  3. Check follower isn't already following someone

  ### Timing Seems Wrong

  1. Check room has coordinates (min_x, max_x, etc.)
  2. Verify exit has position data
  3. Check speed multiplier for current verb
  4. Look at DistanceService.time_for_distance() calculation

  ## Integration Points

  - **Combat**: FightEntryDelayService prevents instant entry to active fights
  - **Prisoner**: Bound characters move with captor via PrisonerService
  - **Events**: Event rooms may override normal access rules
  - **Timeline**: Timeline instances affect movement restrictions
  - **Consent**: ContentConsentService tracks room entry for consent counters
MARKDOWN

NAVIGATION_QUICK_REFERENCE = <<~MARKDOWN
  ## Quick Reference

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `look` | `look [target]` | See surroundings or examine something |
  | `exits` | `exits` | List available exits |
  | `places` | `places` | Show furniture/places in room |
  | `n/s/e/w` | `north`, `n` | Move in direction |
  | `walk` | `walk <target>` | Walk to room, character, or place |
  | `run` | `run <target>` | Move quickly (2x speed) |
  | `follow` | `follow <name>` | Follow a character |
  | `stop` | `stop` | Stop moving or following |
  | `lead` | `lead <name>` | Allow someone to follow you |
  | `taxi` | `taxi to <dest>` | Fast travel by taxi |
  | `journey` | `journey to <city>` | Long-distance travel |
  | `eta` | `eta` | Check arrival time |
  | `map` | `map` | View room map |
  | `minimap` | `minimap` | Toggle minimap |
  | `landmarks` | `landmarks` | List public destinations |
  | `properties` | `properties` | List owned rooms |
  | `lock doors` | `lock doors` | Lock your property |
  | `unlock doors` | `unlock doors [min]` | Unlock property |
  | `grant access` | `grant access <name>` | Give property access |
  | `revoke access` | `revoke access <name>` | Remove access |
MARKDOWN

NAVIGATION_CONSTANTS = {
  timing: {
    BASE_ROOM_TIME_MS: { value: 3000, file: 'config/movement.rb', purpose: 'Default room transition time' },
    MIN_TRANSITION_TIME_MS: { value: 500, file: 'config/movement.rb', purpose: 'Minimum transition floor' },
    BASE_MS_PER_UNIT: { value: 100, file: 'app/services/distance_service.rb', purpose: 'Time per coordinate unit' }
  },
  pathfinding: {
    MAX_PATH_LENGTH: { value: 50, file: 'app/services/pathfinding_service.rb', purpose: 'Max rooms to search' },
    MAX_DIRECT_WALK_DISTANCE: { value: 15, file: 'app/services/smart_navigation_service.rb', purpose: 'Before suggesting taxi' },
    MAX_BUILDING_PATH: { value: 20, file: 'app/services/smart_navigation_service.rb', purpose: 'Building exit/entry limit' },
    WORLD_MAX_PATH_LENGTH: { value: 500, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Max world hexes' }
  },
  speed_multipliers: {
    fly: 0.05,
    sprint: 0.3,
    run: 0.5,
    jog: 0.6,
    walk: 1.0,
    stroll: 1.3,
    meander: 1.5,
    sneak: 2.0,
    limp: 2.0,
    crawl: 5.0
  },
  taxi_config: {
    gaslight: { type: 'carriage', wait_time: 300, base_fare: 5 },
    modern: { type: 'rideshare', wait_time: 180, base_fare: 10 },
    near_future: { type: 'autocab', wait_time: 60, base_fare: 15 },
    sci_fi: { type: 'hovertaxi', wait_time: 30, base_fare: 25 }
  },
  terrain_costs: {
    ocean: 10,
    lake: 10,
    mountain: 4,
    swamp: 3,
    ice: 3,
    forest: 2,
    hill: 2,
    desert: 2,
    urban: 1,
    road: 1,
    plain: 1
  }
}.freeze

puts "\n[Navigation System]"
seed_system('navigation', {
  display_name: 'Navigation System',
  summary: 'Move through the game world, follow others, and travel to distant lands',
  description: 'The Navigation System handles all movement through the game world, from walking between rooms to long-distance journeys. It includes commands for viewing surroundings, following others, using transportation, and managing property access.',
  player_guide: NAVIGATION_PLAYER_GUIDE,
  staff_guide: NAVIGATION_STAFF_GUIDE,
  quick_reference: NAVIGATION_QUICK_REFERENCE,
  constants_json: NAVIGATION_CONSTANTS,
  command_names: %w[look walk move north south east west up down northeast northwest southeast southwest in out follow lead stop directions map minimap citymap taxi landmarks journey eta passengers disembark exits places properties lock\ doors unlock\ doors lock\ room unlock\ room grant\ access revoke\ access grant\ room access\ list],
  related_systems: %w[combat events vehicles],
  key_files: [
    'app/services/movement_service.rb',
    'app/services/pathfinding_service.rb',
    'app/services/distance_service.rb',
    'app/services/taxi_service.rb',
    'app/services/smart_navigation_service.rb',
    'app/services/world_travel_service.rb',
    'app/services/hex_pathfinding_service.rb',
    'app/handlers/movement_handler.rb',
    'config/movement.rb',
    'plugins/core/navigation/commands/'
  ],
  staff_notes: 'Movement uses a timed action system with distance-based duration. Follow/lead mechanics require relationship permissions. Smart navigation chains building exit + taxi + building entry for cross-city travel.',
  display_order: 10
})

# =============================================================================
# COMMUNICATION SYSTEM
# =============================================================================

COMMUNICATION_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Communication System is the heart of roleplay, providing all the ways characters can interact through speech, actions, and written messages. Whether you're having a casual conversation at a tavern, whispering secrets to an ally, or sending a letter to someone across the city, communication commands make it happen.

  Communication in the game is context-aware—your messages appear differently based on who can hear them, what era the game is set in, and what permissions you have. Some speech is public, some is private, and some requires consent from others before it can happen.

  ## Key Concepts

  - **Speech**: Direct verbal communication visible to everyone in the room (say, yell)
  - **Emotes**: Actions and expressions your character performs (pose, emote)
  - **Whispers**: Private speech only the target can hear (whisper)
  - **Private Messages**: Era-aware instant messaging (pm)
  - **Memos/Letters**: Offline messages that persist and can be sent to anyone (send memo)
  - **Bulletins**: Public notices anyone can read (bulletin board)
  - **Consent System**: Some actions require permission before they happen (attempt)
  - **Adverbs**: Modify how you speak or act (say quietly, emote sadly)

  ## Getting Started

  The most common commands you'll use:

  1. **`say Hello!`** or **`"Hello!`** - Speak to the room
  2. **`emote smiles warmly.`** or **`:smiles warmly.`** - Perform an action
  3. **`whisper John I need to talk to you.`** - Private message to someone in the room
  4. **`pm John Meet me later.`** - Send a private message (modern era)

  ## Speaking Commands

  ### Say

  The most basic form of communication. Everyone in the room hears what you say.

  ```
  say Hello everyone!          → Alice says, "Hello everyone!"
  "Hello everyone!             → (same, using shortcut)
  say quietly I have a secret. → Alice says quietly, "I have a secret."
  ```

  **Aliases by tone:**
  | Command | Tone |
  |---------|------|
  | `say` | Normal speech |
  | `yell` / `shout` | Loud, forceful |
  | `mutter` / `grumble` | Quiet, displeased |
  | `scream` | Very loud, emotional |
  | `whisper` (alias) | Soft, quiet |
  | `murmur` | Soft, indistinct |
  | `flirt` | Playful, romantic |
  | `lecture` | Instructive, formal |
  | `confess` | Admitting something |

  ### Say To

  Speak directly to someone while others still hear you:

  ```
  say to John Hello!           → Alice says to John, "Hello!"
  tell John privately I agree. → Alice tells John privately, "I agree."
  ```

  **Aliases:** `tell`, `order`, `instruct`, `beg`, `demand`, `tease`, `mock`, `taunt`

  ### Whisper

  Private speech that only the target can hear. Others see that you whispered but not what you said:

  ```
  whisper John I know your secret.
  ```

  Others in the room see: *"Alice whispers something to John."*

  ## Emoting (Actions)

  Express what your character does, not just what they say:

  ```
  emote waves at everyone.     → Alice waves at everyone.
  :smiles warmly.              → Alice smiles warmly.
  pose stretches and yawns.    → Alice stretches and yawns.
  ```

  **Including speech in emotes:**
  Use quotation marks to include dialogue, which will appear in your character's speech color:

  ```
  emote nods and says, "I understand."
  ```

  **Adverb support:**
  ```
  emote sadly looks away.      → Alice sadly looks away.
  ```

  ### Think

  Express internal thoughts. These are visible to:
  - Yourself
  - Characters observing you
  - Telepaths reading your mind

  ```
  think I wonder what she means...
  ponder the mysteries of the universe
  worry about the future
  ```

  **Aliases:** `hope`, `ponder`, `wonder`, `worry`, `wish`, `feel`, `remember`

  ## Private Communication

  ### Private Message (PM)

  Send a private message to someone in the room:

  ```
  pm John Meet me at the dock at midnight.
  ```

  **Era Awareness:**
  - **Medieval era**: PMs are blocked (no instant messaging technology)
  - **Modern+ eras**: Uses phone/device (others may see you using your phone)

  ### Say Through

  Speak through a door or exit to an adjacent room:

  ```
  say through north, Is anyone there?
  yell through door, Open up!
  ```

  The adjacent room will hear: *"Someone yells from the south, 'Open up!'"*

  ### Knock

  Alert people in an adjacent room without speaking:

  ```
  knock north
  knock bedroom door
  ```

  ## Written Communication

  ### Memos / Letters

  Send written messages that can reach characters even when they're offline:

  ```
  send memo Alice Meeting tomorrow=Don't forget our meeting at noon!
  send letter Bob Important news=I have something to tell you.
  ```

  **Format:** `send memo <recipient> <subject>=<body>`

  **Era Awareness:**
  - **Medieval/Gaslight eras**: Messages are delivered by courier with realistic delay
  - **Modern+ eras**: Instant delivery

  **Reading and managing memos:**
  ```
  read memo           → List all received memos
  read memo 1         → Read memo #1
  delete memo 2       → Delete memo #2
  delete memo all     → Clear your inbox
  ```

  ### Bulletins

  Post public notices to the bulletin board:

  ```
  write bulletin Looking for adventurers! Meet at the tavern at dusk.
  bulletin                  → Read the bulletin board
  delete bulletin           → Remove your bulletin
  ```

  Each character can have one bulletin at a time. Bulletins expire after 10 days.

  ## The Consent System

  Some physical actions require the target's permission. Use the **attempt** system:

  ```
  attempt Alice hugs warmly.
  ```

  Alice receives a prompt asking if she accepts. She can respond with:
  - **`yes`** (or `accept`, `allow`) - The action happens as you described
  - **`no`** (or `deny`, `reject`) - The action is declined privately

  This ensures that physical interactions are consensual and comfortable for all players.

  ## Phone Numbers

  In modern eras, you can exchange phone numbers:

  ```
  give number to John         → Share your phone number
  ```

  ## Blocking and Privacy

  You can control who can communicate with you through the social system:

  - **Block DMs**: Prevent someone from sending you private messages
  - **Block interaction**: Prevent physical attempts
  - **Block perception**: Someone can't describe or target you

  See the Social System documentation for more details.

  ## Tips & Tricks

  1. **Use shortcuts**: `"` for say, `:` for emote
  2. **Add adverbs**: "say quietly" or "emote sadly" for flavor
  3. **Mix speech and action**: Include quotes in emotes for colored dialogue
  4. **Be era-aware**: Medieval characters can't text each other
  5. **Use whisper for secrets**: Others see you whispered but not what
  6. **Check your memos**: Use `read memo` regularly for offline messages
  7. **Consent matters**: Use `attempt` for physical contact with others
MARKDOWN

COMMUNICATION_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Communication System is built around several core services that handle message routing, formatting, and persistence. Messages flow from command execution through services to broadcast distribution, with hooks for IC logging, TTS queuing, and Discord notifications.

  ## Service Architecture

  ### BroadcastService

  **File:** `app/services/broadcast_service.rb`

  The central message distribution hub. All room-level communication passes through here.

  **Key Methods:**
  - `to_room(room_id, message, exclude:, type:, **metadata)` - Broadcast to all in room
  - `to_character(character_instance, message, type:, **metadata)` - Direct to character
  - `to_observers(observed_character, message, type:)` - To all observers of a character
  - `to_room_with_staff_vision(room_id, message, **options)` - Room + staff monitoring
  - `to_staff_vision(room, message, type:)` - Staff with vision enabled only

  **Auto-logging types (IC Log):**
  `say`, `emote`, `whisper`, `room_desc`, `movement`, `combat`, `action`, `departure`, `arrival`, `think`, `attempt`, `private_message`

  **TTS content types (accessibility):**
  `say`, `say_to`, `emote`, `whisper`, `system`, `room`, `combat`, `action`, `departure`, `arrival`, `think`, `attempt`, `private_message`, `message`, `broadcast`, `narrator`

  ### EmoteParserService

  **File:** `app/services/emote_parser_service.rb`

  Parses emotes into speech and action segments by splitting on quotation marks.

  ```ruby
  EmoteParserService.parse('Alice says, "Hello!" warmly.')
  # => [
  #   { type: :action, text: 'Alice says, ' },
  #   { type: :speech, text: 'Hello!' },
  #   { type: :action, text: ' warmly.' }
  # ]
  ```

  ### EmoteFormatterService

  **File:** `app/services/emote_formatter_service.rb`

  Applies speech coloring and personalized name substitution based on viewer knowledge.

  **Key behavior:**
  - Speech in quotes: Wrapped in speaker's `speech_color`
  - Character names: Replaced with viewer's known name for that character
  - Word-boundary aware to avoid partial replacements

  ### MessengerService

  **File:** `app/services/messenger_service.rb`

  Handles delayed message delivery for medieval/gaslight eras with courier mechanics.

  **Era-specific delays:**
  - Medieval: 5 min base + 30s per room distance (same area only)
  - Gaslight: 1 min base + 2 min per area distance (world-wide telegram)

  **Delivery flow:**
  1. `send_message()` creates Memo record
  2. Recipient is notified immediately (modern era)

  ## Data Models

  ### Memo
  **Table:** `memos`

  Letters/emails between characters.

  | Column | Type | Purpose |
  |--------|------|---------|
  | `char_id` | integer | Recipient character ID |
  | `from_id` | integer | Sender character ID |
  | `msubject` | string | Subject line (max 200) |
  | `mtext` | text | Body content |
  | `has_read` | boolean | Read status |
  | `sent_date` | timestamp | When sent |

  ### Message
  **Table:** `messages`

  Real-time room messages for persistence and logging.

  | Column | Type | Purpose |
  |--------|------|---------|
  | `content` | text | Message text (max 1000) |
  | `message_type` | string | say, emote, whisper, etc. |
  | `character_instance_id` | integer | Sender |
  | `target_character_instance_id` | integer | For targeted messages |
  | `room_id` | integer | Where message was said |
  | `reality_id` | integer | Reality segregation |

  **Message types:** `say`, `say_to`, `tell`, `emote`, `system`, `ooc`, `broadcast`, `whisper`, `private_message`

  ### Bulletin
  **Table:** `bulletins`

  Public notice board.

  | Column | Type | Purpose |
  |--------|------|---------|
  | `character_id` | integer | Who posted |
  | `body` | text | Content (max 2000) |
  | `from_text` | string | Cached poster name |
  | `posted_at` | timestamp | When posted |

  **Limits:** 15 bulletins displayed, 10-day expiration, one per character.

  ### Relationship
  **Table:** `relationships`

  Controls communication permissions between characters.

  **Block types:** `block_dm`, `block_ooc`, `block_channels`, `block_interaction`, `block_perception`

  ## Data Flow

  ### Say Command Flow

  ```
  say command
    → Parse adverb (AdverbHelper)
    → Check gag status (character.gagged?)
    → Check duplicate (Message.where recent)
    → Create Message record
    → BroadcastService.to_room()
        → IC Logging (RpLoggingService)
        → TTS Queue (TtsQueueService)
        → Discord notifications (if mentions)
    → Return structured response
  ```

  ### Emote Command Flow

  ```
  emote command
    → Parse adverb
    → EmoteParserService.parse() (split speech/action)
    → For each viewer:
        → EmoteFormatterService.format_for_viewer()
            → Apply speech color to quotes
            → Replace names with known names
        → TtsNarrationService.narrate_emote()
    → BroadcastService.to_room() with personalized messages
  ```

  ### Memo Delivery Flow

  ```
  send memo command
    → Create Memo record
    → Notify recipient if online
    → Send Discord notification
  ```

  ## TTS Integration

  The Communication System integrates with the Text-to-Speech accessibility feature.

  **Services:**
  - `TtsService` - Google Cloud TTS synthesis (Chirp 3 HD, 30 voices)
  - `TtsQueueService` - Sequential audio queue management
  - `TtsNarrationService` - Routes content to appropriate voices

  **Voice assignment:**
  - Speech (say, whisper): Uses speaker's character voice
  - Actions (emote, think): Uses narrator voice
  - System messages: Uses narrator voice

  **Configuration:**
  - 14 female voices, 16 male voices available
  - Pitch range: -20.0 to +20.0
  - Speed range: 0.25x to 4.0x
  - Audio cleanup after 60 minutes

  ## Common Modifications

  ### Adding a new speech verb

  1. Add alias in `plugins/core/communication/commands/say.rb`
  2. The verb is automatically used in output

  ### Changing message limits

  - Memo subject: `Memo` model validation (currently 200 chars)
  - Message content: `Message` model validation (currently 1000 chars)
  - Bulletin body: `Bulletin` model validation (currently 2000 chars)

  ### Adding new message type

  1. Add type to `Message::MESSAGE_TYPES`
  2. Call `IcActivityService.record` from the command if the content is story-worthy
  3. Add to `BroadcastService::TTS_CONTENT_TYPES` if should be narrated

  ### Modifying delivery delays

  Edit constants in `MessengerService`:
  - `MEDIEVAL_BASE_DELAY` (default: 300 seconds)
  - `MEDIEVAL_PER_ROOM_DELAY` (default: 30 seconds)
  - `GASLIGHT_BASE_DELAY` (default: 60 seconds)
  - `GASLIGHT_PER_AREA_DELAY` (default: 120 seconds)

  ## Debugging Tips

  1. **Enable broadcast logging**: Set `LOG_BROADCASTS=true` or run in development mode
  2. **Check message persistence**: Query `Message.for_room(room_id, reality_id).recent`
  3. **Debug TTS**: Check `AudioQueueItem` records for pending audio
  4. **Test formatting**: Call `EmoteFormatterService.format_for_viewer()` directly in console
MARKDOWN

COMMUNICATION_QUICK_REFERENCE = <<~MARKDOWN
  ## Quick Reference

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `say` / `"` | `say <message>` | Speak to the room |
  | `emote` / `:` | `emote <action>` | Perform an action |
  | `say to` | `say to <name> <msg>` | Speak to someone (all hear) |
  | `whisper` | `whisper <name> <msg>` | Private speech (others see action) |
  | `pm` | `pm <name> <msg>` | Private message (modern era) |
  | `think` | `think <thought>` | Internal thought (observers see) |
  | `say through` | `say through <exit>, <msg>` | Speak to adjacent room |
  | `knock` | `knock <direction>` | Alert adjacent room |
  | `attempt` | `attempt <name> <action>` | Request consent for action |
  | `yes` / `no` | `yes` | Accept/deny consent request |
  | `send memo` | `send memo <name> <subj>=<body>` | Send offline message |
  | `read memo` | `read memo [#]` | Read received memos |
  | `delete memo` | `delete memo <#/all>` | Delete memos |
  | `bulletin` | `bulletin` | Read bulletin board |
  | `write bulletin` | `write bulletin <msg>` | Post to bulletin board |
  | `give number` | `give number <name>` | Share phone number |
  | `pemit` | `pemit <names> = <msg>` | Staff: private emit |

  **Adverbs:** Add after command (e.g., `say quietly Hello`)

  **Era restrictions:**
  - Medieval: No PM, memos delivered by courier
  - Gaslight: Telegrams with delay
  - Modern+: Instant everything
MARKDOWN

COMMUNICATION_CONSTANTS = {
  message_limits: {
    MEMO_SUBJECT_MAX: { value: 200, file: 'app/models/memo.rb', purpose: 'Maximum memo subject length' },
    MESSAGE_CONTENT_MAX: { value: 1000, file: 'app/models/message.rb', purpose: 'Maximum message content length' },
    BULLETIN_BODY_MAX: { value: 2000, file: 'app/models/bulletin.rb', purpose: 'Maximum bulletin body length' },
    BULLETIN_DISPLAY_MAX: { value: 15, file: 'app/models/bulletin.rb', purpose: 'Maximum bulletins shown' },
    BULLETIN_EXPIRATION_DAYS: { value: 10, file: 'app/models/bulletin.rb', purpose: 'Days before bulletin expires' }
  },
  messenger_delays: {
    MEDIEVAL_BASE_DELAY: { value: 300, file: 'app/services/messenger_service.rb', purpose: '5 minutes minimum (medieval)' },
    MEDIEVAL_PER_ROOM_DELAY: { value: 30, file: 'app/services/messenger_service.rb', purpose: '30 seconds per room distance' },
    GASLIGHT_BASE_DELAY: { value: 60, file: 'app/services/messenger_service.rb', purpose: '1 minute minimum (gaslight)' },
    GASLIGHT_PER_AREA_DELAY: { value: 120, file: 'app/services/messenger_service.rb', purpose: '2 minutes per area distance' }
  },
  tts_config: {
    MAX_TEXT_LENGTH: { value: 5000, file: 'app/services/tts_service.rb', purpose: 'Max characters for TTS' },
    AUDIO_CLEANUP_MINUTES: { value: 60, file: 'app/services/tts_service.rb', purpose: 'Auto-delete audio after' },
    DEFAULT_VOICE: { value: 'Kore', file: 'app/services/tts_service.rb', purpose: 'Default narrator voice' },
    VOICE_COUNT: { value: 30, file: 'app/services/tts_service.rb', purpose: 'Total available voices (14F/16M)' }
  },
  message_types: {
    IC_STORY_TYPES: 'Callers decide what is story-worthy via IcActivityService.record (no whitelist)',
    TTS_CONTENT_TYPES: ['say', 'say_to', 'emote', 'whisper', 'system', 'room', 'combat', 'action', 'departure', 'arrival', 'think', 'attempt', 'private_message', 'message', 'broadcast', 'narrator']
  }
}.freeze

puts "\n[Communication System]"
seed_system('communication', {
  display_name: 'Communication System',
  summary: 'Speak, emote, whisper, and send messages to other characters',
  description: 'The Communication System handles all forms of character interaction through speech, actions, private messages, and written correspondence. It supports adverb modifiers, consent-based actions, era-aware messaging, and accessibility features like TTS.',
  player_guide: COMMUNICATION_PLAYER_GUIDE,
  staff_guide: COMMUNICATION_STAFF_GUIDE,
  quick_reference: COMMUNICATION_QUICK_REFERENCE,
  constants_json: COMMUNICATION_CONSTANTS,
  command_names: %w[say emote think say\ to whisper pm say\ through knock attempt yes no send\ memo read\ memo delete\ memo bulletin write\ bulletin delete\ bulletin give\ number pemit],
  related_systems: %w[social events],
  key_files: [
    'app/services/broadcast_service.rb',
    'app/services/emote_parser_service.rb',
    'app/services/emote_formatter_service.rb',
    'app/services/messenger_service.rb',
    'app/services/tts_service.rb',
    'app/services/tts_queue_service.rb',
    'app/services/tts_narration_service.rb',
    'app/models/memo.rb',
    'app/models/message.rb',
    'app/models/bulletin.rb',
    'plugins/core/communication/commands/'
  ],
  staff_notes: 'BroadcastService is the central message hub. EmoteFormatter applies speech colors and name substitution per-viewer. MessengerService handles era-aware delayed delivery. TTS integration provides accessibility narration.',
  display_order: 20
})

# =============================================================================
# COMBAT SYSTEM
# =============================================================================

COMBAT_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Combat System brings tactical turn-based fighting to the game. Whether you're dueling a rival, fighting off bandits, or coordinating with allies in a desperate battle, combat is a strategic, segment-based affair where every decision matters.

  Fights happen on an optional hex grid where positioning, movement, and range all affect the outcome. Each round, you choose your actions—attack, defend, use abilities, or move—and once everyone has decided, the round resolves with a detailed narrative.

  ## Key Concepts

  - **Rounds**: Combat is divided into rounds. Each round, you choose your actions, then the round resolves.
  - **Segments**: Rounds are divided into 100 segments. Actions happen at different segments (faster weapons act earlier).
  - **HP (Health Points)**: Your health. Most characters start with 6 HP. Reach 0 and you're knocked out.
  - **Willpower Dice**: Earn these by taking damage or surviving rounds. Spend them for powerful bonuses.
  - **Hex Grid**: Combat uses a hex-based map for positioning. Distance affects ranged attacks and movement.
  - **Actions**: Each round you choose a main action, tactical action, and movement.

  ## Getting Started

  ### Starting a Fight

  ```
  fight Bob          → Start a fight with Bob
  attack goblin      → Attack the goblin (starts fight if not in one)
  ```

  ### Combat Flow

  1. **Choose Actions**: After joining a fight, you'll see a menu of choices
  2. **Select Target**: Pick who you're attacking
  3. **Add Tactics**: Choose defensive boosts or abilities
  4. **Movement**: Decide whether to move toward enemies, away, or hold position
  5. **Submit**: Type `done` when ready
  6. **Resolution**: Once everyone submits, the round resolves

  ## Combat Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `fight` | `fight <target>` | Start a fight with someone |
  | `attack` | `attack [target]` | Attack (changes target if in fight) |
  | `combat` | `combat [status/enemies/allies]` | Get combat information |
  | `done` | `done` | Submit your choices for the round |

  ### Combat Info Subcommands

  ```
  combat              → Full combat status
  combat enemies      → List all enemies with HP and distance
  combat allies       → List all allies
  combat recommend    → AI recommendation for best target
  combat actions      → Show available actions
  combat help         → Combat command reference
  ```

  ## Main Actions

  Each round, choose one main action:

  | Action | Description |
  |--------|-------------|
  | **Attack** | Attack with your weapon |
  | **Defend** | Full defense, gain defensive bonuses |
  | **Dodge** | -5 to incoming attacks this round |
  | **Sprint** | +3 movement (7 total), but no attack |
  | **Pass** | No action (fight ends if everyone passes) |
  | **Ability** | Use a combat ability |

  ## Tactical Actions

  In addition to your main action, choose a tactical action:

  | Action | Effect |
  |--------|--------|
  | **Damage Boost** | +1 to all damage rolls |
  | **Movement Boost** | +1 movement per step |
  | **Defense Boost** | -1 incoming damage |
  | **Tactical Ability** | Use a tactical ability |

  ## Movement Options

  Decide how to move during the round:

  | Option | Description |
  |--------|-------------|
  | **Stand Still** | Hold your position |
  | **Move Toward** | Close distance to a target |
  | **Move Away** | Retreat from a target |
  | **Maintain Distance** | Keep optimal range (default 6 hexes) |

  ## Willpower System

  You earn willpower dice as the fight goes on:
  - **+0.5 dice per round** (passive)
  - **+0.25 dice per HP lost** (from taking damage)
  - **Maximum 3 dice** at any time

  Spend willpower for bonuses:
  - **Attack**: +2 per die, explodes on 8
  - **Defense**: 1d8 per die, explodes on 8
  - **Ability**: +2 per die to ability damage

  ## Weapons & Range

  Weapons have two key stats:
  - **Speed**: Faster weapons attack more times per round
  - **Range**: Melee (1 hex), Ranged (longer reach)

  You can select:
  - **Melee Weapon**: For close combat
  - **Ranged Weapon**: For distance fighting
  - The system automatically uses the right weapon based on distance

  ## HP and Damage

  Damage is calculated based on attack rolls versus defense:

  | Damage Roll | HP Lost |
  |-------------|---------|
  | 10 or less | Miss (0 HP) |
  | 11-15 | 1 HP |
  | 16-24 | 2 HP |
  | 25+ | 3 HP |

  **Wound Penalty**: For each HP lost, you get -1 to all rolls (but thresholds also drop, helping comebacks).

  ## Abilities

  Combat abilities add special effects to fighting:

  - **Main Abilities**: Replace your attack (e.g., Fireball)
  - **Tactical Abilities**: Supplement your action (e.g., Defensive Ward)
  - **Targeting**: Self, ally, or enemy
  - **AoE**: Some abilities hit multiple targets (circle, cone, line)
  - **Cooldowns**: Abilities may have cooldowns before reuse

  ## Battle Map Features

  If the room has a battle map, these additional mechanics apply:

  - **Cover**: +2 to +4 defense bonus depending on direction
  - **Elevation**: Higher ground gives attack bonuses
  - **Hazards**: Fire, electricity, spikes—avoid or take damage
  - **Line of Sight**: Blocked LoS applies -4 penalty

  ## Tips & Tricks

  1. **Submit early**: Type `done` once you've made your choices
  2. **Use `combat` command**: Screen-reader friendly combat status
  3. **Watch your HP**: Wound penalties stack quickly
  4. **Save willpower**: Spend it when it matters most
  5. **Position matters**: Stay at optimal range for your weapon
  6. **Coordinate**: Communicate with allies about targets
  7. **Know when to retreat**: Sprint away if overwhelmed
MARKDOWN

COMBAT_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Combat System is built around a segment-based round structure where all participants submit actions before resolution. The system supports hex-grid positioning, abilities with AoE effects, status effects with stacking, and AI-controlled NPC behavior.

  ## Core Services

  ### FightService

  **File:** `app/services/fight_service.rb`

  Manages the fight lifecycle from initiation to completion.

  **Key Methods:**
  - `start_fight(room, initiator, target)` - Creates or joins existing fights
  - `add_participant(character_instance)` - Registers character, loads weapons
  - `process_choice(participant, stage, choice)` - Routes input through stages
  - `resolve_round!()` - Orchestrates round resolution
  - `next_round!()` - Advances round, resets state
  - `end_fight!()` - Marks fight complete

  **Constants:**
  - `INPUT_TIMEOUT_SECONDS = 480` (8 minutes)
  - `STALE_TIMEOUT_SECONDS = 900` (15 minutes)

  ### CombatResolutionService

  **File:** `app/services/combat_resolution_service.rb`

  Handles damage calculation and round resolution using the 100-segment system.

  **Resolution Flow:**
  1. Schedule all attacks based on weapon speed
  2. Schedule abilities at configured segments
  3. Schedule movement at segment 50
  4. Process events in segment order
  5. Apply accumulated damage
  6. Check for knockouts

  **Attack Modifiers Applied:**
  - Base roll: 2d8 exploding on 8 (or NPC custom dice)
  - Stat modifier: STR (melee) or DEX (ranged)
  - Wound penalty: -1 per HP lost
  - Willpower attack bonus: +2 per die
  - Status effect penalties
  - Tactical bonuses/penalties
  - Dodge: -5 to incoming attacks
  - Battle map modifiers (elevation, cover, LoS)

  ### CombatAIService

  **File:** `app/services/combat_ai_service.rb`

  Controls NPC and AFK player combat decisions.

  **AI Profiles:**
  | Profile | Attack | Defend | Flee | Target Strategy |
  |---------|--------|--------|------|-----------------|
  | Aggressive | 0.8 | 0.1 | 0.1 | Weakest |
  | Defensive | 0.4 | 0.5 | 0.3 | Threat |
  | Balanced | 0.6 | 0.3 | 0.2 | Closest |
  | Berserker | 0.95 | 0.0 | 0.0 | Weakest |
  | Coward | 0.3 | 0.4 | 0.5 | Random |
  | Guardian | 0.5 | 0.6 | 0.15 | Threat |

  ### AbilityProcessorService

  **File:** `app/services/ability_processor_service.rb`

  Processes ability usage including AoE targeting and damage application.

  **AoE Shapes:**
  - `single` - One target
  - `circle` - Radius from target center
  - `cone` - Spreads from actor toward target
  - `line` - Projects through target

  **Processing:**
  1. Resolve targets based on AoE shape
  2. Process damage/healing for each target
  3. Apply status effects
  4. Apply ability costs (cooldowns, penalties)

  ## Data Models

  ### Fight
  **Table:** `fights`

  | Column | Purpose |
  |--------|---------|
  | room_id | Where combat occurs |
  | round_number | Current round (starts 1) |
  | status | input/resolving/narrative/complete |
  | arena_width/height | Grid dimensions (default 10x10) |
  | round_events | JSONB event log |

  **States:**
  - `input` - Accepting player choices
  - `resolving` - Processing round
  - `narrative` - Generating description
  - `complete` - Fight ended

  ### FightParticipant
  **Table:** `fight_participants`

  Tracks each combatant's state, choices, and resources.

  **HP System:**
  - `current_hp` / `max_hp` (typically 6)
  - `wound_penalty` = max_hp - current_hp

  **Willpower System:**
  - `willpower_dice` - Fractional pool (e.g., 2.5)
  - Gains: +0.5/round, +0.25/HP lost
  - Maximum: 3.0 dice

  **Positioning:**
  - `hex_x` / `hex_y` - Grid coordinates

  **Actions (per round):**
  - `main_action` - attack/defend/ability/dodge/pass/sprint
  - `tactical_action` - damage_boost/movement_boost/defense_boost
  - `movement_action` - move_to_hex/towards_person/stand_still/away_from

  **Ability Tracking:**
  - `ability_cooldowns` - JSONB `{"fireball": 2}`
  - `global_ability_cooldown` - All abilities blocked
  - `roll_penalties` - JSONB decay structure

  ### Ability
  **Table:** `abilities`

  **Key Fields:**
  - `ability_type` - combat/utility/passive/social/crafting
  - `action_type` - main/tactical/free/passive/reaction
  - `target_type` - self/ally/enemy
  - `aoe_shape` - single/circle/cone/line
  - `base_damage_dice` - "2d8", "1d6+2"
  - `damage_type` - fire/ice/lightning/physical/holy/shadow/poison/healing

  **Cost Structure (JSONB):**
  ```ruby
  {
    "ability_penalty": { "amount": -6, "decay_per_round": 2 },
    "all_roll_penalty": { "amount": -4, "decay_per_round": 1 },
    "specific_cooldown": { "rounds": 3 },
    "global_cooldown": { "rounds": 1 }
  }
  ```

  ### StatusEffect
  **Table:** `status_effects`

  **Effect Types:** movement, incoming_damage, outgoing_damage, healing, stat_modifier

  **Stacking Behaviors:**
  - `refresh` - Resets duration
  - `stack` - Accumulates (multiplies modifier)
  - `ignore` - Only one active

  ## Battle Map Integration

  ### BattleMapCombatService

  **File:** `app/services/battle_map_combat_service.rb`

  **Cover System:**
  - Full cover: +4 defense from covered direction
  - Half cover: +2 defense from adjacent directions
  - Directional: NE, E, SE, SW, W, NW

  **Elevation Modifiers:**
  - Higher: +1 per level (max +2 attack)
  - Lower: -1 per level (max -2 attack)
  - +2 ranged damage when 2+ levels higher

  **Hazard Types:**
  fire, electricity, sharp, gas, poison, spike_trap, pressure_plate, unstable_floor

  ### CombatPathfindingService

  **File:** `app/services/combat_pathfinding_service.rb`

  A* pathfinding with hazard avoidance costs:
  - `ignore` - 1.0 (treat as normal)
  - `low` - 5.0 (will path through if needed)
  - `moderate` - 15.0 (prefer to avoid)
  - `high` - 50.0 (strongly avoid)

  Max path length: 50 hexes

  ## Damage Calculation

  ### Damage Thresholds

  Base thresholds (adjusted by wound penalty):
  | Damage Roll | HP Lost |
  |-------------|---------|
  | ≤ 10 | 0 (miss) |
  | 11-15 | 1 HP |
  | 16-24 | 2 HP |
  | 25+ | 3 HP |

  Thresholds drop by 1 per HP already lost (comeback mechanic).

  ### Dice Mechanics

  - Attack rolls: 2d8 exploding on 8 (PCs) or NPC custom dice
  - Willpower defense: Xd8 exploding on 8
  - Ability damage: Configured per ability

  ## Segment System

  Rounds are 100 segments. Events scheduled:
  - Attacks: Based on weapon speed (speed 10 = evenly spread)
  - Movement: Segment 50 ± 2
  - Abilities: Configured activation_segment ± variance

  ## Common Modifications

  ### Changing Damage Thresholds

  Modify `FightParticipant#damage_thresholds`:
  ```ruby
  { miss: 10 - wound_penalty, one_hp: 15 - wound_penalty, ... }
  ```

  ### Adding New AI Profile

  Add to `CombatAIService::AI_PROFILES`:
  ```ruby
  TACTICIAN: { attack_weight: 0.7, defend_weight: 0.4, ... }
  ```

  ### Creating New Status Effects

  1. Add record to `status_effects` table
  2. Set effect_type and mechanics JSONB
  3. Configure stacking behavior

  ### Adding New Ability

  1. Create Ability record with costs and damage config
  2. Link to universe for availability
  3. Configure AoE if needed

  ## Debugging Tips

  1. **Check fight state**: `Fight[id].status` and `round_number`
  2. **View participant choices**: `FightParticipant.where(fight_id: id).all`
  3. **Debug AI decisions**: Add logging to `CombatAIService#decide!`
  4. **Test damage**: Call `FightParticipant#calculate_hp_from_damage(roll)`
  5. **Verify abilities**: Check `ability_cooldowns` and `global_ability_cooldown`
  6. **Review events**: `FightEvent.where(fight_id: id).order(:segment)`
MARKDOWN

COMBAT_QUICK_REFERENCE = <<~MARKDOWN
  ## Quick Reference

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `fight` | `fight <target>` | Start a fight |
  | `attack` | `attack [target]` | Attack or change target |
  | `combat` | `combat [status/enemies/allies]` | Combat status |
  | `done` | `done` | Submit round choices |

  **Main Actions:** attack, defend, dodge, sprint, pass, ability

  **Tactical Actions:** damage_boost (+1 dmg), movement_boost (+1 move), defense_boost (-1 incoming)

  **Movement:** stand_still, towards_person, away_from, maintain_distance

  **Willpower:**
  - +0.5/round, +0.25/HP lost, max 3.0
  - Spend: +2 attack, 1d8 defense, +2 ability per die

  **Damage Thresholds:**
  | Roll | HP Lost |
  |------|---------|
  | ≤10 | 0 |
  | 11-15 | 1 |
  | 16-24 | 2 |
  | 25+ | 3 |

  **Wound Penalty:** -1 per HP lost
MARKDOWN

COMBAT_CONSTANTS = {
  timing: {
    INPUT_TIMEOUT_SECONDS: { value: 480, file: 'app/services/fight_service.rb', purpose: '8 minutes for player input' },
    STALE_TIMEOUT_SECONDS: { value: 900, file: 'app/services/fight_service.rb', purpose: '15 minutes auto-cleanup' },
    MOVEMENT_SEGMENT: { value: 50, file: 'app/services/combat_resolution_service.rb', purpose: 'Movement happens at segment 50' },
    ROUND_SEGMENTS: { value: 100, file: 'app/services/combat_resolution_service.rb', purpose: 'Total segments per round' }
  },
  damage: {
    MISS_THRESHOLD: { value: 10, file: 'app/models/fight_participant.rb', purpose: 'Damage ≤10 is a miss' },
    ONE_HP_THRESHOLD: { value: 15, file: 'app/models/fight_participant.rb', purpose: 'Damage 11-15 = 1 HP' },
    TWO_HP_THRESHOLD: { value: 24, file: 'app/models/fight_participant.rb', purpose: 'Damage 16-24 = 2 HP' },
    THREE_HP_MIN: { value: 25, file: 'app/models/fight_participant.rb', purpose: 'Damage 25+ = 3 HP' },
    DEFAULT_MAX_HP: { value: 6, file: 'app/models/fight_participant.rb', purpose: 'Default health points' }
  },
  willpower: {
    GAIN_PER_ROUND: { value: 0.5, file: 'app/services/fight_service.rb', purpose: 'Willpower gained each round' },
    GAIN_PER_HP_LOST: { value: 0.25, file: 'app/models/fight_participant.rb', purpose: 'Willpower from taking damage' },
    MAX_WILLPOWER: { value: 3.0, file: 'app/models/fight_participant.rb', purpose: 'Maximum willpower dice' },
    ATTACK_BONUS_PER_DIE: { value: 2, file: 'app/services/combat_resolution_service.rb', purpose: '+2 per willpower die on attack' },
    MAX_WILLPOWER_SPEND: { value: 2, file: 'app/services/combat_action_service.rb', purpose: 'Max dice per allocation' }
  },
  movement: {
    BASE_MOVEMENT: { value: 4, file: 'app/models/fight_participant.rb', purpose: 'Base hexes per round' },
    SPRINT_BONUS: { value: 3, file: 'app/models/fight_participant.rb', purpose: 'Extra hexes when sprinting' },
    MAINTAIN_DISTANCE_DEFAULT: { value: 6, file: 'app/models/fight_participant.rb', purpose: 'Default range to maintain' }
  },
  pathfinding: {
    MAX_PATH_LENGTH: { value: 50, file: 'app/services/combat_pathfinding_service.rb', purpose: 'Max hexes to search' },
    HAZARD_COST_IGNORE: { value: 1.0, file: 'app/services/combat_pathfinding_service.rb', purpose: 'Hazard avoidance: ignore' },
    HAZARD_COST_LOW: { value: 5.0, file: 'app/services/combat_pathfinding_service.rb', purpose: 'Hazard avoidance: low' },
    HAZARD_COST_MODERATE: { value: 15.0, file: 'app/services/combat_pathfinding_service.rb', purpose: 'Hazard avoidance: moderate' },
    HAZARD_COST_HIGH: { value: 50.0, file: 'app/services/combat_pathfinding_service.rb', purpose: 'Hazard avoidance: high' }
  },
  ai_profiles: {
    aggressive: { attack_weight: 0.8, defend_weight: 0.1, flee_threshold: 0.1, target_strategy: 'weakest' },
    defensive: { attack_weight: 0.4, defend_weight: 0.5, flee_threshold: 0.3, target_strategy: 'threat' },
    balanced: { attack_weight: 0.6, defend_weight: 0.3, flee_threshold: 0.2, target_strategy: 'closest' },
    berserker: { attack_weight: 0.95, defend_weight: 0.0, flee_threshold: 0.0, target_strategy: 'weakest' },
    coward: { attack_weight: 0.3, defend_weight: 0.4, flee_threshold: 0.5, target_strategy: 'random' },
    guardian: { attack_weight: 0.5, defend_weight: 0.6, flee_threshold: 0.15, target_strategy: 'threat' }
  }
}.freeze

puts "\n[Combat System]"
seed_system('combat', {
  display_name: 'Combat System',
  summary: 'Tactical turn-based fighting with hex grids, abilities, and willpower',
  description: 'The Combat System handles all fighting mechanics, from initiating battles to executing attacks. It uses a 100-segment round system with hex-grid positioning, abilities, status effects, and AI-controlled NPC behavior.',
  player_guide: COMBAT_PLAYER_GUIDE,
  staff_guide: COMBAT_STAFF_GUIDE,
  quick_reference: COMBAT_QUICK_REFERENCE,
  constants_json: COMBAT_CONSTANTS,
  command_names: %w[fight attack combat done],
  related_systems: %w[navigation inventory],
  key_files: [
    'app/services/fight_service.rb',
    'app/services/combat_resolution_service.rb',
    'app/services/combat_ai_service.rb',
    'app/services/ability_processor_service.rb',
    'app/services/battle_map_combat_service.rb',
    'app/services/combat_pathfinding_service.rb',
    'app/services/status_effect_service.rb',
    'app/services/combat_narrative_service.rb',
    'app/models/fight.rb',
    'app/models/fight_participant.rb',
    'app/models/ability.rb',
    'app/models/status_effect.rb',
    'plugins/core/combat/commands/'
  ],
  staff_notes: 'FightService manages lifecycle, CombatResolutionService handles damage. 100-segment round with scheduled events. AI profiles control NPC behavior. Willpower provides comeback mechanic. Battle maps add cover, elevation, hazards.',
  display_order: 30
})

# =============================================================================
# CHARACTER SYSTEM
# =============================================================================

CHARACTER_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Character System is the heart of your identity in the game. Your character has a persistent identity with names, descriptions, appearances, and statistics that define who they are. Whether you're customizing how you appear to others, building your stats, or viewing information about other characters, this system handles it all.

  Characters exist at two levels: the **persistent Character** (your account's character with default descriptions, names, and settings) and the **Character Instance** (your active session in a specific reality, which tracks temporary state like health, position, and current descriptions).

  ## Key Concepts

  - **Full Name**: Your character's forename and optional surname. Name changes have a 21-day cooldown.
  - **Nickname**: A shorter name you can change at any time without cooldown.
  - **Handle**: Your formatted display name with colors and styles.
  - **Short Description**: A brief description others see when looking at the room.
  - **Roomtitle**: What you're doing (e.g., "looking thoughtful by the window").
  - **Body Descriptions**: Detailed descriptions for different body parts (head, torso, arms, etc.).
  - **Stats**: Numeric values for attributes like Strength, Agility, Intelligence, etc.
  - **Shapes**: Different forms your character can take (humanoid, animal, etc.).
  - **Appearances**: Disguises within a shape.

  ## Getting Started

  When you first create a character, you'll set up basic information. Here's how to customize further:

  1. **`score`** - View your current statistics and abilities
  2. **`profile`** - View your own profile or another character's
  3. **`customize description <text>`** - Set your short description
  4. **`customize roomtitle <text>`** - Set what you're doing in the room
  5. **`handle`** - View or set your formatted display name

  ## Customization Commands

  ### Names and Handles

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `handle` | `handle` | View your current handle |
  | `handle <formatted>` | `handle <b>Alice</b>` | Set handle with HTML/colors |
  | `change name nickname <name>` | `change name nickname Bobby` | Change nickname (no cooldown) |
  | `change name forename <name>` | `change name forename Robert` | Change first name (21-day cooldown) |
  | `change name surname <name>` | `change name surname Smith` | Change last name (21-day cooldown) |

  **Handle Formatting**: Your handle can include HTML/CSS for colors and styles, but the stripped text must match your full name.

  **Name Change Cooldown**: Forename and surname changes are limited to once every 21 days to prevent identity confusion.

  ### Profile Customization

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `customize description <text>` | `customize description A tall figure with silver hair` | Short description (max 300 chars) |
  | `customize roomtitle <text>` | `customize roomtitle lost in thought` | Room activity (max 200 chars) |
  | `customize picture <url>` | `customize picture https://example.com/pic.jpg` | Profile picture URL |

  The `change` command is an alias for `customize`.

  ### Color Gradients

  Apply beautiful color gradients to text:

  ```
  gradient christmas Hello World
  gradient #ff0000,#00ff00 Merry Christmas
  gradient #ff0000,#ffff00,#00ff00 Rainbow text
  ```

  **Named Gradients**: Use saved gradient names for quick access.
  **Custom Gradients**: Specify hex colors separated by commas.

  ## Viewing Characters

  ### Score Command

  `score` (aliases: `stats`, `status`) shows your character's statistics:

  - **Vitals**: Health, mana, status (alive/unconscious/dead)
  - **Level & Experience**: Current level and total XP
  - **Stats**: All allocated stats grouped by category
  - **Abilities**: Learned abilities with cooldown status
  - **Current State**: Stance, place, current room

  ### Profile Command

  `profile [character]` displays a character's profile:

  ```
  profile           - View your own profile
  profile Alice     - View Alice's profile (if public)
  ```

  Profile includes: name, race, class, gender, age, height, ethnicity, profile picture, and short description.

  ### Finger Command

  `finger <character>` (alias: `info`) gives detailed information:

  - Basic info (name, race, class, level)
  - Online status and last activity
  - Whether you know this character
  - Schedule overlap (best times to meet)

  ### Who Command

  `who [here|all]` lists online characters:

  ```
  who           - Characters in your current area
  who here      - Characters in your current room only
  who all       - All online characters globally
  ```

  ## Observation System

  Watch characters, places, or rooms for continuous updates:

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `observe <character>` | `observe Alice` | Start watching a character |
  | `observe me` | `observe me` | Examine yourself in detail |
  | `observe <place>` | `observe bar` | Watch a place |
  | `observe room` | `observe room` | Watch the entire room |
  | `observe stop` | `observe stop` | Stop observing |
  | `unwatch` | `unwatch` | Stop observing (same as above) |

  While observing, you receive detailed updates about your target's actions.

  ## Meeting Up

  Find the best times to meet other players:

  ```
  meetup Alice Bob       - Find best times for Alice and Bob
  meetup me              - View your own activity schedule
  ```

  The system analyzes activity patterns to suggest optimal meeting times.

  ## Body Descriptions

  Your character has multiple body regions for detailed descriptions:

  - **Head**: Face, hair, eyes, ears, etc.
  - **Torso**: Chest, back, shoulders, etc.
  - **Arms & Hands**: Arms, wrists, hands, fingers
  - **Legs & Feet**: Thighs, legs, feet, etc.

  Descriptions can be:
  - **Public**: Visible to everyone
  - **Private**: Only visible in private mode
  - **Concealed**: Hidden when covered by clothing

  ## Directory

  Find businesses and shops in your area:

  ```
  directory               - List all shops in area
  directory food          - List food-related shops
  directory clothing      - List clothing shops
  ```

  Aliases: `businesses`, `shops`, `yellowpages`

  ## Tips & Tricks

  1. **Quick Profile Picture**: Use `ppic <name>` to quickly view someone's picture
  2. **Save Gradients**: Create named gradients for reuse
  3. **Schedule Overlap**: Use `finger` to find good meeting times with other players
  4. **Nickname Freedom**: Change your nickname anytime without waiting
  5. **Observation Mode**: Observe yourself (`observe me`) for a detailed self-view
MARKDOWN

CHARACTER_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Character System uses a dual-model architecture separating persistent character data from session-specific instance data. This enables multi-reality support, timeline features, and session-specific modifications while maintaining a stable character identity.

  ### Model Hierarchy

  ```
  Character (persistent identity)
    ├─ CharacterInstance (one per reality, session data)
    │    ├─ CharacterDescription (session descriptions)
    │    ├─ CharacterStat (allocated stat values)
    │    └─ CharacterAbility (learned abilities)
    ├─ CharacterDefaultDescription (persistent descriptions)
    ├─ CharacterShape (forms: humanoid, animal, etc.)
    │    └─ Appearance (disguises within shape)
    └─ CharacterKnowledge (who knows whom)
  ```

  ### Key Models

  #### Character (app/models/character.rb)
  Persistent character identity with:
  - **Names**: forename, surname, nickname, handle_display
  - **Profile**: picture_url, short_desc, profile_visible, profile_score
  - **NPC Support**: is_npc, is_unique_npc, npc_archetype_id
  - **Voice Config**: voice_type, voice_pitch, voice_speed
  - **NPC Appearance**: npc_body_desc, npc_hair_desc, npc_eyes_desc, npc_skin_tone

  #### CharacterInstance (app/models/character_instance.rb)
  Session/reality-specific state with 80+ columns including:
  - **Core**: level, experience, health, max_health, mana, max_mana, status
  - **Position**: current_room_id, current_place_id, x, y, z, stance
  - **AFK/Presence**: afk, afk_until, semiafk, gtg_until, last_websocket_ping
  - **Observation**: observing_id, observing_place_id, observing_room
  - **Restraints**: is_helpless, hands_bound, feet_bound, is_gagged, is_blindfolded
  - **TTS**: tts_enabled, tts_paused, tts_narrate_speech/actions/rooms/system
  - **Cards**: current_deck_id, cards_faceup, cards_facedown
  - **Wetness**: wetness (0-100 scale)

  #### CharacterDescription vs CharacterDefaultDescription
  - **Default**: Persistent on Character, synced to instance on login
  - **Instance**: Session-specific, can be modified per session
  - **Sync**: DescriptionCopyService handles login synchronization

  ### Key Services

  #### CharacterDisplayService (app/services/character_display_service.rb)
  Builds comprehensive display data for player characters:
  - Delegates to NpcDisplayService for NPCs
  - Uses VisibilityService for privacy/exposure filtering
  - Returns structured hash with profile, descriptions, clothing, thumbnails

  #### StatAllocationService (app/services/stat_allocation_service.rb)
  Manages stat point allocation:
  - `create_stats_for_character()` - Create stats with validation
  - `get_stat_value()` - Lookup by name or abbreviation
  - `calculate_roll_modifier()` - Single/double-type roll bonuses

  #### GradientService (app/services/gradient_service.rb)
  Color gradient application:
  - **Fast mode**: Sharp sections per color
  - **Smooth mode**: Per-character interpolation
  - **CIEDE2000**: Perceptually uniform Lab color space
  - Handles RGB → XYZ → Lab → LCh conversions

  #### DescriptionCopyService (app/services/description_copy_service.rb)
  Login synchronization:
  - Copies CharacterDefaultDescription → CharacterDescription
  - Updates existing if content differs
  - Cleanup orphaned instance descriptions

  #### DescriptionUploadService (app/services/description_upload_service.rb)
  Image upload handling:
  - Validates type (JPEG, PNG, GIF, WebP)
  - Max 5MB file size
  - Header-based content type detection
  - Path traversal security checks

  #### VisibilityService (app/services/visibility_service.rb)
  Exposure and privacy logic:
  - Body position exposure based on clothing
  - Private content filtering
  - Clothing visibility by layer

  #### WardrobeService (app/services/wardrobe_service.rb)
  Wardrobe operations:
  - Vault access validation
  - Pattern-based item creation (50% cost)
  - Item fetching and equipping

  #### NpcSpawnService (app/services/npc_spawn_service.rb)
  NPC lifecycle management:
  - Schedule-based spawning/despawning
  - Unique vs template NPC spawning
  - Room-specific NPC queries

  ### Data Flows

  #### Character Login
  ```
  User logs in
    → Find/create CharacterInstance for reality
    → DescriptionCopyService.sync_on_login()
      → Copy active default descriptions
      → Update if content differs
    → Character ready with synced descriptions
  ```

  #### Look at Character
  ```
  look <character>
    → CharacterDisplayService.build_display()
      → Check npc? → delegate to NpcDisplayService
      → VisibilityService.filter_descriptions_for_privacy()
      → VisibilityService.visible_clothing_for_privacy()
      → Collect thumbnails from all sources
    → Format and display to viewer
  ```

  #### Stat Roll Calculation
  ```
  roll STR
    → StatAllocationService.calculate_roll_modifier()
      → Look up stat by name/abbreviation
      → Calculate modifier based on stat value
      → Return {modifier, stats_used, stat_block_type}
    → DiceRollService applies modifier to roll
  ```

  ### Commands Implementation

  | Command | File | Key Logic |
  |---------|------|-----------|
  | handle | customization/commands/handle.rb | Validates stripped HTML matches full name |
  | change name | customization/commands/change_name.rb | 21-day cooldown check via can_change_name? |
  | customize | customization/commands/customize.rb | Updates character or instance based on field |
  | gradient | customization/commands/gradient.rb | Uses GradientService.apply() |
  | score | info/commands/score.rb | Aggregates stats, abilities, vitals |
  | profile | info/commands/profile.rb | Uses CharacterDisplayService (simplified) |
  | finger | info/commands/finger.rb | Includes ActivityTrackingService for schedule |
  | who | info/commands/who.rb | Queries CharacterInstance.online scope |
  | observe | info/commands/observe.rb | Sets observing_id/place_id/room on instance |

  ### Configuration Points

  #### Name Change Cooldown
  - **Location**: Character model
  - **Value**: 21 days (NAME_CHANGE_COOLDOWN = 21 * 24 * 60 * 60)
  - **Applies to**: forename, surname (not nickname)

  #### Description Limits
  - **Short description**: 300 characters (customize command)
  - **Roomtitle**: 200 characters (customize command)
  - **Picture URL**: 500 characters (customize command)
  - **Nickname**: 50 characters (change name command)

  #### Image Upload Limits
  - **Max size**: 5MB (DescriptionUploadService)
  - **Allowed types**: JPEG, PNG, GIF, WebP
  - **Storage path**: public/uploads/descriptions/

  #### Stat Allocation
  - **Single-type bonus**: +0.5 modifier per extra stat
  - **Double-type bonus**: +0.25 modifier per extra stat in each category

  #### Gradient Colors
  - **D65 Reference White**: X=95.047, Y=100.0, Z=108.883
  - **Easing values**: 100=linear, >100=ease-in-out, <100=inverse

  #### Wardrobe
  - **Pattern cost multiplier**: 0.5 (50% of base price)

  ### Debugging Tips

  1. **Missing descriptions on login**: Check DescriptionCopyService.sync_on_login() return value
  2. **Stats not appearing**: Verify CharacterStat records exist for instance
  3. **Visibility issues**: Check VisibilityService with xray: true to bypass filters
  4. **NPC display wrong**: Verify is_npc flag and character.npc? method
  5. **Name change failing**: Check last_name_change timestamp and can_change_name? method
  6. **Gradient not applying**: Verify hex codes with GradientService.valid_hex?()

  ### Common Modifications

  1. **Add new body position**: Create BodyPosition record, update DescriptionCopyService
  2. **Change name cooldown**: Modify NAME_CHANGE_COOLDOWN in Character model
  3. **Add stat category**: Update StatBlock and StatAllocationService
  4. **New customization field**: Add to customize command and Character/Instance model
  5. **Modify visibility rules**: Update VisibilityService methods
MARKDOWN

CHARACTER_QUICK_REFERENCE = <<~MARKDOWN
  ## Customization Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `handle` | - | View/set formatted display name |
  | `change name` | - | Change nickname/forename/surname |
  | `customize` | `customise`, `change` | Set description, roomtitle, handle, picture |
  | `gradient` | `grad` | Apply color gradient to text |
  | `profilepic` | `ppic` | View character's profile picture |

  ## Information Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `score` | `stats`, `status` | View your statistics and abilities |
  | `profile` | `view profile` | View character profile |
  | `finger` | `info` | Detailed character info |
  | `who` | `where` | List online characters |
  | `directory` | `shops`, `businesses` | Find shops in area |
  | `observe` | `watch`, `o` | Monitor character/place/room |
  | `unwatch` | `stopwatch` | Stop observing |
  | `meetup` | `schedule`, `findtime` | Find meeting times |

  ## Quick Customization

  ```
  customize description <text>     - Max 300 chars
  customize roomtitle <text>       - Max 200 chars
  customize picture <url>          - Profile picture
  handle <formatted name>          - Colored/styled name
  change name nickname <name>      - No cooldown
  change name forename <name>      - 21-day cooldown
  change name surname <name>       - 21-day cooldown
  ```

  ## Gradient Examples

  ```
  gradient christmas Hello         - Named gradient
  gradient #ff0000,#0000ff Hi      - Red to blue
  gradient #ff0000,#00ff00,#0000ff - RGB rainbow
  ```

  ## Observation

  ```
  observe <character>    - Watch a character
  observe <place>        - Watch a place
  observe room           - Watch the room
  observe stop           - Stop observing
  ```

  ## Character Model Fields

  | Field | Max | Notes |
  |-------|-----|-------|
  | Forename | 50 | Required, titlecase |
  | Surname | 50 | Optional |
  | Nickname | 50 | No cooldown |
  | Short Desc | 300 | customize description |
  | Roomtitle | 200 | customize roomtitle |
  | Picture URL | 500 | HTTPS required |

  ## Cooldowns

  - **Name change**: 21 days (forename/surname only)
  - **Nickname**: No cooldown
MARKDOWN

CHARACTER_CONSTANTS = {
  name_limits: {
    NAME_CHANGE_COOLDOWN_DAYS: { value: 21, file: 'app/models/character.rb', purpose: 'Days between name changes' },
    FORENAME_MAX_LENGTH: { value: 50, file: 'app/models/character.rb', purpose: 'Maximum forename length' },
    SURNAME_MAX_LENGTH: { value: 50, file: 'app/models/character.rb', purpose: 'Maximum surname length' },
    NICKNAME_MAX_LENGTH: { value: 50, file: 'plugins/core/customization/commands/change_name.rb', purpose: 'Maximum nickname length' }
  },
  description_limits: {
    SHORT_DESC_MAX: { value: 300, file: 'plugins/core/customization/commands/customize.rb', purpose: 'Maximum short description' },
    ROOMTITLE_MAX: { value: 200, file: 'plugins/core/customization/commands/customize.rb', purpose: 'Maximum roomtitle' },
    PICTURE_URL_MAX: { value: 500, file: 'plugins/core/customization/commands/customize.rb', purpose: 'Maximum picture URL length' }
  },
  upload_limits: {
    MAX_FILE_SIZE_MB: { value: 5, file: 'app/services/description_upload_service.rb', purpose: 'Maximum upload size' },
    ALLOWED_TYPES: { value: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'], file: 'app/services/description_upload_service.rb', purpose: 'Allowed image types' }
  },
  stat_allocation: {
    SINGLE_TYPE_BONUS: { value: 0.5, file: 'app/services/stat_allocation_service.rb', purpose: 'Modifier bonus per extra stat' },
    DOUBLE_TYPE_BONUS: { value: 0.25, file: 'app/services/stat_allocation_service.rb', purpose: 'Modifier bonus per extra stat in paired category' }
  },
  gradient: {
    D65_REF_X: { value: 95.047, file: 'app/services/gradient_service.rb', purpose: 'D65 white point X' },
    D65_REF_Y: { value: 100.0, file: 'app/services/gradient_service.rb', purpose: 'D65 white point Y' },
    D65_REF_Z: { value: 108.883, file: 'app/services/gradient_service.rb', purpose: 'D65 white point Z' },
    EASING_LINEAR: { value: 100, file: 'app/services/gradient_service.rb', purpose: 'Linear easing value' }
  },
  wardrobe: {
    PATTERN_COST_MULTIPLIER: { value: 0.5, file: 'app/services/wardrobe_service.rb', purpose: 'Pattern creation cost (50% of base)' }
  },
  visibility: {
    FULLY_TORN_THRESHOLD: { value: 10, file: 'app/services/visibility_service.rb', purpose: 'Torn value for full damage' }
  },
  instance_defaults: {
    DEFAULT_LEVEL: { value: 1, file: 'app/models/character_instance.rb', purpose: 'Starting level' },
    MAX_LEVEL: { value: 100, file: 'app/models/character_instance.rb', purpose: 'Maximum level' },
    DEFAULT_MAX_HEALTH: { value: 100, file: 'app/models/character_instance.rb', purpose: 'Default max HP' },
    DEFAULT_MAX_MANA: { value: 50, file: 'app/models/character_instance.rb', purpose: 'Default max mana' }
  },
  stances: {
    VALID_STANCES: { value: ['standing', 'sitting', 'lying', 'reclining'], file: 'app/models/character_instance.rb', purpose: 'Valid stance values' }
  },
  wetness: {
    DRY: { value: 0, file: 'app/models/character_instance.rb', purpose: 'Dry level' },
    SLIGHTLY_DAMP_MAX: { value: 25, file: 'app/models/character_instance.rb', purpose: 'Slightly damp threshold' },
    DAMP_MAX: { value: 50, file: 'app/models/character_instance.rb', purpose: 'Damp threshold' },
    WET_MAX: { value: 75, file: 'app/models/character_instance.rb', purpose: 'Wet threshold' },
    SOAKED_MIN: { value: 76, file: 'app/models/character_instance.rb', purpose: 'Soaked threshold' }
  }
}.freeze

puts "\n[Character System]"
seed_system('character', {
  display_name: 'Character System',
  summary: 'Character identity, customization, stats, profiles, and descriptions',
  description: 'The Character System manages character identity including names, descriptions, stats, appearances, and profiles. It supports multi-reality instances, body descriptions, color gradients, and activity tracking.',
  player_guide: CHARACTER_PLAYER_GUIDE,
  staff_guide: CHARACTER_STAFF_GUIDE,
  quick_reference: CHARACTER_QUICK_REFERENCE,
  constants_json: CHARACTER_CONSTANTS,
  command_names: %w[handle change customize gradient profilepic score profile finger who directory observe unwatch meetup],
  related_systems: %w[clothing inventory communication],
  key_files: [
    'app/models/character.rb',
    'app/models/character_instance.rb',
    'app/models/character_description.rb',
    'app/models/character_default_description.rb',
    'app/models/character_shape.rb',
    'app/models/character_stat.rb',
    'app/services/character_display_service.rb',
    'app/services/stat_allocation_service.rb',
    'app/services/gradient_service.rb',
    'app/services/description_copy_service.rb',
    'app/services/visibility_service.rb',
    'plugins/core/customization/commands/',
    'plugins/core/info/commands/'
  ],
  staff_notes: 'Dual-model architecture: Character (persistent) vs CharacterInstance (session). DescriptionCopyService syncs on login. GradientService supports RGB and CIEDE2000 interpolation. VisibilityService handles exposure/privacy.',
  display_order: 40
})

# =============================================================================
# ECONOMY SYSTEM
# =============================================================================

ECONOMY_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Economy System manages all financial transactions in the game, including currency, banking, shopping, and property ownership. Whether you're buying items from shops, managing your bank accounts, or running your own store, this system handles all monetary interactions.

  The game supports multiple currencies per universe, separate wallets for cash-on-hand, and bank accounts for savings. Different eras have different banking access rules.

  ## Key Concepts

  - **Wallet**: Cash you carry with you. Vulnerable to theft in some situations.
  - **Bank Account**: Safe storage for your money. Protected from loss.
  - **Currency**: The type of money (gold, credits, dollars, etc.). Each universe can have multiple currencies.
  - **Shop**: A store where you can buy items. Some shops are player-owned.
  - **Cash Shop**: A shop that only accepts cash (wallet payments).
  - **Stock**: The quantity of items available in a shop.

  ## Getting Started

  1. **`balance`** - Check your wallet and bank balance
  2. **`list`** - View items for sale in a shop
  3. **`buy <item>`** - Purchase an item
  4. **`deposit <amount>`** - Put cash in the bank
  5. **`withdraw <amount>`** - Take cash from the bank

  ## Checking Your Finances

  ### Balance Command

  `balance` (aliases: `bal`, `money`, `cash`, `wallet`) shows all your finances:

  - All wallets (cash on hand) with formatted amounts
  - All bank accounts with formatted amounts
  - Total per currency across both wallets and bank

  ## Banking

  Banking requires access to a bank location. Where you can bank depends on the game era:

  | Era | Banking Locations |
  |-----|-------------------|
  | Medieval/Gaslight | Physical banks only |
  | Modern+ | Banks, non-cash shops, ATMs |

  ### Deposit

  `deposit <amount>` (alias: `dep`) moves cash to your bank:

  ```
  deposit 100       - Deposit 100 of the default currency
  deposit all       - Deposit all cash
  ```

  Minimum transaction: 5 units.

  ### Withdraw

  `withdraw <amount>` (alias: `with`) takes cash from your bank:

  ```
  withdraw 100      - Withdraw 100
  withdraw all      - Withdraw everything
  ```

  Minimum transaction: 5 units.

  ## Shopping

  ### Viewing Shop Inventory

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `list` | `list [category]` | View items for sale |
  | `browse` | `browse` | Open web shop interface |
  | `preview` | `preview <item>` | See item details before buying |

  ```
  list              - Show all items in shop
  list clothing     - Show only clothing items
  preview sword     - View details of the sword
  ```

  ### Buying Items

  `buy <item>` (alias: `purchase`) purchases items from shops:

  ```
  buy sword         - Buy one sword
  buy 2 potions     - Buy two potions
  ```

  **Payment Priority**:
  - Regular shops: Bank account first, then wallet
  - Cash-only shops: Wallet only
  - Free shops: No payment needed

  ### Shop Stock

  - **Unlimited**: Shop never runs out
  - **Limited**: Shows "X in stock" or "only X left!"
  - **Out of Stock**: Cannot purchase until restocked

  ## Shop Ownership

  If you own a shop, you can manage its inventory:

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `add stock` | `add stock <price> <item>` | Add item from inventory to shop |
  | `remove stock` | `remove stock <item>` | Remove item from shop |

  ```
  add stock 50 leather jacket   - Sell jacket for 50
  remove stock leather jacket   - Remove from shop
  ```

  ## Property Purchase

  Properties (houses, shops, vehicles) are purchased through the web interface:

  - `buy house` - Opens house purchase interface
  - `buy shop` - Opens shop purchase interface
  - `buy vehicle` - Opens vehicle dealership

  ## Finding Shops

  Use the `directory` command (see Character system) to find shops in your area:

  ```
  directory           - List all shops in area
  directory clothing  - Find clothing shops
  ```

  ## Tips & Tricks

  1. **Bank Early**: Keep money in the bank for safety
  2. **Check Prices**: Use `preview` before buying expensive items
  3. **Watch Stock**: Limited items may sell out
  4. **Multiple Currencies**: Some areas use different currencies
  5. **Cash Shops**: Some vendors only accept cash
MARKDOWN

ECONOMY_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Economy System uses a multi-currency, dual-storage (wallet/bank) architecture with shop support. Money exists in three forms: Wallet (cash on character), BankAccount (safe savings), and Item (money dropped on ground).

  ### Data Models

  #### Currency (app/models/currency.rb)
  Defines a type of money in a universe:
  - `universe_id` - Belongs to Universe
  - `name` - Currency name (max 50, unique per universe)
  - `symbol` - Display symbol (e.g., "G", "$", "¢")
  - `decimal_places` - Precision (default 2)
  - `is_default` - Default currency flag

  Key methods:
  - `format_amount(amount)` - Format with symbol (e.g., "G50.00")
  - `Currency.default_for(universe)` - Get default currency

  #### Wallet (app/models/wallet.rb)
  Cash on character's person (one per currency):
  - `character_instance_id` - Owner
  - `currency_id` - Currency type
  - `balance` - Amount (default 0)

  Key methods:
  - `add(amount)`, `remove(amount)` - Modify balance
  - `transfer_to(other_wallet, amount)` - Transfer (same currency)
  - `formatted_balance` - Display format

  #### BankAccount (app/models/bank_account.rb)
  Safe money storage (one per currency):
  - `character_id` - Owner (persistent character, not instance)
  - `currency_id` - Currency type
  - `balance` - Amount (default 0)
  - `account_name` - Auto-generated (e.g., "G1A2B3C4")

  Key methods:
  - `deposit(amount)`, `withdraw(amount)` - Modify balance
  - `transfer_to(other_account, amount)` - Transfer

  #### Shop (app/models/shop.rb)
  Store selling items:
  - `room_id` - Location (unique per room)
  - `name` / `sname` - Display name
  - `shopkeeper_name` - NPC name
  - `free_items` - All items free if true
  - `cash_shop` - Wallet-only payments if true
  - `is_open` - Publicly visible if true

  Key methods:
  - `available_items` - Items with stock
  - `in_stock?(pattern_id)` - Check availability
  - `price_for(pattern_id)` - Get price (0 if free)
  - `decrement_stock(pattern_id)` - Reduce stock

  #### ShopItem (app/models/shop_item.rb)
  Items for sale in a shop:
  - `shop_id` - Parent shop
  - `pattern_id` - Item pattern
  - `price` - Selling price
  - `stock` - Quantity (nil = unlimited)

  Key methods:
  - `available?` - Has stock (nil or non-zero)
  - `unlimited_stock?` - nil or negative stock
  - `effective_price` - Respects shop.free_items

  ### BankingAccessHelper

  Module providing banking logic for commands:

  ```ruby
  def has_bank_access?
    # Physical bank → always
    # Medieval/Gaslight → physical bank only
    # Modern+ → bank, non-cash shop, or ATM
  end

  def default_currency
    # Universe's default currency
  end

  def parse_amount(text, max_amount)
    # "100" or "all" → numeric
  end

  def find_or_create_bank_account(char, currency)
  def find_or_create_wallet(currency)
  ```

  ### Data Flows

  #### Buy Item Flow
  ```
  1. Find shop in location
  2. Resolve item name (TargetResolverService)
  3. Check stock available
  4. Calculate total price
  5. Process payment:
     - Non-cash shop: bank first, then wallet
     - Cash shop: wallet only
  6. Decrement shop stock
  7. Instantiate items from pattern
  8. Broadcast purchase
  ```

  #### Deposit Flow
  ```
  1. Check bank access (era-aware)
  2. Get default currency
  3. Validate wallet balance
  4. Find/create bank account
  5. Transfer: wallet.remove() → bank.deposit()
  6. Broadcast
  ```

  ### Commands Implementation

  | Command | File | Key Logic |
  |---------|------|-----------|
  | balance | economy/commands/balance.rb | Aggregates wallets + bank accounts |
  | deposit | economy/commands/deposit.rb | Uses BankingAccessHelper |
  | withdraw | economy/commands/withdraw.rb | Uses BankingAccessHelper |
  | buy | economy/commands/buy.rb | Handles stock, payment priority |
  | list | economy/commands/list.rb | Groups by category |
  | preview | economy/commands/preview.rb | Shows item details |
  | add stock | economy/commands/add_stock.rb | Requires shop ownership |
  | remove stock | economy/commands/remove_stock.rb | Requires shop ownership |

  ### Configuration

  #### Banking Access Constants
  - `MINIMUM_TRANSACTION_AMOUNT = 5` (BankingAccessHelper)

  #### Era-Based Banking
  - Medieval: Physical banks only
  - Gaslight: Physical banks only
  - Modern+: Banks, non-cash shops, ATMs

  #### Stock Behavior
  - `nil` stock = unlimited (no decrement)
  - Negative stock = unlimited (legacy)
  - `0` stock = out of stock
  - Positive stock = limited quantity

  ### Common Modifications

  1. **Add new currency**: Create Currency record for universe
  2. **Change minimum transaction**: Modify MINIMUM_TRANSACTION_AMOUNT
  3. **Add banking location type**: Update has_bank_access? logic
  4. **Free shop**: Set shop.free_items = true
  5. **Cash-only shop**: Set shop.cash_shop = true
MARKDOWN

ECONOMY_QUICK_REFERENCE = <<~MARKDOWN
  ## Finance Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `balance` | `bal`, `money`, `cash`, `wallet` | Check finances |
  | `deposit` | `dep` | `deposit <amount>` or `deposit all` |
  | `withdraw` | `with` | `withdraw <amount>` or `withdraw all` |

  ## Shopping Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `buy` | `purchase` | `buy <item>` or `buy <qty> <item>` |
  | `list` | `shoplist`, `catalog` | `list [category]` |
  | `preview` | `examine item` | `preview <item>` |
  | `browse` | - | Open web shop interface |

  ## Shop Owner Commands

  | Command | Usage |
  |---------|-------|
  | `add stock` | `add stock <price> <item>` |
  | `remove stock` | `remove stock <item>` |

  ## Banking Rules by Era

  | Era | Banking Access |
  |-----|----------------|
  | Medieval | Physical banks only |
  | Gaslight | Physical banks only |
  | Modern | Banks, shops, ATMs |

  ## Payment Priority

  - **Regular shops**: Bank → Wallet
  - **Cash shops**: Wallet only
  - **Free shops**: No payment

  ## Stock Status

  - **Unlimited**: Never runs out
  - **"X in stock"**: Limited quantity
  - **Out of stock**: Cannot buy

  ## Constants

  - Minimum transaction: 5 units
MARKDOWN

ECONOMY_CONSTANTS = {
  banking: {
    MINIMUM_TRANSACTION_AMOUNT: { value: 5, file: 'app/helpers/banking_access_helper.rb', purpose: 'Minimum deposit/withdrawal' }
  },
  eras: {
    MEDIEVAL_BANKING: { value: 'physical_banks_only', file: 'app/helpers/banking_access_helper.rb', purpose: 'Medieval era banking access' },
    GASLIGHT_BANKING: { value: 'physical_banks_only', file: 'app/helpers/banking_access_helper.rb', purpose: 'Gaslight era banking access' },
    MODERN_BANKING: { value: 'banks_shops_atms', file: 'app/helpers/banking_access_helper.rb', purpose: 'Modern era banking access' }
  },
  stock: {
    NIL_STOCK_MEANING: { value: 'unlimited', file: 'app/models/shop_item.rb', purpose: 'nil stock = unlimited' },
    NEGATIVE_STOCK_MEANING: { value: 'unlimited', file: 'app/models/shop_item.rb', purpose: 'Negative stock = unlimited (legacy)' },
    ZERO_STOCK_MEANING: { value: 'out_of_stock', file: 'app/models/shop_item.rb', purpose: 'Zero stock = unavailable' }
  },
  payment: {
    NON_CASH_PRIORITY: { value: ['bank', 'wallet'], file: 'plugins/core/economy/commands/buy.rb', purpose: 'Bank first, then wallet' },
    CASH_PRIORITY: { value: ['wallet'], file: 'plugins/core/economy/commands/buy.rb', purpose: 'Wallet only for cash shops' }
  }
}.freeze

puts "\n[Economy System]"
seed_system('economy', {
  display_name: 'Economy System',
  summary: 'Currency, banking, shopping, and property ownership',
  description: 'The Economy System manages financial transactions including multi-currency wallets, bank accounts, shopping, and player-owned stores. Supports era-aware banking access.',
  player_guide: ECONOMY_PLAYER_GUIDE,
  staff_guide: ECONOMY_STAFF_GUIDE,
  quick_reference: ECONOMY_QUICK_REFERENCE,
  constants_json: ECONOMY_CONSTANTS,
  command_names: %w[balance deposit withdraw buy list preview browse add\ stock remove\ stock],
  related_systems: %w[inventory character],
  key_files: [
    'app/models/wallet.rb',
    'app/models/bank_account.rb',
    'app/models/shop.rb',
    'app/models/shop_item.rb',
    'app/models/currency.rb',
    'app/helpers/banking_access_helper.rb',
    'app/services/shop_display_service.rb',
    'plugins/core/economy/commands/'
  ],
  staff_notes: 'Multi-currency with wallet (cash) and bank (savings). Era-aware banking access. Stock nil=unlimited. Payment priority: bank first for regular shops, wallet-only for cash shops.',
  display_order: 50
})

# =============================================================================
# INVENTORY SYSTEM
# =============================================================================

INVENTORY_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Inventory System manages all your possessions - items you carry, hold, store, and trade. From picking up objects to organizing your wardrobe, this system handles physical object interaction.

  Items can be in several states: carried (in your inventory), held (visible in hand), worn (clothing/jewelry), equipped (weapons), or stored (in your wardrobe/vault).

  ## Key Concepts

  - **Inventory**: Items you carry but aren't visibly using.
  - **Held Items**: Items in your hands, visible to others.
  - **Worn Items**: Clothing and jewelry on your body.
  - **Stored Items**: Items safely stored in your wardrobe/vault.
  - **Pattern**: The template/design an item is based on.
  - **Quantity**: Some items stack (like money or consumables).
  - **Condition**: Item quality (excellent, good, fair, poor, broken).

  ## Getting Started

  1. **`inventory`** - View everything you're carrying
  2. **`get <item>`** - Pick up an item from the room
  3. **`drop <item>`** - Drop an item in the room
  4. **`hold <item>`** - Hold an item visibly in your hand
  5. **`pocket <item>`** - Put a held item away

  ## Basic Item Commands

  ### Picking Up Items

  `get` (aliases: `take`, `pickup`, `grab`) picks up items from the room:

  ```
  get sword         - Pick up a sword
  get all           - Pick up all items in room
  get 100           - Pick up 100 currency (money)
  get money         - Pick up any money in room
  ```

  ### Dropping Items

  `drop` (aliases: `discard`, `put down`) drops items from your inventory:

  ```
  drop sword        - Drop a sword
  drop all          - Drop all inventory items
  drop 100          - Drop 100 currency
  ```

  ### Giving Items

  `give` (aliases: `hand`, `offer`, `throw`, `toss`, `pass`, `slip`, `gift`):

  ```
  give sword to Bob     - Give sword to Bob
  give 100 to Alice     - Give 100 currency to Alice
  give potion to Carol  - Give potion to Carol
  ```

  The target must be in the same room.

  ## Viewing Your Inventory

  `inventory` (aliases: `inv`, `i`) shows everything you own:

  - **In Hand**: Items you're holding visibly
  - **Carrying**: Items in your inventory
  - **Wearing**: Clothing and jewelry (see Clothing system)
  - **Wallet**: Your cash amounts by currency

  ## Visibility Commands

  ### Holding Items

  Held items are visible to others when they look at you.

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `hold` | `wield`, `brandish`, `unsheathe`, `unholster` | `hold <item>` |
  | `pocket` | `stow`, `stash`, `put away`, `sheathe`, `holster` | `pocket <item>` |

  ```
  hold sword        - Hold sword visibly
  pocket sword      - Put sword away
  pocket all        - Put all held items away
  ```

  ### Showing Items

  `show` (aliases: `display`, `present`) shows an item to someone:

  ```
  show sword to Bob     - Show Bob your sword
  show ring to Alice    - Show Alice your ring
  ```

  They'll see the full item description.

  ## Item Visibility Control

  ### Hiding Descriptions

  Control whether others can see item details:

  | Command | Aliases | Description |
  |---------|---------|-------------|
  | `hidedesc` | `hide description` | Hide item description from others |
  | `showdesc` | `show description` | Reveal item description to others |

  ```
  hidedesc ring         - Others can't examine your ring
  showdesc ring         - Others can examine your ring
  ```

  ## Storage System

  Store items in your wardrobe/vault for safekeeping. Requires vault access (usually at home or certain locations).

  ### Storing Items

  `store` (alias: `stash`) puts items in your vault:

  ```
  store sword       - Store sword in vault
  store all         - Store all unstored items
  ```

  Items cannot be stored while worn or equipped.

  ### Retrieving Items

  `retrieve` (aliases: `ret`, `wardrobe`, `fetch`) gets items from your vault:

  ```
  retrieve          - List all stored items
  retrieve sword    - Retrieve sword from vault
  retrieve all      - Retrieve all stored items
  ```

  ## Item Customization

  ### Reskinning Items

  Change an item's appearance to a different pattern (same type):

  ```
  reskin jacket                     - See available patterns
  reskin jacket to denim jacket     - Change appearance
  ```

  Only works on stored items. Must be same item category.

  ## Destroying Items

  `trash` (aliases: `destroy`, `junk`) permanently destroys an item:

  ```
  trash broken sword    - Destroy the broken sword
  ```

  **Warning**: This cannot be undone! Money items cannot be trashed.

  ## Tips & Tricks

  1. **Pocket Weapons**: Use `pocket` to hide weapons when not fighting
  2. **Store Valuables**: Keep important items in your vault
  3. **Organize Outfits**: Store clothing for outfit system access
  4. **Check Condition**: Items degrade - watch for "poor" or "broken"
  5. **Stacking**: Some items stack automatically (same pattern)
MARKDOWN

INVENTORY_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Inventory System uses the Item model (stored in `objects` table) with Pattern templates. Items can be owned by a CharacterInstance or located in a Room.

  ### Core Models

  #### Item (app/models/item.rb)
  Individual object instances:

  **Ownership Columns**:
  - `character_instance_id` - Owner (if carried)
  - `room_id` - Location (if on ground)
  - Validation: Must have exactly one (not both, not neither)

  **State Columns**:
  - `held` - Visible in hand (boolean)
  - `worn` - Being worn (boolean)
  - `equipped` - In equipment slot (boolean)
  - `equipment_slot` - 'left_hand', 'right_hand', 'both_hands'
  - `stored` - In vault/wardrobe (boolean)
  - `concealed` - Hidden from view (boolean)
  - `desc_hidden` - Description hidden (boolean)

  **Physical Columns**:
  - `quantity` - Stack count (default 1)
  - `condition` - 'excellent', 'good', 'fair', 'poor', 'broken'
  - `torn` - Damage level 0-10
  - `zipped` - Fastened state

  **Type Columns**:
  - `is_clothing`, `is_jewelry`, `is_tattoo`, `is_piercing`

  Key methods:
  - `move_to_character(instance)` - Transfer to character
  - `move_to_room(room)` - Drop to room
  - `hold!`, `pocket!` - Toggle held state
  - `store!`, `retrieve!` - Toggle stored state
  - `Item.stored_items_for(instance)` - Query stored items

  #### Pattern (app/models/pattern.rb)
  Item templates:
  - `description` - Pattern name
  - `unified_object_type_id` - Links to type (determines category)
  - `price` - Base price
  - `consume_type` - 'food', 'drink', 'smoke', or null

  Key methods:
  - `instantiate(options)` - Create Item from pattern
  - `clothing?`, `jewelry?`, `weapon?`, `consumable?` - Type checks (based on unified_object_type category)
  - `Pattern.search(query)` - Full-text search
  - `Pattern.by_category(*cats)` - Query by category

  #### UnifiedObjectType (app/models/unified_object_type.rb)
  Shared type metadata:
  - `name`, `category`, `subcategory`
  - `layer` - Display layer
  - `covered_position_1..20` - Body positions covered

  #### Wallet (app/models/wallet.rb)
  Currency storage per character instance:
  - `character_instance_id`, `currency_id`, `balance`
  - `add(amount)`, `remove(amount)`, `transfer_to(wallet, amount)`

  ### Data Flows

  #### Get Item Flow
  ```
  1. Find item in room by name (TargetResolverService)
  2. If money: add to wallet, destroy item (or update quantity)
  3. If item: call item.move_to_character(instance)
  4. Broadcast pickup
  ```

  #### Give Item Flow
  ```
  1. Parse "X to Y" format
  2. Find target character in room
  3. If money: wallet.transfer_to(target_wallet, amount)
  4. If item: item.move_to_character(target_instance)
  5. Broadcast transfer
  ```

  #### Store Item Flow
  ```
  1. Check vault access (room.vault_accessible?)
  2. Find item in inventory
  3. Validate not worn/equipped
  4. Call item.store!
  5. Broadcasts action
  ```

  ### WardrobeService (app/services/wardrobe_service.rb)

  Handles storage operations:
  - `vault_accessible?` - Check room access
  - `stored_items_by_category` - Get items by type
  - `fetch_item(id)` - Retrieve from storage
  - `create_from_pattern(id)` - Create at 50% cost

  Constants:
  - `PATTERN_CREATE_COST_MULTIPLIER = 0.5`

  ### Commands Implementation

  | Command | File | Key Logic |
  |---------|------|-----------|
  | get | inventory/commands/get.rb | Handles items and money |
  | drop | inventory/commands/drop.rb | Supports money creation |
  | give | inventory/commands/give.rb | Parses "X to Y" format |
  | inventory | inventory/commands/inventory.rb | Groups by state |
  | hold | inventory/commands/hold.rb | Sets held: true |
  | pocket | inventory/commands/pocket.rb | Sets held: false |
  | store | storage/commands/store.rb | Requires vault access |
  | retrieve | storage/commands/retrieve.rb | Requires vault access |
  | reskin | inventory/commands/reskin.rb | Pattern matching by type |
  | trash | inventory/commands/trash.rb | Prevents money destruction |

  ### Money System

  Money is tracked two ways:
  1. **Wallet model**: Currency on character (not Item)
  2. **Money items**: Currency on ground (Item with properties)

  Money item properties:
  ```ruby
  {
    'is_currency' => true,
    'currency_id' => currency.id
  }
  ```

  ### Item Visibility States

  | State | Visible To Others | Description |
  |-------|------------------|-------------|
  | Held | Yes | In hands, displayed |
  | Worn | Yes | On body (clothing) |
  | Carried | No | In inventory |
  | Stored | No | In vault |
  | Concealed | No | Hidden even if worn |

  ### Timeline Support

  Items can be timeline-restricted:
  - `timeline_id = null` - Visible everywhere
  - `timeline_id = X` - Only in that timeline
  - Methods check viewer's timeline

  ### Common Modifications

  1. **Add item state**: Add boolean column to objects table
  2. **New item type**: Create patterns and unified_object_type
  3. **Change storage access**: Modify vault_accessible? logic
  4. **Add stacking rule**: Modify Item.stackable?
  5. **Custom condition**: Add to condition enum
MARKDOWN

INVENTORY_QUICK_REFERENCE = <<~MARKDOWN
  ## Basic Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `get` | `take`, `pickup`, `grab` | `get <item>`, `get all`, `get money` |
  | `drop` | `discard`, `put down` | `drop <item>`, `drop all` |
  | `give` | `hand`, `offer`, `toss` | `give <item> to <character>` |
  | `inventory` | `inv`, `i` | View all possessions |

  ## Visibility Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `hold` | `wield`, `brandish` | `hold <item>` |
  | `pocket` | `stow`, `sheathe` | `pocket <item>`, `pocket all` |
  | `show` | `display`, `present` | `show <item> to <character>` |
  | `hidedesc` | `hide description` | `hidedesc <item>` |
  | `showdesc` | `show description` | `showdesc <item>` |

  ## Storage Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `store` | `stash` | `store <item>`, `store all` |
  | `retrieve` | `wardrobe`, `fetch` | `retrieve [item]`, `retrieve all` |
  | `reskin` | `restyle` | `reskin <item> [to <pattern>]` |

  ## Other Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `trash` | `destroy`, `junk` | `trash <item>` (permanent!) |

  ## Item States

  | State | Visible | Can Trade |
  |-------|---------|-----------|
  | Held | Yes | Yes |
  | Worn | Yes | No (remove first) |
  | Carried | No | Yes |
  | Stored | No | No (retrieve first) |

  ## Money Commands

  ```
  get 100           - Pick up 100 currency
  get money         - Pick up all money
  drop 100          - Drop 100 currency
  give 100 to Bob   - Give 100 to Bob
  ```

  ## Item Conditions

  excellent → good → fair → poor → broken
MARKDOWN

INVENTORY_CONSTANTS = {
  item_states: {
    HELD: { value: true, file: 'app/models/item.rb', purpose: 'Visible in hand' },
    WORN: { value: true, file: 'app/models/item.rb', purpose: 'Being worn (clothing)' },
    EQUIPPED: { value: true, file: 'app/models/item.rb', purpose: 'In equipment slot' },
    STORED: { value: true, file: 'app/models/item.rb', purpose: 'In vault/wardrobe' },
    CONCEALED: { value: true, file: 'app/models/item.rb', purpose: 'Hidden from view' }
  },
  equipment_slots: {
    LEFT_HAND: { value: 'left_hand', file: 'app/models/item.rb', purpose: 'Left hand slot' },
    RIGHT_HAND: { value: 'right_hand', file: 'app/models/item.rb', purpose: 'Right hand slot' },
    BOTH_HANDS: { value: 'both_hands', file: 'app/models/item.rb', purpose: 'Two-handed slot' }
  },
  conditions: {
    EXCELLENT: { value: 'excellent', file: 'app/models/item.rb', purpose: 'Best condition' },
    GOOD: { value: 'good', file: 'app/models/item.rb', purpose: 'Default condition' },
    FAIR: { value: 'fair', file: 'app/models/item.rb', purpose: 'Worn but usable' },
    POOR: { value: 'poor', file: 'app/models/item.rb', purpose: 'Badly worn' },
    BROKEN: { value: 'broken', file: 'app/models/item.rb', purpose: 'Non-functional' }
  },
  damage: {
    TORN_MIN: { value: 0, file: 'app/models/item.rb', purpose: 'Pristine (no damage)' },
    TORN_MAX: { value: 10, file: 'app/models/item.rb', purpose: 'Fully destroyed' },
    DAMAGE_PERCENT_MULTIPLIER: { value: 10, file: 'app/models/item.rb', purpose: 'torn * 10 = percentage' }
  },
  wardrobe: {
    PATTERN_CREATE_COST_MULTIPLIER: { value: 0.5, file: 'app/services/wardrobe_service.rb', purpose: '50% cost to recreate' }
  },
  reskin: {
    MAX_COMPATIBLE_PATTERNS: { value: 20, file: 'plugins/core/inventory/commands/reskin.rb', purpose: 'Max patterns to show' }
  }
}.freeze

puts "\n[Inventory System]"
seed_system('inventory', {
  display_name: 'Inventory System',
  summary: 'Item management, storage, and trading',
  description: 'The Inventory System manages item pickup, dropping, giving, holding, and storage. Supports stacking, conditions, visibility states, and vault storage.',
  player_guide: INVENTORY_PLAYER_GUIDE,
  staff_guide: INVENTORY_STAFF_GUIDE,
  quick_reference: INVENTORY_QUICK_REFERENCE,
  constants_json: INVENTORY_CONSTANTS,
  command_names: %w[get drop give inventory hold pocket show hidedesc showdesc store retrieve reskin trash],
  related_systems: %w[economy clothing character],
  key_files: [
    'app/models/item.rb',
    'app/models/pattern.rb',
    'app/models/unified_object_type.rb',
    'app/models/wallet.rb',
    'app/services/wardrobe_service.rb',
    'plugins/core/inventory/commands/',
    'plugins/core/storage/commands/'
  ],
  staff_notes: 'Items in objects table with state booleans. Wallet for currency, Item for dropped money. vault_accessible? for storage access. Pattern.instantiate() creates items.',
  display_order: 60
})

# =============================================================================
# CLOTHING SYSTEM
# =============================================================================

CLOTHING_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Clothing System manages everything you wear - from everyday clothes to jewelry, tattoos, and piercings. It handles body coverage, layering, concealment, and outfit management.

  What you wear affects what others see when they look at you. Clothing covers body parts, and the layering system determines what's visible on top.

  ## Key Concepts

  - **Worn Items**: Clothing and jewelry currently on your body.
  - **Layering**: Outer clothes (jackets) appear over inner clothes (shirts).
  - **Body Coverage**: Clothing covers specific body positions.
  - **Concealment**: Items can be hidden even while worn.
  - **Outfits**: Saved clothing combinations for quick changes.
  - **Tattoos/Piercings**: Permanent body modifications.

  ## Getting Started

  1. **`wear <item>`** - Put on clothing from your inventory
  2. **`remove <item>`** - Take off worn clothing
  3. **`inventory`** - See what you're wearing and carrying
  4. **`outfit list`** - View your saved outfits

  ## Basic Commands

  ### Wearing and Removing

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `wear` | `don`, `put on` | `wear <item>` |
  | `remove` | `doff`, `take off`, `tear off` | `remove <item>` |
  | `strip` | `undress` | `strip all` or `strip naked` |

  ```
  wear jacket         - Put on a jacket
  remove jacket       - Take off the jacket
  strip all           - Remove all clothing
  ```

  **Note**: `strip` requires "all" or "naked" to prevent accidents.

  ### Dressing Others

  `dress <character> with <item>` - Dress another character (requires their consent):

  ```
  dress Bob with hat      - Offer to put hat on Bob
  ```

  If they haven't pre-approved, they'll get a menu to accept or decline.

  ## Concealment

  Hide or reveal items you're wearing:

  | Command | Aliases | Description |
  |---------|---------|-------------|
  | `cover` | `conceal`, `hide` | Hide a worn item |
  | `expose` | `reveal` | Show a hidden item |
  | `flash` | - | Briefly show hidden item |

  ```
  cover dagger        - Conceal your dagger
  expose badge        - Reveal your badge
  flash weapon        - Brief glimpse of hidden weapon
  ```

  Concealed items are still worn but invisible to others.

  ## Zipping and Buttoning

  Control whether clothing is fastened:

  | Command | Aliases | Description |
  |---------|---------|-------------|
  | `zipup` | `zip`, `button`, `button up` | Fasten clothing |
  | `unzip` | `unbutton`, `tear open` | Unfasten clothing |

  ```
  unzip jacket        - Open your jacket
  zipup jacket        - Close your jacket
  ```

  This affects which body positions are exposed.

  ## Outfit System

  Save and apply clothing combinations:

  ### Commands

  ```
  outfit              - Show outfit commands
  outfit list         - View all saved outfits
  outfit save Casual  - Save current clothing as "Casual"
  outfit wear Formal  - Change into "Formal" outfit
  outfit delete Old   - Delete "Old" outfit
  ```

  ### How Outfits Work

  - **Saving**: Records the patterns (not specific items) of what you're wearing
  - **Wearing**: Strips current clothing and creates new items from patterns
  - **Full Outfits**: All outfits replace your entire wardrobe
  - **Empty Outfits**: Saving with nothing worn creates a "nude" outfit

  ## Body Modifications

  Create permanent modifications:

  ### Piercings

  ```
  pierce my left ear with a silver stud
  pierce my eyebrow
  ```

  Creates a new piercing item worn on your body.

  ### Tattoos

  ```
  tattoo a small dragon on my shoulder
  tattoo a rose on my wrist
  ```

  Creates a new tattoo at the base layer (always visible under clothing).

  ## Visibility and Layering

  ### How Layering Works

  - Each item has a layer number (higher = outer)
  - Tattoos are layer 0 (base, under everything)
  - Only the outermost layer for each body position is visible
  - Damaged clothing (torn ≥10) no longer covers

  ### Privacy Considerations

  - Some body positions are marked as "private"
  - Items covering only private areas require private mode
  - Both characters must be in private mode to see private content

  ## Tips & Tricks

  1. **Save Common Outfits**: Create outfits for different occasions
  2. **Conceal Weapons**: Use `cover` to hide weapons in social situations
  3. **Layer Smart**: Outer layers hide inner layers
  4. **Quick Flash**: Show ID or weapons briefly without uncovering
  5. **Check Damage**: Torn clothing may expose what's underneath
MARKDOWN

CLOTHING_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Clothing System uses the Item model with clothing-specific flags and the Outfit system for saved combinations. VisibilityService handles exposure calculations.

  ### Item Clothing Fields (app/models/item.rb)

  **Type Flags**:
  - `is_clothing` - Clothing item
  - `is_jewelry` - Jewelry item
  - `is_tattoo` - Tattoo (permanent)
  - `is_piercing` - Piercing (permanent)

  **State Flags**:
  - `worn` - Currently on body
  - `worn_layer` - Layer number (0 = base, higher = outer)
  - `concealed` - Hidden from view
  - `zipped` - Fastened closed

  **Damage**:
  - `torn` - Damage level 0-10 (10 = fully destroyed)
  - Fully torn items don't cover positions

  Key methods:
  - `wear!`, `remove!` - Toggle worn state
  - `clothing?`, `jewelry?`, `tattoo?`, `piercing?` - Type checks
  - `body_positions_covered` - Positions this covers
  - `covers_position?(position_id)` - Check specific position
  - `visibility_layer` - Returns worn_layer or 0

  ### Outfit System

  #### Outfit (app/models/outfit.rb)
  Saved clothing combinations:
  - `character_instance_id` - Owner
  - `name` - Unique name per character (max 100)
  - `description` - Optional description

  Key methods:
  - `save_from_worn!(instance)` - Capture current clothing
  - `apply_to!(instance)` - Apply outfit (strips current, creates new)
  - `item_count` - Number of items

  #### OutfitItem (app/models/outfit_item.rb)
  Links outfit to patterns:
  - `outfit_id`, `pattern_id`, `display_order`

  ### VisibilityService (app/services/visibility_service.rb)

  Handles exposure and privacy calculations:

  ```ruby
  VisibilityService.position_exposed?(instance, position_id, viewer:, xray:)
  # Returns true if body position is visible (not covered or covered by torn items)

  VisibilityService.visible_clothing(instance, viewer:, xray:)
  # Returns array of visible worn items (sorted outer-first)

  VisibilityService.show_private_content?(viewer, target)
  # Returns true if both are in private_mode

  VisibilityService.visible_clothing_for_privacy(instance, viewer:, xray:)
  # Filters out items covering only private positions (unless private mode)
  ```

  **Visibility Logic**:
  - Items visible if outermost layer for any position they cover
  - Concealed items never visible (unless xray)
  - Fully torn items (torn ≥ 10) don't cover positions
  - Private positions require both in private_mode

  ### WardrobeService (app/services/wardrobe_service.rb)

  Handles storage operations:
  - `vault_accessible?` - Check room access
  - `stored_items_by_category` - Items by type
  - `fetch_and_wear(id)` - Retrieve and wear item
  - `create_from_pattern(id)` - Create at 50% cost

  ### CharacterDisplayService Integration

  Uses VisibilityService for look command:
  - Calls `visible_clothing_for_privacy()`
  - Maps to display data with damage percentages
  - Memoizes for performance

  ### Commands Implementation

  | Command | File | Key Logic |
  |---------|------|-----------|
  | wear | clothing/commands/wear.rb | Sets worn: true |
  | remove | clothing/commands/remove.rb | Sets worn: false |
  | strip | clothing/commands/strip.rb | Requires "all" confirmation |
  | dress | clothing/commands/dress.rb | InteractionPermissionService |
  | outfit | clothing/commands/outfit.rb | save/wear/list/delete modes |
  | cover | clothing/commands/cover.rb | Sets concealed: true |
  | expose | clothing/commands/expose.rb | Sets concealed: false |
  | flash | clothing/commands/flash.rb | No state change, just broadcast |
  | zipup | clothing/commands/zipup.rb | Sets zipped: true |
  | unzip | clothing/commands/unzip.rb | Sets zipped: false |
  | pierce | clothing/commands/pierce.rb | Creates Item with is_piercing |
  | tattoo | clothing/commands/tattoo.rb | Creates Item with is_tattoo, layer 0 |

  ### Layering System

  ```
  Layer 0:  Tattoos (always base)
  Layer 1:  Underwear
  Layer 2:  Shirts, pants
  Layer 3:  Jackets, outerwear
  Layer 4:  Coats, heavy outerwear
  ```

  Items are sorted by:
  1. `display_order` (primary)
  2. `worn_layer` descending (secondary)

  ### Body Position Coverage

  Items define coverage via item_body_positions join table:
  - BodyPosition model defines regions (head, torso, etc.)
  - is_private flag for privacy-restricted positions
  - Zipped state can affect which positions are exposed

  ### Configuration Points

  #### Damage Threshold
  - `FULLY_TORN_THRESHOLD = 10` (VisibilityService)
  - Items with torn ≥ 10 don't provide coverage

  #### Tattoo Layer
  - Always created with `worn_layer: 0`
  - Visible under all other clothing

  #### Pattern Cost
  - `PATTERN_CREATE_COST_MULTIPLIER = 0.5` (WardrobeService)
  - Creating from pattern costs 50%

  ### Common Modifications

  1. **Add layer type**: Update worn_layer conventions
  2. **New body position**: Add to body_positions table
  3. **Change visibility rules**: Modify VisibilityService
  4. **New clothing type flag**: Add column to objects table
  5. **Outfit partial support**: Modify apply_to! to not strip first
MARKDOWN

CLOTHING_QUICK_REFERENCE = <<~MARKDOWN
  ## Wear/Remove Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `wear` | `don`, `put on` | `wear <item>` |
  | `remove` | `doff`, `take off` | `remove <item>` |
  | `strip` | `undress` | `strip all` |
  | `dress` | - | `dress <character> with <item>` |

  ## Concealment Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `cover` | `conceal`, `hide` | `cover <item>` |
  | `expose` | `reveal` | `expose <item>` |
  | `flash` | - | `flash <item>` |

  ## Fastening Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `zipup` | `zip`, `button` | `zipup <item>` |
  | `unzip` | `unbutton` | `unzip <item>` |

  ## Outfit Commands

  ```
  outfit list           - View saved outfits
  outfit save <name>    - Save current as outfit
  outfit wear <name>    - Apply saved outfit
  outfit delete <name>  - Remove outfit
  ```

  ## Body Modifications

  ```
  pierce <description>   - Add piercing
  tattoo <description>   - Add tattoo (layer 0)
  ```

  ## Visibility Rules

  | State | Visible | Notes |
  |-------|---------|-------|
  | Worn | Yes | Unless concealed |
  | Concealed | No | Still worn, just hidden |
  | Zipped | Varies | Affects body exposure |
  | Torn ≥10 | Visible | But doesn't cover body |

  ## Layer Order (outer first)

  4. Coats, heavy outerwear
  3. Jackets, outerwear
  2. Shirts, pants
  1. Underwear
  0. Tattoos (always base)

  ## Privacy

  - Private positions require both in private_mode
  - Items covering only private areas filtered otherwise
MARKDOWN

CLOTHING_CONSTANTS = {
  item_types: {
    IS_CLOTHING: { value: true, file: 'app/models/item.rb', purpose: 'Clothing flag' },
    IS_JEWELRY: { value: true, file: 'app/models/item.rb', purpose: 'Jewelry flag' },
    IS_TATTOO: { value: true, file: 'app/models/item.rb', purpose: 'Tattoo flag' },
    IS_PIERCING: { value: true, file: 'app/models/item.rb', purpose: 'Piercing flag' }
  },
  layers: {
    TATTOO_LAYER: { value: 0, file: 'plugins/core/clothing/commands/tattoo.rb', purpose: 'Tattoos always base layer' },
    DEFAULT_LAYER: { value: 1, file: 'app/models/item.rb', purpose: 'Default worn layer' }
  },
  damage: {
    FULLY_TORN_THRESHOLD: { value: 10, file: 'app/services/visibility_service.rb', purpose: 'Item no longer covers' }
  },
  outfit: {
    MAX_NAME_LENGTH: { value: 100, file: 'app/models/outfit.rb', purpose: 'Maximum outfit name' }
  },
  wardrobe: {
    PATTERN_CREATE_COST_MULTIPLIER: { value: 0.5, file: 'app/services/wardrobe_service.rb', purpose: '50% cost to recreate' }
  }
}.freeze

puts "\n[Clothing System]"
seed_system('clothing', {
  display_name: 'Clothing System',
  summary: 'Wearing, layering, concealment, and outfit management',
  description: 'The Clothing System manages worn items, body coverage, layering, concealment, and outfit saving. Integrates with VisibilityService for exposure calculations.',
  player_guide: CLOTHING_PLAYER_GUIDE,
  staff_guide: CLOTHING_STAFF_GUIDE,
  quick_reference: CLOTHING_QUICK_REFERENCE,
  constants_json: CLOTHING_CONSTANTS,
  command_names: %w[wear remove strip dress outfit cover expose flash zipup unzip pierce tattoo],
  related_systems: %w[inventory character],
  key_files: [
    'app/models/item.rb',
    'app/models/outfit.rb',
    'app/models/outfit_item.rb',
    'app/services/visibility_service.rb',
    'app/services/wardrobe_service.rb',
    'app/services/character_display_service.rb',
    'plugins/core/clothing/commands/'
  ],
  staff_notes: 'VisibilityService handles layering and exposure. Outfits store patterns, not items. Tattoos layer 0. Torn ≥10 = no coverage. Private positions need both in private_mode.',
  display_order: 70
})

# =============================================================================
# ENVIRONMENT SYSTEM
# =============================================================================

ENVIRONMENT_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Environment System brings the game world to life with realistic time, weather, seasons, and celestial events. Every aspect of the environment—from the position of the sun to the phase of the moon—affects your gameplay experience.

  The system tracks:
  - **Time of Day**: Dawn, day, dusk, and night cycles
  - **Weather Conditions**: Rain, snow, fog, storms, and more
  - **Seasons**: Spring, summer, fall, and winter with unique characteristics
  - **Moon Phases**: Full astronomical moon cycle affecting visibility and atmosphere

  ## Key Concepts

  - **Time Periods**: The day is divided into dawn (6-8 AM), day (8 AM-6 PM), dusk (6-8 PM), and night (8 PM-6 AM)
  - **Seasons**: Follow calendar months (Spring: Mar-May, Summer: Jun-Aug, Fall: Sep-Nov, Winter: Dec-Feb)
  - **Moon Cycle**: 29.5-day lunar cycle with 8 distinct phases
  - **Weather Intensity**: Light, moderate, heavy, or severe conditions
  - **Era System**: Game era (medieval, gaslight, modern, future) affects available technology

  ## Getting Started

  Check the current time and weather to plan your activities:

  1. **`time`** - See the current time, date, and moon phase
  2. **`weather`** - Check current weather conditions
  3. Observe environmental prose in room descriptions

  ## Commands

  ### Time Command

  The `time` command (aliases: `clock`, `date`) shows:

  ```
  > time
  It is 3:45 PM on Monday, January 3, 2026.
  The afternoon sun shines through 30% cloud cover.
  Tonight's moon: Waning Crescent 🌘 (22% illuminated)
  ```

  **Information displayed:**
  - Current time in 12-hour format
  - Full date with day name
  - Time of day period (dawn, day, dusk, night)
  - Cloud cover affecting visibility
  - Current moon phase with emoji and illumination

  ### Weather Command

  The `weather` command (aliases: `forecast`, `conditions`) shows:

  ```
  > weather
  Heavy rain pounds the ground as thunder rumbles in the distance.
  Temperature: 15°C (59°F)
  Wind: 25 kph | Humidity: 80% | Cloud Cover: 90%
  ⚠️ Severe weather conditions
  ```

  **Weather conditions include:**
  - Clear, cloudy, overcast
  - Rain (light to torrential)
  - Storms and thunderstorms
  - Snow and blizzards
  - Fog (reduces visibility)
  - Wind, hail, heat waves, cold snaps

  **Special conditions:**
  - Indoor rooms show "You cannot see the sky from here"
  - Severe weather may affect travel and combat

  ## Time System Details

  ### Time Periods

  | Period | Hours | Characteristics |
  |--------|-------|-----------------|
  | Dawn | 6-8 AM | First light, gradual brightness |
  | Day | 8 AM-6 PM | Full daylight, best visibility |
  | Dusk | 6-8 PM | Fading light, evening twilight |
  | Night | 8 PM-6 AM | Darkness, moon and stars visible |

  **Effects on gameplay:**
  - Some NPCs are only active during certain periods
  - Stealth is easier at night
  - Vision range may be affected
  - Creatures may be nocturnal or diurnal

  ### Seasons

  | Season | Months | Weather Tendencies |
  |--------|--------|-------------------|
  | Spring | Mar-May | Temperate, occasional rain |
  | Summer | Jun-Aug | Warm, long days |
  | Fall | Sep-Nov | Cooling, falling leaves |
  | Winter | Dec-Feb | Cold, snow possible |

  **Seasonal effects:**
  - Temperature ranges vary
  - Daylight hours change
  - Some activities are season-dependent
  - Room descriptions may change

  ## Moon System

  The moon follows a real 29.5-day cycle with 8 phases:

  | Phase | Emoji | Illumination | Direction |
  |-------|-------|--------------|-----------|
  | New Moon | 🌑 | 0-5% | - |
  | Waxing Crescent | 🌒 | 5-25% | Growing |
  | First Quarter | 🌓 | 25-55% | Growing |
  | Waxing Gibbous | 🌔 | 55-95% | Growing |
  | Full Moon | 🌕 | 95-100% | Peak |
  | Waning Gibbous | 🌖 | 95-55% | Shrinking |
  | Last Quarter | 🌗 | 55-25% | Shrinking |
  | Waning Crescent | 🌘 | 25-5% | Shrinking |

  **Moon effects:**
  - Full moon provides natural nighttime illumination
  - New moon means total darkness at night
  - May affect magical or supernatural themes

  ## Weather Conditions

  ### Intensity Levels

  | Level | Impact |
  |-------|--------|
  | Light | Minimal effect, atmospheric |
  | Moderate | Some impact on activities |
  | Heavy | Significant penalties possible |
  | Severe | Dangerous, may restrict movement |

  ### Temperature Descriptions

  | Range | Description |
  |-------|-------------|
  | Below -10°C | Bitterly cold |
  | -10 to 0°C | Freezing |
  | 0 to 10°C | Cold |
  | 10 to 15°C | Cool |
  | 15 to 20°C | Mild |
  | 20 to 25°C | Warm |
  | 25 to 30°C | Hot |
  | Above 30°C | Scorching |

  ### Weather Flags

  - **Severe Weather**: Storms, blizzards, hurricanes may trigger warnings
  - **Reduced Visibility**: Fog and heavy precipitation limit sightlines
  - **Outdoor Penalty**: Rain/snow may affect exposed characters
  - **Stars Visible**: Clear nights show celestial features

  ## Tips & Tricks

  - Check weather before long journeys
  - Use fog for stealthy approaches
  - Plan social events during pleasant weather
  - Night provides natural cover for covert activities
  - Seasonal room descriptions add atmosphere

  ## Related Systems

  - **Navigation**: Weather may affect travel times
  - **Combat**: Visibility affects sightlines
  - **NPCs**: Behavior changes with time/weather
MARKDOWN

ENVIRONMENT_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Environment System consists of four major services managing time, weather, moon phases, and era configurations:

  ```
  Environment System
  ├── GameTimeService     - Clock modes, time periods, seasons
  ├── MoonPhaseService    - Astronomical lunar calculations
  ├── WeatherProseService - Atmospheric descriptions
  ├── WeatherApiService   - OpenWeatherMap integration
  └── EraService          - Era-based feature flags
  ```

  ## Key Services

  ### GameTimeService

  Calculates and formats game time. Supports realtime and accelerated modes.

  **Constants:**
  ```ruby
  TIME_PERIODS = %i[dawn day dusk night].freeze
  SEASONS = %i[spring summer fall winter].freeze
  ```

  **Key Methods:**
  ```ruby
  GameTimeService.current_time(location)    # => Time object
  GameTimeService.time_of_day(location)     # => :dawn, :day, :dusk, :night
  GameTimeService.season(location)          # => :spring, :summer, :fall, :winter
  GameTimeService.night?(location)          # => true/false
  GameTimeService.formatted_time(location)  # => "3:45 PM"
  GameTimeService.formatted_date(location)  # => "Monday, January 3, 2026"
  ```

  **Clock Modes:**
  1. **Realtime** (default): 1 real hour = 1 game hour
  2. **Accelerated**: Configurable ratio (e.g., 4.0 = 4 game hours per real hour)

  ### MoonPhaseService

  Calculates lunar phases using astronomical data.

  **Constants:**
  ```ruby
  LUNAR_CYCLE_DAYS = 29.53059
  KNOWN_NEW_MOON = Time.utc(2000, 1, 6, 18, 14, 0)
  ```

  **Returns MoonPhase struct:**
  ```ruby
  {
    name: 'waning crescent',
    emoji: '🌘',
    illumination: 0.25,        # 0.0 to 1.0
    waxing: false,
    cycle_position: 0.756
  }
  ```

  **Key Methods:**
  ```ruby
  MoonPhaseService.current_phase(date)      # => MoonPhase struct
  MoonPhaseService.emoji(date)              # => '🌘'
  MoonPhaseService.illumination(date)       # => 0.25
  MoonPhaseService.full_moon?(date)         # => illumination >= 0.95
  MoonPhaseService.new_moon?(date)          # => illumination <= 0.05
  ```

  ### WeatherProseService

  Generates atmospheric descriptions with caching.

  **Cache Duration:** 45 minutes

  **Methods:**
  ```ruby
  WeatherProseService.prose_for(location)   # => Cached or fresh prose
  WeatherProseService.generate_for(location) # => Fresh prose only
  WeatherProseService.invalidate_cache!(location)
  ```

  **Prose Generation:**
  1. Check cache (matching location, condition, time, moon)
  2. Try AI generation (if `ai_weather_prose_enabled`)
  3. Fall back to templates

  ### WeatherApiService

  Fetches real-world weather from OpenWeatherMap API.

  **Configuration:**
  - `GameSetting.get('weather_api_key')` - API key
  - Rate limit: 60 calls/minute (free tier)
  - Refresh interval: Configurable per location (default 15 min)

  **Methods:**
  ```ruby
  WeatherApiService.fetch_by_query('London,uk')
  WeatherApiService.fetch_by_coordinates(latitude: 51.5, longitude: -0.1)
  WeatherApiService.update_weather(weather_record)
  WeatherApiService.refresh_all_stale  # For background job
  WeatherApiService.test_connection
  ```

  ### EraService

  Maps time period to era-specific features.

  **Eras:** medieval, gaslight, modern, near_future, scifi

  **Key Methods:**
  ```ruby
  EraService.current_era            # => :modern
  EraService.medieval?              # => true/false
  EraService.currency_config        # => { name: 'Dollar', symbol: '$', ... }
  EraService.phones_available?      # => true/false
  EraService.taxi_available?        # => true/false
  EraService.format_currency(125)   # => '$125.00'
  ```

  ## Key Models

  ### GameClockConfig

  Per-universe time settings.

  **Fields:**
  - `clock_mode`: 'realtime' or 'accelerated'
  - `time_ratio`: Float (game hours per real hour)
  - `game_epoch`, `real_epoch`: For accelerated mode calculation
  - `fixed_dawn_hour`, `fixed_dusk_hour`: Optional overrides

  **Methods:**
  ```ruby
  config.realtime?
  config.accelerated?
  config.start_accelerated_time!(ratio: 4.0)
  config.switch_to_realtime!
  config.current_game_time
  ```

  ### Weather

  Current weather for a location.

  **Key Fields:**
  - `condition`: clear, cloudy, rain, storm, snow, fog, etc.
  - `intensity`: light, moderate, heavy, severe
  - `temperature_c`, `humidity`, `wind_speed_kph`, `cloud_cover`
  - `weather_source`: 'internal' or 'api'
  - `api_location_query`, `api_refresh_minutes`

  **Methods:**
  ```ruby
  weather.severe?                   # Storm/blizzard/severe intensity
  weather.visibility_reduced?       # Fog/storm/blizzard
  weather.outdoor_penalty?          # Rain/snow affects outdoor
  weather.stars_visible?            # Clear enough for stars
  weather.configure_api!(provider: 'openweathermap', location_query: 'London')
  weather.refresh_from_api!
  weather.randomize!                # Internal simulation
  ```

  ### GameSetting

  Global key/value configuration with Redis caching.

  **Relevant Keys:**
  - `weather_api_key`: OpenWeatherMap API key
  - `ai_weather_prose_enabled`: AI prose generation
  - `time_period`: Current era (affects features)
  - `default_clock_mode`: realtime or accelerated
  - `default_time_ratio`: Accelerated ratio

  **Methods:**
  ```ruby
  GameSetting.get('weather_api_key')
  GameSetting.boolean('ai_weather_prose_enabled')
  GameSetting.set('time_period', 'scifi')
  GameSetting.clear_cache!
  ```

  ## Configuration Examples

  ### Enable API Weather

  ```ruby
  GameSetting.set('weather_api_key', 'your_api_key')
  weather = Weather.for_location(location)
  weather.configure_api!(
    provider: 'openweathermap',
    location_query: 'London,uk',
    refresh_minutes: 15
  )
  weather.refresh_from_api!
  ```

  ### Enable Accelerated Time

  ```ruby
  config = GameClockConfig.for_universe(universe)
  config.start_accelerated_time!(ratio: 4.0)
  # Now 4 game hours pass per real hour
  ```

  ### Switch Eras

  ```ruby
  GameSetting.set('time_period', 'scifi')
  # All era-dependent features now use scifi config
  ```

  ## Database Queries

  ```ruby
  # Get weather for location
  Weather.first(location_id: location.id)

  # Find severe weather
  Weather.where { condition IN %w[storm thunderstorm blizzard] }
         .or { intensity = 'severe' }

  # Check room weather visibility
  room.weather_visible == false  # Indoors, no weather
  ```

  ## Integration Points

  **Used by:**
  - Combat: Visibility penalties in fog/storms
  - NPCs: Behavior changes with weather/time
  - Movement: Terrain difficulty in severe weather
  - Display: Atmospheric prose in room descriptions
  - Events: Weather affects planning
MARKDOWN

ENVIRONMENT_QUICK_REFERENCE = <<~MARKDOWN
  ## Time Commands

  | Command | Aliases | Description |
  |---------|---------|-------------|
  | `time` | `clock`, `date` | Show current time, date, moon |
  | `weather` | `forecast`, `conditions` | Show weather conditions |

  ## Time Periods

  | Period | Hours | Description |
  |--------|-------|-------------|
  | Dawn | 6-8 AM | First light |
  | Day | 8 AM-6 PM | Full daylight |
  | Dusk | 6-8 PM | Evening twilight |
  | Night | 8 PM-6 AM | Darkness |

  ## Seasons

  | Season | Months |
  |--------|--------|
  | Spring | Mar-May |
  | Summer | Jun-Aug |
  | Fall | Sep-Nov |
  | Winter | Dec-Feb |

  ## Moon Phases

  | Phase | Emoji | Illumination |
  |-------|-------|--------------|
  | New | 🌑 | 0-5% |
  | Waxing Crescent | 🌒 | 5-25% |
  | First Quarter | 🌓 | 25-55% |
  | Waxing Gibbous | 🌔 | 55-95% |
  | Full | 🌕 | 95-100% |
  | Waning Gibbous | 🌖 | 95-55% |
  | Last Quarter | 🌗 | 55-25% |
  | Waning Crescent | 🌘 | 25-5% |

  ## Weather Conditions

  - Clear, Cloudy, Overcast
  - Rain (light → torrential)
  - Storm, Thunderstorm
  - Snow, Blizzard
  - Fog
  - Wind, Hail
  - Heat Wave, Cold Snap

  ## Intensity Levels

  | Level | Impact |
  |-------|--------|
  | Light | Minimal |
  | Moderate | Some effects |
  | Heavy | Significant |
  | Severe | Dangerous ⚠️ |
MARKDOWN

ENVIRONMENT_CONSTANTS = {
  time_periods: {
    DAWN_START: { value: 6, file: 'app/services/game_time_service.rb', purpose: 'Dawn begins at 6 AM' },
    DAY_START: { value: 8, file: 'app/services/game_time_service.rb', purpose: 'Day begins at 8 AM' },
    DUSK_START: { value: 18, file: 'app/services/game_time_service.rb', purpose: 'Dusk begins at 6 PM' },
    NIGHT_START: { value: 20, file: 'app/services/game_time_service.rb', purpose: 'Night begins at 8 PM' }
  },
  moon: {
    LUNAR_CYCLE_DAYS: { value: 29.53059, file: 'app/services/moon_phase_service.rb', purpose: 'Synodic month length' },
    FULL_MOON_THRESHOLD: { value: 0.95, file: 'app/services/moon_phase_service.rb', purpose: 'Illumination for full moon' },
    NEW_MOON_THRESHOLD: { value: 0.05, file: 'app/services/moon_phase_service.rb', purpose: 'Illumination for new moon' }
  },
  weather: {
    CACHE_DURATION_MINUTES: { value: 45, file: 'app/services/weather_prose_service.rb', purpose: 'Prose cache TTL' },
    API_REFRESH_DEFAULT: { value: 15, file: 'app/models/weather.rb', purpose: 'Default API refresh interval' }
  },
  game_settings: {
    REDIS_CACHE_TTL: { value: 300, file: 'app/models/game_setting.rb', purpose: 'Redis cache TTL (5 min)' }
  },
  eras: {
    AVAILABLE_ERAS: { value: %w[medieval gaslight modern near_future scifi], file: 'app/services/era_service.rb', purpose: 'Valid era options' }
  }
}.freeze

puts "\n[Environment System]"
seed_system('environment', {
  display_name: 'Environment System',
  summary: 'Time, weather, seasons, moon phases, and era configuration',
  description: 'The Environment System simulates realistic time cycles, weather conditions, seasons, and moon phases. Integrates with OpenWeatherMap API for real-world weather.',
  player_guide: ENVIRONMENT_PLAYER_GUIDE,
  staff_guide: ENVIRONMENT_STAFF_GUIDE,
  quick_reference: ENVIRONMENT_QUICK_REFERENCE,
  constants_json: ENVIRONMENT_CONSTANTS,
  command_names: %w[time weather],
  related_systems: %w[navigation combat],
  key_files: [
    'app/services/game_time_service.rb',
    'app/services/moon_phase_service.rb',
    'app/services/weather_prose_service.rb',
    'app/services/weather_api_service.rb',
    'app/services/era_service.rb',
    'app/models/weather.rb',
    'app/models/game_clock_config.rb',
    'app/models/game_setting.rb',
    'plugins/core/environment/commands/'
  ],
  staff_notes: 'GameTimeService handles clock modes. WeatherApiService integrates OpenWeatherMap. EraService controls feature availability per era. Moon phase uses astronomical calculation from reference new moon.',
  display_order: 75
})

# =============================================================================
# WORLD TRAVEL SYSTEM
# =============================================================================

WORLD_TRAVEL_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The World Travel System allows you to journey between distant cities and locations across the game world. Rather than walking through countless intermediate rooms, you travel as a passenger on various vehicles, experiencing the journey as it unfolds across the hex-grid world map.

  World travel is for **long-distance journeys**—crossing continents, traveling between cities, or venturing into distant wilderness. For moving within a location, use regular navigation commands.

  ## Key Concepts

  - **Journey**: A multi-hex trip from your current location to a distant destination
  - **Passengers**: Multiple characters can travel together on the same journey
  - **Vehicles**: Transportation varies by era (horses, carriages, cars, aircraft, etc.)
  - **Hex Grid**: The world is divided into hexagonal tiles with different terrain
  - **Travel Mode**: Land, water, rail, or air depending on route and era

  ## Starting a Journey

  Use the `journey` command to begin traveling:

  ```
  journey to <destination>
  journey to Ravencroft
  voyage to the capital
  embark to Thornfield
  ```

  **Aliases:** `voyage`, `depart`, `embark`, `world_travel`

  **Requirements:**
  - You must not be in combat
  - Your current location must have world coordinates
  - The destination must also have world coordinates
  - Both must be on the same world

  **What happens:**
  1. A journey is created with a calculated hex path
  2. You board an appropriate vehicle for your era
  3. The journey progresses hex-by-hex (approximately 5 minutes per hex)
  4. You can interact with fellow travelers during the trip

  ## Checking Journey Status

  The `eta` command shows your travel status:

  ```
  > eta
  === Journey Status ===
  Destination: Ravencroft
  Vehicle: Horse
  Current terrain: rolling plains
  Distance remaining: 8 hexes
  Estimated arrival: 45 minutes
  ```

  **Aliases:** `arrival`, `travel_status`, `journey_status`

  ## Traveling with Others

  See who's traveling with you using `passengers`:

  ```
  > passengers
  === Passengers aboard the Horse ===
  - You (driving)
  - Sir Lancelot
  - Lady Guinevere

  Destination: Ravencroft
  ETA: 45 minutes
  ```

  **Aliases:** `fellow_travelers`, `traveling_companions`, `travel_party`

  **Notes:**
  - One passenger is the driver (usually whoever started the journey)
  - You can chat, emote, and interact normally with fellow travelers
  - Others can board your journey if they're at your vehicle's location

  ## Leaving Early

  Exit a journey before arrival with `disembark`:

  ```
  > disembark
  You disembark and find yourself in Wilderness (15, 22).
  ```

  **Aliases:** `leave_journey`, `exit_vehicle`, `get_off`, `abandon_journey`

  **Warning:** Disembarking mid-journey leaves you in the wilderness at your current hex coordinates. You may need to find your way to a settlement!

  ## Travel Modes and Vehicles

  The game era determines available transportation:

  **Medieval Era:**
  - Land: Horse, Cart, Wagon
  - Water: Ferry, Rowboat, Sailing Ship
  - No air or rail travel

  **Gaslight Era (Steampunk):**
  - Land: Carriage, Bicycle, Horse
  - Water: Steamship, Ferry
  - Rail: Steam Train

  **Modern Era:**
  - Land: Car, Bus, Motorcycle
  - Water: Ferry, Motorboat
  - Rail: Train
  - Air: Airplane

  **Near Future Era:**
  - Land: Maglev, Hoverbike
  - Water: Hydrofoil
  - Rail: Maglev Train
  - Air: VTOL, Aircraft

  **Science Fiction Era:**
  - Land: Hovercar, Hoverbike
  - Water: Submarine, Hovercraft
  - Air: Shuttle, Spacecraft

  ## Travel Speed Factors

  Journey time depends on several factors:

  | Factor | Effect |
  |--------|--------|
  | Era | Earlier eras travel slower |
  | Vehicle | Fast vehicles (planes) > slow (carts) |
  | Terrain | Mountains/swamps slow you down |
  | Roads | Built roads double travel speed |
  | Travel Mode | Air > Rail > Land > Water (generally) |

  **Examples:**
  - Horse over plains: ~5 minutes per hex
  - Car on highway: ~1 minute per hex
  - Airplane: Even faster

  ## Tips & Tricks

  - Check `eta` regularly to monitor progress
  - Use `passengers` to see who you're traveling with
  - Chat with fellow travelers to pass the time
  - If you disembark early, you may be stranded far from civilization
  - Some terrain (ocean, mountains) may be impassable

  ## Related Systems

  - **Navigation**: For movement within locations
  - **Economy**: Purchasing passage may cost currency
  - **Environment**: Weather may affect travel conditions
MARKDOWN

WORLD_TRAVEL_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The World Travel System uses hex-grid pathfinding for cross-world journeys:

  ```
  World Travel System
  ├── WorldTravelService       - Journey orchestration
  ├── HexPathfindingService    - A* pathfinding on hex grid
  ├── WorldTravelProcessorService - Scheduler-driven advancement
  └── Models
      ├── WorldJourney         - Journey state
      ├── WorldJourneyPassenger - Passenger tracking
      ├── WorldHex             - Terrain/features
      └── Location             - Cities with coordinates
  ```

  ## Key Services

  ### WorldTravelService

  Orchestrates journey creation, boarding, and disembarking.

  **Methods:**
  ```ruby
  WorldTravelService.start_journey(
    character_instance,
    destination: location_obj,
    travel_mode: 'land',      # Optional, auto-detected
    vehicle_type: 'horse'     # Optional, era default
  )
  # => { success: true, journey: WorldJourney }

  WorldTravelService.board_journey(character, journey)
  WorldTravelService.disembark(character)
  WorldTravelService.journey_eta(journey)
  # => { hexes_remaining: 8, time_remaining: "45 min" }
  ```

  **Travel Mode Selection:**
  - If either location is water-adjacent → 'water'
  - If both have train stations → 'rail'
  - Otherwise → 'land'

  **Vehicle by Era:**
  ```ruby
  medieval:    { land: 'horse', water: 'ferry' }
  gaslight:    { land: 'carriage', rail: 'steam_train' }
  modern:      { land: 'car', air: 'airplane' }
  near_future: { land: 'maglev', air: 'aircraft' }
  scifi:       { land: 'hovercar', air: 'shuttle' }
  ```

  ### HexPathfindingService

  A* algorithm on hex grid.

  **Methods:**
  ```ruby
  HexPathfindingService.find_path(
    world: world,
    start_x: 5, start_y: 10,
    end_x: 15, end_y: 20,
    avoid_water: true
  )
  # => [[5,10], [7,10], [9,10], ...]

  HexPathfindingService.direction_between(5, 10, 7, 10)
  # => 'ne', 'se', 'sw', etc.

  HexPathfindingService.build_feature_path(
    world: world, start_x: 5, start_y: 10,
    end_x: 15, end_y: 20, feature_type: 'road'
  )
  ```

  **Movement Costs:**
  - Ocean/Lake: 100 (almost impassable)
  - Mountain: 4
  - Swamp/Ice: 3
  - Forest/Hill: 2
  - Plain/Urban: 1

  ### WorldTravelProcessorService

  Scheduler-driven journey advancement.

  ```ruby
  # Called every ~60 seconds by scheduler
  WorldTravelProcessorService.process_due_journeys!
  # => { advanced: 5, arrived: 2, errors: [] }
  ```

  **Processing:**
  1. Find journeys with `next_hex_at <= Time.now`
  2. Advance to next hex or complete arrival
  3. Notify passengers of terrain changes

  ## Key Models

  ### WorldJourney

  **Fields:**
  - `current_hex_x`, `current_hex_y`: Current position
  - `path_remaining`: JSONB array of [x, y] coordinates
  - `travel_mode`: 'land', 'water', 'air', 'rail'
  - `vehicle_type`: 'horse', 'car', etc.
  - `next_hex_at`: When to advance (scheduler timing)
  - `status`: 'traveling', 'paused', 'arrived', 'cancelled'

  **Methods:**
  ```ruby
  journey.traveling?
  journey.ready_to_advance?
  journey.passengers              # => [CharacterInstance, ...]
  journey.driver                  # First passenger marked as driver
  journey.time_remaining_display  # => "45 minutes"
  journey.advance_to_next_hex!
  journey.complete_arrival!
  ```

  **Time Calculation:**
  ```ruby
  base_time = 300 seconds (5 minutes)
  time_per_hex = base_time / (era_mod * vehicle_mod * terrain_mod * road_mod)
  ```

  ### WorldHex

  Represents a hexagon on world map.

  **Fields:**
  - `terrain_type`: plain, ocean, mountain, forest, etc.
  - `traversable`: Boolean
  - `feature_n`, `feature_ne`, etc.: Directional features (roads, railways)

  **Movement Costs:**
  | Terrain | Cost |
  |---------|------|
  | Ocean/Lake | 100 |
  | Mountain | 4 |
  | Swamp/Ice | 3 |
  | Forest/Hill | 2 |
  | Urban/Plain | 1 |

  ### Location Travel Fields

  **Added to Location model:**
  - `hex_x`, `hex_y`: Position on world grid
  - `has_port`: Can start water journeys
  - `has_train_station`: Can start rail journeys
  - `has_stable`: Horse/cart available
  - `has_ferry_terminal`, `has_bus_depot`

  ## Hex Grid Coordinate Rules

  **CRITICAL:** Y must always be even, X parity depends on Y/2:

  | Y Value | Y/2 | X Must Be |
  |---------|-----|-----------|
  | 0 | 0 (even) | Even |
  | 2 | 1 (odd) | Odd |
  | 4 | 2 (even) | Even |
  | 6 | 3 (odd) | Odd |

  **Always use HexGrid helpers:**
  ```ruby
  HexGrid.valid_hex_coords?(5, 10)      # => true
  HexGrid.to_hex_coords(5.3, 9.8)       # => [6, 10]
  HexGrid.hex_distance(0, 0, 10, 10)    # => 10 hexes
  HexGrid.hex_neighbors(5, 10)          # => neighbor coordinates
  ```

  ## Scheduler Integration

  **In config/initializers/scheduler.rb:**
  ```ruby
  Scheduler.on_cron({ mins: :every }) do |_event|
    results = WorldTravelProcessorService.process_due_journeys!
    # Log results
  end
  ```

  ## Testing

  ```ruby
  # Manual journey test
  world = World.first
  origin = Location.first
  dest = Location.where { id != origin.id }.first
  char = CharacterInstance.first

  result = WorldTravelService.start_journey(char, destination: dest)
  journey = char.reload.current_world_journey

  # Simulate advancement
  WorldTravelProcessorService.process_due_journeys!
  ```
MARKDOWN

WORLD_TRAVEL_QUICK_REFERENCE = <<~MARKDOWN
  ## Journey Commands

  | Command | Aliases | Usage |
  |---------|---------|-------|
  | `journey` | `voyage`, `embark`, `depart` | `journey to <destination>` |
  | `eta` | `arrival`, `travel_status` | `eta` |
  | `passengers` | `fellow_travelers` | `passengers` |
  | `disembark` | `leave_journey`, `get_off` | `disembark` |

  ## Travel Modes

  | Mode | Requires | Examples |
  |------|----------|----------|
  | Land | Default | Horse, car, hoverbike |
  | Water | Port | Ferry, ship, hydrofoil |
  | Rail | Station | Train, maglev |
  | Air | Modern+ era | Airplane, shuttle |

  ## Vehicle Speed (relative)

  | Vehicle | Speed |
  |---------|-------|
  | Cart | 0.8x |
  | Horse | 1.5x |
  | Car | 3.0x |
  | Train | 4.0x |
  | Airplane | 7.0x |
  | Shuttle | 10.0x |

  ## Terrain Difficulty

  | Terrain | Difficulty |
  |---------|------------|
  | Urban/Road | Easy |
  | Plain/Field | Easy |
  | Forest/Hill | Moderate |
  | Desert | Moderate |
  | Swamp/Ice | Hard |
  | Mountain | Very Hard |
  | Ocean | Impassable (land) |

  ## Era Defaults

  | Era | Land | Water | Air |
  |-----|------|-------|-----|
  | Medieval | Horse | Ferry | - |
  | Gaslight | Carriage | Steamship | - |
  | Modern | Car | Ferry | Airplane |
  | Future | Maglev | Hydrofoil | Aircraft |
  | Sci-Fi | Hovercar | Hovercraft | Shuttle |
MARKDOWN

WORLD_TRAVEL_CONSTANTS = {
  timing: {
    BASE_HEX_TIME_SECONDS: { value: 300, file: 'app/models/world_journey.rb', purpose: 'Base 5 min per hex' },
    SCHEDULER_INTERVAL: { value: 60, file: 'config/initializers/scheduler.rb', purpose: 'Process every 60 sec' }
  },
  pathfinding: {
    MAX_PATH_LENGTH: { value: 500, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Maximum path length' },
    IMPASSABLE_COST: { value: 100, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Cost for ocean/lake' }
  },
  terrain_costs: {
    MOUNTAIN: { value: 4, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Mountain movement cost' },
    SWAMP: { value: 3, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Swamp movement cost' },
    FOREST: { value: 2, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Forest movement cost' },
    PLAIN: { value: 1, file: 'app/services/hex_pathfinding_service.rb', purpose: 'Plain movement cost' }
  },
  era_speed_modifiers: {
    MEDIEVAL: { value: 0.5, file: 'app/services/world_travel_service.rb', purpose: 'Medieval era speed mod' },
    GASLIGHT: { value: 1.0, file: 'app/services/world_travel_service.rb', purpose: 'Gaslight era speed mod' },
    MODERN: { value: 2.0, file: 'app/services/world_travel_service.rb', purpose: 'Modern era speed mod' },
    SCIFI: { value: 3.0, file: 'app/services/world_travel_service.rb', purpose: 'Sci-fi era speed mod' }
  }
}.freeze

puts "\n[World Travel System]"
seed_system('world_travel', {
  display_name: 'World Travel System',
  summary: 'Long-distance hex-grid journeys between cities and locations',
  description: 'The World Travel System enables cross-world journeys using hex pathfinding, multiple travel modes, era-appropriate vehicles, and passenger mechanics.',
  player_guide: WORLD_TRAVEL_PLAYER_GUIDE,
  staff_guide: WORLD_TRAVEL_STAFF_GUIDE,
  quick_reference: WORLD_TRAVEL_QUICK_REFERENCE,
  constants_json: WORLD_TRAVEL_CONSTANTS,
  command_names: %w[journey eta passengers disembark],
  related_systems: %w[navigation environment],
  key_files: [
    'app/services/world_travel_service.rb',
    'app/services/hex_pathfinding_service.rb',
    'app/services/world_travel_processor_service.rb',
    'app/models/world_journey.rb',
    'app/models/world_journey_passenger.rb',
    'app/models/world_hex.rb',
    'app/lib/hex_grid.rb',
    'plugins/core/navigation/commands/journey.rb',
    'plugins/core/navigation/commands/eta.rb'
  ],
  staff_notes: 'HexGrid uses offset coordinates with parity rules. Scheduler runs WorldTravelProcessorService every minute. A* pathfinding with terrain costs. EraService determines vehicle types.',
  display_order: 80
})

# =============================================================================
# BUILDING SYSTEM
# =============================================================================

BUILDING_PLAYER_GUIDE = <<~MARKDOWN
  ## Overview

  The Building System allows you to customize and create spaces in the game world. From renaming rooms you own to building entire cities (for staff), the system provides tools for personalizing your environment.

  Most players interact with building through **room ownership**—if you own a room (apartment, home, etc.), you can customize it to your liking.

  ## Key Concepts

  - **Room Ownership**: Owning a room grants customization rights
  - **Places**: Furniture and interaction spots within rooms
  - **Decorations**: Visual elements that enhance room atmosphere
  - **Exits**: Connections between rooms (doors, passages)
  - **Privacy Modes**: Control who can see and enter your space

  ## Room Customization Commands

  ### Renaming Your Room

  ```
  rename <new name>
  ```

  Change your room's display name:
  ```
  > rename Cozy Living Room
  This room is now called 'Cozy Living Room'.
  ```

  ### Setting a Background

  ```
  set background <url>
  ```

  Add a visual background image for graphical clients:
  ```
  > set background https://i.imgur.com/abc123.png
  Background image has been set.
  ```

  Clear with: `set background` (no URL)

  ### Seasonal Descriptions

  Set descriptions that change with time and season:

  ```
  set seasonal desc <time> <season> <text>
  set seasonal bg <time> <season> <url>
  set seasonal list
  set seasonal clear <type> <time> <season>
  ```

  **Time options:** morning, afternoon, evening, night, day, dawn, dusk, default (or `-` for any)
  **Season options:** spring, summer, fall, winter, default (or `-` for any)

  **Examples:**
  ```
  > set seasonal desc morning spring The spring sun streams through the windows...
  > set seasonal desc - winter Snow blankets the view outside...
  > set seasonal bg night - https://example.com/night.jpg
  > set seasonal list
  ```

  ### Window Controls

  Toggle curtains/window visibility:
  ```
  > windows
  You close the curtains. (or: You open the curtains.)
  ```

  ### Setting Your Home

  Mark a room as your spawn location:
  ```
  > make home
  This room is now your home.
  ```

  **Aliases:** `makehome`, `sethome`

  ## Decorations

  Add and modify decorative elements:

  ```
  decorate              - Add a new decoration
  redecorate            - Modify existing decorations
  ```

  Decorations can include images and descriptions that enhance the room's atmosphere.

  ## Graffiti

  Leave your mark (up to 220 characters):
  ```
  > graffiti "Kilroy was here"
  You write graffiti on the wall.
  ```

  Room owners can clean graffiti:
  ```
  > clean graffiti
  You remove all graffiti from this room.
  ```

  ## Privacy Controls

  Room owners can control access:

  ```
  lock doors            - Remove all guest access
  unlock doors          - Grant public access (optional time limit)
  grant access <name>   - Allow specific character access
  revoke access <name>  - Remove character access
  access list           - View current access list
  ```

  ## Creator Mode (Staff/Builders)

  Staff and designated builders can enter creator mode:

  ```
  > creator mode
  You enter creator mode. (You fade from the room.)
  ```

  In creator mode, you can:
  - Build new locations: `build location`
  - Create shops: `build shop`
  - Construct cities: `build city` (staff only)
  - Add buildings: `build block` (staff only)

  Exit creator mode by typing `creator mode` again.

  ## Building Hierarchy

  The world is organized as:

  ```
  World
  └── Area (city, region)
      └── Location (building, landmark)
          └── Room (individual space)
              ├── Places (furniture)
              ├── Decorations
              └── Sub-rooms (closets, alcoves)
  ```

  ## Tips & Tricks

  - Seasonal descriptions add immersion—visitors see different text based on time/season
  - Background images work best with graphical clients
  - Use `access list` to see who can enter your space
  - Graffiti persists until cleaned
  - Room names should be descriptive but not too long

  ## Related Systems

  - **Navigation**: Move between rooms you've created
  - **Economy**: Purchasing property grants ownership
  - **Character**: Home room affects respawn location
MARKDOWN

BUILDING_STAFF_GUIDE = <<~MARKDOWN
  ## Architecture Overview

  The Building System provides room creation, customization, and urban development:

  ```
  Building System
  ├── RoomBuilderService    - CRUD for room elements
  ├── CityBuilderService    - City grid creation
  ├── BlockBuilderService   - Building interior generation
  └── Models
      ├── Room              - Primary container
      ├── Place             - Furniture/interaction spots
      ├── Decoration        - Visual elements
      ├── RoomFeature       - Doors/windows
      ├── RoomExit          - Connections
      └── Graffiti          - Player-written text
  ```

  ## Key Services

  ### RoomBuilderService

  CRUD operations for room elements via admin interface.

  **Methods:**
  ```ruby
  RoomBuilderService.room_to_api_hash(room)
  RoomBuilderService.update_room(room, data)
  RoomBuilderService.create_subroom(parent, data)

  # Places (furniture)
  RoomBuilderService.create_place(room, {
    name: "Red Couch", x: 50, y: 30, capacity: 3
  })
  RoomBuilderService.update_place(place, data)

  # Decorations
  RoomBuilderService.create_decoration(room, data)

  # Features (doors/windows)
  RoomBuilderService.create_feature(room, {
    name: "Wooden Door", feature_type: "door",
    orientation: "north", connected_room_id: other.id
  })

  # Exits
  RoomBuilderService.create_exit(room, {
    direction: 'north', to_room_id: other.id,
    bidirectional: true
  })
  ```

  ### CityBuilderService

  Creates city grids with streets and intersections.

  **Methods:**
  ```ruby
  CityBuilderService.build_city(
    location: location,
    params: {
      city_name: "New York",
      horizontal_streets: 10,
      vertical_streets: 10,
      max_building_height: 200,
      use_llm_names: true
    }
  )
  # => { streets: [...], avenues: [...], intersections: [...] }

  CityBuilderService.can_build?(character, :build_city)
  ```

  ### BlockBuilderService

  Creates buildings at city intersections with interior rooms.

  **Methods:**
  ```ruby
  BlockBuilderService.build_block(
    location: location,
    intersection_room: intersection,
    building_type: :apartment_tower,
    options: { max_height: 200 }
  )

  BlockBuilderService.build_block_layout(
    location: location, intersection_room: intersection,
    layout: :quadrants,
    building_assignments: {
      ne: :house, nw: :brownstone,
      se: :apartment_tower, sw: :shop
    }
  )
  ```

  **Building Types:**
  - Residential: apartment_tower, brownstone, house, townhouse, cottage
  - Commercial: office_tower, hotel, mall, shop, restaurant, bar
  - Civic: church, temple, school, hospital, library, police_station
  - Recreation: park, playground, garden, plaza

  **Layouts:**
  - `full` - Single building fills block
  - `split_ns`, `split_ew` - Two buildings
  - `quadrants` - Four corner buildings
  - `perimeter` - Buildings around central courtyard

  ## Key Models

  ### Room

  **Customization Fields:**
  - `owner_id`: Character who owns room
  - `private_mode`: Excludes from staff broadcasts
  - `seasonal_descriptions`: JSONB (time/season → text)
  - `seasonal_backgrounds`: JSONB (time/season → url)
  - `curtains`: Boolean for window toggle
  - `default_background_url`: Background image

  **Spatial Fields:**
  - `min_x`, `max_x`, `min_y`, `max_y`, `min_z`, `max_z`: Bounds

  **City Fields:**
  - `grid_x`, `grid_y`: City grid position
  - `city_role`: 'building', 'street', 'avenue', 'intersection'
  - `building_type`: apartment_tower, house, etc.

  **Methods:**
  ```ruby
  room.owned_by?(character)
  room.lock_doors!
  room.unlock_doors!(expires_in_minutes: 1440)
  room.grant_access!(character, permanent: true)
  room.revoke_access!(character)
  room.enable_private_mode!
  ```

  ### Place (Furniture)

  **Fields:**
  - `name`, `description`, `image_url`
  - `x`, `y`, `z`: Coordinates
  - `capacity`: How many can use it
  - `is_furniture`: Boolean
  - `default_sit_action`: "on", "in", "at", etc.

  ### RoomFeature (Doors/Windows)

  **Fields:**
  - `feature_type`: door, window, opening, portal, gate
  - `open_state`: open, closed, locked, ajar, broken
  - `transparency_state`: transparent, translucent, opaque
  - `allows_movement`, `allows_sight`
  - `connected_room_id`: Where it leads

  ### RoomExit

  **Fields:**
  - `from_room_id`, `to_room_id`
  - `direction`: north, south, up, down, etc.
  - `exit_name`: "a wooden door"
  - `visible`, `passable`

  ### Graffiti

  Uses legacy Ravencroft schema with column mapping:
  ```ruby
  class Graffiti < Sequel::Model(:graffiti)
    alias_method :x, :g_x
    alias_method :y, :g_y
    alias_method :text, :gdesc
  end
  ```

  ## Permission Levels

  1. **Admin**: Full access—cities, areas, any room
  2. **Staff with Building**: Cities, blocks, locations
  3. **Creator Mode**: Locations, rooms in allowed areas
  4. **Room Owner**: Customize owned rooms only

  **Permission Check Pattern:**
  ```ruby
  unless outer_room.owned_by?(character_instance.character)
    return error_result("You don't own this room.")
  end
  ```

  ## Admin Web Interface

  **Location:** `/admin/room_builder/:room_id`

  **Features:**
  - SVG canvas editor for visual placement
  - Place/decoration/feature CRUD
  - Exit management with bidirectional support
  - Subroom creation
  - Property editing

  ## Database Considerations

  **Seasonal Storage:**
  ```ruby
  # JSONB format
  {
    "morning_spring" => "The spring sun...",
    "night_winter" => "Snow covers...",
    "default" => "Base description"
  }
  ```

  **Fallback Chain:**
  1. Specific time + season
  2. Same time, any season
  3. Any time, same season
  4. Default

  ## Testing Commands

  ```ruby
  # Test room ownership
  room = Room.first
  char = Character.first
  room.update(owner_id: char.id)
  room.owned_by?(char)  # => true

  # Test access control
  room.lock_doors!
  room.grant_access!(other_char)
  room.unlocked_for?(other_char)  # => true
  ```
MARKDOWN

BUILDING_QUICK_REFERENCE = <<~MARKDOWN
  ## Room Customization

  | Command | Permission | Usage |
  |---------|------------|-------|
  | `rename` | Owner | `rename <new name>` |
  | `set background` | Owner | `set background <url>` |
  | `set seasonal` | Owner | `set seasonal desc morning spring <text>` |
  | `windows` | Owner | `windows` (toggle) |
  | `make home` | Owner | `make home` |

  ## Decoration

  | Command | Permission | Usage |
  |---------|------------|-------|
  | `decorate` | Owner | `decorate` |
  | `redecorate` | Owner | `redecorate` |
  | `graffiti` | Anyone | `graffiti <text>` |
  | `clean graffiti` | Owner/Staff | `clean graffiti` |

  ## Access Control

  | Command | Permission | Usage |
  |---------|------------|-------|
  | `lock doors` | Owner | `lock doors` |
  | `unlock doors` | Owner | `unlock doors` |
  | `grant access` | Owner | `grant access <name>` |
  | `revoke access` | Owner | `revoke access <name>` |
  | `access list` | Owner | `access list` |

  ## Creator Mode

  | Command | Permission | Usage |
  |---------|------------|-------|
  | `creator mode` | Staff/Builder | `creator mode` |
  | `build location` | Creator | `build location` |
  | `build shop` | Creator | `build shop` |
  | `build city` | Staff | `build city <name>` |
  | `build block` | Staff | `build block <type>` |

  ## Building Types

  **Residential:** apartment_tower, brownstone, house, townhouse, cottage
  **Commercial:** office_tower, hotel, mall, shop, restaurant, bar
  **Civic:** church, school, hospital, library, police_station
  **Recreation:** park, playground, garden, plaza

  ## Block Layouts

  | Layout | Description |
  |--------|-------------|
  | `full` | Single building |
  | `split_ns` | Two buildings (N/S) |
  | `split_ew` | Two buildings (E/W) |
  | `quadrants` | Four corners |
  | `perimeter` | Ring with courtyard |

  ## Seasonal Time Options

  morning, afternoon, evening, night, day, dawn, dusk, default (or `-` for any)

  ## Seasonal Season Options

  spring, summer, fall, winter, default (or `-` for any)
MARKDOWN

BUILDING_CONSTANTS = {
  room_limits: {
    NAME_MAX_LENGTH: { value: 100, file: 'plugins/core/building/commands/rename.rb', purpose: 'Max room name length' },
    GRAFFITI_MAX_LENGTH: { value: 220, file: 'app/models/graffiti.rb', purpose: 'Max graffiti text' }
  },
  city_building: {
    MIN_STREETS: { value: 2, file: 'app/services/city_builder_service.rb', purpose: 'Minimum streets' },
    MAX_STREETS: { value: 50, file: 'app/services/city_builder_service.rb', purpose: 'Maximum streets' },
    MIN_BUILDING_HEIGHT: { value: 50, file: 'app/services/city_builder_service.rb', purpose: 'Min height in feet' },
    MAX_BUILDING_HEIGHT: { value: 1000, file: 'app/services/city_builder_service.rb', purpose: 'Max height in feet' }
  },
  block_building: {
    FLOORS_APARTMENT_TOWER: { value: '6-15', file: 'app/services/block_builder_service.rb', purpose: 'Apartment floor range' },
    UNITS_PER_FLOOR: { value: 4, file: 'app/services/block_builder_service.rb', purpose: 'Default units per floor' },
    BROWNSTONE_FLOORS: { value: 3, file: 'app/services/block_builder_service.rb', purpose: 'Brownstone floor count' },
    HOUSE_FLOORS: { value: 2, file: 'app/services/block_builder_service.rb', purpose: 'House floor count' }
  },
  room_defaults: {
    DEFAULT_MIN_X: { value: 0, file: 'app/models/room.rb', purpose: 'Default room min X' },
    DEFAULT_MAX_X: { value: 100, file: 'app/models/room.rb', purpose: 'Default room max X' },
    DEFAULT_MIN_Y: { value: 0, file: 'app/models/room.rb', purpose: 'Default room min Y' },
    DEFAULT_MAX_Y: { value: 100, file: 'app/models/room.rb', purpose: 'Default room max Y' }
  }
}.freeze

puts "\n[Building System]"
seed_system('building', {
  display_name: 'Building System',
  summary: 'Room customization, city building, and space creation',
  description: 'The Building System enables room customization (for owners), location creation (for creators), and city/block generation (for staff). Includes places, decorations, exits, and access control.',
  player_guide: BUILDING_PLAYER_GUIDE,
  staff_guide: BUILDING_STAFF_GUIDE,
  quick_reference: BUILDING_QUICK_REFERENCE,
  constants_json: BUILDING_CONSTANTS,
  command_names: %w[rename decorate redecorate graffiti windows creator build],
  related_systems: %w[navigation character economy],
  key_files: [
    'app/services/room_builder_service.rb',
    'app/services/city_builder_service.rb',
    'app/services/block_builder_service.rb',
    'app/models/room.rb',
    'app/models/place.rb',
    'app/models/decoration.rb',
    'app/models/room_feature.rb',
    'app/models/room_exit.rb',
    'app/models/graffiti.rb',
    'plugins/core/building/commands/'
  ],
  staff_notes: 'RoomBuilderService for CRUD. CityBuilderService creates grids. BlockBuilderService generates interiors. Room ownership controls access. Graffiti uses legacy Ravencroft schema columns.',
  display_order: 85
})

# ============================================================================
# EVENTS SYSTEM - Priority 4
# ============================================================================

EVENTS_PLAYER_GUIDE = <<~MARKDOWN
  # Events System

  Events are in-character gatherings where players come together for parties, meetings, competitions, concerts, ceremonies, and more. The Events system provides full lifecycle management from creation to completion.

  ## Overview

  Events allow you to:
  - Schedule gatherings at specific times and locations
  - Invite players and manage RSVPs
  - Add temporary decorations and furniture
  - Use spotlight effects for performances
  - Manage who can enter (bouncing unwanted guests)
  - Track IC logs separately for each event

  ## Finding Events

  ### Viewing the Calendar

  Use the `events` command to see what's happening:

  ```
  events              View all public upcoming events
  events my           Show events you're attending or hosting
  events here         Show events at your current location
  ```

  ### Getting Event Details

  ```
  event info                    View details of current/nearby event
  event info Birthday Party     View details of a specific event
  ```

  ## Attending Events

  ### Joining an Event

  When an event is active at your location:
  ```
  enter event         Join the currently active event
  join event          Same as enter event
  ```

  ### Leaving an Event

  ```
  leave event         Exit the event and return to normal room
  exit event          Same as leave event
  ```

  ### Finding Your Way

  ```
  directions to event Birthday Party    Get directions to an event
  goto event                            Navigate to nearest active event
  ```

  ## Hosting Events

  ### Creating an Event

  **Quick create** (starts 1 hour from now at current room):
  ```
  create event Birthday Party
  ```

  **Full creation** (opens form with all options):
  ```
  create event
  ```

  Event options include:
  - **Name**: Event title
  - **Type**: party, meeting, competition, concert, ceremony, private, public
  - **Start/End Time**: When the event runs
  - **Location**: Where it takes place
  - **Max Attendees**: Capacity limit (optional)
  - **Description**: Event details and rules
  - **Log Visibility**: Who can see event logs (public, attendees, organizer)

  ### Managing Your Event

  As the organizer, you have special controls:

  ```
  start event         Begin your scheduled event (allows others to join)
  end event           Conclude the event (removes all participants)
  ```

  ### Customizing the Space

  Add temporary decorations that exist only during your event:

  ```
  add decoration Balloons=Colorful balloons float near the ceiling
  add decoration Banner=A welcome banner hangs across the entrance
  decorate Streamers
  ```

  Decorations are automatically removed when the event ends.

  ### Spotlight/Camera

  Draw attention to someone during performances:

  ```
  camera Alice        Focus spotlight on Alice
  spotlight Bob       Toggle spotlight on Bob
  ```

  ### Removing Guests

  Remove troublemakers permanently from your event:

  ```
  bounce Bob          Remove Bob from the event (cannot return)
  ```

  ## Event Types

  | Type | Best For |
  |------|----------|
  | `party` | Casual gatherings, celebrations |
  | `meeting` | Formal discussions, planning |
  | `competition` | Contests, tournaments |
  | `concert` | Performances, shows |
  | `ceremony` | Formal rituals, graduations |
  | `private` | Invite-only gatherings |
  | `public` | Open to everyone |

  ## Tips for Hosts

  1. **Set start time appropriately** - Give guests time to arrive
  2. **Use decorations** - They make the space feel special
  3. **Spotlight performers** - Draw attention during key moments
  4. **Set max attendees** - Prevent overcrowding
  5. **Choose log visibility** - Consider privacy needs
MARKDOWN

EVENTS_STAFF_GUIDE = <<~MARKDOWN
  # Events System - Staff Guide

  ## Architecture Overview

  The Events system uses several interconnected models:
  - **Event** - Main event record with status, times, settings
  - **EventAttendee** - Tracks RSVPs, check-ins, bounces
  - **EventDecoration** - Temporary decorations during event
  - **EventPlace** - Temporary furniture during event
  - **EventRoomState** - Snapshots and overrides room state

  ## Key Models

  ### Event Model

  **File:** `app/models/event.rb`

  **Status Flow:**
  ```
  scheduled → active → completed
       ↓
  cancelled
  ```

  **Key Methods:**
  - `start!` / `complete!` / `cancel!` - Status transitions
  - `add_attendee(character, rsvp:)` - Add participant
  - `attending?(character)` - Check attendance
  - `characters_in_event` - All CharacterInstance objects in event
  - `end_for_all!` - Remove all participants, cleanup content
  - `snapshot_room!` - Save room state when starting
  - `decorations_for(room)` / `places_for(room)` - Get temporary content

  ### EventAttendee Model

  **File:** `app/models/event_attendee.rb`

  **RSVP States:** yes, no, maybe, pending
  **Roles:** attendee, host, staff, vip

  **Key Methods:**
  - `confirm!` / `decline!` - RSVP actions
  - `check_in!` - Record entry timestamp
  - `bounce!(bouncer)` - Mark as bounced
  - `can_enter?` - Check if not bounced

  ### CharacterInstance Integration

  **Fields:**
  - `in_event_id` - FK to current event (nil if not in event)
  - `event_camera` - Boolean for spotlight effect

  **Methods:**
  - `in_event?` / `spotlighted?` - Status checks
  - `enter_event!(event)` / `leave_event!` - Join/leave
  - `toggle_spotlight!` - Toggle camera

  ## EventService

  **File:** `app/services/event_service.rb`

  **Creation:**
  ```ruby
  EventService.create_event(
    organizer: character,
    name: 'Party',
    starts_at: 1.hour.from_now,
    room: room,
    event_type: 'party',
    is_public: true
  )
  ```

  **Lifecycle:**
  ```ruby
  EventService.start_event!(event)   # Snapshot room, set active
  EventService.end_event!(event)     # Remove all, cleanup
  EventService.cancel_event!(event)  # Cancel and cleanup
  ```

  **Participation:**
  ```ruby
  EventService.can_enter_event?(event:, character:)
  EventService.enter_event!(event:, character_instance:)
  EventService.leave_event!(character_instance:)
  EventService.rsvp(event:, character:, status: 'yes')
  ```

  **Customization:**
  ```ruby
  EventService.add_decoration(event:, room:, name:, description:, created_by:)
  EventService.add_place(event:, room:, name:, capacity:, place_type:)
  EventService.set_room_description(event:, room:, description:)
  EventService.set_room_background(event:, room:, url:)
  ```

  ## EventRoomDisplayService

  **File:** `app/services/event_room_display_service.rb`

  Extends RoomDisplayService to merge permanent and temporary content:

  ```ruby
  service = EventRoomDisplayService.new(room, viewer_instance, event)
  display = service.build_display
  # Returns merged places, decorations, room state overrides
  ```

  ## Room State Snapshots

  When an event starts, `EventRoomState` captures:
  - Original description
  - Original background URLs

  Event can override these without affecting permanent room:
  ```ruby
  room_state = event.room_state_for(room)
  room_state.set_event_description('Special event description')
  room_state.effective_description  # Returns override or original
  ```

  ## Broadcast Integration

  Event actions broadcast to:
  - **Room** (location) - "X enters [event]"
  - **Event participants** - "X arrives"
  - Specific patterns per action type

  ## Permission Checks

  ```ruby
  EventService.is_host_or_staff?(event:, character:)
  # True if organizer OR has host/staff role in EventAttendee
  ```

  ## Cleanup Lifecycle

  When event ends:
  1. All participants removed (in_event_id set to nil)
  2. Camera flags cleared
  3. EventDecoration records deleted
  4. EventPlace records deleted
  5. EventRoomState preserved (for historical reference)
  6. Status set to 'completed'
MARKDOWN

EVENTS_QUICK_REFERENCE = <<~MARKDOWN
  # Events Quick Reference

  ## Player Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `events` | `events [my\\|here]` | View calendar |
  | `event info` | `event info [name]` | View event details |
  | `enter event` | `enter event` | Join active event |
  | `leave event` | `leave event` | Exit current event |
  | `directions to event` | `directions to event <name>` | Get directions |

  ## Host Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `create event` | `create event [name]` | Create new event |
  | `start event` | `start event [name]` | Begin scheduled event |
  | `end event` | `end event` | Conclude event |
  | `add decoration` | `add decoration <name>=<desc>` | Add temp decor |
  | `camera` | `camera <character>` | Toggle spotlight |
  | `bounce` | `bounce <character>` | Remove from event |

  ## Event Types

  party, meeting, competition, concert, ceremony, private, public

  ## Event Statuses

  scheduled → active → completed (or cancelled)

  ## RSVP Statuses

  yes, no, maybe, pending

  ## Attendee Roles

  attendee, host, staff, vip
MARKDOWN

EVENTS_CONSTANTS = {
  event_types: {
    TYPES: { value: %w[party meeting competition concert ceremony private public], file: 'app/models/event.rb', purpose: 'Valid event types' }
  },
  statuses: {
    STATUSES: { value: %w[scheduled active completed cancelled], file: 'app/models/event.rb', purpose: 'Event status flow' },
    LOG_VISIBILITY: { value: %w[public attendees organizer], file: 'app/models/event.rb', purpose: 'Who can see event logs' }
  },
  attendee: {
    RSVP_STATUSES: { value: %w[yes no maybe pending], file: 'app/models/event_attendee.rb', purpose: 'RSVP options' },
    ROLES: { value: %w[attendee host staff vip], file: 'app/models/event_attendee.rb', purpose: 'Attendee roles' }
  },
  places: {
    PLACE_TYPES: { value: %w[furniture seating stage bar table booth lounge other], file: 'app/models/event_place.rb', purpose: 'Temporary furniture types' }
  },
  defaults: {
    DEFAULT_QUICK_START: { value: '1 hour', file: 'plugins/core/events/commands/create_event.rb', purpose: 'Quick create start time' },
    DEFAULT_TYPE: { value: 'party', file: 'plugins/core/events/commands/create_event.rb', purpose: 'Default event type' },
    DEFAULT_PUBLIC: { value: true, file: 'plugins/core/events/commands/create_event.rb', purpose: 'Default visibility' }
  }
}.freeze

puts "\n[Events System]"
seed_system('events', {
  display_name: 'Events System',
  summary: 'Calendar events, gatherings, and temporary room customization',
  description: 'The Events System provides comprehensive event management with calendars, RSVPs, temporary decorations, spotlight controls, and participant management.',
  player_guide: EVENTS_PLAYER_GUIDE,
  staff_guide: EVENTS_STAFF_GUIDE,
  quick_reference: EVENTS_QUICK_REFERENCE,
  constants_json: EVENTS_CONSTANTS,
  command_names: %w[events event\ info create\ event start\ event end\ event enter\ event leave\ event add\ decoration camera bounce],
  related_systems: %w[communication navigation building],
  key_files: [
    'app/models/event.rb',
    'app/models/event_attendee.rb',
    'app/models/event_decoration.rb',
    'app/models/event_place.rb',
    'app/models/event_room_state.rb',
    'app/services/event_service.rb',
    'app/services/event_room_display_service.rb',
    'plugins/core/events/commands/'
  ],
  staff_notes: 'EventService handles lifecycle. Room state snapshots preserve originals. Temporary content auto-deleted on event end. CharacterInstance.in_event_id tracks participation.',
  display_order: 90
})

# ============================================================================
# ACTIVITIES SYSTEM - Priority 4
# ============================================================================

ACTIVITIES_PLAYER_GUIDE = <<~MARKDOWN
  # Activities System

  Activities are structured game experiences where players collaborate to overcome challenges. They include missions, competitions, tasks, and more. Each activity consists of a series of **rounds** where participants make choices, roll stats, and progress toward success or failure.

  ## Overview

  Activities provide:
  - **Missions** - Narrative-driven challenges with branching paths
  - **Competitions** - Individual or team contests
  - **Tasks** - Quick, focused challenges
  - **Dice mechanics** - Roll 2d8 with stat modifiers
  - **Willpower system** - Strategic resource management
  - **Team play** - Collaborative or competitive modes

  ## Basic Workflow

  1. **Find activities**: `activity list`
  2. **Start or join**: `activity start <name>` or `activity join`
  3. **Check status**: `activity status`
  4. **Make your choice**: `activity choose <action>`
  5. **Adjust effort** (optional): `activity effort <1-4>`
  6. **Mark ready**: `activity ready`
  7. **Repeat** until activity concludes

  ## Commands

  ### Discovery & Participation

  ```
  activity list        List available activities in your room
  activity join        Join the running activity
  activity leave       Leave the activity
  activity status      View current round and your choices
  ```

  ### Making Choices

  Each round presents actions to choose from:

  ```
  activity choose 1    Pick action #1
  activity choose 3    Pick action #3
  activity help Alice  Help Alice (she gets advantage on her roll)
  activity recover     Skip your roll, gain 1 willpower
  activity ready       Confirm you're done choosing
  ```

  ### Effort Levels

  Control how hard you try (costs willpower for higher levels):

  ```
  activity effort 1    Minimal effort - roll 1d8
  activity effort 2    Normal effort - roll 2d8 (default)
  activity effort 3    Strong effort - roll 3d8, costs 1 willpower
  activity effort 4    Maximum effort - roll 4d8, costs 2 willpower
  ```

  ### Special Round Types

  **Branch Rounds** (voting on paths):
  ```
  activity vote        See available choices
  activity vote 1      Vote for option #1
  ```

  **Rest Rounds** (recovery):
  ```
  activity heal        Recover HP (permanent damage = damage/2)
  activity continue    Vote to continue from rest
  ```

  **Free Roll Rounds** (open-ended, AI-powered):
  ```
  activity assess look for guards    Learn about the situation
  activity action pick the lock      Attempt an action
  ```

  **Persuade Rounds** (NPC conversation):
  ```
  activity persuade    Try to convince the NPC
  ```

  ## Dice Mechanics

  ### Base Rolling

  - **Standard roll**: 2d8 + stat modifier
  - **Exploding dice**: Roll again on 8, add to total
  - **Success**: Total ≥ Difficulty Class (DC)

  ### Help System

  When you help another player:
  - You don't roll
  - They roll 2 dice and take the higher
  - **Exception**: If either die is a 1, they must take the 1

  ### Willpower

  - Start with 10 willpower per activity
  - Maximum of 10 (capped)
  - Effort level 3 costs 1 willpower
  - Effort level 4 costs 2 willpower
  - Use `activity recover` to gain 1 willpower (skips your roll)

  ## Activity Types

  | Type | Description |
  |------|-------------|
  | `mission` | Narrative challenges with rounds and choices |
  | `competition` | Individual players compete |
  | `tcompetition` | Team-based competition |
  | `task` | Quick, focused challenges |
  | `elimination` | Last player standing wins |
  | `collaboration` | Work together toward shared goal |
  | `adventure` | Narrative adventure |
  | `mystery` | Puzzle/mystery solving |
  | `encounter` | Single confrontation |
  | `survival` | Environmental/resource challenge |

  ## Round Types

  | Type | Description |
  |------|-------------|
  | `standard` | Choose action, roll stats, compare to DC |
  | `reflex` | Quick reaction (2 min timeout instead of 8) |
  | `group_check` | Everyone rolls, combined result |
  | `branch` | Vote on which path to take |
  | `combat` | Fight against NPCs |
  | `free_roll` | Open-ended, AI determines stats/DC |
  | `persuade` | Convince NPC through conversation |
  | `rest` | Recovery point, heal and vote to continue |

  ## Tips

  1. **Manage willpower** - Don't spend it all early
  2. **Help strategically** - Advantage on key rolls
  3. **Recover when safe** - Regain willpower during easy rounds
  4. **Coordinate with team** - Spread out actions to cover skills
  5. **Study free roll** - AI picks stats based on your description
MARKDOWN

ACTIVITIES_STAFF_GUIDE = <<~MARKDOWN
  # Activities System - Staff Guide

  ## Architecture Overview

  Activities use several interconnected models:
  - **Activity** - Template definition with type and settings
  - **ActivityInstance** - Running instance of an activity
  - **ActivityParticipant** - Player state within instance
  - **ActivityRound** - Round definition with type and DC
  - **ActivityAction** - Available choices per round
  - **ActivityLog** - Narrative and outcome logging

  ## Key Models

  ### Activity Model

  **File:** `app/models/activity.rb`

  **Key Attributes:**
  - `aname` - Activity name
  - `atype` - Type (mission, competition, task, etc.)
  - `share_type` - public/private/unique
  - `launch_mode` - creator/anyone/anchor
  - `location` - Room where it runs

  **Activity Types:**
  ```ruby
  ACTIVITY_TYPES = %w[
    mission competition tcompetition task elimination
    collaboration adventure mystery encounter survival
    intersym interasym
  ].freeze
  ```

  ### ActivityInstance Model

  **File:** `app/models/activity_instance.rb`

  **Key Attributes:**
  - `activity_id` - Link to template
  - `room_id` - Where running
  - `setup_stage` - 1=setup, 2=running, 3=complete
  - `rounds_done` - Progress tracker
  - `branch` - Current branch (0=main)

  **Key Methods:**
  - `current_round` - Get active round
  - `active_participants` - Players still in
  - `all_ready?` - Check if input complete
  - `advance_round!` - Move to next round

  ### ActivityParticipant Model

  **File:** `app/models/activity_participant.rb`

  **Key Attributes:**
  - `willpower` - Current willpower (0-10)
  - `action_chosen` - Selected action ID
  - `effort_chosen` - Effort level
  - `roll_result` - Dice result

  **Effort Levels:**
  ```ruby
  EFFORT_LEVELS = {
    '1' => { dice: 1, name: 'Minimal' },
    '2' => { dice: 2, name: 'Normal' },
    '3' => { dice: 3, name: 'Strong' },
    '4' => { dice: 4, name: 'Maximum' },
    'wildcard' => { dice: 2, name: 'Wildcard' },
    'psychic' => { dice: 2, name: 'Psychic' }
  }.freeze
  ```

  ### ActivityRound Model

  **File:** `app/models/activity_round.rb`

  **Round Types:**
  ```ruby
  ROUND_TYPES = %w[
    standard group_check reflex branch combat
    free_roll persuade rest mystery mysterybranch break
  ].freeze
  ```

  **Timeouts:**
  - `DEFAULT_TIMEOUT = 480` (8 minutes)
  - `REFLEX_TIMEOUT = 120` (2 minutes)

  ## Services

  ### ActivityService

  **File:** `app/services/activity_service.rb`

  Main orchestrator:
  ```ruby
  ActivityService.start_activity(activity, room:, initiator:, event:)
  ActivityService.add_participant(instance, character_instance, team:, role:)
  ActivityService.submit_choice(participant, action_id:, effort:, risk:, target_id:)
  ActivityService.check_all_ready(instance)  # Triggers resolution if ready
  ActivityService.resolve_round(instance)
  ActivityService.advance_round(instance)
  ActivityService.complete_activity(instance, success:)
  ```

  **Constants:**
  - `INPUT_TIMEOUT_SECONDS = 480`

  ### ActivityResolutionService

  **File:** `app/services/activity_resolution_service.rb`

  Handles dice rolling and outcome determination:
  ```ruby
  ActivityResolutionService.resolve(instance, round)
  # Returns RoundResult with participant rolls, success flag, etc.
  ```

  **Dice Mechanics:**
  - Base: 2d8 exploding on 8
  - Willpower: Extra d8s (1-2)
  - Risk: Optional d4 [-4 to +4]
  - Help: Roll 2, take higher (unless either is 1)

  ### ActivityRestService

  **File:** `app/services/activity_rest_service.rb`

  Handles rest round healing:
  ```ruby
  ActivityRestService.heal_at_rest(participant)
  ActivityRestService.vote_to_continue(participant)
  ActivityRestService.ready_to_continue?(instance)  # >50% majority
  ```

  **Permanent Damage:** damage_taken / 2 (integer division)

  ### ActivityFreeRollService

  **File:** `app/services/activity_free_roll_service.rb`

  LLM-powered open-ended rounds:
  ```ruby
  ActivityFreeRollService.assess(participant, description, round)
  ActivityFreeRollService.take_action(participant, description, round)
  ```

  Config:
  - Model: `claude-sonnet-4-6`
  - Enabled: `GameSetting.boolean('activity_free_roll_enabled')`

  ### ActivityPersuadeService

  **File:** `app/services/activity_persuade_service.rb`

  NPC conversation rounds:
  ```ruby
  ActivityPersuadeService.attempt_persuasion(participant, instance, round)
  ```

  ## Creating Activities

  1. Create Activity record with `aname`, `atype`, settings
  2. Create ActivityRound records (sequential `round_number`)
  3. Create ActivityAction records for choices
  4. Set `difficulty_class` on rounds

  ## Key Files

  - **Commands:** `plugins/core/activity/commands/activity.rb`
  - **Models:** `app/models/activity*.rb`
  - **Services:** `app/services/activity_*.rb` (11 files)

  ## Integration Points

  - **Combat System** - Combat rounds trigger FightService
  - **Event System** - Activities can be part of events
  - **Stat System** - Actions use character stats for modifiers
  - **RP Logging** - ActivityLog tracks narrative
MARKDOWN

ACTIVITIES_QUICK_REFERENCE = <<~MARKDOWN
  # Activities Quick Reference

  ## Basic Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `activity list` | `activity list` | See available activities |
  | `activity start` | `activity start <name>` | Start an activity |
  | `activity join` | `activity join` | Join running activity |
  | `activity leave` | `activity leave` | Leave activity |
  | `activity status` | `activity status` | View current state |

  ## Choice Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | `activity choose` | `activity choose <#>` | Pick an action |
  | `activity help` | `activity help <player>` | Give advantage |
  | `activity recover` | `activity recover` | Skip roll, gain WP |
  | `activity effort` | `activity effort <1-4>` | Set effort level |
  | `activity ready` | `activity ready` | Confirm choices |

  ## Special Round Commands

  | Command | Usage | Round Type |
  |---------|-------|------------|
  | `activity vote` | `activity vote <#>` | Branch rounds |
  | `activity heal` | `activity heal` | Rest rounds |
  | `activity continue` | `activity continue` | Rest rounds |
  | `activity assess` | `activity assess <desc>` | Free roll |
  | `activity action` | `activity action <desc>` | Free roll |
  | `activity persuade` | `activity persuade` | Persuade |

  ## Effort Levels

  | Level | Dice | Willpower Cost |
  |-------|------|----------------|
  | 1 | 1d8 | 0 |
  | 2 | 2d8 | 0 (default) |
  | 3 | 3d8 | 1 |
  | 4 | 4d8 | 2 |

  ## Round Types

  standard, reflex, group_check, branch, combat, free_roll, persuade, rest, mystery, break

  ## Activity Types

  mission, competition, tcompetition, task, elimination, intersym, interasym
MARKDOWN

ACTIVITIES_CONSTANTS = {
  activity_types: {
    TYPES: { value: %w[mission competition tcompetition task elimination intersym interasym], file: 'app/models/activity.rb', purpose: 'Valid activity types' },
    SHARE_TYPES: { value: %w[public private unique], file: 'app/models/activity.rb', purpose: 'Visibility options' },
    LAUNCH_MODES: { value: %w[creator anyone anchor], file: 'app/models/activity.rb', purpose: 'Who can start activity' }
  },
  rounds: {
    ROUND_TYPES: { value: %w[standard reflex group_check branch combat free_roll persuade rest mystery mysterybranch break], file: 'app/models/activity_round.rb', purpose: 'Round type options' },
    DEFAULT_TIMEOUT: { value: 480, file: 'app/models/activity_round.rb', purpose: '8 minute timeout' },
    REFLEX_TIMEOUT: { value: 120, file: 'app/models/activity_round.rb', purpose: '2 minute reflex timeout' }
  },
  effort: {
    MINIMAL_DICE: { value: 1, file: 'app/models/activity_participant.rb', purpose: 'Level 1 dice' },
    NORMAL_DICE: { value: 2, file: 'app/models/activity_participant.rb', purpose: 'Level 2 dice (default)' },
    STRONG_DICE: { value: 3, file: 'app/models/activity_participant.rb', purpose: 'Level 3 dice' },
    MAXIMUM_DICE: { value: 4, file: 'app/models/activity_participant.rb', purpose: 'Level 4 dice' },
    STRONG_WP_COST: { value: 1, file: 'app/models/activity_participant.rb', purpose: 'WP cost for level 3' },
    MAXIMUM_WP_COST: { value: 2, file: 'app/models/activity_participant.rb', purpose: 'WP cost for level 4' }
  },
  willpower: {
    STARTING_WILLPOWER: { value: 10, file: 'app/models/activity_participant.rb', purpose: 'Initial WP per activity' },
    MAX_WILLPOWER: { value: 10, file: 'app/models/activity_participant.rb', purpose: 'WP cap' }
  },
  service: {
    INPUT_TIMEOUT_SECONDS: { value: 480, file: 'app/services/activity_service.rb', purpose: 'Auto-resolve timeout' }
  }
}.freeze

puts "\n[Activities System]"
seed_system('activities', {
  display_name: 'Activities System',
  summary: 'Missions, competitions, tasks, and structured challenges',
  description: 'The Activities System provides structured game experiences with rounds, dice mechanics, willpower management, and collaborative/competitive gameplay modes.',
  player_guide: ACTIVITIES_PLAYER_GUIDE,
  staff_guide: ACTIVITIES_STAFF_GUIDE,
  quick_reference: ACTIVITIES_QUICK_REFERENCE,
  constants_json: ACTIVITIES_CONSTANTS,
  command_names: %w[activity],
  related_systems: %w[combat dice character],
  key_files: [
    'app/models/activity.rb',
    'app/models/activity_instance.rb',
    'app/models/activity_participant.rb',
    'app/models/activity_round.rb',
    'app/models/activity_action.rb',
    'app/models/activity_log.rb',
    'app/services/activity_service.rb',
    'app/services/activity_resolution_service.rb',
    'app/services/activity_rest_service.rb',
    'app/services/activity_free_roll_service.rb',
    'app/services/activity_persuade_service.rb',
    'plugins/core/activity/commands/'
  ],
  staff_notes: 'ActivityService orchestrates lifecycle. Resolution uses 2d8 exploding dice. Free roll/persuade use LLM. Rest healing has permanent damage formula. 11 service files total.',
  display_order: 95
})

# ============================================================================
# DELVE SYSTEM - Priority 4
# ============================================================================

DELVE_PLAYER_GUIDE = <<~MARKDOWN
  # Delve System

  Delve is a roguelike-style procedural dungeon exploration system. Enter time-limited dungeons to collect loot, defeat monsters, navigate traps, and solve puzzles before time runs out.

  ## Overview

  Delve features:
  - **Procedurally-generated dungeons** with grid-based levels
  - **Time pressure** (60 minutes default) - every action costs time
  - **Fog of war** - explore to reveal the map
  - **Traps** with timing puzzles you must learn
  - **Skill blockers** requiring stat checks
  - **Puzzles** blocking progression
  - **Roving monsters** that move when you act
  - **Treasure** scaled by depth

  ## Getting Started

  ### Entering a Delve

  ```
  delve enter                  Create dungeon with default name
  delve enter Dark Cave        Create dungeon with custom name
  ```

  ### Basic Navigation

  Movement costs 10 seconds each:
  ```
  delve n / delve north       Move north
  delve s / delve south       Move south
  delve e / delve east        Move east
  delve w / delve west        Move west
  delve down                  Descend to next level (at exit)
  ```

  **Shortcut**: When inside a delve, you can use just `n`, `s`, `e`, `w`, etc.

  ### Information Commands

  ```
  delve look / delve l        View current room
  delve map                   Show minimap with fog of war
  delve fullmap               Show all explored rooms
  delve status                View HP, loot, time, progress
  ```

  ### Actions

  ```
  delve grab / delve take     Collect treasure (no time cost)
  delve fight                 Combat monster (5 minutes)
  delve recover               Heal to full HP (5 minutes)
  delve focus                 Gain 1 willpower die (30 seconds)
  delve flee / delve exit     Exit dungeon with your loot
  ```

  ## Obstacles

  ### Traps

  Traps block movement in a direction with a timing puzzle. You must observe the pattern and pass during a safe moment.

  ```
  delve study north           Study the trap in that direction
  delve listen north          Observe pattern (10 sec per observation)
  delve go north 4            Attempt passage at pulse #4
  ```

  **Trap Timing**: Traps have a repeating pattern. Watch for "safe" pulses where you can pass. First-time passage requires 2 consecutive safe pulses.

  ### Skill Blockers

  Blockers require stat checks to pass:

  | Type | Stat | On Failure |
  |------|------|------------|
  | Barricade | STR | Blocked |
  | Locked Door | DEX | Blocked |
  | Gap | AGI | Damage, pass anyway |
  | Narrow | AGI | Damage, pass anyway |

  ```
  delve study east            Study the blocker
  delve easier east           Lower DC by 1 (30 seconds)
  ```

  Then just move in that direction to attempt the check.

  ### Puzzles

  Some rooms contain puzzles that must be solved:

  ```
  delve study puzzle          Examine the puzzle
  delve solve <answer>        Attempt solution (15 seconds)
  ```

  Puzzle types: symbol grids, pipe networks, toggle matrices

  ## Combat

  When encountering monsters:

  ```
  delve fight                 Engage monster (5 minutes)
  delve study goblin          Study monster type for +2 bonus (1 min)
  ```

  Combat deals damage to you based on monster tier. Victory grants bonus loot.

  ## Monster Tiers

  From weakest to strongest: rat, spider, goblin, skeleton, orc, troll, ogre, demon, dragon

  ## Time Management

  **Every action costs time:**
  - Movement: 10 seconds
  - Combat: 5 minutes
  - Recovery: 5 minutes
  - Study monster: 1 minute
  - Listen (trap): 10 seconds per observation
  - Easier (blocker): 30 seconds
  - Puzzle attempt: 15 seconds
  - Focus: 30 seconds

  **Time runs out** = lose 50% loot, forced exit

  ## Minimap Legend

  - `@` = You
  - `M` = Monster
  - `$` = Treasure
  - `T` = Trap
  - `X` = Blocker
  - `>` = Exit (descend)
  - `^` = Entrance
  - Fog hides unexplored areas

  ## Tips

  1. **Study monsters** - +2 bonus saves health
  2. **Learn trap patterns** - Don't rush, observe first
  3. **Use easier** - Reduce blocker DCs when needed
  4. **Grab treasure first** - No time cost
  5. **Recover strategically** - 5 minutes is significant
  6. **Don't overstay** - Better to flee with loot than die
  7. **Watch roving monsters** - They move when you act
MARKDOWN

DELVE_STAFF_GUIDE = <<~MARKDOWN
  # Delve System - Staff Guide

  ## Architecture Overview

  The Delve system uses a grid-based procedural generation approach:
  - **Delve** - Main dungeon record with settings
  - **DelveRoom** - Grid cells with coordinates and content
  - **DelveParticipant** - Player state and progress
  - **DelveMonster** - Roving enemies
  - **DelveTrap** - Timing-based obstacles
  - **DelveBlocker** - Skill check obstacles
  - **DelvePuzzle** - Puzzle rooms
  - **DelveTreasure** - Loot containers

  ## Key Models

  ### Delve Model

  **File:** `app/models/delve.rb`

  **Key Attributes:**
  - `difficulty` - 'easy', 'normal', 'hard', 'nightmare'
  - `status` - 'generating', 'active', 'completed', 'abandoned', 'failed'
  - `time_limit_minutes` - Default 60
  - `grid_width`, `grid_height` - Default 15x15
  - `seed` - For reproducible generation
  - `monster_move_counter` - Tracks monster movement triggers

  **Action Time Costs:**
  ```ruby
  ACTION_TIMES_SECONDS = {
    move: 10,
    combat: 300,      # 5 minutes
    recover: 300,     # 5 minutes
    focus: 30,
    study: 60,        # 1 minute
    trap_listen: 10,
    easier: 30,
    puzzle_attempt: 15,
    puzzle_hint: 30
  }
  ```

  ### DelveRoom Model

  **File:** `app/models/delve_room.rb`

  **Room Types:** corridor, chamber, treasure, monster, trap, puzzle, boss, exit

  **Key Attributes:**
  - `level` - Which dungeon level
  - `grid_x`, `grid_y` - Grid coordinates
  - `is_entrance`, `is_exit` - Special flags
  - `is_terminal` - Dead-end (1 exit only)
  - Content flags: `has_treasure`, `has_monster`, `has_trap`, `has_puzzle`

  ### DelveTrap Model

  **File:** `app/models/delve_trap.rb`

  Uses coprime number timing patterns:
  ```ruby
  # Trap is dangerous at ticks divisible by timing_a OR timing_b
  trapped_at?(tick) # (tick % timing_a).zero? || (tick % timing_b).zero?

  # First passage: chosen tick AND next tick must be safe
  # Experienced: only chosen tick must be safe
  safe_at?(tick, experienced: false)
  ```

  ### DelveBlocker Model

  **File:** `app/models/delve_blocker.rb`

  **Types:**
  - `barricade` (STR) - Blocked on fail
  - `locked_door` (DEX) - Blocked on fail
  - `gap` (AGI) - Damage + pass on fail
  - `narrow` (AGI) - Damage + pass on fail

  **DC Calculation:**
  ```ruby
  base_dc = GameSetting.integer('delve_base_skill_dc') || 10
  dc_per_level = GameSetting.integer('delve_dc_per_level') || 2
  dc = base_dc + (dc_per_level * level) - easier_attempts
  ```

  ## Services

  ### DelveGeneratorService

  **File:** `app/services/delve_generator_service.rb`

  Generates procedural levels using fractal branching:
  1. Main tunnel (25% of rooms) - vertical path
  2. Sub-tunnels (75%) - branch recursively
  3. Place content based on difficulty weights
  4. Add traps, blockers, puzzles, treasures

  **Room Type Weights by Difficulty:**
  - Easy: 50% corridor, 5% monster
  - Nightmare: 20% corridor, 35% monster

  ### DelveMovementService

  **File:** `app/services/delve_movement_service.rb`

  Handles movement, trap passages, level transitions:
  ```ruby
  DelveMovementService.move!(participant, direction, trap_pulse:, trap_sequence_start:)
  DelveMovementService.descend!(participant)
  DelveMovementService.look(participant)
  ```

  ### DelveMapService

  **File:** `app/services/delve_map_service.rb`

  Renders minimap as canvas commands or ASCII:
  ```ruby
  DelveMapService.render_minimap(participant)  # Canvas format
  DelveMapService.render_ascii(participant)    # Text format
  ```

  ### DelveVisibilityService

  **File:** `app/services/delve_visibility_service.rb`

  Fog of war with visibility ranges:
  - Full visibility: current + adjacent rooms
  - Danger visibility: 2 rooms away (monsters only)
  - Explored: previously visited rooms

  ### DelveActionService

  **File:** `app/services/delve_action_service.rb`

  Non-movement actions:
  ```ruby
  DelveActionService.fight!(participant)
  DelveActionService.recover!(participant)
  DelveActionService.focus!(participant)
  DelveActionService.study!(participant, monster_type)
  DelveActionService.flee!(participant)
  ```

  ## GameSettings

  | Setting | Default | Purpose |
  |---------|---------|---------|
  | `delve_base_monster_multiplier` | 0.5 | Monster difficulty |
  | `delve_monster_level_increase` | 0.2 | +20% per level |
  | `delve_base_skill_dc` | 10 | Base DC |
  | `delve_dc_per_level` | 2 | DC increase per level |
  | `delve_monster_move_threshold` | 10 | Seconds to trigger movement |
  | `delve_defeat_loot_penalty` | 0.5 | Lose 50% on death |

  ## Key Mechanics

  ### Monster Movement

  Monsters move when player spends time:
  ```ruby
  delve.tick_monster_movement!(seconds_spent)
  # Returns collision data if monster enters player's room
  ```

  ### Treasure Scaling

  Base: 5-10 gold
  Multiplier: 2^(level-1)
  - Level 1: 5-10g
  - Level 2: 10-20g
  - Level 3: 20-40g

  ### Defeat/Timeout Penalties

  Both result in losing 50% of collected loot.

  ## File Structure

  - **Command:** `plugins/core/delve/commands/delve.rb`
  - **Models:** `app/models/delve*.rb` (8 files)
  - **Services:** `app/services/delve_*.rb` (10+ files)
MARKDOWN

DELVE_QUICK_REFERENCE = <<~MARKDOWN
  # Delve Quick Reference

  ## Navigation

  | Command | Time | Description |
  |---------|------|-------------|
  | `delve enter [name]` | - | Create/enter dungeon |
  | `n/s/e/w` | 10s | Move in direction |
  | `delve down` | 10s | Descend at exit |
  | `delve flee` | - | Exit with loot |

  ## Information

  | Command | Description |
  |---------|-------------|
  | `delve look` | View current room |
  | `delve map` | Minimap with fog |
  | `delve fullmap` | All explored rooms |
  | `delve status` | HP, loot, time, progress |

  ## Actions

  | Command | Time | Description |
  |---------|------|-------------|
  | `delve grab` | 0 | Collect treasure |
  | `delve fight` | 5 min | Combat monster |
  | `delve recover` | 5 min | Heal to full |
  | `delve focus` | 30s | Gain 1 willpower die |

  ## Obstacles

  | Command | Time | Description |
  |---------|------|-------------|
  | `delve study <dir>` | 0 | Study trap/blocker |
  | `delve study <monster>` | 1 min | Study monster (+2 bonus) |
  | `delve listen <dir>` | 10s | Observe trap pattern |
  | `delve go <dir> <#>` | 10s | Pass trap at pulse |
  | `delve easier <dir>` | 30s | Lower blocker DC by 1 |
  | `delve study puzzle` | 0 | Examine puzzle |
  | `delve solve <answer>` | 15s | Attempt puzzle |

  ## Blocker Types

  | Type | Stat | On Failure |
  |------|------|------------|
  | Barricade | STR | Blocked |
  | Locked Door | DEX | Blocked |
  | Gap | AGI | Damage, pass |
  | Narrow | AGI | Damage, pass |

  ## Monster Tiers

  rat → spider → goblin → skeleton → orc → troll → ogre → demon → dragon

  ## Map Legend

  `@` You | `M` Monster | `$` Treasure | `T` Trap | `X` Blocker | `>` Exit | `^` Entrance
MARKDOWN

DELVE_CONSTANTS = {
  difficulty: {
    DIFFICULTIES: { value: %w[easy normal hard nightmare], file: 'app/models/delve.rb', purpose: 'Difficulty options' },
    STATUSES: { value: %w[generating active completed abandoned failed], file: 'app/models/delve.rb', purpose: 'Delve status flow' }
  },
  timing: {
    MOVE_TIME: { value: 10, file: 'app/models/delve.rb', purpose: 'Seconds per movement' },
    COMBAT_TIME: { value: 300, file: 'app/models/delve.rb', purpose: 'Seconds per combat (5 min)' },
    RECOVER_TIME: { value: 300, file: 'app/models/delve.rb', purpose: 'Seconds to heal (5 min)' },
    FOCUS_TIME: { value: 30, file: 'app/models/delve.rb', purpose: 'Seconds to gain willpower' },
    STUDY_TIME: { value: 60, file: 'app/models/delve.rb', purpose: 'Seconds to study monster (1 min)' },
    LISTEN_TIME: { value: 10, file: 'app/models/delve.rb', purpose: 'Seconds per trap observation' },
    EASIER_TIME: { value: 30, file: 'app/models/delve.rb', purpose: 'Seconds to lower DC' },
    PUZZLE_ATTEMPT_TIME: { value: 15, file: 'app/models/delve.rb', purpose: 'Seconds per puzzle try' }
  },
  grid: {
    DEFAULT_WIDTH: { value: 15, file: 'app/models/delve.rb', purpose: 'Default grid width' },
    DEFAULT_HEIGHT: { value: 15, file: 'app/models/delve.rb', purpose: 'Default grid height' },
    TIME_LIMIT_DEFAULT: { value: 60, file: 'app/models/delve.rb', purpose: 'Default time limit (minutes)' }
  },
  blockers: {
    BASE_DC: { value: 10, file: 'app/services/delve_skill_check_service.rb', purpose: 'Base difficulty class' },
    DC_PER_LEVEL: { value: 2, file: 'app/services/delve_skill_check_service.rb', purpose: 'DC increase per level' }
  },
  treasure: {
    BASE_MIN: { value: 5, file: 'app/services/delve_treasure_service.rb', purpose: 'Minimum gold per treasure' },
    BASE_MAX: { value: 10, file: 'app/services/delve_treasure_service.rb', purpose: 'Maximum gold per treasure' },
    LEVEL_MULTIPLIER: { value: '2^(level-1)', file: 'app/services/delve_treasure_service.rb', purpose: 'Treasure scaling formula' }
  },
  penalties: {
    DEFEAT_LOOT_PENALTY: { value: 0.5, file: 'app/services/delve_action_service.rb', purpose: 'Lose 50% loot on death' },
    TIMEOUT_LOOT_PENALTY: { value: 0.5, file: 'app/services/delve_action_service.rb', purpose: 'Lose 50% loot on timeout' }
  },
  monsters: {
    TIERS: { value: %w[rat spider goblin skeleton orc troll ogre demon dragon], file: 'app/services/delve_generator_service.rb', purpose: 'Monster tier order' },
    STUDY_BONUS: { value: 2, file: 'app/models/delve_participant.rb', purpose: 'Bonus for studied monsters' },
    MOVE_THRESHOLD: { value: 10, file: 'app/models/delve.rb', purpose: 'Seconds to trigger monster movement' }
  },
  room_types: {
    TYPES: { value: %w[corridor chamber treasure monster trap puzzle boss exit], file: 'app/models/delve_room.rb', purpose: 'Room type options' }
  },
  puzzles: {
    TYPES: { value: %w[symbol_grid pipe_network toggle_matrix], file: 'app/models/delve_puzzle.rb', purpose: 'Puzzle type options' },
    DIFFICULTIES: { value: %w[easy medium hard expert], file: 'app/models/delve_puzzle.rb', purpose: 'Puzzle difficulty levels' }
  }
}.freeze

puts "\n[Delve System]"
seed_system('delve', {
  display_name: 'Delve System',
  summary: 'Procedural roguelike dungeons with time pressure and fog of war',
  description: 'The Delve System provides procedurally-generated dungeon exploration with grid-based movement, timing traps, skill blockers, puzzles, roving monsters, and treasure collection under time pressure.',
  player_guide: DELVE_PLAYER_GUIDE,
  staff_guide: DELVE_STAFF_GUIDE,
  quick_reference: DELVE_QUICK_REFERENCE,
  constants_json: DELVE_CONSTANTS,
  command_names: %w[delve],
  related_systems: %w[combat character navigation],
  key_files: [
    'app/models/delve.rb',
    'app/models/delve_room.rb',
    'app/models/delve_participant.rb',
    'app/models/delve_monster.rb',
    'app/models/delve_trap.rb',
    'app/models/delve_blocker.rb',
    'app/models/delve_puzzle.rb',
    'app/models/delve_treasure.rb',
    'app/services/delve_generator_service.rb',
    'app/services/delve_movement_service.rb',
    'app/services/delve_map_service.rb',
    'app/services/delve_action_service.rb',
    'app/services/delve_visibility_service.rb',
    'plugins/core/delve/commands/'
  ],
  staff_notes: 'Generator uses fractal branching algorithm. Traps use coprime timing patterns. Fog of war with 3 visibility ranges. Monsters move on player time expenditure. GameSettings control difficulty scaling.',
  display_order: 100
})

# =============================================================================
# PRIORITY 5: SOCIAL & META SYSTEMS
# =============================================================================

# -----------------------------------------------------------------------------
# SOCIAL SYSTEM
# -----------------------------------------------------------------------------

SOCIAL_PLAYER_GUIDE = <<~MARKDOWN
  # Social System

  ## Overview

  The Social System manages all relationship-based features between characters, including friendships, blocks, interaction permissions, and consent mechanics. It provides granular control over who can interact with your character and how, ensuring a safe and comfortable roleplay environment.

  The system operates on multiple levels: basic social connections (friends/blocks), detailed relationship tracking with notes and categories, interaction permissions for specific actions, and content consent for mature themes.

  ## Key Concepts

  ### Relationships

  Relationships are bidirectional connections between characters that track:

  - **Connection Type**: How you know someone (friend, acquaintance, rival, etc.)
  - **Notes**: Private notes about the relationship only you can see
  - **IC Name**: What your character calls this person (nicknames, titles)
  - **Interaction Permissions**: Fine-grained controls for this specific relationship

  Relationships are automatically created when characters interact meaningfully.

  ### Blocks

  Blocks provide complete isolation from another player:

  - **Communication Block**: Can't receive messages, whispers, or emotes targeting you
  - **Visibility Block**: Reduced visibility in room descriptions
  - **Interaction Block**: Can't be targeted by their commands

  Blocks are immediate and don't require the other person's consent.

  ### Interaction Permissions

  The permission system has three levels:

  | Level | Description |
  |-------|-------------|
  | **Ask** | Prompt before this action (default for sensitive actions) |
  | **Allow** | Allow this action without prompting |
  | **Block** | Never allow this action |

  Permissions apply to specific interaction types like touching, lifting, dragging, etc.

  ### Content Consent

  Content consent controls what themes and situations your character can be involved in:

  - **Violence Level**: None, mild, moderate, graphic
  - **Romance Level**: None, fade-to-black, descriptive
  - **Dark Themes**: Enabled or disabled for specific themes

  Content consent is checked before scenes begin and can be changed at any time.

  ## Getting Started

  ### Blocking Someone

  If someone is making you uncomfortable, block them immediately:

  ```
  block <character>
  ```

  This prevents all their interactions with you. No notification is sent to them.

  ### Setting Global Permissions

  Configure your default interaction preferences:

  ```
  consent                    # View current consent settings
  consent touch allow        # Allow casual touch without asking
  consent drag block         # Never allow being dragged
  consent lift ask           # Ask before being picked up
  ```

  ### Managing Relationships

  ```
  friends                    # List your relationships
  unfriend <character>       # Remove a relationship
  ```

  ### Check-In System

  Use check-in to express that you're comfortable with current roleplay:

  ```
  check in                   # Signal you're comfortable
  check in <character>       # Check in with specific person
  ```

  This provides a subtle way to communicate comfort during intense scenes.

  ## Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | block | block <character> | Block all interactions from a character |
  | unblock | unblock <character> | Remove a block |
  | unfriend | unfriend <character> | Remove a relationship |
  | check in | check in [character] | Signal comfort with current RP |
  | consent | consent [type] [level] | Manage interaction consent |
  | private | private [on/off] | Toggle private mode for conversations |

  ## Examples

  ### Managing Blocks

  ```
  > block ToxicPlayer
  You have blocked ToxicPlayer. They can no longer interact with you.

  > unblock ToxicPlayer
  You have unblocked ToxicPlayer.
  ```

  ### Setting Consent Levels

  ```
  > consent
  Current Consent Settings:
  - Touch: Ask
  - Lift: Ask
  - Drag: Block
  - Violence: Moderate
  - Romance: Fade-to-black

  > consent violence graphic
  Violence level set to: Graphic
  ```

  ### Checking In

  ```
  > check in
  [OOC] You signal that you're comfortable with the current scene.

  > check in Alice
  [OOC] You check in with Alice, confirming your comfort.
  ```

  ## Tips & Tricks

  - **Blocks are private**: The blocked person doesn't know they're blocked
  - **Consent can change**: You can update consent settings at any time
  - **Check-in is subtle**: Other players only see a brief OOC note
  - **Relationship notes**: Use notes to remember important details
  - **IC names**: Set IC names for how your character knows someone

  ## Related Systems

  - **Communication**: Messages and channels respect blocks
  - **Combat**: Combat system checks interaction permissions
  - **Character**: Character visibility affected by blocks
MARKDOWN

SOCIAL_STAFF_GUIDE = <<~MARKDOWN
  # Social System - Staff Guide

  ## Architecture Overview

  The Social System uses three main models and two services:

  - **Relationship Model**: Tracks connections between characters with metadata
  - **Block Model**: Simple table of blocker/blocked character pairs
  - **InteractionPermissionService**: Evaluates if an action is allowed
  - **ContentConsentService**: Checks scene-level consent compatibility

  ### Data Flow

  1. **Action Attempted**: Command initiates character-to-character action
  2. **Block Check**: InteractionPermissionService checks blocks first
  3. **Relationship Check**: Loads relationship for specific permissions
  4. **Default Check**: Falls back to character's global defaults
  5. **Result**: Returns :allow, :ask, or :block

  ## Key Files

  | File | Purpose |
  |------|---------|
  | app/models/relationship.rb | Relationship storage and metadata |
  | app/models/block.rb | Block list implementation |
  | app/services/interaction_permission_service.rb | Permission evaluation logic |
  | app/services/content_consent_service.rb | Scene consent checking |
  | plugins/core/social/commands/ | Social commands |

  ## Database Schema

  ### relationships Table

  ```ruby
  create_table(:relationships) do
    primary_key :id
    foreign_key :character_id, :characters
    foreign_key :target_character_id, :characters
    String :connection_type, default: 'acquaintance'
    Text :notes
    String :ic_name
    :jsonb :interaction_overrides, default: '{}'
    DateTime :created_at
    DateTime :updated_at

    unique [:character_id, :target_character_id]
  end
  ```

  ### blocks Table

  ```ruby
  create_table(:blocks) do
    primary_key :id
    foreign_key :blocker_id, :characters
    foreign_key :blocked_id, :characters
    String :reason
    DateTime :created_at

    unique [:blocker_id, :blocked_id]
  end
  ```

  ## InteractionPermissionService

  The core permission evaluation service:

  ```ruby
  class InteractionPermissionService
    # Permission levels in order of restrictiveness
    PERMISSION_LEVELS = %w[block ask allow].freeze

    # Default permissions for interaction types
    DEFAULT_PERMISSIONS = {
      'touch' => 'ask',
      'lift' => 'ask',
      'drag' => 'block',
      'whisper' => 'allow',
      'emote' => 'allow',
      'combat' => 'ask'
    }.freeze

    def self.check(actor, target, action_type)
      return :block if Block.blocked?(actor.id, target.id)

      relationship = Relationship.first(
        character_id: target.id,
        target_character_id: actor.id
      )

      if relationship&.interaction_overrides&.key?(action_type)
        return relationship.interaction_overrides[action_type].to_sym
      end

      target.default_permission_for(action_type).to_sym
    end
  end
  ```

  ## Block Model

  Simple blocking implementation:

  ```ruby
  class Block < Sequel::Model
    many_to_one :blocker, class: :Character
    many_to_one :blocked, class: :Character

    def self.blocked?(blocker_id, blocked_id)
      where(blocker_id: blocker_id, blocked_id: blocked_id).any?
    end

    def self.blocking?(character_id, target_id)
      # Either direction counts
      blocked?(character_id, target_id) || blocked?(target_id, character_id)
    end
  end
  ```

  ## Content Consent Service

  Evaluates scene-level consent compatibility:

  ```ruby
  class ContentConsentService
    CONTENT_TYPES = {
      violence: %w[none mild moderate graphic],
      romance: %w[none fade_to_black descriptive],
      dark_themes: %w[disabled enabled]
    }.freeze

    def self.compatible?(participants, content_type, level)
      participants.all? do |char|
        char_level = char.content_consent[content_type.to_s]
        level_index = CONTENT_TYPES[content_type].index(level)
        char_index = CONTENT_TYPES[content_type].index(char_level)
        char_index >= level_index
      end
    end
  end
  ```

  ## Command Integration

  Commands check permissions before acting:

  ```ruby
  # In a command that targets another character
  permission = InteractionPermissionService.check(
    context[:character],
    target,
    'touch'
  )

  case permission
  when :block
    return error_response("\#{target.name} has blocked this action.")
  when :ask
    # Queue quickmenu for target to approve/deny
    queue_permission_request(target, context[:character], 'touch')
    return pending_response("Waiting for \#{target.name}'s permission...")
  when :allow
    # Proceed with action
  end
  ```

  ## Relationship Automatic Creation

  Relationships are created automatically during meaningful interactions:

  ```ruby
  # In BroadcastService or command handlers
  def ensure_relationship(char1, char2)
    Relationship.find_or_create(
      character_id: char1.id,
      target_character_id: char2.id
    ) do |r|
      r.connection_type = 'acquaintance'
    end
  end
  ```

  ## Check-In System

  The check-in command broadcasts subtle OOC comfort signals:

  ```ruby
  class CheckIn < Commands::Base::Command
    def execute(args, context)
      character = context[:character]
      instance = context[:instance]

      message = if args.empty?
        "[OOC] \#{character.name} checks in, signaling comfort."
      else
        target = resolve_target(args.first, instance)
        "[OOC] \#{character.name} checks in with \#{target.name}."
      end

      BroadcastService.to_room(instance.room, message, type: :ooc)
      success_response(message)
    end
  end
  ```

  ## Private Mode

  Private mode limits broadcast visibility:

  ```ruby
  # In CharacterInstance
  def private_mode?
    !!values[:private_mode]
  end

  # In BroadcastService
  def filter_recipients(room, sender)
    room.character_instances.reject do |instance|
      instance.private_mode? && instance != sender
    end
  end
  ```

  ## Staff Notes

  - Blocks are **bidirectional in effect**: Either direction prevents interaction
  - Permission requests use the **quickmenu system** for async approval
  - Content consent is checked at **scene start**, not per-action
  - Relationships are created lazily to avoid bloating the database
  - Check-in is **OOC** and doesn't affect IC gameplay
MARKDOWN

SOCIAL_QUICK_REFERENCE = <<~MARKDOWN
  # Social Quick Reference

  ## Block Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | block | block <char> | Block a character |
  | unblock | unblock <char> | Remove block |

  ## Relationship Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | friends | friends | List relationships |
  | unfriend | unfriend <char> | Remove relationship |

  ## Consent Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | consent | consent | View settings |
  | consent | consent <type> <level> | Set permission |
  | check in | check in [char] | Signal comfort |

  ## Permission Levels

  | Level | Description |
  |-------|-------------|
  | block | Never allow |
  | ask | Prompt first |
  | allow | Auto-allow |

  ## Interaction Types

  touch, lift, drag, whisper, emote, combat
MARKDOWN

SOCIAL_CONSTANTS = {
  permissions: {
    PERMISSION_LEVELS: { value: %w[block ask allow], file: 'app/services/interaction_permission_service.rb', purpose: 'Permission level options' },
    DEFAULT_TOUCH: { value: 'ask', file: 'app/services/interaction_permission_service.rb', purpose: 'Default touch permission' },
    DEFAULT_LIFT: { value: 'ask', file: 'app/services/interaction_permission_service.rb', purpose: 'Default lift permission' },
    DEFAULT_DRAG: { value: 'block', file: 'app/services/interaction_permission_service.rb', purpose: 'Default drag permission' },
    DEFAULT_WHISPER: { value: 'allow', file: 'app/services/interaction_permission_service.rb', purpose: 'Default whisper permission' }
  },
  content: {
    VIOLENCE_LEVELS: { value: %w[none mild moderate graphic], file: 'app/services/content_consent_service.rb', purpose: 'Violence content levels' },
    ROMANCE_LEVELS: { value: %w[none fade_to_black descriptive], file: 'app/services/content_consent_service.rb', purpose: 'Romance content levels' },
    DARK_THEMES: { value: %w[disabled enabled], file: 'app/services/content_consent_service.rb', purpose: 'Dark theme toggle' }
  },
  relationships: {
    CONNECTION_TYPES: { value: %w[acquaintance friend rival lover enemy], file: 'app/models/relationship.rb', purpose: 'Relationship type options' }
  }
}.freeze

puts "\n[Social System]"
seed_system('social', {
  display_name: 'Social System',
  summary: 'Relationships, blocks, interaction permissions, and consent mechanics',
  description: 'The Social System manages character relationships, blocking, interaction permissions, and content consent to ensure safe and comfortable roleplay.',
  player_guide: SOCIAL_PLAYER_GUIDE,
  staff_guide: SOCIAL_STAFF_GUIDE,
  quick_reference: SOCIAL_QUICK_REFERENCE,
  constants_json: SOCIAL_CONSTANTS,
  command_names: %w[block unblock unfriend consent],
  related_systems: %w[communication character combat],
  key_files: [
    'app/models/relationship.rb',
    'app/models/block.rb',
    'app/services/interaction_permission_service.rb',
    'app/services/content_consent_service.rb',
    'plugins/core/social/commands/'
  ],
  staff_notes: 'Three-tier permission system (block/ask/allow). Blocks are bidirectional in effect. Relationships created lazily. Check-in is OOC only.',
  display_order: 105
})

# -----------------------------------------------------------------------------
# CARDS SYSTEM
# -----------------------------------------------------------------------------

CARDS_PLAYER_GUIDE = <<~MARKDOWN
  # Cards System

  ## Overview

  The Cards System provides a complete card game implementation with standard and custom decks, dealing, drawing, and playing mechanics. Characters can create their own custom decks using the pattern system, or use standard playing card decks for poker, blackjack, and other games.

  Cards exist as objects in the game world and can be held, shown, passed, and discarded just like physical cards. The system supports multiple simultaneous games with separate draw piles, discard piles, and hands.

  ## Key Concepts

  ### Deck Patterns

  Deck patterns are templates that define a set of cards:

  - **Standard 52**: Classic playing cards (hearts, diamonds, clubs, spades)
  - **Tarot Major**: 22 Major Arcana tarot cards
  - **Custom**: User-created patterns with any cards

  Patterns define the cards available; actual decks are created from patterns.

  ### Decks

  A deck is a specific instance of a deck pattern:

  - **Draw Pile**: Undrawn cards (face down)
  - **Discard Pile**: Played/discarded cards
  - **Center**: Cards played to the table center
  - **Ownership**: Who controls the deck

  Decks can be shuffled, cut, and reset.

  ### Cards

  Individual cards that can be:

  - In the draw pile (face down)
  - In a player's hand
  - On the table (center)
  - In the discard pile

  Cards have a suit, value, and optional custom properties.

  ## Getting Started

  ### Playing a Quick Game

  1. **Get a deck**: `deck get standard52`
  2. **Shuffle**: `shuffle`
  3. **Deal to players**: `deal 5 to Alice, Bob, Charlie`
  4. **Draw cards**: `draw 2`
  5. **Play cards**: `play Ace of Spades`
  6. **Discard**: `discard 3 of Hearts`

  ### Creating a Custom Deck

  1. **Design pattern**: Use the pattern editor in `/admin/patterns`
  2. **Create deck**: `deck create mypattern "My Custom Deck"`
  3. **Use normally**: Shuffle, deal, draw, play

  ## Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | deck | deck [get/create/list] | Manage decks |
  | shuffle | shuffle | Shuffle the deck |
  | deal | deal <count> to <players> | Deal cards to players |
  | draw | draw [count] | Draw cards to your hand |
  | play | play <card> | Play a card to center |
  | discard | discard <card> | Discard a card |
  | show | show <card> to <player> | Show a card privately |
  | peek | peek | Look at your hand |
  | hand | hand | Display your current hand |
  | fold | fold | Discard your entire hand |
  | cut | cut [position] | Cut the deck |
  | pass | pass <card> to <player> | Pass a card to someone |

  ## Examples

  ### Dealing a Poker Hand

  ```
  > deck get standard52
  You take a standard 52-card deck.

  > shuffle
  You shuffle the deck thoroughly.

  > deal 5 to Alice, Bob, Charlie, David, You
  You deal 5 cards to each player.
  Alice receives 5 cards.
  Bob receives 5 cards.
  Charlie receives 5 cards.
  David receives 5 cards.
  You receive 5 cards.

  > hand
  Your hand:
  - King of Hearts
  - Queen of Diamonds
  - 10 of Spades
  - 7 of Clubs
  - 2 of Hearts
  ```

  ### Playing Cards

  ```
  > play King of Hearts
  You play the King of Hearts to the center.

  > discard 2 of Hearts
  You discard the 2 of Hearts.

  > draw 2
  You draw 2 cards from the deck.
  ```

  ### Showing Cards

  ```
  > show Ace of Spades to Alice
  You secretly show the Ace of Spades to Alice.
  (Alice sees: "Bob shows you the Ace of Spades.")

  > peek
  You peek at your cards without revealing them.
  ```

  ## Card Notation

  Cards can be referred to in several ways:

  - Full name: `King of Hearts`, `Ace of Spades`
  - Abbreviation: `KH`, `AS`, `10D`, `2C`
  - Value only (if unique in hand): `King`, `Ace`
  - Position: `card 1`, `card 3`

  ## Tips & Tricks

  - **Shuffle well**: Use `shuffle` multiple times for a thorough mix
  - **Cut for fairness**: Let another player `cut` before dealing
  - **Track discards**: Discards are public; use `look discard` to see them
  - **Private shows**: `show` is only seen by the target
  - **Fold gracefully**: `fold` discards your whole hand at once

  ## Related Systems

  - **Inventory**: Cards are objects you can hold
  - **Dice**: Combine with dice for complex games
  - **Economy**: Some games may have currency stakes
MARKDOWN

CARDS_STAFF_GUIDE = <<~MARKDOWN
  # Cards System - Staff Guide

  ## Architecture Overview

  The Cards System uses three models and PostgreSQL arrays for hand tracking:

  - **DeckPattern**: Template defining what cards exist
  - **Deck**: Instance of a pattern with state (draw pile, discard, etc.)
  - **Card**: Individual card records with position tracking

  ### Data Flow

  1. **Pattern Created**: Admin creates DeckPattern with card definitions
  2. **Deck Instantiated**: Player gets deck, creating Deck and Card records
  3. **Cards Move**: Commands update card positions (draw pile → hand → center → discard)
  4. **State Tracked**: Deck tracks current state; Cards track location

  ## Key Files

  | File | Purpose |
  |------|---------|
  | app/models/deck_pattern.rb | Deck template definitions |
  | app/models/deck.rb | Deck instance and state |
  | app/models/card.rb | Individual card records |
  | plugins/core/cards/commands/ | All card commands |

  ## Database Schema

  ### deck_patterns Table

  ```ruby
  create_table(:deck_patterns) do
    primary_key :id
    String :name, null: false, unique: true
    String :display_name
    Text :description
    :jsonb :card_definitions, default: '[]'  # Array of card specs
    Boolean :is_standard, default: false
    Boolean :is_public, default: true
    foreign_key :creator_id, :users
    DateTime :created_at
    DateTime :updated_at
  end
  ```

  ### decks Table

  ```ruby
  create_table(:decks) do
    primary_key :id
    foreign_key :deck_pattern_id, :deck_patterns
    foreign_key :owner_id, :characters
    foreign_key :room_id, :rooms
    String :name
    Boolean :shuffled, default: false
    Integer :cut_position
    DateTime :created_at
    DateTime :updated_at
  end
  ```

  ### cards Table

  ```ruby
  create_table(:cards) do
    primary_key :id
    foreign_key :deck_id, :decks
    String :suit
    String :value
    String :display_name
    String :location  # draw_pile, hand, center, discard
    foreign_key :holder_id, :characters  # Who holds this card
    Integer :position  # Order in pile/hand
    :jsonb :properties, default: '{}'
    DateTime :created_at
    DateTime :updated_at
  end
  ```

  ## DeckPattern Model

  Defines card templates:

  ```ruby
  class DeckPattern < Sequel::Model
    one_to_many :decks

    STANDARD_52 = {
      name: 'standard52',
      display_name: 'Standard 52-Card Deck',
      card_definitions: generate_standard_cards
    }.freeze

    def self.generate_standard_cards
      suits = %w[Hearts Diamonds Clubs Spades]
      values = %w[2 3 4 5 6 7 8 9 10 Jack Queen King Ace]

      suits.flat_map do |suit|
        values.map do |value|
          {
            suit: suit,
            value: value,
            display_name: "\#{value} of \#{suit}"
          }
        end
      end
    end

    def create_deck(owner:, room:, name: nil)
      deck = Deck.create(
        deck_pattern_id: id,
        owner_id: owner.id,
        room_id: room.id,
        name: name || display_name
      )

      card_definitions.each_with_index do |card_def, idx|
        Card.create(
          deck_id: deck.id,
          suit: card_def['suit'],
          value: card_def['value'],
          display_name: card_def['display_name'],
          location: 'draw_pile',
          position: idx
        )
      end

      deck
    end
  end
  ```

  ## Deck Model

  Manages deck state:

  ```ruby
  class Deck < Sequel::Model
    many_to_one :deck_pattern
    many_to_one :owner, class: :Character
    many_to_one :room
    one_to_many :cards

    def draw_pile
      cards_dataset.where(location: 'draw_pile').order(:position)
    end

    def discard_pile
      cards_dataset.where(location: 'discard').order(:position)
    end

    def center
      cards_dataset.where(location: 'center').order(:position)
    end

    def hand_for(character)
      cards_dataset.where(location: 'hand', holder_id: character.id).order(:position)
    end

    def shuffle!
      draw_cards = draw_pile.to_a.shuffle
      draw_cards.each_with_index do |card, idx|
        card.update(position: idx)
      end
      update(shuffled: true, cut_position: nil)
    end

    def deal(count, recipients)
      dealt = {}
      recipients.each do |char|
        dealt[char.id] = []
        count.times do
          card = draw_pile.first
          break unless card
          card.update(location: 'hand', holder_id: char.id, position: hand_for(char).count)
          dealt[char.id] << card
        end
      end
      dealt
    end

    def draw(character, count = 1)
      drawn = []
      count.times do
        card = draw_pile.first
        break unless card
        card.update(location: 'hand', holder_id: character.id, position: hand_for(character).count)
        drawn << card
      end
      drawn
    end

    def play(character, card)
      return false unless card.holder_id == character.id
      card.update(location: 'center', holder_id: nil, position: center.count)
      true
    end

    def discard(character, card)
      return false unless card.holder_id == character.id
      card.update(location: 'discard', holder_id: nil, position: discard_pile.count)
      true
    end

    def reset!
      cards.each do |card|
        card.update(location: 'draw_pile', holder_id: nil)
      end
      shuffle!
    end
  end
  ```

  ## Card Model

  Individual card tracking:

  ```ruby
  class Card < Sequel::Model
    many_to_one :deck
    many_to_one :holder, class: :Character

    LOCATIONS = %w[draw_pile hand center discard].freeze

    def in_hand?
      location == 'hand'
    end

    def in_play?
      location == 'center'
    end

    def discarded?
      location == 'discard'
    end

    def abbreviated_name
      suit_abbrev = suit[0].upcase
      value_abbrev = case value
        when 'Jack' then 'J'
        when 'Queen' then 'Q'
        when 'King' then 'K'
        when 'Ace' then 'A'
        else value
      end
      "\#{value_abbrev}\#{suit_abbrev}"
    end
  end
  ```

  ## Card Resolution

  Finding cards by name:

  ```ruby
  class CardResolver
    def self.resolve(input, hand)
      input = input.strip.downcase

      # Try exact match
      card = hand.find { |c| c.display_name.downcase == input }
      return card if card

      # Try abbreviation (KH, AS, 10D)
      card = hand.find { |c| c.abbreviated_name.downcase == input }
      return card if card

      # Try value only (King, Ace)
      cards_by_value = hand.select { |c| c.value.downcase == input }
      return cards_by_value.first if cards_by_value.size == 1

      # Try position (card 1, card 3)
      if input =~ /card\s+(\d+)/i
        idx = $1.to_i - 1
        return hand[idx] if idx >= 0 && idx < hand.size
      end

      nil
    end
  end
  ```

  ## Staff Notes

  - Cards are **physical objects** in the game world (held, dropped, etc.)
  - Deck patterns use **JSONB arrays** for card definitions
  - Shuffling uses Ruby's `Array#shuffle` (Fisher-Yates algorithm)
  - Hands are tracked via `holder_id` foreign key
  - Deck ownership controls who can shuffle/deal
  - Standard patterns are seeded and marked `is_standard: true`
MARKDOWN

CARDS_QUICK_REFERENCE = <<~MARKDOWN
  # Cards Quick Reference

  ## Deck Management

  | Command | Usage | Description |
  |---------|-------|-------------|
  | deck get | deck get <pattern> | Get a deck |
  | deck create | deck create <pattern> "Name" | Create custom deck |
  | deck list | deck list | List available patterns |
  | shuffle | shuffle | Shuffle the deck |
  | cut | cut [position] | Cut the deck |

  ## Card Movement

  | Command | Usage | Description |
  |---------|-------|-------------|
  | deal | deal <n> to <players> | Deal cards |
  | draw | draw [n] | Draw to hand |
  | play | play <card> | Play to center |
  | discard | discard <card> | Discard card |
  | pass | pass <card> to <player> | Give card |

  ## Viewing Cards

  | Command | Usage | Description |
  |---------|-------|-------------|
  | hand | hand | View your hand |
  | peek | peek | Look at hand secretly |
  | show | show <card> to <player> | Show card privately |
  | fold | fold | Discard entire hand |

  ## Card Notation

  | Format | Example |
  |--------|---------|
  | Full | King of Hearts |
  | Abbrev | KH, AS, 10D |
  | Value | King, Ace |
  | Position | card 1, card 3 |
MARKDOWN

CARDS_CONSTANTS = {
  locations: {
    CARD_LOCATIONS: { value: %w[draw_pile hand center discard], file: 'app/models/card.rb', purpose: 'Valid card locations' }
  },
  suits: {
    STANDARD_SUITS: { value: %w[Hearts Diamonds Clubs Spades], file: 'app/models/deck_pattern.rb', purpose: 'Standard playing card suits' }
  },
  values: {
    STANDARD_VALUES: { value: %w[2 3 4 5 6 7 8 9 10 Jack Queen King Ace], file: 'app/models/deck_pattern.rb', purpose: 'Standard playing card values' }
  },
  patterns: {
    STANDARD_52: { value: 'standard52', file: 'db/seeds.rb', purpose: 'Standard 52-card deck pattern name' },
    TAROT_MAJOR: { value: 'tarot_major', file: 'db/seeds.rb', purpose: 'Tarot Major Arcana pattern name' }
  }
}.freeze

puts "\n[Cards System]"
seed_system('cards', {
  display_name: 'Cards System',
  summary: 'Card decks, dealing, drawing, and card games',
  description: 'The Cards System provides complete card game functionality with standard and custom decks, dealing, drawing, playing, and showing cards.',
  player_guide: CARDS_PLAYER_GUIDE,
  staff_guide: CARDS_STAFF_GUIDE,
  quick_reference: CARDS_QUICK_REFERENCE,
  constants_json: CARDS_CONSTANTS,
  command_names: %w[deck shuffle deal draw play discard show peek hand fold cut pass],
  related_systems: %w[inventory dice economy],
  key_files: [
    'app/models/deck_pattern.rb',
    'app/models/deck.rb',
    'app/models/card.rb',
    'plugins/core/cards/commands/'
  ],
  staff_notes: 'Cards are physical objects. Deck patterns use JSONB arrays. Fisher-Yates shuffle. Holder tracking via foreign key. Standard patterns seeded.',
  display_order: 110
})

# -----------------------------------------------------------------------------
# DICE SYSTEM
# -----------------------------------------------------------------------------

DICE_PLAYER_GUIDE = <<~MARKDOWN
  # Dice System

  ## Overview

  The Dice System provides comprehensive dice rolling for roleplaying games, including stat-modified rolls, exploding dice, custom dice expressions, and result broadcasting. The core mechanic uses 2d8 with exploding 8s, but the system supports arbitrary dice expressions.

  Dice rolls are automatically announced to the room, creating a shared experience for all participants. Rolls can be modified by character stats, making the system deeply integrated with character progression.

  ## Key Concepts

  ### Exploding Dice

  When you roll the maximum value on a die (8 on a d8), that die "explodes":

  1. Keep the 8
  2. Roll again
  3. Add the new result
  4. If you roll another 8, repeat!

  This creates a chance for exceptional results and dramatic moments.

  ### Stat-Based Rolls

  The primary roll format is `roll <stat>`, which:

  1. Rolls 2d8 (with explosion on 8s)
  2. Adds your stat modifier
  3. Compares against difficulty or opponent

  Example: With STR 14 (+2 modifier), rolling 2d8 giving [5, 8, 3] = 16 + 2 = 18

  ### Difficulty Classes

  | Difficulty | DC |
  |------------|-----|
  | Easy | 10 |
  | Medium | 15 |
  | Hard | 20 |
  | Very Hard | 25 |
  | Legendary | 30+ |

  ## Getting Started

  ### Basic Stat Roll

  ```
  roll STR      # Roll Strength check
  roll DEX      # Roll Dexterity check
  roll INT      # Roll Intelligence check
  ```

  ### Custom Dice

  ```
  roll 1d20            # Single d20
  roll 2d6+5           # 2d6 plus 5
  roll 4d6 drop lowest # D&D stat generation
  roll 1d100           # Percentile
  ```

  ### Private Rolls

  ```
  roll STR private     # Only you see the result
  diceroll 1d20 private
  ```

  ## Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | roll | roll <stat> [private] | Roll a stat check |
  | diceroll | diceroll <expression> [private] | Roll custom dice |
  | reroll | reroll | Repeat your last roll |

  ## Stat Modifiers

  Stats provide modifiers to rolls:

  | Stat Value | Modifier |
  |------------|----------|
  | 1-3 | -3 |
  | 4-5 | -2 |
  | 6-7 | -1 |
  | 8-9 | +0 |
  | 10-11 | +1 |
  | 12-13 | +2 |
  | 14-15 | +3 |
  | 16-17 | +4 |
  | 18+ | +5 |

  ## Examples

  ### Stat Roll with Explosion

  ```
  > roll STR
  [Dice] Alice rolls Strength (STR 14, +2):
  2d8: [5, 8] → 8 explodes! [3] = 16
  Total: 16 + 2 = 18

  Alice rolled 18 on Strength!
  ```

  ### Custom Dice Expression

  ```
  > diceroll 4d6 drop lowest
  [Dice] Alice rolls 4d6 drop lowest:
  4d6: [6, 3, 5, 2] → drop 2 = 14

  Alice rolled 14!
  ```

  ### Opposed Roll

  ```
  > roll STR vs Bob
  [Dice] Alice rolls Strength vs Bob:
  Alice: 2d8 [4, 7] + 2 = 13
  Bob: 2d8 [3, 5] + 1 = 9

  Alice wins the contest!
  ```

  ## Dice Expression Syntax

  | Expression | Meaning |
  |------------|---------|
  | NdX | Roll N dice with X sides |
  | +Y | Add Y to total |
  | -Y | Subtract Y from total |
  | drop lowest | Remove lowest die |
  | drop highest | Remove highest die |
  | keep N | Keep only N highest dice |
  | exploding | Maximum rolls again |

  ## Tips & Tricks

  - **Exploding dice** can chain multiple times for big results
  - **Private rolls** useful for GM-only checks
  - **Reroll** repeats exact same expression
  - **Stat rolls** are the standard for most checks
  - **Custom dice** for special game systems

  ## Related Systems

  - **Character**: Stats determine modifiers
  - **Combat**: Combat uses stat rolls
  - **Activities**: Missions use stat checks
  - **Delve**: Dungeons use skill checks
MARKDOWN

DICE_STAFF_GUIDE = <<~MARKDOWN
  # Dice System - Staff Guide

  ## Architecture Overview

  The Dice System uses two main services:

  - **DiceRollService**: Parses and evaluates dice expressions
  - **DiceNotationService**: Higher-level wrapper with stat integration

  ### Data Flow

  1. **Command Received**: `roll STR` or `diceroll 2d6+3`
  2. **Parsing**: DiceRollService parses the expression
  3. **Stat Lookup**: If stat roll, get character's stat value and modifier
  4. **Rolling**: Generate random results with explosion handling
  5. **Formatting**: Build result string with individual dice shown
  6. **Broadcasting**: Send result to room (or just player if private)

  ## Key Files

  | File | Purpose |
  |------|---------|
  | app/services/dice_roll_service.rb | Core dice engine |
  | app/services/dice_roller_service.rb | High-level integration |
  | app/services/stat_allocation_service.rb | Stat modifier calculation |
  | plugins/core/dice/commands/roll.rb | Roll command |
  | plugins/core/dice/commands/diceroll.rb | Custom dice command |

  ## DiceRollService

  The core dice engine:

  ```ruby
  class DiceRollService
    # Parse and evaluate a dice expression
    def self.roll(expression)
      result = new(expression)
      result.evaluate
      result
    end

    def initialize(expression)
      @expression = expression.downcase.strip
      @dice = []
      @modifier = 0
      @dropped = []
      @kept = []
      @total = 0
      @exploded = []
    end

    def evaluate
      parse_expression
      roll_dice
      apply_modifiers
      calculate_total
    end

    private

    def parse_expression
      # Match patterns like 2d8, 1d20, 4d6
      @expression.scan(/(\d+)d(\d+)/) do |count, sides|
        @dice << { count: count.to_i, sides: sides.to_i }
      end

      # Match +N or -N modifiers
      @expression.scan(/([+-])(\d+)/) do |sign, value|
        mod = value.to_i
        @modifier += (sign == '+' ? mod : -mod)
      end

      # Handle special modifiers
      @drop_lowest = @expression.include?('drop lowest')
      @drop_highest = @expression.include?('drop highest')
      @exploding = @expression.include?('exploding') || @expression.include?('2d8')
      @keep_count = $1.to_i if @expression =~ /keep (\d+)/
    end

    def roll_dice
      @results = []
      @dice.each do |die|
        die[:count].times do
          roll = roll_single(die[:sides])
          @results << roll
        end
      end
    end

    def roll_single(sides)
      total = 0
      explosions = []
      loop do
        roll = rand(1..sides)
        total += roll
        break unless @exploding && roll == sides
        explosions << roll
      end
      { value: total, explosions: explosions }
    end

    def apply_modifiers
      values = @results.map { |r| r[:value] }

      if @drop_lowest
        min_idx = values.index(values.min)
        @dropped << @results.delete_at(min_idx)
      end

      if @drop_highest
        max_idx = values.index(values.max)
        @dropped << @results.delete_at(max_idx)
      end

      if @keep_count && @keep_count < @results.size
        sorted = @results.sort_by { |r| -r[:value] }
        @kept = sorted.first(@keep_count)
        @dropped += sorted[@keep_count..]
        @results = @kept
      end
    end

    def calculate_total
      @total = @results.sum { |r| r[:value] } + @modifier
    end
  end
  ```

  ## Stat Modifier Calculation

  From StatAllocationService:

  ```ruby
  class StatAllocationService
    MODIFIER_TABLE = {
      (1..3) => -3,
      (4..5) => -2,
      (6..7) => -1,
      (8..9) => 0,
      (10..11) => 1,
      (12..13) => 2,
      (14..15) => 3,
      (16..17) => 4,
      (18..Float::INFINITY) => 5
    }.freeze

    def self.modifier_for(stat_value)
      MODIFIER_TABLE.find { |range, _| range.include?(stat_value) }&.last || 0
    end
  end
  ```

  ## Roll Command

  ```ruby
  class Roll < Commands::Base::Command
    command_name 'roll'
    help_text 'Roll a stat check'
    usage 'roll <stat> [private]'

    STATS = %w[STR DEX CON INT WIS CHA].freeze

    def execute(args, context)
      character = context[:character]
      instance = context[:instance]
      stat_name = args.first&.upcase
      is_private = args.include?('private')

      unless STATS.include?(stat_name)
        return error_response("Unknown stat: \#{stat_name}. Valid: \#{STATS.join(', ')}")
      end

      stat_value = character.stat_value(stat_name)
      modifier = StatAllocationService.modifier_for(stat_value)

      result = DiceRollService.roll('2d8')
      total = result.total + modifier

      message = format_roll_message(character, stat_name, stat_value, modifier, result, total)

      if is_private
        success_response(message)
      else
        BroadcastService.to_room(instance.room, message, type: :dice)
        success_response("You rolled \#{total} on \#{stat_name}.")
      end
    end

    private

    def format_roll_message(character, stat, value, mod, result, total)
      mod_str = mod >= 0 ? "+\#{mod}" : mod.to_s
      dice_str = result.results.map { |r|
        if r[:explosions].any?
          "[\#{r[:value]}!]"
        else
          "[\#{r[:value]}]"
        end
      }.join(' ')

      "[Dice] \#{character.name} rolls \#{stat} (\#{value}, \#{mod_str}):\\n" \\
        "2d8: \#{dice_str} = \#{result.total}\\n" \\
        "Total: \#{result.total} \#{mod_str} = \#{total}"
    end
  end
  ```

  ## Opposed Rolls

  When rolling against another character:

  ```ruby
  def opposed_roll(actor, target, stat)
    actor_stat = actor.stat_value(stat)
    target_stat = target.stat_value(stat)

    actor_mod = StatAllocationService.modifier_for(actor_stat)
    target_mod = StatAllocationService.modifier_for(target_stat)

    actor_result = DiceRollService.roll('2d8')
    target_result = DiceRollService.roll('2d8')

    actor_total = actor_result.total + actor_mod
    target_total = target_result.total + target_mod

    {
      actor: { result: actor_result, modifier: actor_mod, total: actor_total },
      target: { result: target_result, modifier: target_mod, total: target_total },
      winner: actor_total >= target_total ? :actor : :target,
      tie: actor_total == target_total
    }
  end
  ```

  ## Broadcasting

  Dice results are broadcast to the room:

  ```ruby
  # In BroadcastService
  def self.to_room(room, message, type: :default)
    recipients = room.character_instances.map(&:user)

    case type
    when :dice
      # Dice rolls get special formatting
      formatted = format_dice_message(message)
    else
      formatted = message
    end

    recipients.each do |user|
      push_to_websocket(user, formatted)
    end
  end
  ```

  ## Staff Notes

  - **2d8 with explosion** is the core mechanic (max roll triggers reroll)
  - Stat modifiers range from **-3 to +5** based on stat value
  - **Private rolls** only show to the roller
  - **Opposed rolls** compare totals (tie goes to initiator)
  - Results are **broadcast to room** with formatting
  - **Reroll** stores last expression in session
MARKDOWN

DICE_QUICK_REFERENCE = <<~MARKDOWN
  # Dice Quick Reference

  ## Commands

  | Command | Usage | Description |
  |---------|-------|-------------|
  | roll | roll <STAT> [private] | Stat check (2d8+mod) |
  | diceroll | diceroll <expr> [private] | Custom dice |
  | reroll | reroll | Repeat last roll |

  ## Stats

  STR, DEX, CON, INT, WIS, CHA

  ## Modifiers

  | Stat | Mod | Stat | Mod |
  |------|-----|------|-----|
  | 1-3 | -3 | 12-13 | +2 |
  | 4-5 | -2 | 14-15 | +3 |
  | 6-7 | -1 | 16-17 | +4 |
  | 8-9 | +0 | 18+ | +5 |
  | 10-11 | +1 | | |

  ## Dice Expressions

  | Expr | Meaning |
  |------|---------|
  | NdX | N dice, X sides |
  | +Y | Add Y |
  | -Y | Subtract Y |
  | drop lowest | Remove lowest |
  | keep N | Keep N highest |

  ## Difficulty Classes

  Easy 10 | Medium 15 | Hard 20 | Very Hard 25 | Legendary 30+
MARKDOWN

DICE_CONSTANTS = {
  core: {
    DEFAULT_DICE: { value: '2d8', file: 'app/services/dice_roll_service.rb', purpose: 'Default stat roll dice' },
    EXPLOSION_TRIGGER: { value: 'max', file: 'app/services/dice_roll_service.rb', purpose: 'Explode on max roll' }
  },
  stats: {
    STAT_NAMES: { value: %w[STR DEX CON INT WIS CHA], file: 'plugins/core/dice/commands/roll.rb', purpose: 'Valid stat abbreviations' }
  },
  modifiers: {
    MIN_MODIFIER: { value: -3, file: 'app/services/stat_allocation_service.rb', purpose: 'Minimum stat modifier' },
    MAX_MODIFIER: { value: 5, file: 'app/services/stat_allocation_service.rb', purpose: 'Maximum stat modifier' }
  },
  difficulty: {
    DC_EASY: { value: 10, file: 'app/services/dice_roll_service.rb', purpose: 'Easy difficulty class' },
    DC_MEDIUM: { value: 15, file: 'app/services/dice_roll_service.rb', purpose: 'Medium difficulty class' },
    DC_HARD: { value: 20, file: 'app/services/dice_roll_service.rb', purpose: 'Hard difficulty class' },
    DC_VERY_HARD: { value: 25, file: 'app/services/dice_roll_service.rb', purpose: 'Very hard difficulty class' },
    DC_LEGENDARY: { value: 30, file: 'app/services/dice_roll_service.rb', purpose: 'Legendary difficulty class' }
  }
}.freeze

puts "\n[Dice System]"
seed_system('dice', {
  display_name: 'Dice System',
  summary: 'Stat-based rolls with exploding dice mechanics',
  description: 'The Dice System provides comprehensive dice rolling including stat-modified checks (2d8 with explosion), custom expressions, and room broadcasting.',
  player_guide: DICE_PLAYER_GUIDE,
  staff_guide: DICE_STAFF_GUIDE,
  quick_reference: DICE_QUICK_REFERENCE,
  constants_json: DICE_CONSTANTS,
  command_names: %w[roll diceroll reroll],
  related_systems: %w[character combat activities delve],
  key_files: [
    'app/services/dice_roll_service.rb',
    'app/services/dice_roller_service.rb',
    'app/services/stat_allocation_service.rb',
    'plugins/core/dice/commands/'
  ],
  staff_notes: '2d8 with explosion on 8s is core mechanic. Stat modifiers range -3 to +5. Opposed rolls compare totals. Private rolls only show to roller.',
  display_order: 115
})

# -----------------------------------------------------------------------------
# NPC SYSTEM
# -----------------------------------------------------------------------------

NPC_PLAYER_GUIDE = <<~MARKDOWN
  # NPC System

  ## Overview

  The NPC System brings the game world to life with non-player characters that follow schedules, remember players, engage in combat, and create dynamic narrative encounters. NPCs range from shopkeepers and guards to complex AI-driven characters with goals and memories.

  NPCs appear and behave like player characters in most ways, but are controlled by the game rather than human players. They can talk, emote, move between rooms, enter combat, and react to player actions.

  ## Key Concepts

  ### NPC Archetypes

  An archetype is a template defining an NPC's core traits:

  - **Appearance**: Description, shape, clothing
  - **Personality**: How they speak and act
  - **Skills**: Combat abilities, stats
  - **Behaviors**: What triggers reactions

  Multiple NPCs can share the same archetype (e.g., many "City Guard" instances).

  ### Schedules

  NPCs follow daily schedules:

  - **Morning Shift**: Guard patrols the market
  - **Afternoon**: Shopkeeper works at their shop
  - **Evening**: Bartender serves drinks
  - **Night**: Guard returns to barracks

  Schedules are based on game time, not real time.

  ### Spawn Locations

  NPCs spawn at specific locations based on their schedule:

  - **Static**: Always at one location
  - **Scheduled**: Moves between locations by time
  - **Roaming**: Randomly moves within an area
  - **Event-based**: Appears during specific events

  ### Combat AI

  When NPCs enter combat, AI profiles control their decisions:

  | Profile | Behavior |
  |---------|----------|
  | Aggressive | Attacks strongest target, uses offensive abilities |
  | Defensive | Prioritizes survival, uses buffs and heals |
  | Balanced | Adapts to situation, mixed strategy |
  | Berserker | All-out attack, ignores defense |
  | Coward | Flees when hurt, avoids combat |
  | Guardian | Protects allies, uses taunts |

  ## Interacting with NPCs

  ### Talking to NPCs

  Use normal communication commands:

  ```
  say to Guard Hello, is everything safe?
  whisper Merchant I'm looking for something special...
  ```

  NPCs may respond based on their programming and your relationship.

  ### Triggering NPC Actions

  Some NPCs react to keywords or actions:

  - Saying "help" to a guard may trigger assistance
  - Attacking near guards may draw their attention
  - Giving items to merchants initiates trade

  ### NPC Combat

  NPCs can be:

  - **Allies**: Fight alongside you
  - **Enemies**: Hostile and will attack
  - **Neutral**: Only fight if provoked

  Use normal combat commands against hostile NPCs.

  ## Tips & Tricks

  - **NPCs have schedules**: If someone's not at their shop, try later
  - **Reputation matters**: Some NPCs remember past interactions
  - **Watch the time**: NPC behavior changes throughout the day
  - **AI is adaptive**: Combat NPCs learn from repeated fights
  - **Not all NPCs are friendly**: Some will attack on sight

  ## Related Systems

  - **Combat**: NPC combat uses the fight system
  - **Communication**: Talk to NPCs normally
  - **Economy**: Merchants use the shop system
  - **Events**: Event NPCs appear during events
MARKDOWN

NPC_STAFF_GUIDE = <<~MARKDOWN
  # NPC System - Staff Guide

  ## Architecture Overview

  The NPC System uses several models and services:

  - **NpcArchetype**: Template defining NPC characteristics
  - **NpcSchedule**: Time-based location assignments
  - **NpcSpawnInstance**: Active NPC in the game world
  - **NpcSpawnService**: Manages spawning and despawning
  - **CombatAIService**: Combat decision-making

  ### Data Flow

  1. **Scheduler Tick**: Check current game time
  2. **Schedule Match**: Find NPCs that should be active
  3. **Spawn/Despawn**: Create or remove NPC instances
  4. **AI Loop**: Active NPCs make periodic decisions
  5. **Combat AI**: When in combat, use AI profiles

  ## Key Files

  | File | Purpose |
  |------|---------|
  | app/models/npc_archetype.rb | NPC template definition |
  | app/models/npc_schedule.rb | Time-based scheduling |
  | app/models/npc_spawn_instance.rb | Active NPC instance |
  | app/services/npc_spawn_service.rb | Spawn management |
  | app/services/combat_ai_service.rb | Combat decisions |

  ## Database Schema

  ### npc_archetypes Table

  ```ruby
  create_table(:npc_archetypes) do
    primary_key :id
    String :name, null: false, unique: true
    String :display_name
    Text :description
    Text :appearance
    String :shape, default: 'humanoid'
    String :gender
    :jsonb :stats, default: '{}'
    :jsonb :abilities, default: '[]'
    String :ai_profile, default: 'balanced'
    Text :personality
    :jsonb :dialogue_triggers, default: '{}'
    :jsonb :combat_config, default: '{}'
    String :faction
    Boolean :is_hostile, default: false
    Boolean :is_merchant, default: false
    foreign_key :stat_block_id, :stat_blocks
    String :profile_image
    DateTime :created_at
    DateTime :updated_at
  end
  ```

  ### npc_schedules Table

  ```ruby
  create_table(:npc_schedules) do
    primary_key :id
    foreign_key :npc_archetype_id, :npc_archetypes
    foreign_key :room_id, :rooms
    Integer :start_hour  # 0-23
    Integer :end_hour    # 0-23
    String :days_active, default: 'all'  # all, weekdays, weekends, or specific
    String :spawn_type, default: 'static'  # static, roaming, patrol
    :jsonb :patrol_path, default: '[]'  # For patrol type
    Integer :spawn_count, default: 1
    Boolean :enabled, default: true
    DateTime :created_at
    DateTime :updated_at
  end
  ```

  ### npc_spawn_instances Table

  ```ruby
  create_table(:npc_spawn_instances) do
    primary_key :id
    foreign_key :npc_archetype_id, :npc_archetypes
    foreign_key :npc_schedule_id, :npc_schedules
    foreign_key :room_id, :rooms
    foreign_key :character_id, :characters  # Virtual character for this NPC
    :jsonb :current_state, default: '{}'
    :jsonb :memories, default: '[]'
    :jsonb :goals, default: '[]'
    DateTime :spawned_at
    DateTime :last_action_at
  end
  ```

  ## NpcArchetype Model

  ```ruby
  class NpcArchetype < Sequel::Model
    one_to_many :npc_schedules
    one_to_many :npc_spawn_instances
    many_to_one :stat_block

    AI_PROFILES = %w[aggressive defensive balanced berserker coward guardian].freeze

    def create_virtual_character
      Character.create(
        name: display_name,
        is_npc: true,
        npc_archetype_id: id,
        description: description,
        shape: shape,
        gender: gender
      )
    end

    def stats_hash
      return stat_block.stats if stat_block
      values[:stats] || {}
    end
  end
  ```

  ## NpcSpawnService

  Manages NPC lifecycle:

  ```ruby
  class NpcSpawnService
    def self.tick(current_hour)
      # Spawn NPCs that should be active
      schedules_to_spawn = NpcSchedule
        .where(enabled: true)
        .where { start_hour <= current_hour }
        .where { end_hour > current_hour }

      schedules_to_spawn.each do |schedule|
        spawn_for_schedule(schedule)
      end

      # Despawn NPCs that should be inactive
      active_instances = NpcSpawnInstance.all
      active_instances.each do |instance|
        schedule = instance.npc_schedule
        unless schedule.active_at?(current_hour)
          despawn(instance)
        end
      end
    end

    def self.spawn_for_schedule(schedule)
      current_count = NpcSpawnInstance.where(npc_schedule_id: schedule.id).count
      return if current_count >= schedule.spawn_count

      (schedule.spawn_count - current_count).times do
        spawn(schedule)
      end
    end

    def self.spawn(schedule)
      archetype = schedule.npc_archetype
      room = schedule.room

      # Create virtual character
      character = archetype.create_virtual_character

      # Create character instance in room
      instance = CharacterInstance.create(
        character_id: character.id,
        room_id: room.id,
        is_npc: true
      )

      # Create spawn instance record
      NpcSpawnInstance.create(
        npc_archetype_id: archetype.id,
        npc_schedule_id: schedule.id,
        room_id: room.id,
        character_id: character.id,
        spawned_at: Time.now
      )

      # Announce arrival
      BroadcastService.to_room(room, "\#{character.name} arrives.", type: :arrival)
    end

    def self.despawn(instance)
      character = instance.character
      room = Room[instance.room_id]

      BroadcastService.to_room(room, "\#{character.name} departs.", type: :departure)

      # Clean up
      CharacterInstance.where(character_id: character.id).delete
      instance.destroy
      character.destroy
    end
  end
  ```

  ## CombatAIService

  Combat decision-making:

  ```ruby
  class CombatAIService
    AI_PROFILES = {
      'aggressive' => {
        target_priority: :highest_threat,
        ability_preference: :offensive,
        retreat_threshold: 0.1,
        uses_cover: false
      },
      'defensive' => {
        target_priority: :lowest_health,
        ability_preference: :defensive,
        retreat_threshold: 0.4,
        uses_cover: true
      },
      'balanced' => {
        target_priority: :nearest,
        ability_preference: :adaptive,
        retreat_threshold: 0.25,
        uses_cover: true
      },
      'berserker' => {
        target_priority: :random,
        ability_preference: :offensive,
        retreat_threshold: 0.0,
        uses_cover: false
      },
      'coward' => {
        target_priority: :weakest,
        ability_preference: :escape,
        retreat_threshold: 0.6,
        uses_cover: true
      },
      'guardian' => {
        target_priority: :threatening_ally,
        ability_preference: :protective,
        retreat_threshold: 0.2,
        uses_cover: false
      }
    }.freeze

    def self.decide_action(npc_participant, fight)
      profile = AI_PROFILES[npc_participant.ai_profile] || AI_PROFILES['balanced']

      # Check retreat condition
      if should_retreat?(npc_participant, profile)
        return { action: :flee }
      end

      # Select target
      target = select_target(npc_participant, fight, profile)
      return { action: :wait } unless target

      # Select ability
      ability = select_ability(npc_participant, target, profile)

      # Determine if movement needed
      if needs_to_move?(npc_participant, target, ability)
        path = calculate_path(npc_participant, target, fight)
        return { action: :move, path: path }
      end

      { action: :attack, target: target, ability: ability }
    end

    private

    def self.should_retreat?(participant, profile)
      health_ratio = participant.current_health.to_f / participant.max_health
      health_ratio <= profile[:retreat_threshold]
    end

    def self.select_target(npc, fight, profile)
      enemies = fight.enemies_of(npc)
      return nil if enemies.empty?

      case profile[:target_priority]
      when :highest_threat
        enemies.max_by(&:threat_level)
      when :lowest_health
        enemies.min_by(&:current_health)
      when :nearest
        enemies.min_by { |e| distance(npc, e) }
      when :random
        enemies.sample
      when :weakest
        enemies.min_by(&:max_health)
      when :threatening_ally
        enemies.max_by { |e| threat_to_allies(e, fight.allies_of(npc)) }
      end
    end
  end
  ```

  ## NPC Memories

  NPCs can remember interactions:

  ```ruby
  class NpcSpawnInstance < Sequel::Model
    def remember(event_type, character_id, details = {})
      memory = {
        type: event_type,
        character_id: character_id,
        details: details,
        timestamp: Time.now.to_i
      }

      current_memories = memories || []
      current_memories << memory
      # Keep only recent memories
      current_memories = current_memories.last(100)
      update(memories: current_memories)
    end

    def recall(character_id)
      (memories || []).select { |m| m['character_id'] == character_id }
    end
  end
  ```

  ## Dialogue Triggers

  NPCs can respond to keywords:

  ```ruby
  # In npc_archetype.dialogue_triggers:
  {
    "help" => {
      "response" => "Trouble? Tell me more.",
      "action" => "alert"
    },
    "buy" => {
      "response" => "Let me show you what I have.",
      "action" => "open_shop"
    },
    "attack" => {
      "response" => "You'll regret that!",
      "action" => "become_hostile"
    }
  }
  ```

  ## Staff Notes

  - NPCs are **virtual characters** with `is_npc: true` flag
  - Schedules use **game time**, not real time
  - AI profiles are **configurable per archetype**
  - Memories persist across **respawns** (within session)
  - Combat AI runs **async** during fight resolution
  - Dialogue triggers use **keyword matching**
MARKDOWN

NPC_QUICK_REFERENCE = <<~MARKDOWN
  # NPC Quick Reference

  ## AI Profiles

  | Profile | Target | Retreat | Style |
  |---------|--------|---------|-------|
  | aggressive | Highest threat | 10% | Offensive |
  | defensive | Lowest HP | 40% | Defensive |
  | balanced | Nearest | 25% | Adaptive |
  | berserker | Random | 0% | All-out |
  | coward | Weakest | 60% | Escape |
  | guardian | Threatening ally | 20% | Protect |

  ## Schedule Types

  | Type | Behavior |
  |------|----------|
  | static | Stay in one room |
  | roaming | Random movement in area |
  | patrol | Follow defined path |

  ## Spawn Configuration

  - start_hour / end_hour: 0-23
  - days_active: all, weekdays, weekends
  - spawn_count: Number of instances

  ## Key Services

  | Service | Purpose |
  |---------|---------|
  | NpcSpawnService | Lifecycle management |
  | CombatAIService | Combat decisions |
MARKDOWN

NPC_CONSTANTS = {
  ai_profiles: {
    PROFILES: { value: %w[aggressive defensive balanced berserker coward guardian], file: 'app/services/combat_ai_service.rb', purpose: 'AI behavior profiles' }
  },
  spawn: {
    SPAWN_TYPES: { value: %w[static roaming patrol], file: 'app/models/npc_schedule.rb', purpose: 'NPC spawn behavior types' },
    DAYS_OPTIONS: { value: %w[all weekdays weekends monday tuesday wednesday thursday friday saturday sunday], file: 'app/models/npc_schedule.rb', purpose: 'Schedule day options' }
  },
  memory: {
    MAX_MEMORIES: { value: 100, file: 'app/models/npc_spawn_instance.rb', purpose: 'Maximum memories per NPC' }
  },
  retreat: {
    AGGRESSIVE_THRESHOLD: { value: 0.1, file: 'app/services/combat_ai_service.rb', purpose: 'Aggressive AI retreat at 10% HP' },
    DEFENSIVE_THRESHOLD: { value: 0.4, file: 'app/services/combat_ai_service.rb', purpose: 'Defensive AI retreat at 40% HP' },
    BALANCED_THRESHOLD: { value: 0.25, file: 'app/services/combat_ai_service.rb', purpose: 'Balanced AI retreat at 25% HP' },
    COWARD_THRESHOLD: { value: 0.6, file: 'app/services/combat_ai_service.rb', purpose: 'Coward AI retreat at 60% HP' }
  }
}.freeze

puts "\n[NPC System]"
seed_system('npcs', {
  display_name: 'NPC System',
  summary: 'AI-driven non-player characters with schedules, combat, and memories',
  description: 'The NPC System manages non-player characters including archetypes, schedules, spawning, combat AI profiles, and interaction memories.',
  player_guide: NPC_PLAYER_GUIDE,
  staff_guide: NPC_STAFF_GUIDE,
  quick_reference: NPC_QUICK_REFERENCE,
  constants_json: NPC_CONSTANTS,
  command_names: %w[],
  related_systems: %w[combat communication economy events],
  key_files: [
    'app/models/npc_archetype.rb',
    'app/models/npc_schedule.rb',
    'app/models/npc_spawn_instance.rb',
    'app/services/npc_spawn_service.rb',
    'app/services/combat_ai_service.rb'
  ],
  staff_notes: 'NPCs are virtual characters (is_npc: true). Schedules use game time. AI profiles control combat. Memories persist within session. Dialogue uses keyword matching.',
  display_order: 120
})

# =============================================================================
# PRIORITY 6 SYSTEMS
# =============================================================================

# -----------------------------------------------------------------------------
# Prisoner System
# -----------------------------------------------------------------------------

PRISONER_PLAYER_GUIDE = <<~MARKDOWN
  # Prisoner System

  ## Overview

  The Prisoner system handles character restraint mechanics including binding, blindfolding,
  gagging, and dragging. This enables consensual roleplay scenarios where one character
  can temporarily restrict another's actions and movement.

  **Important**: All prisoner mechanics require consent. Characters can always use the
  `release` command to free themselves if the scenario becomes uncomfortable.

  ## Key Concepts

  - **Binding**: Restraining someone's hands, preventing them from using certain commands
  - **Blindfolding**: Covering someone's eyes, limiting what they can see
  - **Gagging**: Covering someone's mouth, affecting their ability to speak clearly
  - **Dragging**: Leading a bound character when they cannot walk on their own
  - **Searching**: Checking a restrained character's belongings

  ## Getting Started

  Prisoner mechanics typically involve two roles:

  1. **Captor**: The character doing the restraining
  2. **Prisoner**: The character being restrained

  Both must be in the same room. The prisoner must consent to being restrained.

  ## Commands

  ### Restraining Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `bind` | `bind <target>` | Bind someone's hands |
  | `unbind` | `unbind <target>` | Release someone's hands |
  | `blindfold` | `blindfold <target>` | Cover someone's eyes |
  | `unblindfold` | `unblindfold <target>` | Remove someone's blindfold |
  | `gag` | `gag <target>` | Cover someone's mouth |
  | `ungag` | `ungag <target>` | Remove someone's gag |

  ### Movement Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `drag` | `drag <target> <direction>` | Drag a bound person somewhere |
  | `release` | `release` | Free yourself from all restraints |

  ### Interaction Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `search` | `search <target>` | Search a restrained person |

  ## Effects of Restraints

  ### When Bound

  - Cannot use most object manipulation commands (get, drop, give)
  - Cannot attack or use combat abilities
  - Cannot use items
  - Movement may be restricted

  ### When Blindfolded

  - Cannot see room descriptions or other characters
  - Room displays as darkness with sounds only
  - Cannot target specific characters by sight
  - May still hear speech and emotes

  ### When Gagged

  - Speech comes out muffled or unintelligible
  - Cannot use say command normally
  - May still emote and perform physical actions
  - Whispers become impossible

  ## Examples

  **Basic Capture Scenario**:
  ```
  > bind Marcus
  You bind Marcus's hands behind their back.

  > blindfold Marcus
  You place a blindfold over Marcus's eyes.

  > drag Marcus north
  You drag Marcus to the north.
  ```

  **Self-Release**:
  ```
  > release
  You struggle free from your restraints.
  ```

  **Searching a Prisoner**:
  ```
  > search Marcus
  You search Marcus and find:
  - A small knife
  - 50 credits
  - A mysterious key
  ```

  ## Tips & Tricks

  1. **Consent is key**: These mechanics are for consensual RP scenarios only
  2. **Emergency release**: The `release` command always works as a safety valve
  3. **Combine restraints**: Binding + blindfolding + gagging creates full restraint
  4. **Movement options**: Bound characters can still be led via the follow system
  5. **IC consequences**: Items found during searches can become plot points

  ## Related Systems

  - **Combat**: Restraints may affect combat actions
  - **Inventory**: Searching interacts with inventory system
  - **Navigation**: Dragging uses movement mechanics
  - **Communication**: Gags affect speech commands
MARKDOWN

PRISONER_STAFF_GUIDE = <<~MARKDOWN
  # Prisoner System - Staff Guide

  ## Architecture Overview

  The Prisoner system manages character restraint states through the CharacterInstance model.
  Each restraint type (bound, blindfolded, gagged) is stored as a boolean flag that affects
  command execution and display rendering.

  ## Key Files

  | File | Purpose |
  |------|---------|
  | `plugins/core/prisoner/commands/bind.rb` | Bind hands command |
  | `plugins/core/prisoner/commands/unbind.rb` | Unbind hands command |
  | `plugins/core/prisoner/commands/blindfold.rb` | Blindfold command |
  | `plugins/core/prisoner/commands/unblindfold.rb` | Remove blindfold |
  | `plugins/core/prisoner/commands/gag.rb` | Gag command |
  | `plugins/core/prisoner/commands/ungag.rb` | Remove gag |
  | `plugins/core/prisoner/commands/drag.rb` | Drag bound character |
  | `plugins/core/prisoner/commands/search.rb` | Search restrained character |
  | `plugins/core/prisoner/commands/release.rb` | Self-release command |
  | `app/models/character_instance.rb` | Restraint state storage |

  ## Database Schema

  Restraint states are stored on character_instances:

  ```ruby
  # CharacterInstance columns
  :is_bound       # Boolean - hands bound
  :is_blindfolded # Boolean - eyes covered
  :is_gagged      # Boolean - mouth covered
  :dragged_by_id  # Integer - FK to dragging character
  ```

  ## Command Requirements

  Each prisoner command has specific requirements:

  ```ruby
  # Bind command requirements
  requires :in_same_room_as_target
  requires :target_not_already_bound
  requires :target_consent  # Optional consent system

  # Drag command requirements
  requires :target_is_bound
  requires :valid_exit
  ```

  ## Display Integration

  Blindfolded characters receive modified room output:

  ```ruby
  # In RoomDisplayService
  def render_for_character(character)
    if character.instance.is_blindfolded?
      render_blindfolded_view(character)
    else
      render_normal_view(character)
    end
  end

  def render_blindfolded_view(character)
    # Only sounds, no visual descriptions
    "Darkness surrounds you. You hear: \#{ambient_sounds}"
  end
  ```

  ## Speech Modification

  Gagged characters have speech modified:

  ```ruby
  # In say command or BroadcastService
  def format_gagged_speech(message)
    # Convert speech to muffled sounds
    message.gsub(/[aeiou]/i, 'm').gsub(/[bcdfghjklnpqrstvwxyz]/i, 'f')
  end
  ```

  ## Consent Framework

  The system can integrate with the consent/permission framework:

  ```ruby
  # Optional consent check
  def can_restrain?(captor, target)
    return true if target.allows_restraint_from?(captor)
    return true if target.relationship_with(captor)&.allows_physical_interaction?
    false
  end
  ```

  ## Important Constants

  | Constant | Value | Purpose |
  |----------|-------|---------|
  | `RELEASE_COOLDOWN` | 60 | Seconds before self-release (if enabled) |
  | `SEARCH_DURATION` | 10 | Seconds to complete search action |

  ## Debugging Tips

  1. Check CharacterInstance flags: `ci.is_bound?`, `ci.is_blindfolded?`, `ci.is_gagged?`
  2. Verify dragged_by association: `ci.dragged_by`
  3. Test command requirements individually
  4. Check RoomDisplayService blindfold logic
  5. Verify BroadcastService gag modification

  ## Common Modifications

  - **Adding restraint types**: Add new boolean to CharacterInstance, create command pair
  - **Changing effects**: Modify command requirements or display services
  - **Consent integration**: Update can_restrain? method with new permission checks
MARKDOWN

PRISONER_QUICK_REFERENCE = <<~MARKDOWN
  # Prisoner System - Quick Reference

  ## Restraining Commands

  | Command | Syntax | Effect |
  |---------|--------|--------|
  | `bind` | `bind <target>` | Restrict hand use |
  | `blindfold` | `blindfold <target>` | Block vision |
  | `gag` | `gag <target>` | Muffle speech |

  ## Release Commands

  | Command | Syntax | Effect |
  |---------|--------|--------|
  | `unbind` | `unbind <target>` | Free hands |
  | `unblindfold` | `unblindfold <target>` | Restore vision |
  | `ungag` | `ungag <target>` | Restore speech |
  | `release` | `release` | Self-free from all |

  ## Other Commands

  | Command | Syntax | Effect |
  |---------|--------|--------|
  | `drag` | `drag <target> <dir>` | Move bound target |
  | `search` | `search <target>` | Check belongings |

  ## Restraint Effects

  | Type | Prevents |
  |------|----------|
  | Bound | get, drop, give, attack, use |
  | Blindfolded | Seeing room, targeting by sight |
  | Gagged | Clear speech, whisper |
MARKDOWN

PRISONER_CONSTANTS = {
  restraint: {
    RELEASE_COOLDOWN: { value: 60, file: 'plugins/core/prisoner/commands/release.rb', purpose: 'Seconds before self-release allowed' },
    SEARCH_DURATION: { value: 10, file: 'plugins/core/prisoner/commands/search.rb', purpose: 'Seconds to complete search' }
  }
}.freeze

puts "\n[Prisoner System]"
seed_system('prisoner', {
  display_name: 'Prisoner System',
  summary: 'Character restraint mechanics for consensual RP scenarios',
  description: 'The Prisoner system handles binding, blindfolding, gagging, and dragging mechanics for consensual roleplay scenarios.',
  player_guide: PRISONER_PLAYER_GUIDE,
  staff_guide: PRISONER_STAFF_GUIDE,
  quick_reference: PRISONER_QUICK_REFERENCE,
  constants_json: PRISONER_CONSTANTS,
  command_names: %w[bind unbind blindfold unblindfold gag ungag drag search release],
  related_systems: %w[combat inventory navigation communication],
  key_files: [
    'plugins/core/prisoner/commands/bind.rb',
    'plugins/core/prisoner/commands/drag.rb',
    'plugins/core/prisoner/commands/release.rb',
    'app/models/character_instance.rb'
  ],
  staff_notes: 'Restraint states stored on CharacterInstance. Display modified for blindfolded. Speech modified for gagged. Always allow self-release as safety valve.',
  display_order: 130
})

# -----------------------------------------------------------------------------
# Vehicles System
# -----------------------------------------------------------------------------

VEHICLES_PLAYER_GUIDE = <<~MARKDOWN
  # Vehicles System

  ## Overview

  The Vehicles system provides personal transportation for characters. Vehicles can be
  purchased, customized, and driven through city streets. They offer faster travel than
  walking and can carry passengers.

  ## Key Concepts

  - **Vehicle**: A personal transport (car, motorcycle, etc.) owned by a character
  - **Vehicle Type**: The make and model determining appearance and stats
  - **Parking**: Where vehicles are stored when not in use
  - **Driving**: Actively operating a vehicle on streets
  - **Passengers**: Other characters riding in your vehicle

  ## Getting Started

  1. **Purchase a vehicle** from a dealership or player
  2. **Find your parked vehicle** in the lot where you left it
  3. **Enter and start** the vehicle to drive
  4. **Navigate streets** using drive commands
  5. **Park** when you reach your destination

  ## Commands

  ### Vehicle Management

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `vehicles` | `vehicles` | List your owned vehicles |
  | `enter` | `enter <vehicle>` | Get into a vehicle |
  | `exit` | `exit` | Get out of current vehicle |
  | `start` | `start` | Start the vehicle engine |
  | `stop` | `stop` | Turn off the engine |

  ### Driving

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `drive` | `drive <direction>` | Drive in a direction |
  | `park` | `park` | Park the vehicle |
  | `speed` | `speed <slow/normal/fast>` | Set driving speed |

  ### Passengers

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `invite` | `invite <player>` | Invite someone into vehicle |
  | `eject` | `eject <player>` | Remove a passenger |
  | `passengers` | `passengers` | List current passengers |

  ### Customization

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `paint` | `paint <color>` | Change vehicle color |
  | `plates` | `plates <text>` | Set license plate text |

  ## Vehicle Types

  Different vehicle types have different capabilities:

  | Type | Speed | Passengers | Notes |
  |------|-------|------------|-------|
  | Sedan | Normal | 4 | Standard all-rounder |
  | Sports Car | Fast | 2 | Quick but limited space |
  | SUV | Normal | 6 | More passenger capacity |
  | Motorcycle | Fast | 1 | Solo transport only |
  | Truck | Slow | 2 | Can carry cargo |
  | Convertible | Normal | 2-4 | Top can be up or down |

  ## Examples

  **Getting into and driving**:
  ```
  > enter sedan
  You climb into your black sedan.

  > start
  You turn the key and the engine rumbles to life.

  > drive north
  You drive north along Main Street.
  ```

  **Picking up a passenger**:
  ```
  > invite Sarah
  You invite Sarah to join you in your vehicle.

  [Sarah enters your vehicle]

  > passengers
  Passengers in your Black Sedan:
  - Sarah (front passenger seat)
  ```

  **Parking and leaving**:
  ```
  > park
  You pull into an available parking spot.

  > stop
  You turn off the engine.

  > exit
  You step out of your sedan and close the door.
  ```

  ## Tips & Tricks

  1. **Street navigation**: Vehicles can only travel on streets, not through buildings
  2. **Fuel**: Some games track fuel - keep an eye on your gauge
  3. **Parking lots**: Designated areas keep your vehicle safe
  4. **Weather**: Convertibles interact with weather systems
  5. **Speed tickets**: Driving fast may attract NPC attention

  ## Related Systems

  - **Navigation**: Driving uses street-level pathfinding
  - **Economy**: Purchase and customize vehicles
  - **Weather**: Affects convertible experience
  - **World Travel**: Vehicles for inter-area journeys
MARKDOWN

VEHICLES_STAFF_GUIDE = <<~MARKDOWN
  # Vehicles System - Staff Guide

  ## Architecture Overview

  The Vehicles system consists of three main models: Vehicle (individual instances),
  VehicleType (templates for makes/models), and integration with the street navigation
  system for movement.

  ## Key Files

  | File | Purpose |
  |------|---------|
  | `app/models/vehicle.rb` | Individual vehicle instances |
  | `app/models/vehicle_type.rb` | Vehicle templates (makes/models) |
  | `plugins/core/vehicles/commands/drive.rb` | Driving command |
  | `plugins/core/vehicles/commands/enter.rb` | Enter vehicle |
  | `plugins/core/vehicles/commands/exit.rb` | Exit vehicle |
  | `plugins/core/vehicles/commands/park.rb` | Parking command |
  | `app/services/vehicle_service.rb` | Vehicle business logic |
  | `app/services/taxi_service.rb` | NPC taxi integration |

  ## Database Schema

  ### vehicles table
  ```ruby
  :id
  :owner_id          # FK to characters
  :vehicle_type_id   # FK to vehicle_types
  :name              # Custom vehicle name
  :color             # Paint color
  :license_plate     # Custom plate text
  :location_id       # Current room (if parked)
  :is_running        # Engine state
  :fuel_level        # Current fuel (0-100)
  :condition         # Damage state
  :is_locked         # Lock state
  :is_convertible_open # Top state for convertibles
  ```

  ### vehicle_types table
  ```ruby
  :id
  :name              # Type name (e.g., "Sedan")
  :description       # Type description
  :max_passengers    # Passenger capacity
  :base_speed        # Movement speed multiplier
  :fuel_capacity     # Max fuel
  :is_convertible    # Can have open top
  :price             # Purchase cost
  ```

  ## Movement Integration

  Vehicles use street-level pathfinding:

  ```ruby
  # In DriveCommand
  def execute(args, context)
    direction = parse_direction(args)
    vehicle = context.character.current_vehicle

    # Check if street exists in that direction
    street_exit = vehicle.location.street_exits[direction]
    return error("No street in that direction") unless street_exit

    # Move vehicle and all passengers
    VehicleService.move_vehicle(vehicle, street_exit.destination)
  end
  ```

  ## Passenger Management

  ```ruby
  # Vehicle model associations
  class Vehicle < Sequel::Model
    many_to_one :owner, class: 'Character'
    many_to_one :location, class: 'Room'
    one_to_many :passengers, class: 'CharacterInstance', key: :in_vehicle_id

    def add_passenger(character_instance)
      return false if passengers.count >= vehicle_type.max_passengers
      character_instance.update(in_vehicle_id: id)
      true
    end
  end
  ```

  ## TaxiService Integration

  ```ruby
  # TaxiService handles NPC taxi calls
  class TaxiService
    def call_taxi(character, destination)
      # Find nearest available taxi
      taxi = find_available_taxi(character.location)
      return nil unless taxi

      # Calculate fare and ETA
      route = PathfindingService.street_route(taxi.location, character.location)
      eta = route.length * TAXI_SPEED_FACTOR

      # Schedule taxi arrival
      Scheduler.schedule_once(eta) do
        taxi_arrives(taxi, character, destination)
      end
    end
  end
  ```

  ## World Travel Integration

  Vehicles can be used for world hex travel:

  ```ruby
  # WorldTravelService vehicle support
  def start_journey_by_vehicle(character, destination_hex, vehicle)
    journey = WorldJourney.create(
      character: character,
      vehicle: vehicle,
      origin_hex: character.location.world_hex,
      destination_hex: destination_hex,
      travel_mode: 'vehicle'
    )

    # Vehicle speed affects travel time
    journey.calculate_eta(vehicle.vehicle_type.base_speed)
    journey
  end
  ```

  ## Important Constants

  | Constant | Value | Location | Purpose |
  |----------|-------|----------|---------|
  | `DEFAULT_FUEL_CONSUMPTION` | 1 | VehicleService | Fuel per street segment |
  | `TAXI_SPEED_FACTOR` | 5 | TaxiService | Seconds per street for taxis |
  | `PARKING_SEARCH_RADIUS` | 3 | ParkCommand | Rooms to search for parking |

  ## Debugging Tips

  1. Check vehicle location: `Vehicle[id].location`
  2. Verify passenger list: `Vehicle[id].passengers`
  3. Check street connectivity: `room.street_exits`
  4. Trace TaxiService logs for taxi issues
  5. Verify vehicle type configuration

  ## Common Modifications

  - **New vehicle types**: Add row to vehicle_types, optionally create VehicleTypeDesigner admin
  - **Speed adjustments**: Modify base_speed in vehicle_types
  - **Fuel mechanics**: Adjust DEFAULT_FUEL_CONSUMPTION or add fuel stations
  - **Taxi fares**: Configure in TaxiService constants
MARKDOWN

VEHICLES_QUICK_REFERENCE = <<~MARKDOWN
  # Vehicles System - Quick Reference

  ## Basic Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `vehicles` | `vehicles` | List owned vehicles |
  | `enter` | `enter <vehicle>` | Get in vehicle |
  | `exit` | `exit` | Get out |
  | `start` | `start` | Start engine |
  | `stop` | `stop` | Stop engine |

  ## Driving

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `drive` | `drive <direction>` | Drive direction |
  | `park` | `park` | Park vehicle |
  | `speed` | `speed <level>` | Set speed |

  ## Passengers

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `invite` | `invite <player>` | Invite passenger |
  | `eject` | `eject <player>` | Remove passenger |
  | `passengers` | `passengers` | List passengers |

  ## Vehicle Types

  | Type | Speed | Passengers |
  |------|-------|------------|
  | Sedan | Normal | 4 |
  | Sports | Fast | 2 |
  | SUV | Normal | 6 |
  | Motorcycle | Fast | 1 |
  | Truck | Slow | 2 |
MARKDOWN

VEHICLES_CONSTANTS = {
  movement: {
    DEFAULT_FUEL_CONSUMPTION: { value: 1, file: 'app/services/vehicle_service.rb', purpose: 'Fuel used per street segment' },
    TAXI_SPEED_FACTOR: { value: 5, file: 'app/services/taxi_service.rb', purpose: 'Seconds per street for taxi travel' },
    PARKING_SEARCH_RADIUS: { value: 3, file: 'plugins/core/vehicles/commands/park.rb', purpose: 'Rooms to search for parking spots' }
  }
}.freeze

puts "\n[Vehicles System]"
seed_system('vehicles', {
  display_name: 'Vehicles System',
  summary: 'Personal transportation and street-level travel',
  description: 'The Vehicles system provides personal transportation including cars, motorcycles, and taxis for street navigation.',
  player_guide: VEHICLES_PLAYER_GUIDE,
  staff_guide: VEHICLES_STAFF_GUIDE,
  quick_reference: VEHICLES_QUICK_REFERENCE,
  constants_json: VEHICLES_CONSTANTS,
  command_names: %w[vehicles enter exit start stop drive park speed invite eject passengers paint plates taxi],
  related_systems: %w[navigation economy world_travel],
  key_files: [
    'app/models/vehicle.rb',
    'app/models/vehicle_type.rb',
    'app/services/vehicle_service.rb',
    'app/services/taxi_service.rb',
    'plugins/core/vehicles/commands/drive.rb'
  ],
  staff_notes: 'Vehicles stored on Vehicle model with VehicleType templates. Movement via street exits. TaxiService for NPC taxis. WorldTravelService for hex journeys.',
  display_order: 140
})

# -----------------------------------------------------------------------------
# Timeline System
# -----------------------------------------------------------------------------

TIMELINE_PLAYER_GUIDE = <<~MARKDOWN
  # Timeline System

  ## Overview

  The Timeline system allows game administrators to create and manage snapshots
  of game state at different points in time. This enables flashback scenes,
  historical roleplay, and alternate timeline exploration.

  **Note**: Timeline features are primarily staff-controlled. Players experience
  timelines through special events and scenes rather than direct commands.

  ## Key Concepts

  - **Timeline**: A named period or version of game history
  - **Snapshot**: A saved state of rooms, characters, or objects at a point in time
  - **Era**: The current time period the game world is in
  - **Flashback**: A scene set in a past timeline
  - **Restriction**: What players can and cannot do in historical timelines

  ## How Timelines Work

  ### Current Era

  The game operates in a "current era" - the main timeline where normal gameplay
  occurs. All standard commands and interactions work normally.

  ### Flashback Scenes

  Staff can initiate flashback scenes that transport characters to a past timeline:

  1. Staff announces/initiates a flashback scene
  2. Participating characters enter the flashback
  3. Room descriptions may change to reflect the past
  4. Some modern features may be restricted
  5. Scene concludes and characters return to present

  ### Historical Characters

  In flashbacks, you might encounter:
  - Past versions of existing characters
  - Historical NPCs no longer in the present
  - Locations that have since changed or been destroyed

  ## Player Experience

  ### During Flashbacks

  - Room descriptions reflect the historical period
  - Some items may not exist yet or be different
  - Communication may be limited (no phones in medieval times)
  - Your character might be younger or have different abilities

  ### Restrictions

  Flashback timelines often restrict:
  - Creating permanent changes (history already happened)
  - Using anachronistic technology
  - Certain combat or economic actions
  - Leaving the flashback area until scene ends

  ## Examples

  **Entering a Flashback** (staff-initiated):
  ```
  [SYSTEM] A flashback scene is beginning...
  [SYSTEM] You find yourself in Ravenport, 50 years ago.

  > look
  Town Square (50 years ago)
  The cobblestone square bustles with activity. Horse-drawn
  carriages pass by where you remember cars. The old clock
  tower stands pristine, not yet damaged by the great fire.
  ```

  **Historical Restrictions**:
  ```
  > pm Sarah Hi!
  [SYSTEM] Private messaging is not available in this era.
  Communication was limited to in-person or written letters.

  > bank deposit 100
  [SYSTEM] Banking works differently in this era.
  ```

  ## Tips for Timeline RP

  1. **Embrace the setting**: Play along with historical restrictions
  2. **Character history**: Use flashbacks to explore your character's past
  3. **No spoilers**: Your character doesn't know future events
  4. **Ask staff**: If unsure what's appropriate for the era
  5. **Enjoy the story**: Flashbacks reveal world lore and history

  ## Related Systems

  - **Events**: Flashbacks often occur during special events
  - **NPCs**: Historical NPCs may appear in flashbacks
  - **Environment**: Weather and time reflect the historical period
MARKDOWN

TIMELINE_STAFF_GUIDE = <<~MARKDOWN
  # Timeline System - Staff Guide

  ## Architecture Overview

  The Timeline system uses snapshots to store historical game state and era
  configuration to manage what features are available in different time periods.
  Flashbacks temporarily transport characters to historical snapshots.

  ## Key Files

  | File | Purpose |
  |------|---------|
  | `app/models/timeline.rb` | Timeline/era definitions |
  | `app/models/timeline_snapshot.rb` | Saved state snapshots |
  | `app/services/timeline_service.rb` | Timeline management logic |
  | `app/services/era_service.rb` | Era feature restrictions |
  | `config/eras.yml` | Era configuration file |

  ## Database Schema

  ### timelines table
  ```ruby
  :id
  :name              # Timeline name (e.g., "Medieval Era")
  :slug              # URL-safe identifier
  :description       # Timeline description
  :start_year        # Game year this era begins
  :end_year          # Game year this era ends (nil for ongoing)
  :is_active         # Whether this timeline is accessible
  :restrictions      # JSONB of feature restrictions
  ```

  ### timeline_snapshots table
  ```ruby
  :id
  :timeline_id       # FK to timelines
  :room_id           # FK to rooms (if room snapshot)
  :character_id      # FK to characters (if character snapshot)
  :snapshot_data     # JSONB containing saved state
  :snapshot_type     # 'room', 'character', 'world'
  :created_at
  ```

  ## Era Service

  The EraService controls what features are available:

  ```ruby
  class EraService
    ERA_FEATURES = {
      modern: {
        has_phones: true,
        has_cars: true,
        has_internet: true,
        banking_type: 'digital'
      },
      victorian: {
        has_phones: false,
        has_cars: false,
        has_internet: false,
        banking_type: 'physical',
        communication: ['say', 'whisper', 'letter']
      },
      medieval: {
        has_phones: false,
        has_cars: false,
        has_internet: false,
        banking_type: 'barter',
        communication: ['say', 'whisper']
      }
    }

    def feature_available?(feature, era = current_era)
      ERA_FEATURES.dig(era, feature) || false
    end
  end
  ```

  ## Timeline Service

  ```ruby
  class TimelineService
    def start_flashback(room, timeline, participants)
      # Load historical snapshot
      snapshot = TimelineSnapshot.find(timeline_id: timeline.id, room_id: room.id)

      # Store current state for return
      save_return_state(participants)

      # Apply historical room description
      room.apply_snapshot(snapshot)

      # Set era restrictions for participants
      participants.each do |char|
        char.instance.update(current_era: timeline.slug)
      end

      # Notify participants
      BroadcastService.to_room(room, flashback_start_message(timeline))
    end

    def end_flashback(room, participants)
      # Restore room to present
      room.restore_from_snapshot

      # Remove era restrictions
      participants.each do |char|
        char.instance.update(current_era: 'modern')
      end

      # Notify participants
      BroadcastService.to_room(room, flashback_end_message)
    end
  end
  ```

  ## Command Integration

  Commands check era restrictions:

  ```ruby
  # In command base or individual commands
  def check_era_restriction
    era = context.character.instance.current_era
    return true if era == 'modern'

    unless EraService.command_available?(command_name, era)
      return error("This command is not available in \#{era.humanize} era.")
    end
    true
  end
  ```

  ## Snapshot Management

  Creating a snapshot:
  ```ruby
  # Snapshot a room's current state
  TimelineSnapshot.create(
    timeline: medieval_timeline,
    room: town_square,
    snapshot_type: 'room',
    snapshot_data: {
      name: town_square.name,
      description: "Historical description...",
      exits: town_square.exits.to_h,
      objects: town_square.objects.map(&:to_snapshot)
    }
  )
  ```

  ## Important Constants

  | Constant | Value | Location | Purpose |
  |----------|-------|----------|---------|
  | `DEFAULT_ERA` | 'modern' | EraService | Default era for new instances |
  | `FLASHBACK_DURATION` | 3600 | TimelineService | Max flashback seconds |

  ## Debugging Tips

  1. Check character era: `ci.current_era`
  2. Verify snapshot exists: `TimelineSnapshot.where(timeline_id: X, room_id: Y)`
  3. Test era restrictions: `EraService.command_available?('pm', 'medieval')`
  4. Check ERA_FEATURES config for available features

  ## Common Modifications

  - **New eras**: Add to ERA_FEATURES hash with appropriate restrictions
  - **New restrictions**: Add feature flags to era configs
  - **Snapshot tools**: Build admin interface for creating/managing snapshots
  - **Automated flashbacks**: Tie to event system for scheduled historical scenes
MARKDOWN

TIMELINE_QUICK_REFERENCE = <<~MARKDOWN
  # Timeline System - Quick Reference

  ## Concepts

  | Term | Definition |
  |------|------------|
  | Timeline | Named historical period |
  | Snapshot | Saved room/character state |
  | Era | Current time period |
  | Flashback | Scene in past timeline |

  ## Era Restrictions

  | Era | Phones | Cars | Internet | Banking |
  |-----|--------|------|----------|---------|
  | Modern | Yes | Yes | Yes | Digital |
  | Victorian | No | No | No | Physical |
  | Medieval | No | No | No | Barter |

  ## Staff Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `flashback` | `flashback start <timeline>` | Start flashback scene |
  | `flashback` | `flashback end` | End current flashback |
  | `snapshot` | `snapshot create <timeline>` | Save room state |

  ## Player Experience

  - Room descriptions change
  - Some commands restricted
  - Historical NPCs may appear
  - Changes don't persist to present
MARKDOWN

TIMELINE_CONSTANTS = {
  era: {
    DEFAULT_ERA: { value: 'modern', file: 'app/services/era_service.rb', purpose: 'Default era for new character instances' },
    FLASHBACK_DURATION: { value: 3600, file: 'app/services/timeline_service.rb', purpose: 'Maximum flashback duration in seconds' }
  }
}.freeze

puts "\n[Timeline System]"
seed_system('timeline', {
  display_name: 'Timeline System',
  summary: 'Historical snapshots and era-based feature restrictions',
  description: 'The Timeline system manages historical snapshots, flashback scenes, and era-based restrictions for temporal roleplay.',
  player_guide: TIMELINE_PLAYER_GUIDE,
  staff_guide: TIMELINE_STAFF_GUIDE,
  quick_reference: TIMELINE_QUICK_REFERENCE,
  constants_json: TIMELINE_CONSTANTS,
  command_names: %w[],
  related_systems: %w[events npcs environment],
  key_files: [
    'app/models/timeline.rb',
    'app/models/timeline_snapshot.rb',
    'app/services/timeline_service.rb',
    'app/services/era_service.rb'
  ],
  staff_notes: 'Snapshots store historical state. EraService controls feature availability. Characters have current_era on instance. Commands check era restrictions.',
  display_order: 150
})

# -----------------------------------------------------------------------------
# Entertainment System
# -----------------------------------------------------------------------------

ENTERTAINMENT_PLAYER_GUIDE = <<~MARKDOWN
  # Entertainment System

  ## Overview

  The Entertainment system provides shared media experiences for characters.
  Watch videos together, play music on jukeboxes, and share screens with others
  in the same room. Perfect for bars, clubs, and social gatherings.

  ## Key Concepts

  - **Media Session**: A shared viewing/listening experience
  - **Jukebox**: Room furniture that plays music
  - **Screen Share**: Sharing a video or stream with others
  - **Watch Party**: Synchronized video watching
  - **Media Library**: Saved media for quick access

  ## Getting Started

  Entertainment features are typically tied to room objects:

  1. **Find a venue** with entertainment equipment
  2. **Interact with the device** (jukebox, screen, etc.)
  3. **Choose media** to play or share
  4. **Others can join** to watch/listen together

  ## Commands

  ### Jukebox Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `jukebox` | `jukebox` | View current jukebox status |
  | `jukebox play` | `jukebox play <song>` | Request a song |
  | `jukebox stop` | `jukebox stop` | Stop current song |
  | `jukebox queue` | `jukebox queue` | View song queue |
  | `jukebox skip` | `jukebox skip` | Skip to next song |

  ### Screen Sharing

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `screen` | `screen <url>` | Share a video URL |
  | `screen stop` | `screen stop` | Stop sharing |
  | `watch` | `watch` | Join current screen share |
  | `unwatch` | `unwatch` | Leave screen share |

  ### Media Library

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `media save` | `media save <name> <url>` | Save media to library |
  | `media list` | `media list` | List saved media |
  | `media play` | `media play <name>` | Play from library |
  | `media delete` | `media delete <name>` | Remove from library |

  ## Venue Features

  Different venues may have different entertainment options:

  | Venue Type | Features |
  |------------|----------|
  | Bar | Jukebox, TV screens |
  | Club | DJ booth, dance floor effects |
  | Lounge | Screen sharing, ambient music |
  | Theater | Main screen, surround sound |
  | Home | Personal media devices |

  ## Examples

  **Using a Jukebox**:
  ```
  > jukebox
  The Rusty Anchor Jukebox
  Currently playing: "Neon Dreams" by The Synthwave Collective
  Queue: 3 songs remaining

  > jukebox play midnight runner
  You select "Midnight Runner" on the jukebox.
  Your song has been added to the queue (position 4).
  ```

  **Screen Sharing**:
  ```
  > screen https://youtube.com/watch?v=abc123
  You start sharing "Epic Gaming Moments" on the room screen.
  Others in the room can use 'watch' to join.

  > watch
  You turn your attention to the shared screen.
  [Now watching: "Epic Gaming Moments"]

  > unwatch
  You look away from the screen.
  ```

  **Media Library**:
  ```
  > media save intro https://youtube.com/watch?v=xyz789
  Saved "intro" to your media library.

  > media list
  Your Media Library:
  1. intro - https://youtube.com/watch?v=xyz789
  2. party-mix - https://youtube.com/playlist?list=...
  ```

  ## Synchronized Watching

  When you share a screen or watch with others:

  - Video playback is synchronized across viewers
  - Chat appears alongside the video
  - Host can pause/play for everyone
  - Viewers see what's playing and current timestamp

  ## Tips & Tricks

  1. **Queue etiquette**: Don't flood the jukebox queue
  2. **Room rules**: Some venues may restrict certain content
  3. **Volume**: Personal volume controls affect only you
  4. **AFK watching**: You can watch while doing other activities
  5. **Host controls**: The person who started sharing controls playback

  ## Related Systems

  - **Communication**: Chat while watching
  - **Social**: Watch parties with friends
  - **Events**: Entertainment at special events
MARKDOWN

ENTERTAINMENT_STAFF_GUIDE = <<~MARKDOWN
  # Entertainment System - Staff Guide

  ## Architecture Overview

  The Entertainment system uses the MediaSyncService for synchronized playback,
  the Jukebox model for music queues, and MediaSession for tracking active
  watch parties. Integration with WebSockets enables real-time sync.

  ## Key Files

  | File | Purpose |
  |------|---------|
  | `app/models/jukebox.rb` | Jukebox furniture with track queues |
  | `app/models/jukebox_track.rb` | Individual tracks in queue |
  | `app/models/media_session.rb` | Active media sharing sessions |
  | `app/models/media_session_viewer.rb` | Viewers in a session |
  | `app/models/media_library.rb` | Saved media items |
  | `app/services/media_sync_service.rb` | Synchronized playback |
  | `plugins/core/entertainment/commands/jukebox.rb` | Jukebox commands |
  | `plugins/core/entertainment/commands/screen.rb` | Screen share command |
  | `public/js/media_sync.js` | Client-side sync |

  ## Database Schema

  ### jukeboxes table
  ```ruby
  :id
  :room_id           # FK to rooms
  :name              # Jukebox name
  :is_active         # Whether playing
  :current_track_id  # FK to jukebox_tracks
  :volume            # 0-100
  ```

  ### jukebox_tracks table
  ```ruby
  :id
  :jukebox_id        # FK to jukeboxes
  :url               # Media URL
  :title             # Track title
  :duration          # Length in seconds
  :requested_by_id   # FK to characters
  :position          # Queue position
  :played_at         # When played
  ```

  ### media_sessions table
  ```ruby
  :id
  :room_id           # FK to rooms
  :host_character_id # FK to characters (who started)
  :media_url         # Current media URL
  :media_title       # Display title
  :is_playing        # Play state
  :current_time      # Playback position (seconds)
  :started_at        # Session start
  ```

  ### media_session_viewers table
  ```ruby
  :id
  :media_session_id  # FK to media_sessions
  :character_id      # FK to characters
  :joined_at         # When joined
  ```

  ## MediaSyncService

  Handles synchronized playback:

  ```ruby
  class MediaSyncService
    def start_session(room, host, url, title)
      session = MediaSession.create(
        room: room,
        host_character: host,
        media_url: url,
        media_title: title,
        is_playing: true,
        current_time: 0
      )

      # Notify room
      BroadcastService.to_room(room, {
        type: 'media_session_started',
        session_id: session.id,
        url: url,
        title: title,
        host: host.name
      })

      session
    end

    def sync_playback(session, action, time = nil)
      case action
      when :play
        session.update(is_playing: true)
      when :pause
        session.update(is_playing: false)
      when :seek
        session.update(current_time: time)
      end

      # Broadcast sync event to all viewers
      broadcast_sync(session, action, time)
    end

    def join_session(session, character)
      MediaSessionViewer.create(
        media_session: session,
        character: character
      )

      # Send current state to new viewer
      send_current_state(session, character)
    end
  end
  ```

  ## Jukebox Logic

  ```ruby
  class Jukebox < Sequel::Model
    one_to_many :tracks, class: 'JukeboxTrack', order: :position

    def add_to_queue(url, title, character)
      next_position = tracks.count + 1
      JukeboxTrack.create(
        jukebox: self,
        url: url,
        title: title,
        requested_by: character,
        position: next_position
      )
    end

    def advance_track
      current = current_track
      current&.update(played_at: Time.now)

      next_track = tracks_dataset.where(played_at: nil).order(:position).first
      update(current_track: next_track)

      # Schedule next advance when track ends
      if next_track
        Scheduler.schedule_once(next_track.duration) { advance_track }
      end
    end
  end
  ```

  ## WebSocket Integration

  Client-side sync via WebSockets:

  ```javascript
  // public/js/media_sync.js
  class MediaSync {
    constructor(sessionId) {
      this.sessionId = sessionId;
      this.player = null;
    }

    handleSync(data) {
      switch(data.action) {
        case 'play':
          this.player.play();
          break;
        case 'pause':
          this.player.pause();
          break;
        case 'seek':
          this.player.seekTo(data.time);
          break;
      }
    }

    // Periodic sync check
    syncCheck() {
      const serverTime = this.lastKnownTime + (Date.now() - this.lastSync) / 1000;
      const drift = Math.abs(this.player.currentTime - serverTime);
      if (drift > SYNC_THRESHOLD) {
        this.player.seekTo(serverTime);
      }
    }
  }
  ```

  ## Important Constants

  | Constant | Value | Location | Purpose |
  |----------|-------|----------|---------|
  | `MAX_QUEUE_SIZE` | 20 | JukeboxCommand | Max songs per user in queue |
  | `SYNC_THRESHOLD` | 2 | media_sync.js | Seconds drift before resync |
  | `SESSION_TIMEOUT` | 3600 | MediaSyncService | Inactive session timeout |

  ## Debugging Tips

  1. Check active sessions: `MediaSession.where(is_playing: true)`
  2. Verify viewer list: `MediaSession[id].viewers`
  3. Check jukebox queue: `Jukebox[id].tracks`
  4. Monitor WebSocket events for sync issues
  5. Check browser console for media_sync.js errors

  ## Common Modifications

  - **Supported platforms**: Update URL validators for new video sites
  - **Queue limits**: Adjust MAX_QUEUE_SIZE per venue
  - **Sync frequency**: Tune SYNC_THRESHOLD for better/worse connections
  - **Room permissions**: Add room flags for entertainment access
MARKDOWN

ENTERTAINMENT_QUICK_REFERENCE = <<~MARKDOWN
  # Entertainment System - Quick Reference

  ## Jukebox Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `jukebox` | `jukebox` | View status |
  | `jukebox play` | `jukebox play <song>` | Add to queue |
  | `jukebox queue` | `jukebox queue` | View queue |
  | `jukebox skip` | `jukebox skip` | Skip song |

  ## Screen Sharing

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `screen` | `screen <url>` | Start sharing |
  | `screen stop` | `screen stop` | Stop sharing |
  | `watch` | `watch` | Join session |
  | `unwatch` | `unwatch` | Leave session |

  ## Media Library

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `media save` | `media save <name> <url>` | Save media |
  | `media list` | `media list` | List saved |
  | `media play` | `media play <name>` | Play saved |

  ## Key Models

  | Model | Purpose |
  |-------|---------|
  | Jukebox | Room music player |
  | JukeboxTrack | Queue item |
  | MediaSession | Watch party |
  | MediaSessionViewer | Participant |
MARKDOWN

ENTERTAINMENT_CONSTANTS = {
  jukebox: {
    MAX_QUEUE_SIZE: { value: 20, file: 'plugins/core/entertainment/commands/jukebox.rb', purpose: 'Maximum songs per user in queue' }
  },
  sync: {
    SYNC_THRESHOLD: { value: 2, file: 'public/js/media_sync.js', purpose: 'Seconds of drift before forced resync' },
    SESSION_TIMEOUT: { value: 3600, file: 'app/services/media_sync_service.rb', purpose: 'Inactive session timeout in seconds' }
  }
}.freeze

puts "\n[Entertainment System]"
seed_system('entertainment', {
  display_name: 'Entertainment System',
  summary: 'Shared media experiences including jukeboxes and watch parties',
  description: 'The Entertainment system provides synchronized video watching, jukebox music queues, and screen sharing for social venues.',
  player_guide: ENTERTAINMENT_PLAYER_GUIDE,
  staff_guide: ENTERTAINMENT_STAFF_GUIDE,
  quick_reference: ENTERTAINMENT_QUICK_REFERENCE,
  constants_json: ENTERTAINMENT_CONSTANTS,
  command_names: %w[jukebox screen watch unwatch media],
  related_systems: %w[communication social events],
  key_files: [
    'app/models/jukebox.rb',
    'app/models/media_session.rb',
    'app/services/media_sync_service.rb',
    'plugins/core/entertainment/commands/jukebox.rb',
    'public/js/media_sync.js'
  ],
  staff_notes: 'MediaSyncService handles playback sync. Jukebox queues per-room. MediaSession tracks active watch parties. WebSocket broadcasts sync events.',
  display_order: 160
})

# -----------------------------------------------------------------------------
# Accessibility System
# -----------------------------------------------------------------------------

ACCESSIBILITY_PLAYER_GUIDE = <<~MARKDOWN
  # Accessibility System

  ## Overview

  The Accessibility system provides features to make the game more accessible
  to all players. This includes text-to-speech narration, screen reader
  optimization, audio cues, and customizable output settings.

  ## Key Features

  - **Text-to-Speech (TTS)**: Have game output read aloud
  - **Screen Reader Mode**: Optimized text formatting for screen readers
  - **Audio Cues**: Sound effects for game events
  - **High Contrast**: Enhanced visual contrast options
  - **Keyboard Navigation**: Full keyboard control

  ## Getting Started

  Access accessibility settings through the `accessibility` command:

  ```
  > accessibility
  Accessibility Settings for Marcus:
  - TTS: Enabled (Voice: Kore)
  - Screen Reader Mode: Disabled
  - Audio Cues: Enabled
  ```

  ## Commands

  ### Main Settings

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `accessibility` | `accessibility` | View current settings |
  | `accessibility tts` | `accessibility tts on/off` | Toggle TTS |
  | `accessibility voice` | `accessibility voice <name>` | Set TTS voice |
  | `accessibility screenreader` | `accessibility screenreader on/off` | Toggle screen reader mode |
  | `accessibility audio` | `accessibility audio on/off` | Toggle audio cues |

  ### TTS Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `narrate` | `narrate` | Re-read last output |
  | `narrate stop` | `narrate stop` | Stop current narration |
  | `voices` | `voices` | List available voices |

  ## Text-to-Speech (TTS)

  The TTS system uses Google Cloud's Chirp 3 HD voices for natural speech.

  ### Available Voices

  The game offers 30 high-quality voices across different styles:

  **Feminine Voices**: Aoede, Kore, Leda, Zephyr, Elara, Nova, Lyra, Aurora
  **Masculine Voices**: Puck, Charon, Koda, Orus, Fenrir, Atlas, Orion, Titan
  **Neutral Voices**: Sage, Echo, River, Morgan

  ### Voice Settings

  ```
  > voices
  Available TTS Voices:
  Feminine: Aoede, Kore, Leda, Zephyr...
  Masculine: Puck, Charon, Koda, Orus...
  Neutral: Sage, Echo, River, Morgan...

  > accessibility voice Kore
  TTS voice set to Kore.
  ```

  ### What Gets Narrated

  - Room descriptions when you enter
  - Speech from other characters
  - Emotes and actions
  - System messages
  - Combat events (optional)

  ## Screen Reader Mode

  Optimizes output for screen reader software:

  - Removes decorative ASCII art
  - Simplifies formatting
  - Adds structural cues (headings, lists)
  - Reduces redundant information
  - Cleaner line breaks

  ```
  > accessibility screenreader on
  Screen reader mode enabled. Output will be optimized for assistive technology.
  ```

  ## Audio Cues

  Sound effects provide additional feedback:

  | Event | Sound |
  |-------|-------|
  | Someone enters room | Door chime |
  | Received message | Notification tone |
  | Combat starts | Alert |
  | Combat hit taken | Impact |
  | Item received | Pickup sound |

  ```
  > accessibility audio on
  Audio cues enabled.
  ```

  ## Keyboard Shortcuts

  For web client users:

  | Shortcut | Action |
  |----------|--------|
  | `Tab` | Navigate elements |
  | `Enter` | Activate/Submit |
  | `Escape` | Close dialogs |
  | `Ctrl+/` | Toggle TTS |
  | `Ctrl+.` | Stop narration |

  ## Examples

  **Setting up TTS**:
  ```
  > accessibility tts on
  Text-to-speech enabled.

  > accessibility voice Zephyr
  TTS voice set to Zephyr.

  > look
  [Room description is read aloud in Zephyr's voice]
  ```

  **Screen Reader Setup**:
  ```
  > accessibility screenreader on
  Screen reader mode enabled.

  > look
  Town Square.
  A cobblestone square with a central fountain.
  Exits: north, east, south.
  Characters present: Sarah, Marcus.
  ```

  ## Tips for Accessibility

  1. **Voice preview**: Use `voices preview <name>` to hear samples
  2. **Selective narration**: Configure what types of output get TTS
  3. **Speed control**: Adjust narration speed in settings
  4. **Quiet mode**: Mute TTS temporarily with `narrate stop`
  5. **Combine features**: Use TTS + audio cues for best experience

  ## Related Systems

  - **Communication**: Speech has TTS integration
  - **Combat**: Combat narration options
  - **Navigation**: Room entry narration
MARKDOWN

ACCESSIBILITY_STAFF_GUIDE = <<~MARKDOWN
  # Accessibility System - Staff Guide

  ## Architecture Overview

  The Accessibility system integrates with output rendering through services that
  transform text for TTS or screen reader consumption. The TtsService handles
  Google Cloud TTS integration with Chirp 3 HD voices, while AccessibilityOutputService
  formats text for assistive technology.

  ## Key Files

  | File | Purpose |
  |------|---------|
  | `app/services/tts_service.rb` | Google Cloud TTS integration |
  | `app/services/tts_queue_service.rb` | Audio queue management |
  | `app/services/tts_narration_service.rb` | Context-aware narration |
  | `app/services/accessibility_output_service.rb` | Screen reader formatting |
  | `plugins/core/system/commands/accessibility.rb` | Settings command |
  | `plugins/core/system/commands/narrate.rb` | TTS control command |
  | `app/models/audio_queue_item.rb` | Queued audio items |
  | `public/js/audio_queue_manager.js` | Client-side playback |

  ## Database Schema

  Accessibility settings on characters:

  ```ruby
  # Character columns (or character_settings JSONB)
  :tts_enabled           # Boolean - TTS on/off
  :tts_voice             # String - Voice name (e.g., 'Kore')
  :tts_speed             # Float - Speed multiplier (0.5-2.0)
  :screen_reader_mode    # Boolean - Optimized output
  :audio_cues_enabled    # Boolean - Sound effects
  :tts_narrate_rooms     # Boolean - Narrate room descriptions
  :tts_narrate_speech    # Boolean - Narrate character speech
  :tts_narrate_emotes    # Boolean - Narrate emotes
  :tts_narrate_combat    # Boolean - Narrate combat
  ```

  ## TtsService

  Google Cloud TTS with Chirp 3 HD voices:

  ```ruby
  class TtsService
    CHIRP_VOICES = {
      'Kore' => 'en-US-Chirp3-HD-Kore',
      'Aoede' => 'en-US-Chirp3-HD-Aoede',
      'Puck' => 'en-US-Chirp3-HD-Puck',
      'Charon' => 'en-US-Chirp3-HD-Charon',
      # ... 30 total voices
    }.freeze

    def synthesize(text, voice_name, speed: 1.0)
      client = Google::Cloud::TextToSpeech.text_to_speech

      input = { text: text }
      voice = {
        language_code: 'en-US',
        name: CHIRP_VOICES[voice_name]
      }
      audio_config = {
        audio_encoding: :MP3,
        speaking_rate: speed
      }

      response = client.synthesize_speech(
        input: input,
        voice: voice,
        audio_config: audio_config
      )

      response.audio_content
    end
  end
  ```

  ## TtsQueueService

  Manages audio queue per character:

  ```ruby
  class TtsQueueService
    def queue_narration(character, text, priority: :normal)
      audio = TtsService.synthesize(text, character.tts_voice)

      AudioQueueItem.create(
        character: character,
        audio_data: audio,
        text: text,
        priority: priority_value(priority),
        status: 'pending'
      )

      # Notify client
      BroadcastService.to_character(character, {
        type: 'tts_queued',
        queue_length: queue_length(character)
      })
    end

    def priority_value(priority)
      { urgent: 0, high: 1, normal: 2, low: 3 }[priority]
    end
  end
  ```

  ## AccessibilityOutputService

  Formats output for screen readers:

  ```ruby
  class AccessibilityOutputService
    def format_for_screen_reader(content, context)
      return content unless context.character.screen_reader_mode

      content
        .gsub(/={3,}/, '') # Remove decorative lines
        .gsub(/[*_]{2,}/, '') # Remove markdown emphasis
        .gsub(/\\n{3,}/, "\\n\\n") # Collapse multiple newlines
        .gsub(/\\[([^\\]]+)\\]/, '\\1') # Remove brackets
        .strip
    end

    def announce(section, content)
      # Add ARIA-like announcements
      "\\n\#{section}:\\n\#{content}\\n"
    end

    def format_room(room, character)
      [
        room.name,
        room.description,
        "Exits: \#{room.exits.join(', ')}",
        format_characters_present(room, character),
        format_objects(room)
      ].compact.join("\\n")
    end
  end
  ```

  ## Client-Side Integration

  ```javascript
  // public/js/audio_queue_manager.js
  class AudioQueueManager {
    constructor() {
      this.queue = [];
      this.isPlaying = false;
    }

    add(audioData) {
      this.queue.push(audioData);
      this.playNext();
    }

    async playNext() {
      if (this.isPlaying || this.queue.length === 0) return;

      this.isPlaying = true;
      const audio = this.queue.shift();

      const audioElement = new Audio('data:audio/mp3;base64,' + audio);
      await audioElement.play();

      audioElement.onended = () => {
        this.isPlaying = false;
        this.playNext();
      };
    }

    stop() {
      this.queue = [];
      // Stop current audio
    }
  }
  ```

  ## Important Constants

  | Constant | Value | Location | Purpose |
  |----------|-------|----------|---------|
  | `CHIRP_VOICES` | Hash | TtsService | Voice name to GCP voice ID mapping |
  | `DEFAULT_VOICE` | 'Kore' | TtsService | Default voice for new users |
  | `MAX_TTS_LENGTH` | 5000 | TtsService | Max characters per synthesis |
  | `QUEUE_LIMIT` | 10 | TtsQueueService | Max queued items per character |

  ## Voice List

  30 Chirp 3 HD voices organized by style:

  **Feminine (10)**: Aoede, Elara, Kore, Leda, Nova, Lyra, Zephyr, Aurora, Phoebe, Calliope
  **Masculine (10)**: Puck, Charon, Fenrir, Koda, Orus, Atlas, Orion, Titan, Apollo, Perseus
  **Neutral (10)**: Sage, Echo, River, Morgan, Finley, Avery, Quinn, Taylor, Jordan, Casey

  ## Debugging Tips

  1. Check TTS settings: `Character[id].tts_enabled`, `.tts_voice`
  2. Verify GCP credentials: `ENV['GOOGLE_APPLICATION_CREDENTIALS']`
  3. Test voice synthesis: `TtsService.new.synthesize("Test", "Kore")`
  4. Check audio queue: `AudioQueueItem.where(character_id: X, status: 'pending')`
  5. Browser console for audio playback errors

  ## Common Modifications

  - **New voices**: Add to CHIRP_VOICES hash (requires GCP voice availability)
  - **Default settings**: Update Character model defaults
  - **Narration scope**: Add/remove content types in TtsNarrationService
  - **Output formatting**: Modify AccessibilityOutputService transforms
MARKDOWN

ACCESSIBILITY_QUICK_REFERENCE = <<~MARKDOWN
  # Accessibility System - Quick Reference

  ## Settings Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `accessibility` | `accessibility` | View settings |
  | `accessibility tts` | `accessibility tts on/off` | Toggle TTS |
  | `accessibility voice` | `accessibility voice <name>` | Set voice |
  | `accessibility screenreader` | `accessibility screenreader on/off` | Screen reader |
  | `accessibility audio` | `accessibility audio on/off` | Audio cues |

  ## TTS Commands

  | Command | Syntax | Description |
  |---------|--------|-------------|
  | `narrate` | `narrate` | Re-read output |
  | `narrate stop` | `narrate stop` | Stop TTS |
  | `voices` | `voices` | List voices |

  ## Voice Categories

  | Type | Examples |
  |------|----------|
  | Feminine | Kore, Aoede, Leda, Zephyr |
  | Masculine | Puck, Charon, Koda, Orus |
  | Neutral | Sage, Echo, River, Morgan |

  ## Key Services

  | Service | Purpose |
  |---------|---------|
  | TtsService | Google Cloud TTS synthesis |
  | TtsQueueService | Audio queue management |
  | AccessibilityOutputService | Screen reader formatting |
MARKDOWN

ACCESSIBILITY_CONSTANTS = {
  tts: {
    DEFAULT_VOICE: { value: 'Kore', file: 'app/services/tts_service.rb', purpose: 'Default TTS voice for new users' },
    MAX_TTS_LENGTH: { value: 5000, file: 'app/services/tts_service.rb', purpose: 'Maximum characters per TTS synthesis' },
    QUEUE_LIMIT: { value: 10, file: 'app/services/tts_queue_service.rb', purpose: 'Maximum queued audio items per character' }
  },
  voices: {
    CHIRP_VOICES_COUNT: { value: 30, file: 'app/services/tts_service.rb', purpose: 'Total available Chirp 3 HD voices' }
  }
}.freeze

puts "\n[Accessibility System]"
seed_system('accessibility', {
  display_name: 'Accessibility System',
  summary: 'TTS narration, screen reader support, and accessibility features',
  description: 'The Accessibility system provides text-to-speech with 30 Chirp 3 HD voices, screen reader optimization, audio cues, and customizable output settings.',
  player_guide: ACCESSIBILITY_PLAYER_GUIDE,
  staff_guide: ACCESSIBILITY_STAFF_GUIDE,
  quick_reference: ACCESSIBILITY_QUICK_REFERENCE,
  constants_json: ACCESSIBILITY_CONSTANTS,
  command_names: %w[accessibility narrate voices],
  related_systems: %w[communication combat navigation],
  key_files: [
    'app/services/tts_service.rb',
    'app/services/tts_queue_service.rb',
    'app/services/accessibility_output_service.rb',
    'plugins/core/system/commands/accessibility.rb',
    'public/js/audio_queue_manager.js'
  ],
  staff_notes: 'TtsService uses Google Cloud Chirp 3 HD voices (30 total). TtsQueueService manages per-character audio queues. AccessibilityOutputService formats for screen readers. Requires GOOGLE_APPLICATION_CREDENTIALS.',
  display_order: 170
})

puts "\n" + "=" * 60
puts "System documentation seeded successfully!"
puts "Run the server and visit /info/systems to see the results."
