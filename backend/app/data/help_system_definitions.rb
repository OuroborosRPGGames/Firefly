# frozen_string_literal: true

module HelpSystemDefinitions
  SYSTEM_DEFINITIONS = [
    {
      name: 'help_info',
      display_name: 'Getting Help & Information',
      summary: 'Finding help, looking up characters, and getting information',
      description: "Everything you need to find help in the game. Use 'help' with any topic or command name to get detailed information. The 'who' and 'directory' commands show online and registered characters, while 'finger' and 'profile' let you look up character details. The 'news' system keeps you informed about game updates.",
      command_names: %w[help helpsearch finger who profile observe news look weather time calendar],
      related_systems: %w[commands_ui communication],
      key_files: [
        'lib/firefly/help_manager.rb',
        'app/models/helpfile.rb',
        'app/models/help_system.rb',
        'app/services/profile_display_service.rb',
        'app/services/character_display_service.rb',
        'app/services/autohelper_service.rb',
        'plugins/core/system/commands/help.rb',
        'plugins/core/system/commands/helpsearch.rb',
        'plugins/core/info/commands/finger.rb',
        'plugins/core/info/commands/who.rb',
        'plugins/core/info/commands/profile.rb',
        'plugins/core/info/commands/observe.rb',
        'plugins/core/system/commands/news.rb',
        'plugins/core/navigation/commands/look.rb',
        'plugins/core/environment/commands/weather.rb',
        'plugins/core/environment/commands/time.rb'
      ],
      player_guide: <<~'GUIDE',
        # Getting Help & Information
  
        ## Getting Help on Commands
  
        **help** - Get help on any command or topic
          - `help` - Show general help
          - `help <command>` - Get detailed help on a command (e.g., `help look`, `help fight`)
          - `help systems` - List all help system categories
          - `help system <name>` - View a specific help system (e.g., `help system combat`)
  
        **AI-Powered Help** - If you ask a question (end with "?"), the AI autohelper will try to answer:
          - `help how do I fight?` - AI synthesizes help from relevant topics
          - Uses semantic search to find related commands
          - Remembers context for follow-up questions (10 min window)
  
        **helpsearch** - Search for help topics by keyword
          - `helpsearch combat` - Find all help topics mentioning "combat"
          - `helpsearch sword navigation` - Search with multiple keywords
          - `helpsearch look` - Find commands related to "look"
  
        **Aliases:** help = h, ?, helpsearch = searchhelp, findhelp
  
        ## Looking Up Characters
  
        **finger** - Get detailed information about a character
          - `finger Alice` - See Alice's stats, online status, location, schedule overlap
          - Shows: name, race/class, level, online/offline status, last seen
          - Schedule overlap: See when you're most likely to find each other online
  
        **who** - See who's online
          - `who` - List online characters in your current zone
          - `who here` - List characters in your current room
          - `who all` - List all online characters globally (grouped by zone/event/timeline)
          - Shows character names, posture (sitting/standing), and furniture they're at
          - Also shows upcoming events
  
        **profile** - View a character's full profile
          - `profile` - View your own profile
          - `profile Alice` - View Alice's profile
          - Shows: name, race/class, gender, age, height, profile picture, descriptions, current location
  
        **observe** - Continuously watch a character, place, or room for updates
          - `observe Alice` - Watch Alice's actions and see detailed description
          - `observe bar` - Watch a specific place (furniture/location)
          - `observe room` - Watch the entire room
          - `observe self` or `observe me` - See your own detailed description
          - `observe stop` - Stop observing
          - While observing, you'll receive real-time updates about what happens
  
        **Aliases:** observe = watch, o
  
        ## Looking Around
  
        **look** - Examine your surroundings, objects, or characters
          - `look` - Look at the room (full description, exits, characters, places, objects)
          - `look Alice` - Look at Alice (appearance, clothing, held items)
          - `look sword` - Look at an object in the room
          - `look Alice's sword` - Look at an item Alice is wearing/holding
          - `look north` - Look at an exit to see where it leads
          - `look me` - See your own appearance
          - Works while blindfolded (limited to sounds/presence)
          - Works in vehicles (shows interior and passengers)
          - Works while traveling (shows journey progress)
  
        **Aliases:** look = l, examine, ex, "look at"
  
        ## News & Announcements
  
        **news** - View staff announcements and updates
          - `news` - Show categories and unread counts
          - `news announcement` - View all announcements
          - `news ic` - View IC (in-character) news
          - `news ooc` - View OOC (out-of-character) news
          - `news 5` - Read article #5
          - `news read 5` - Same as above
          - Unread articles marked with [NEW]
  
        **Categories:**
          - announcement - Important game updates
          - ic - In-character world news
          - ooc - Out-of-character announcements
  
        ## Weather & Time
  
        **weather** - Check current weather conditions
          - `weather` - See atmospheric prose, temperature, wind, humidity, cloud cover
          - Shows realistic weather based on location's real-world coordinates
          - Only works outdoors or in rooms with sky visibility
          - Includes severe weather warnings and visibility notes
  
        **time** - Check the current time and date
          - `time` - See game time, date, time of day, moon phase, celestial info
          - Shows: formatted date/time, time period (morning/afternoon/evening/night)
          - Includes: moon phase with emoji, cloud cover, stars visibility
          - Useful for planning RP and understanding world state
  
        **Aliases:** weather = forecast, conditions; time = clock, date
  
        ## Tips
  
        - **Staff members** see extra information in help output (source files, implementation notes)
        - **Tab completion** works for command names
        - **Partial matches** work for most commands (e.g., "fi" for "finger")
        - **Case insensitive** - all commands work in any case
        - **Context memory** - AI autohelper remembers your recent questions
        - **Privacy** - Use `who all` to respect others' privacy settings
        - **Schedule overlap** - Use `finger` to find the best times to connect with others
      GUIDE
      staff_notes: <<~'STAFF',
        # Help & Information System - Staff Implementation Notes
  
        ## Architecture Overview
  
        ### Help System Components
        1. **HelpManager** (lib/firefly/help_manager.rb)
           - Central API for help content access
           - Redis caching with 5-minute TTL (CACHE_TTL = 300)
           - Cache prefix: 'help:'
           - Methods: get_help, search, suggest_topics, table_of_contents, sync_commands!
  
        2. **Helpfile Model** (app/models/helpfile.rb)
           - Stores command documentation in database
           - Auto-synced from Command DSL on server startup
           - Fields: command_name, topic, summary, category, content, source_file, source_line
           - Flags: admin_only, hidden
           - Synonyms via HelpfileSynonym join table
  
        3. **HelpSystem Model** (app/models/help_system.rb)
           - Groups commands into browsable categories
           - SYSTEM_DEFINITIONS constant is source of truth
           - seed_defaults! syncs DB on server boot (called from scheduler initializer)
           - Methods: to_player_display, to_staff_display, to_agent_format
  
        ### Command Registration & Auto-Sync
        - Commands define metadata via DSL: command_name, aliases, category, help_text, usage, examples
        - Helpfile.sync_all_commands! extracts via Ruby reflection
        - Source location extracted via Method#source_location
        - Requirements auto-summarized from command requirements DSL
        - Triggered: Server startup (scheduler.rb:490), /admin/help sync endpoint
  
        ## AI Autohelper (AutohelperService)
  
        **Trigger Conditions:**
        - Query ends with "?" (explicit question), OR
        - No suggestions found (standard help completely failed)
        - Must be enabled via GameSetting 'autohelper_enabled'
  
        **Pipeline:**
        1. **Semantic Search** - Voyage AI embeddings for helpfile similarity (threshold: 0.3)
        2. **Context Gathering** - Player location, recent RP logs (max 10), prior questions (10-min window)
        3. **LLM Synthesis** - Gemini Flash generates response
        4. **Context Caching** - Redis stores query/response for follow-ups (CONTEXT_WINDOW_SECONDS)
  
        **Configuration:**
        - Provider: google_gemini
        - Model: gemini-3-flash-preview
        - Max tokens: GameConfig::LLM::MAX_TOKENS[:default]
        - Temperature: GameConfig::LLM::TEMPERATURES[:summary]
        - Max helpfiles: 5 (MAX_HELPFILE_MATCHES)
  
        ## Character Lookup Commands
  
        ### Finger Command
        - CharacterLookupHelper: find_character_room_then_global (checks room first, then global)
        - Displays: full_name, race, character_class, level, online status, location, stance
        - **Schedule Overlap** - ActivityTrackingService.calculate_overlap
          - Shows percentage overlap, best days, common hours
          - Requires sufficient activity data from both characters
          - Uses full_day_name and format_hour_range helpers
  
        ### Who Command
        **Scopes:**
        - `who` (default) - Zone scope (joins rooms→locations→zones)
        - `who here` - Room scope
        - `who all` - Global scope with grouping (timeline/event/zone)
  
        **Visibility Filtering:**
        - Checks private_mode flag
        - Checks room publicity (secluded rooms hidden)
        - UserPermission.can_see_in_where? for locatability settings
        - Timeline/Event access checks
        - User always sees own alts
  
        **Display Formatting:**
        - Groups by zone/event/timeline
        - Shows stance (sitting/standing/lying) and furniture
        - Upcoming events appended (Event.public_upcoming)
  
        ### Profile Command
        - Uses CharacterDisplayService for formatting
        - Shows: name, race, class, gender, age, height, ethnicity, picture_url, short_desc
        - Current status: online/offline, room, stance, place
        - Viewer sees own profile with `profile` (no args)
  
        ### Observe Command
        **Targets:** character, place, room, self
        **Persistence:** CharacterInstance fields (observing_id, observing_type, observed_place_id)
        **Methods:**
        - start_observing!(target_instance)
        - start_observing_place!(place)
        - start_observing_room!
        - stop_observing!
  
        **Display Services:**
        - CharacterDisplayService.build_display
        - RoomDisplayService.build_display
        - Custom build_place_display for furniture
  
        **Updates:** Observers receive broadcasts for observed target's actions
  
        ## Look Command
  
        **Target Resolution Priority:**
        1. Special cases: `--mode=` flag, empty (room), "self"/"me"
        2. Self item: "look me sword"
        3. Possessive: "look John's sword"
        4. Compound: "look John sword"
        5. Generic: collect_possible_matches
  
        **Match Types:** character, place, decoration, spatial_exit, object (item), feature
  
        **Special Modes:**
        - Blindfolded: look_at_room_blindfolded (audio cues only)
        - Traveling: look_at_traveling_room (journey progress)
        - Vehicle: look_at_vehicle_interior (passengers, description)
        - Accessibility: AccessibilityOutputService.transform_room
  
        **Display Services:**
        - RoomDisplayService (mode: :full/:arrival/:transit)
        - CharacterDisplayService (viewer_instance for personalization)
        - build_nearby_areas_text (Ravencroft-style distance tags)
  
        ## Environmental Info
  
        ### Weather Command
        - Weather.for_location(room_location) - queries weather data
        - WeatherProseService.prose_for(location) - atmospheric narrative
        - Checks room.weather_visible flag (defaults true)
        - Shows: condition, temperature (C/F), wind (mph), humidity, cloud cover
        - Flags: severe?, visibility_reduced?
        - Source: weather_source field (real-world API or generated)
  
        ### Time Command
        - GameTimeService.current_time(location) - in-game time with possible location offsets
        - GameTimeService.time_of_day(location) - period (morning/afternoon/evening/night/dawn/dusk)
        - MoonPhaseService.current_phase - moon phase, emoji, illumination %
        - Celestial info varies by time_of_day:
          - Night/dusk/dawn: Moon visibility based on cloud cover
          - Day: Sun/cloud description + tonight's moon phase
  
        ## News System
  
        **StaffBulletin Model:**
        - Types: announcement, ic, ooc (NEWS_TYPES constant)
        - States: draft, published, archived
        - Read tracking: NewsReadStatus join table
        - Methods: unread_counts_for(user), mark_read_by!(user), read_by?(user)
  
        **Display:**
        - Categories: Shows unread counts per type
        - Article list: [NEW] marker for unread, posted date, author
        - Article view: Auto-marks as read
  
        ## Performance Optimizations
  
        - HelpManager: 5-min Redis cache for help content
        - CharacterInstance queries: Use .eager(:character) to avoid N+1
        - Who command: Single query per scope, grouped in Ruby
        - RoomDisplayService: Caches room data per mode
        - Weather/Time: Cached by location (TTL varies by service)
  
        ## Privacy & Permissions
  
        - Who visibility: private_mode, room publicity, locatability settings
        - Helpfile.admin_only: Hidden from non-admins
        - Timeline/Event access: Checks can_enter? and attendance
        - Observe: No explicit permission check (visible = observable)
  
        ## Edge Cases & Gotchas
  
        - Observe persists across movements (must explicitly stop)
        - Look disambiguation: Multiple matches trigger quickmenu
        - Finger schedule overlap: Fails gracefully if insufficient data
        - Weather indoor: Returns "cannot see sky" message
        - News categories: Input normalized (e.g., "announcements" → "announcement")
        - Calendar: Listed in command_names but no implementation (may be aliased or planned)
      STAFF
      display_order: 10
    },
    {
      name: 'commands_ui',
      display_name: 'Commands, UI and Playing the Game',
      summary: 'Game basics, utility commands, and interface features',
      description: "Core utility commands for interacting with the game. The webclient provides a rich interface with map views, quickmenus, and popout windows. Use 'commands' to see everything available, 'quit' to leave, and 'ticket' to report issues or make suggestions. Status commands let others know your availability.",
      command_names: ['commands', 'quit', 'tickets', 'afk', 'semiafk', 'gtg', 'walk', 'stickymode', 'sticky', 'asleft', 'onleft', 'asright', 'onright', 'inventory', 'equipment', 'check in'],
      related_systems: %w[help_info accessibility],
      key_files: [
        'app/commands/base/command.rb',
        'app/commands/base/registry.rb',
        'app/services/auto_afk_service.rb',
        'plugins/core/status/commands/afk.rb',
        'plugins/core/status/commands/gtg.rb',
        'plugins/core/system/commands/commands.rb',
        'plugins/core/system/commands/quit.rb',
        'plugins/core/system/commands/tickets.rb',
        'plugins/core/navigation/commands/walk.rb',
        'plugins/core/inventory/commands/inventory.rb',
        'plugins/core/inventory/commands/equipment.rb',
        'app/views/webclient/index.erb'
      ],
      player_guide: <<~'GUIDE',
        # Commands, UI and Playing the Game
  
        ## Finding & Using Commands
  
        **commands** - List all available commands
          - `commands` - Show all categories in a two-column table
          - `commands navigation` - List all navigation commands with descriptions
          - `commands combat` - List combat commands
          - Use with any category: system, navigation, combat, social, inventory, etc.
          - Shows unavailable commands with an empty circle ○, available with filled circle ●
  
        **Categories:**
          - building - World building and room creation
          - clothing - Wearing and managing clothing
          - combat - Fighting and restraining others
          - communication - Channels, mail, and messaging
          - crafting - Creating items and objects
          - economy - Money, shopping, and trading
          - entertainment - Games, dice, and media
          - events - Activities and group events
          - info - Information and lookup commands
          - inventory - Managing belongings and storage
          - navigation - Movement, posture, and vehicles
          - roleplaying - Emotes, speech, and scenes
          - social - Relationships and customization
          - staff - Staff and admin commands
          - system - System, help, and status
  
        **Aliases:** commands = cmds, cmdlist
  
        ## Webclient UI Prefixes (Meta-Commands)
  
        These are special prefixes that control how the webclient behaves. They can be combined!
  
        `sticky <command>` - Keep command in input after sending (for repeated commands)
          - `sticky say hello` - Sends "say hello" but keeps it in input for quick resend
          - `sticky roll 2d6` - Useful for repeated dice rolls
          - Great for spam-free repeated actions
  
        `asleft <command>` - Send as if typed in left (OOC) pane
          - `asleft look` - Executes in OOC context even if typed on right side
          - Affects command type sent to server
  
        `asright <command>` - Send as if typed in right (RP) pane
          - `asright who` - Executes in RP context even if typed on left side
  
        `onleft <command>` - Display result in left pane (doesn't change execution context)
          - `onleft look` - Command executes normally but result shows in left pane
          - Good for keeping RP pane clean
  
        `onright <command>` - Display result in right pane
          - `onright commands` - Show command list in right pane instead of left
  
        **Combining prefixes:**
          - `sticky asleft say Hello` - Keep in input AND send as OOC
          - `sticky onleft roll 2d6` - Keep in input AND show results on left
          - Order doesn't matter: `asleft sticky` works the same as `sticky asleft`
  
        **Aliases:** atleft = asleft, atright = asright
  
        ## Movement & Navigation
  
        **walk** - Walk toward a target with optional style
          - `walk north` - Walk in a cardinal direction
          - `walk to tavern` - Walk to a named room
          - `run to John` - Run to a character's location
          - `crawl east` - Crawl in a direction (movement verb changes speed and description)
          - `stroll to park` - Use different movement verbs for flavor
          - `angrily run north` - Add an adverb for extra description
  
        **Available movement verbs:**
          walk, run, jog, crawl, limp, strut, meander, stroll, sneak, sprint, fly,
          swagger, stride, march, hike, creep, shuffle, amble, trudge, wander,
          lumber, pad, skip, plod, shamble, patrol, sashay, stalk, stomp,
          pace, scramble, stagger, prowl, traipse, drift, saunter
  
        Note: Movement uses pathfinding. Multi-room walks show duration and broadcast arrival.
  
        ## Inventory & Equipment
  
        **inventory** - View everything you're carrying
          - `inventory` - Shows wallet balance, held items, carried items, worn items
          - Groups items by location: In Hand, Carrying, Wearing
          - Shows item quantity, condition, and damage level
          - `inv` or `i` for short
  
        **equipment** - View what you're wearing and holding
          - `equipment` - Focused view of equipped items only
          - Shows In Hand and Wearing sections
          - Stacks identical items with count
          - `eq` or `worn` for short
  
        ## Player Availability Status
  
        **afk** - Toggle away from keyboard status
          - `afk` - Set AFK status (indefinite)
          - `afk 30` - Set AFK for 30 minutes (auto-clears)
          - `afk` again - Clear AFK status
          - Broadcasts to room: "gets busy with their phone. [AFK]"
          - Auto-AFK: System sets AFK after inactivity (17 min with others, 60 min alone)
  
        **gtg** - Set "got to go" status (imminent departure)
          - `gtg` - Set GTG with default 15 minutes
          - `gtg 30` - Set GTG for 30 minutes
          - `gtg` (when already set) - Clear GTG status
          - Broadcasts: "receives a message on their phone. [GTG 30 Minutes]"
          - Use to signal you're about to leave soon
  
        **Auto-AFK Behavior:**
          - Alone in room: AFK after 60 minutes inactive
          - With others: AFK after 17 minutes inactive
          - WebSocket timeout: Disconnected after 5 minutes without ping
          - Hard timeout: Logged out after 3 hours inactive (2 hours for agents)
          - AFK characters excluded from NPC animation triggers and some auto-features
  
        **Aliases:** afk = away, gtg = gottago, gotta_go
  
        ## Tickets & Support
  
        **tickets** - Manage bug reports, suggestions, and requests
          - `tickets` - Open tickets menu (quickmenu with options)
          - `tickets list` - View your open tickets
          - `tickets all` - View all tickets (including resolved)
          - `tickets new` - Submit a new ticket (opens form)
          - `tickets view 42` - View ticket #42
          - `bug` - Quick shortcut to submit a bug report
          - `typo` - Quick shortcut to report a typo
          - `request` - Submit a feature request
          - `suggest` - Submit a suggestion
          - `report` - Report player behavior
  
        **Ticket Categories:**
          - bug - Code errors, broken features
          - typo - Text errors, spelling mistakes
          - behaviour - Player conduct issues
          - request - Feature requests
          - suggestion - Improvement ideas
  
        **Ticket Workflow:**
        1. Submit via form (category, subject, description)
        2. Staff receives alert with ticket ID
        3. Track status: open → resolved/closed
        4. View resolution notes and staff response
        5. Auto-captures game context (room, character, timestamp)
  
        **Aliases:** mytickets, ticket, bug, typo, report, request, suggest, viewticket
  
        ## Quitting the Game
  
        **quit** - Leave the game and go to sleep
          - `quit` - Log out safely
          - Broadcasts departure to room: "goes to sleep"
          - Records playtime for session tracking
          - Clears active states: observing, following, AFK, attempts, mind reading
          - Cannot quit while in combat
  
        **Aliases:** logout, sleep, "log out"
  
        ## Tips
  
        - **Command shortcuts** - Most commands have short aliases (e.g., `i` for inventory)
        - **Sticky mode** - Use for repeated commands without re-typing
        - **Status visibility** - AFK/GTG shows in `who` and `finger` output
        - **Auto-logout** - Game disconnects you after 3 hours inactive (safety feature)
        - **WebSocket** - If connection drops, you have 5 minutes to reconnect
        - **Ticket tracking** - Use tickets to track bugs you've reported
        - **Movement verbs** - Add flavor to your movement with crawl, strut, swagger, etc. Add adverbs too: `angrily run north`
        - **Category browsing** - Use `commands <category>` to explore specific feature sets
      GUIDE
      staff_notes: <<~'STAFF',
        # Commands & UI System - Staff Implementation Notes
  
        ## Command Registry Architecture
  
        **Commands::Base::Registry** (app/commands/base/registry.rb)
        - Central registry for all game commands
        - Hash-based lookups: @commands, @aliases, @multiword_aliases, @contextual_aliases
        - Auto-discovers commands from plugins/**/commands/*.rb on server boot
        - reload_commands! method: Uses `load` (not `require`) to pick up code changes
  
        **Registration Process:**
        1. Command files end with `Commands::Base::Registry.register(CommandClass)`
        2. Registry extracts: command_name, aliases, category from DSL
        3. Multi-word aliases (e.g., "look at") stored separately for priority matching
        4. Contextual aliases support (e.g., delve context gets different N/S/E/W)
  
        **Command Lookup Priority:**
        1. Multi-word command names (e.g., "say to")
        2. Multi-word contextual aliases
        3. Multi-word global aliases
        4. Exact command name match
        5. Context-specific alias
        6. Global alias
        7. Partial prefix match (if enabled)
  
        **Methods:**
        - register(command_class) - Register a command with aliases
        - find_command(input, context:) - Resolve command with context awareness
        - list_commands_for_character(char_instance) - Filter by requirements
        - suggest_commands(partial) - Levenshtein distance suggestions
        - reload_commands! - Hot-reload all command files
  
        ## Command DSL
  
        Commands define metadata via class-level DSL:
        ```ruby
        command_name 'walk'
        aliases 'run', 'jog', 'crawl'
        category :navigation
        output_category :info        # Where output displays
        help_text 'Walk toward target'
        usage 'walk <target>'
        examples 'walk north', 'run to tavern'
        requires :not_in_combat, message: "Can't leave during combat"
        ```
  
        **Requirements System:**
        - Declarative pre-conditions checked before execution
        - Built-in: not_in_combat, alive, online, not_bound, etc.
        - Custom requirements via method names or lambdas
        - Error messages customizable per requirement
  
        ## Commands Command
  
        **CATEGORY_DESCRIPTIONS** - Hard-coded category descriptions (lines 14-30)
        - 15 categories defined with user-friendly descriptions
        - Used for display in `commands <category>` output
  
        **list_commands_for_character** - Filters commands by:
        - Character instance (for requirement checking)
        - Returns: { name:, help:, category:, status: (:available | :unavailable) }
  
        **Display Formatting:**
        - Two-column table for category list (16 categories max, rest hidden)
        - Symbol indicators: ● (available), ○ (unavailable)
        - Category filtering: `commands navigation` shows only navigation commands
  
        ## Webclient UI Prefixes
  
        **Client-side parsing** (app/views/webclient/index.erb, lines 6410-6497)
        - Prefixes: sticky, asleft, asright, onleft, onright
        - Aliases: atleft→asleft, atright→asright
        - Multiple prefixes can be combined: "sticky asleft say Hello"
  
        **Parsing Logic:**
        ```javascript
        parseCommandPrefix(text) {
          const prefixes = ['sticky', 'asleft', 'asright', 'atleft', 'atright', 'onleft', 'onright'];
          // Parse multiple prefixes in sequence
          // Return { prefixes: [], command: cleanedText }
        }
        ```
  
        **Prefix Effects:**
        - **sticky**: isSticky flag prevents input clear (line 6560)
        - **asleft/asright**: forcedInputSide changes message type sent
        - **onleft/onright**: forcedOutputSide changes display pane
        - Prefixes stripped before command execution
  
        ## Walk Command
  
        **MovementService.start_movement** - Main pathfinding entry point
        - Targets: direction, room name, character name, furniture/place
        - Adverb extraction: 35+ movement verbs supported
        - Returns: success/failure with duration, path_length, destination
        - Disambiguation: Quickmenu for ambiguous targets
  
        **Adverb System:**
        - 35+ aliases (walk, run, jog, crawl, etc.) map to movement flavor
        - extract_adverb_from_command checks if command word is valid adverb
        - Default: 'walk' if not recognized
        - Used in broadcast messages for flavor
  
        **Multi-room Pathfinding:**
        - TimedActionProcessor handles delays between rooms
        - Broadcasts: departure, arrival, transit messages
        - Look display modes: :full, :arrival, :transit
  
        ## Inventory Commands
  
        **Data Sources:**
        - character_instance.objects_dataset - All owned items
        - character_instance.wallets_dataset - Currency balances
        - Item states: held?, worn?, carried (neither held nor worn)
  
        **Inventory Display:**
        - Wallet: currency.format_amount(balance)
        - In Hand: held? items
        - Carrying: !held? && !worn? items
        - Wearing: worn? items
        - Format: quantity, condition, damage (torn levels 1-10)
  
        **Equipment Display:**
        - HTML output with <ul> lists
        - Stacking: Groups identical items, shows (x3) for count
        - Item grouping by format_item result (name + condition + damage)
  
        ## AFK/Status Commands
  
        **CharacterInstance Fields:**
        - afk: boolean
        - afk_until: timestamp (nil = indefinite)
        - semiafk: boolean (active feature; reduces XP gain to reduce strain on automated systems)
        - gtg_until: timestamp
        - last_activity: timestamp (updated on command execution)
  
        **AFK Command:**
        - Toggle behavior: afk? → clear, !afk? → set
        - Minutes argument: afk_until = Time.now + minutes
        - Overrides touch_activity! to not clear AFK when setting it
        - Broadcasts: "gets busy with their phone. [AFK]"
  
        **GTG Command:**
        - Default duration: 15 minutes
        - Max duration: 1000 minutes
        - gtg? → clear, !gtg? → set
        - Broadcasts: "receives a message on their phone. [GTG N Minutes]"
  
        ## Auto-AFK Service
  
        **Scheduler Job** (runs every 5 minutes):
        - AutoAfkService.process_idle_characters!
        - Processes all CharacterInstance.online
  
        **Timeout Thresholds** (GameConfig::Timeouts):
        - PLAYER_ALONE: 60 minutes (alone in room)
        - PLAYER_WITH_OTHERS: 17 minutes (with others)
        - WEBSOCKET_STALE: 5 minutes (no WebSocket ping)
        - AGENT_LOGOUT: 120 minutes (API token users)
        - HARD_DISCONNECT: 180 minutes (force logout)
  
        **Processing Logic:**
        1. Skip NPCs and exempt characters
        2. Check hard disconnect (180 min player, 120 min agent)
        3. Check WebSocket timeout (5 min, skip agents)
        4. Check auto-AFK (17/60 min based on room occupancy)
  
        **Methods:**
        - process_character(ci) - Returns :afk, :disconnected, :skipped
        - should_force_logout? - Hard timeout check
        - should_auto_afk? - Idle threshold check
        - set_auto_afk! - Broadcasts: "appears to have dozed off. [AUTO-AFK]"
        - char_instance.auto_logout!(reason) - Clears session, broadcasts departure
  
        **inactive_minutes:**
        - Calculated from Time.now - last_activity
        - Updated by Base::Command#touch_activity! (called on every command)
  
        ## Tickets System
  
        **Ticket Model Fields:**
        - user_id, category, subject, content, status
        - room_id, game_context (auto-captured on submit)
        - resolved_by_user_id, resolved_at, resolution_notes
  
        **Categories:** bug, typo, behaviour, request, suggestion (Ticket::CATEGORIES)
  
        **Status Workflow:** open → resolved/closed
        - status_open scope: where(status: 'open')
        - resolved?, closed? helper methods
  
        **Alias Shortcuts:**
        - alias_to_category maps: bug→bug, typo→typo, report→behaviour, request→request, suggest→suggestion
        - Shortcut commands open form with preselected category
  
        **Display:**
        - show_tickets_menu: Quickmenu with open/all/new options
        - list_tickets: Shows up to 20 recent, status icons [OPEN]/[RESOLVED]/[CLOSED]
        - view_ticket: Full ticket display with staff response if resolved
  
        **Staff Alerts:**
        - StaffAlertService.broadcast_to_staff on ticket creation
        - Format: "[TICKET] New {category} ticket #{id} from {user}: {subject}"
  
        ## Quit Command
  
        **Departure Sequence:**
        1. build_departure_message (includes place if sitting)
        2. BroadcastService.to_room (departure message)
        3. clear_active_states (observing, following, afk, attempts, mind reading)
        4. record_session_playtime! (updates total_playtime)
        5. update(online: false, session_start_at: nil)
        6. RpLoggingService.on_logout (finalizes RP sessions)
  
        **Cleared States:**
        - Observing (stop_observing!)
        - Following (MovementService.stop_following)
        - AFK, Semi-AFK, GTG
        - Pending attempts (clear_pending_attempt!)
        - Mind reading (stop_reading_mind!)
  
        **Combat Check:**
        - requires :not_in_combat prevents quitting during fights
  
        ## Performance & Caching
  
        - Command lookup: O(1) hash lookup by name/alias
        - Multi-word aliases: Checked before single-word (priority)
        - Contextual aliases: Separate hash per context for fast lookup
        - Command list: Filters by requirements (may call DB for permission checks)
        - Auto-AFK: Single query for all online CharacterInstance, processes in memory
  
        ## Edge Cases & Gotchas
  
        - **Sticky mode** persists across input clears (client-side only)
        - **AFK touch override** - afk command doesn't clear AFK when setting it
        - **GTG defaults** - Empty gtg arg clears status instead of setting default
        - **Walk disambiguation** - Multiple matches trigger quickmenu
        - **Ticket context** - Auto-captures room, character, timestamp
        - **Multi-word commands** - "look at" takes priority over "look" + "at"
        - **Contextual aliases** - Same alias can resolve differently per context (e.g., delve mode)
        - **Inventory stacking** - Equipment command groups identical items, inventory does not
        - **WebSocket agents** - API users skip WebSocket timeout check
      STAFF
      display_order: 15
    },
    {
      name: 'communication',
      display_name: 'Communication',
      summary: 'Talking, messaging, channels, memos, and bulletins',
      description: "All the ways characters communicate. 'say' and 'emote' are for in-room conversation and action. 'whisper' sends private messages within the room. 'pm' sends private messages to anyone online. Channels let groups chat across distances. Memos and bulletins provide asynchronous communication. Clans have their own dedicated channels.",
      command_names: ['msg', 'bb', 'mail', 'ooc', 'oocrequest', 'knock', 'give number', 'channel', 'channels', 'join channel', 'leave channel', 'clan', 'quiet', 'undo'],
      related_systems: %w[roleplaying permissions world_memory],
      key_files: [
        'app/services/broadcast_service.rb',
        'app/services/emote_parser_service.rb',
        'app/services/messenger_service.rb',
        'app/helpers/message_formatting_helper.rb',
        'app/services/clan_service.rb',
        'app/services/channel_broadcast_service.rb',
        'app/services/direct_message_service.rb',
        'app/services/ooc_message_service.rb',
        'app/models/group.rb',
        'app/models/group_member.rb',
        'app/models/channel.rb',
        'app/models/channel_member.rb',
        'app/models/memo.rb',
        'app/models/bulletin.rb',
        'plugins/core/communication/commands/msg.rb',
        'plugins/core/communication/commands/bb.rb',
        'plugins/core/communication/commands/mail.rb',
        'plugins/core/communication/commands/ooc.rb',
        'plugins/core/communication/commands/channel.rb',
        'plugins/core/communication/commands/channels.rb',
        'plugins/core/communication/commands/join_channel.rb',
        'plugins/core/clan/commands/clan.rb',
        'plugins/core/status/commands/quiet.rb'
      ],
      player_guide: <<~'GUIDE',
        # Communication System
  
        ## Direct Messaging
  
        **msg** - Send a direct message to someone anywhere in the game
          - `msg Alice Hey, where are you?` - Message Alice directly
          - `dm Bob Meeting at 5` - Same as msg (alias)
          - `text Charlie On my way!` - Another alias
          - Shows phone use in modern eras ("eyes flick to phone")
          - Recent targets tracked for quick access (last 10)
          - Era-aware routing (phone, pager, magical message, etc.)
  
        **Aliases:** msg = dm, text
  
        ## Out-of-Character (OOC) Communication
  
        **ooc** - Send private OOC message to one or more players
          - `ooc Alice Hello there!` - Message one player
          - `ooc Alice,Bob,Charlie Hey everyone!` - Message multiple (comma-separated)
          - `ooc` (no args) - Show recent OOC contacts
          - Messages sent to users, not characters (crosses character boundaries)
          - Recent contacts cached for quick access (last 10)
  
        **Aliases:** ooc = oocp, oocmsg
  
        ## Channels
  
        **channel** - Chat on a communication channel
          - `channel ooc Hello everyone!` - Send to a channel
          - `+ Hi there!` - Quick OOC channel shortcut
          - `chan general What's up?` - Use alias
          - Auto-join public channels on first message
          - Muted members can't send
          - Supports multi-word channel names
          - Last channel tracked for status bar
  
        **channels** - List available channels
          - `channels` - Show all channels with status
          - Shows: [TYPE] name (status) - N online
          - Status: (joined), (muted), or (not joined)
          - Includes description if set
  
        **join channel** - Join a communication channel
          - `join channel OOC` - Join the OOC channel
          - `joinchannel General` - Use compact alias
          - Public channels: auto-join allowed
          - Private channels: invitation required
          - Broadcasts join message to members
  
        **leave channel** - Leave a channel
          - `leave channel OOC` - Leave the channel
          - Broadcasts departure to remaining members
          - Can rejoin public channels anytime
  
        **Aliases:**
          - channel = chan, ch, +
          - channels = chanlist, "channel list", listchannels
          - join channel = joinchannel, "chan join", "channel join"
          - leave channel = leavechannel, "chan leave", "channel leave"
  
        ## Memos (Asynchronous Mail)
  
        **mail** - Read and send memos/mail
          - `mail` - View inbox (quickmenu)
          - `mail list` - List all memos
          - `mail read 1` - Read memo #1
          - `mail 5` - Quick-read memo #5 (shortcut)
          - `mail send Alice` - Compose via form
          - `mail send Alice Subject=Body` - Quick format
          - `mail delete 1` - Delete memo #1
          - `mail delete all` - Delete all memos
          - Unread memos marked with ●
          - Subject and body required
          - Abuse checking on send
  
        **Aliases:** mail = memo, memos, email, messages, inbox
  
        ## Bulletin Board
  
        **bb** - View and manage the bulletin board
          - `bb` - List all recent bulletins (shows last N)
          - `bb list` - Same as above
          - `bb post Looking for group!` - Post a bulletin
          - `bb Looking for group!` - Quick post (shortcut)
          - `bb read 1` - Read bulletin #1
          - `bb delete` - Delete YOUR bulletin (only one per character)
          - Bulletins expire over time
          - Age shown: "just now", "5h ago", "2d ago"
          - Broadcasts preview to room on post
  
        **Aliases:** bb = bulletin, bulletins, board
  
        ## Clans
  
        **clan** - Manage clan membership and activities
          - `clan list` - List all clans (shows membership status)
          - `clan create The Shadows` - Create a new clan
          - `clan create --secret The Hidden Order` - Create a secret clan
          - `clan invite Alice` - Invite someone
          - `clan invite Alice as ShadowMaster` - Invite with handle
          - `clan kick Bob` - Remove a member (requires permissions)
          - `clan leave` - Leave your clan
          - `clan info` - Show clan details
          - `clan roster` - List all members
          - `clan memo Subject=Message` - Send memo to all members
          - `clan handle ShadowMaster` - Set your clan handle
          - `clan grant` - Grant room access to clan (leader/officer)
          - `clan revoke` - Revoke room access from clan
  
        **Clan Features:**
          - **Secret clans**: Members get Greek letter handles (Alpha, Beta, etc.)
          - **Ranks**: leader (full control), officer (invite/kick), member (basic access)
          - **Channels**: Auto-created for clan communication
          - **Multi-clan**: Characters can belong to multiple clans
          - **Room access**: Leaders/officers can grant clan-wide room permissions
  
        **Aliases:** clan = clans, guild, group
  
        ## Quiet Mode
  
        **quiet** - Toggle quiet mode to hide all channel messages
          - `quiet` - Enable quiet mode (hides OOC, channels, broadcasts)
          - `quiet` again - Disable with catch-up option
          - Broadcasts: "puts on headphones [Quiet Mode]"
          - On exit: Offer to catch up on missed messages (up to 100)
          - Suppressed: ooc, channel, broadcast, global, area, group
          - Still see: room messages, DMs, whispers
  
        **Aliases:** quiet = quietmode
  
        ## Undo
  
        **undo** - Delete your last message
          - `undo` - Removes your most recent message from everyone's screen
          - Works on **both panels**: in-character messages (right panel) and channel messages (left panel)
          - The message is deleted from the database and removed from all viewers' screens
          - Must be used within **60 seconds** of sending the message
          - Only affects your most recent message — you can't undo further back
          - Great for fixing typos, accidental sends, or messages sent to the wrong place
  
        **How it works:**
          - Type `undo` in the same panel where you sent the message
          - Right panel: Undoes say, emote, whisper, and other IC messages
          - Left panel: Undoes channel messages and OOC chat
  
        ## Tips
  
        - **Channel shortcuts**: `+` is fastest for OOC channel
        - **Era-awareness**: Msg command adapts to game era (phone/pager/magic)
        - **Recent contacts**: msg and ooc track your last contacts
        - **Bulletin limits**: Only one bulletin per character (deletes old on post)
        - **Memo persistence**: Memos stay until deleted
        - **Secret clans**: Hidden membership, Greek letter handles for anonymity
        - **Auto-join**: Public channels let you send without explicit join
        - **Quiet mode**: Great for focused RP without OOC distractions
        - **Multi-recipient OOC**: Use commas to message multiple players at once
        - **Clan disambiguation**: If in multiple clans, you'll get a quickmenu to choose
        - **Undo mistakes**: Use `undo` within 60 seconds to delete your last message
      GUIDE
      staff_notes: <<~'STAFF',
        # Communication System - Staff Implementation Notes
  
        ## Direct Messaging (msg command)
  
        **DirectMessageService** - Era-based routing
        - Modern: Phone message ("eyes flick to phone" broadcast)
        - Near-future: Pager, neural link
        - Historical: Magical message, courier pigeon
        - EraService.visible_phone_use? determines if action broadcasts to room
  
        **Tracking:**
        - last_dm_target_ids: Sequel.pg_array (last 10 targets)
        - last_channel_name: 'msg' (for status bar)
        - Target list updated on every send
  
        **Implementation:**
        - find_character_globally(name) - Searches all characters, not just in room
        - parse_target_and_message(text) - Splits "name message" format
        - show_phone_use_if_applicable - Broadcasts to room if visible phone use
  
        ## Bulletin Board (bb command)
  
        **Bulletin Model:**
        - character_id (owner), from_text (display name), body (content)
        - created_at (for age calculation)
        - delete_for_character(char) - Deletes old before creating new (1 per character)
  
        **Age Display:**
        - age_hours method: (Time.now - created_at) / 3600
        - < 1 hour: "just now"
        - < 24 hours: "5h ago"
        - >= 24 hours: "2d ago"
  
        **Scopes:**
        - recent - Orders by created_at desc, limits to recent bulletins
  
        **Max Length:** GameConfig::Forms::MAX_LENGTHS[:bulletin_body]
  
        **Broadcasts:** Preview (first 100 chars) to room on post
  
        ## Memos/Mail (mail command)
  
        **Memo Model:**
        - sender_id, recipient_id, subject, body
        - read_at (nil = unread)
        - inbox_for(character) scope - where(recipient_id: char.id).order(sent_at desc)
  
        **Form Fields:**
        - recipient (character name lookup)
        - subject (required, max: GameConfig::Forms::MAX_LENGTHS[:memo_subject])
        - body (required, max: GameConfig::Forms::MAX_LENGTHS[:memo_body])
  
        **Abuse Checking:**
        - MessagePersistenceHelper.check_for_abuse(content, message_type: 'memo')
        - Returns { allowed: bool, reason: string }
        - Concatenates subject + body for full content check
  
        **Inbox Display:**
        - Quickmenu with read/compose/delete options
        - Unread indicator: ● (filled circle)
        - format_time_ago helper for timestamps
  
        **Quick Syntax:**
        - `mail send Alice Subject=Body` - Parses Subject= separator
        - Delimiter must be `=` between subject and body
  
        ## OOC Messages (ooc command)
  
        **OocMessageService** - Cross-character messaging
        - Sends to users, not characters
        - Stores in OocMessage model with sender_user_id, recipient_user_id
        - recent_contacts_for(user, limit:) - Returns last N contacted users
  
        **Parsing:**
        - Comma-separated recipients: "Alice,Bob,Charlie"
        - find_character_by_name_globally for each recipient
        - Collects users from characters
  
        **Tracking:**
        - last_channel_name = 'ooc' (for status bar)
        - Result includes: recipient_user_ids, recipient_names, sent_count
  
        ## Channels
  
        **Channel Model:**
        - name, description, channel_type (ooc, global, area, group)
        - is_public (bool) - auto-join allowed
        - created_by_user_id
  
        **ChannelMember Model:**
        - channel_id, character_id
        - is_muted (bool) - can't send if true
        - status (active/inactive)
  
        **ChannelBroadcastService:**
        - find_channel(name) - Case-insensitive lookup
        - default_ooc_channel - Returns channel where name ilike 'ooc'
        - available_channels(character) - Returns all channels with membership status
        - online_members(channel, exclude:) - CharacterInstance.online + member
        - broadcast(channel, sender_instance, message) - Sends to all online members
  
        **Progressive Name Matching:**
        - Try 1-word, 2-word, 3-word prefixes until match found
        - Fallback: prefix matching with ILIKE "name%"
        - Supports multi-word channel names
  
        **Auto-join:**
        - Public channels: add_member on first message if not member
        - Private channels: error, require explicit join
  
        **'+' Shortcut:**
        - command_word == '+' → routes to default OOC channel
        - Convenience for quick OOC chat
  
        ## Clan System
  
        **Group Model (group_type = 'clan'):**
        - name, description, group_type, secret (bool)
        - created_by_character_id, channel_id (auto-created)
  
        **GroupMember Model:**
        - group_id, character_id, rank, status, handle (for secret clans)
        - Ranks: 'leader', 'officer', 'member'
        - status: 'active', 'inactive', 'invited'
  
        **ClanService Methods:**
        - list_clans_for(character) - All clans (shows membership)
        - create_clan(character, name:, secret:, create_channel:)
        - invite_member(clan, inviter, target, handle:)
        - kick_member(clan, kicker, target)
        - send_memo(clan, sender, subject, body) - Bulk memo to all members
  
        **Secret Clans:**
        - Greek letter handles: Alpha, Beta, Gamma, etc.
        - Set on invite with "as <handle>" or auto-generated
        - Hides real identity in clan communications
  
        **Room Access:**
        - grant_room_access - Grants clan-wide permission to current room
        - revoke_room_access - Revokes clan-wide permission
        - Requires leader or officer rank
  
        **Multi-Clan Support:**
        - my_clans helper returns all clans for character
        - Disambiguation quickmenu if multiple clans
        - clan_quickmenu_result for action selection
  
        **Permissions:**
        - leader: All actions (invite, kick, grant, revoke, delete)
        - officer: Invite, kick, grant, revoke
        - member: View, chat, leave
  
        ## Quiet Mode (quiet command)
  
        **CharacterInstance Fields:**
        - quiet_mode (bool)
        - quiet_mode_since (timestamp)
  
        **Methods:**
        - set_quiet_mode! - Sets flag and timestamp
        - clear_quiet_mode! - Clears flag
        - quiet_mode? - Check if enabled
  
        **Suppressed Message Types:**
        - ooc, channel, broadcast, global, area, group
        - Counts via Message.where(message_type: channel_types).where { created_at >= since }.count
  
        **Catch-up Feature:**
        - On exit: count_missed_messages(since)
        - If > 0: Quickmenu "Would you like to catch up?"
        - Yes: Shows up to 100 missed messages
        - No: Just exits quiet mode
  
        **Broadcasts:**
        - Enter: "puts on their headphones, tuning out the chatter. [Quiet Mode]"
        - Exit: "takes off their headphones. [Quiet Mode Off]"
  
        ## Message Personalization
  
        **BroadcastService** - All room-level broadcasts
        - to_room(room_id, message, exclude:, type:)
        - to_character(char_instance, message, type:)
        - Per-viewer personalization via MessagePersonalizationService
        - Name substitution based on CharacterKnowledge
  
        **EmoteParserService** - Pose text processing
        - Substitution patterns: %n (name), %o (objective), %p (possessive), %r (reflexive)
        - Speech integration: `emote %n says, "Hello!"`
  
        **MessengerService** - Async memo delivery
        - Queues delivery if recipient offline
        - Notification on login if unread memos
  
        ## Channel Types
  
        - **ooc**: General out-of-character chat
        - **global**: Game-wide announcements
        - **area**: Zone/location-specific
        - **group**: Clan/party channels
  
        ## Abuse Detection
  
        **check_for_abuse(content, message_type:)** - Called by:
        - mail (memos)
        - channel messages
        - ooc messages (via OocMessageService)
  
        **Two-tier system:**
        1. Gemini Flash: Fast initial screening
        2. Claude Opus: Verification with context
  
        **Returns:** { allowed: bool, reason: string }
  
        ## Performance & Caching
  
        - **DirectMessageService**: last_dm_target_ids cached in CharacterInstance
        - **OocMessageService**: recent_contacts_for cached query (limit 10)
        - **ChannelBroadcastService**: online_members query per broadcast
        - **ClanService**: GroupMember queries with .eager(:group) to avoid N+1
        - **Bulletin**: recent scope limits query size
  
        ## Edge Cases & Gotchas
  
        - **Bulletin deletion**: Only 1 per character - creating new deletes old
        - **Channel auto-join**: Only works for public channels
        - **Clan disambiguation**: Multi-clan members get quickmenus for actions
        - **Secret clan handles**: Must be unique within clan, auto-generated if not provided
        - **Quiet mode catch-up**: Max 100 messages to prevent overwhelming display
        - **Memo self-send**: Blocked with error "Can't send to yourself"
        - **OOC comma parsing**: Whitespace after commas stripped automatically
        - **Channel '+' shortcut**: Only works if default OOC channel exists
        - **Multi-word channels**: Progressive prefix matching for "General Chat" etc.
        - **Era-based messaging**: DirectMessageService routes differently per era
        - **Phone use broadcast**: Only in modern eras with visible_phone_use?
      STAFF
      display_order: 20
    },
    {
      name: 'accessibility',
      display_name: 'Accessibility',
      summary: 'TTS narration, screen reader support, colorblind modes, and accessibility features',
      description: "Firefly includes comprehensive accessibility features. Text-to-speech narration uses 30 high-quality Chirp 3 HD voices. Screen reader optimization ensures all game content is accessible. A replay buffer lets screen reader users step through recent messages via configurable hotkeys without leaving the input field. Colorblind modes, high contrast themes, dyslexia-friendly fonts, and customizable font sizes are available through the settings panel.",
      command_names: %w[accessibility narrate],
      related_systems: %w[commands_ui communication],
      key_files: [
        'app/services/tts_service.rb',
        'app/services/tts_queue_service.rb',
        'app/services/accessibility_output_service.rb',
        'plugins/core/system/commands/accessibility.rb',
        'plugins/core/system/commands/narrate.rb',
        'public/js/audio_queue_manager.js',
        'app/models/character_instance.rb',
        'app/models/user.rb'
      ],
      player_guide: <<~'GUIDE',
        # Accessibility Features
  
        Firefly provides comprehensive accessibility features including **text-to-speech narration** with 30 high-quality AI voices, **screen reader optimization**, **visual accessibility settings**, and **customizable playback controls**.
  
        ## Text-to-Speech (TTS) Narration
  
        ### Getting Started with TTS
  
        **narrate on** - Enable text-to-speech narration
          - Converts game text to natural-sounding audio
          - Uses Google Cloud Chirp 3 HD voices (30 voices available)
          - Queues audio for smooth playback
          - Works with all game content (speech, actions, room descriptions, system messages)
  
        **narrate off** - Disable TTS narration
  
        **narrate status** - Check current TTS settings and queue status
  
        ### Choosing Your Voice
  
        **narrate config** - Open voice and playback configuration
          - **Voice Selection**: Choose from 30 Chirp 3 HD voices
            - 14 female voices: Achernar, Aoede, Alula, Azha, Botein, Celaeno, Deneb, Electra, Hamal, Lesath, Maia, Merope, Taygeta, Unukalhai
            - 16 male voices: Achird, Algenib, Alioth, Alnair, Alphard, Alphecca, Altair, Dabih, Denebola, Eltanin, Kaus, Menkent, Polaris, Sabik, Sadalsuud, Zaurak
          - **Pitch**: Adjust voice pitch (-20 to +20 semitones, default 0)
          - **Speed**: Control speaking rate (0.5x to 2.0x, default 1.0x)
          - **Locale**: Choose accent (en-US, en-GB, en-AU, en-IN)
  
        Each voice has unique characteristics:
          - **Narrator voices**: Warm, expressive, ideal for storytelling (e.g., Achernar, Achird)
          - **Character voices**: Distinct personalities, great for speech (e.g., Aoede, Algenib)
          - **Neutral voices**: Clear and professional (e.g., Deneb, Polaris)
  
        ### Playback Controls
  
        **narrate pause** - Pause current audio playback
          - Audio queue is preserved
          - Resume from where you left off
  
        **narrate resume** - Resume paused audio playback
  
        **narrate skip** - Skip to the latest queued audio
          - Useful if the queue gets long
          - Discards intermediate messages
  
        **narrate clear** - Clear the entire audio queue
          - Stops playback immediately
          - Removes all queued audio
  
        **narrate current** - Check what's currently playing
  
        **narrate queue** - View all queued audio messages
  
        ### Content Type Filtering
  
        You can customize which types of content get narrated:
  
        **narrate config** form includes:
          - **Narrate speech**: Character dialogue (say, whisper, shout, etc.)
          - **Narrate actions**: Emotes, movement, combat actions
          - **Narrate rooms**: Room descriptions when you look or move
          - **Narrate system**: System messages, help text, errors
  
        Toggle each type on/off to focus on what's important to you. For example:
          - **Combat-focused**: Enable actions and system, disable rooms
          - **RP-focused**: Enable speech and actions, disable system
          - **Minimal**: Only enable speech to hear what others say
  
        ## Screen Reader Mode
  
        **accessibility mode on** - Enable screen reader optimization
          - Converts visual/spatial output to linear, screen-reader-friendly text
          - Transforms room layouts into sequential descriptions
          - Simplifies combat output for easy navigation
          - Removes visual formatting, emojis, and decorative elements
  
        **accessibility mode off** - Disable screen reader mode (normal visual output)
  
        ### How Screen Reader Mode Works
  
        When enabled, the game transforms complex visual layouts into simple linear text:
  
        **Room descriptions:**
          - **Normal**: ASCII art, spatial layout, directional arrows
          - **Screen reader mode**: "You are in [room name]. [Description]. Exits: north to [room], south to [room]. Characters present: [list]. Objects: [list]."
  
        **Combat output:**
          - **Normal**: Battle map, hex positions, visual effects
          - **Screen reader mode**: "You are at position [coords]. Enemies: [name] at [coords], [range]. Your turn. Available actions: attack, defend, move."
  
        **Character descriptions:**
          - **Normal**: Formatted profile, visual indicators
          - **Screen reader mode**: "[Name], [race] [class], level [X]. [Description]. Equipment: [list]. Status: [conditions]."
  
        ## Visual Accessibility Settings
  
        **accessibility contrast on** - Enable high-contrast mode
          - Increases text contrast for better readability
          - Adjusts color palette for visual clarity
          - Helpful for low vision or bright/dim environments
  
        **accessibility contrast off** - Disable high-contrast mode
  
        **accessibility effects on** - Enable visual effects (animations, transitions)
        **accessibility effects off** - Disable visual effects
          - Reduces motion and animations
          - Helpful for vestibular disorders or motion sensitivity
  
        ## Typing and Auto-Resume
  
        **accessibility typing on** - Pause TTS when you start typing
          - Automatically pauses narration when you begin typing a command
          - Prevents audio from interfering with your input
  
        **accessibility typing off** - Don't pause TTS while typing
  
        **accessibility resume on** - Auto-resume TTS after typing
          - Automatically resumes narration after you submit a command
          - Works with `accessibility typing on` for seamless experience
  
        **accessibility resume off** - Don't auto-resume after typing
  
        **Pro tip:** Enable both typing pause and auto-resume for a smooth workflow:
          1. TTS plays room description
          2. You start typing → TTS pauses
          3. You submit command
          4. TTS automatically resumes with new output
  
        ## Playback Speed
  
        `accessibility speed <rate>` - Set TTS playback speed
          - Rate: 0.5 (half speed) to 2.0 (double speed)
          - Default: 1.0 (normal speed)
          - Examples:
            - `accessibility speed 1.5` - 50% faster (good for experienced players)
            - `accessibility speed 0.75` - 25% slower (good for complex content)
  
        ## Screen Reader Selection
  
        `accessibility reader <type>` - Select screen reader software
          - **jaws**: JAWS (Job Access With Speech)
          - **nvda**: NVDA (NonVisual Desktop Access)
          - **voiceover**: macOS VoiceOver
          - **talkback**: Android TalkBack
          - **narrator**: Windows Narrator
          - **other**: Generic screen reader
  
        This helps the game optimize output for your specific screen reader's conventions.
  
        ## Viewing Your Settings
  
        **accessibility** (no arguments) - Show current accessibility settings
          - Displays all 7 settings with current values
          - Shows TTS status and queue length
  
        **accessibility help** - Show detailed help for accessibility command
  
        ## Tips for Best Experience
  
        ### For Screen Reader Users:
          1. Enable `accessibility mode on` for linear output
          2. Choose your screen reader with `accessibility reader <type>`
          3. Enable TTS with `narrate on` for dual audio (screen reader + TTS)
          4. Disable visual effects with `accessibility effects off`
          5. Use `narrate config` to filter content types (reduce noise)
  
        ### For Vision Impaired Users:
          1. Enable `accessibility contrast on` for better text visibility
          2. Use TTS with a clear voice like Deneb or Polaris
          3. Adjust `accessibility speed` to your comfortable listening rate
          4. Consider disabling effects with `accessibility effects off`
  
        ### For Motion Sensitivity:
          1. Disable visual effects: `accessibility effects off`
          2. Enable high contrast for less eye strain: `accessibility contrast on`
  
        ### For Audio Focus:
          1. Enable typing pause: `accessibility typing on`
          2. Enable auto-resume: `accessibility resume on`
          3. Use `narrate skip` if the queue gets long during busy scenes
          4. Customize content types in `narrate config` to reduce noise
  
        ## Examples
  
        **Complete setup for blind user:**
        ```
        accessibility mode on
        accessibility reader nvda
        accessibility effects off
        accessibility typing on
        accessibility resume on
        narrate on
        narrate config
          (Select: Achernar voice, pitch 0, speed 1.0, locale en-US)
          (Enable: speech, actions, rooms, system)
        ```
  
        **Quick TTS for sighted user who wants to listen:**
        ```
        narrate on
        narrate config
          (Select: Altair voice, pitch 0, speed 1.2, locale en-US)
          (Enable: speech and actions only)
        accessibility typing on
        accessibility resume on
        ```
  
        **High-contrast mode for low vision:**
        ```
        accessibility contrast on
        accessibility effects off
        accessibility speed 0.75
        narrate on
        ```
  
        ## Troubleshooting
  
        **"TTS unavailable"**: Server requires Google Cloud credentials (contact staff)
        **Audio not playing**: Check browser audio permissions, unmute tab
        **Queue too long**: Use `narrate skip` to jump to latest or `narrate clear` to reset
        **Voice sounds wrong**: Try `narrate config` and experiment with different voices
        **Too fast/slow**: Adjust with `accessibility speed <rate>` (0.5-2.0)
        **TTS interrupts typing**: Enable `accessibility typing on`
        **Need to catch up after AFK**: Use `narrate skip` to jump to current
      GUIDE
      staff_notes: <<~'NOTES',
        ## TTS Service Architecture
  
        ### TtsService (app/services/tts_service.rb)
        **Primary TTS engine using Google Cloud Text-to-Speech API (Chirp 3 HD voices).**
  
        ```ruby
        CHIRP3_HD_VOICES = {
          female: {
            'Achernar' => { voice_id: 'en-US-Chirp3-HD-Achernar', gender: 'FEMALE', traits: 'Warm narrator' },
            'Aoede' => { voice_id: 'en-US-Chirp3-HD-Aoede', gender: 'FEMALE', traits: 'Expressive character' },
            # ... 14 total female voices
          },
          male: {
            'Achird' => { voice_id: 'en-US-Chirp3-HD-Achird', gender: 'MALE', traits: 'Deep narrator' },
            'Algenib' => { voice_id: 'en-US-Chirp3-HD-Algenib', gender: 'MALE', traits: 'Versatile character' },
            # ... 16 total male voices
          }
        }
        ```
  
        **Key Methods:**
        - `synthesize(text, voice_type:, pitch:, speed:, locale:)` → Audio bytes
          - Calls Google Cloud TTS API
          - Returns MP3 audio data
          - Handles SSML escaping
          - Caches credentials from GOOGLE_APPLICATION_CREDENTIALS env var
        - `available?` → Boolean (checks if Google Cloud credentials exist)
        - `default_voice` → GameConfig::Tts::DEFAULT_VOICE (usually 'Achernar')
  
        **Configuration (config/game_config.rb):**
        ```ruby
        module GameConfig
          module Tts
            DEFAULT_VOICE = 'Achernar'
            DEFAULT_PITCH = 0
            DEFAULT_SPEED = 1.0
            DEFAULT_LOCALE = 'en-US'
            MIN_PITCH = -20.0
            MAX_PITCH = 20.0
            MIN_SPEED = 0.5
            MAX_SPEED = 2.0
          end
        end
        ```
  
        **Environment Requirements:**
        - `GOOGLE_APPLICATION_CREDENTIALS` must point to service account JSON
        - Service account needs `roles/cloudtts.user` permission
        - Billing must be enabled on GCP project
  
        ### TtsQueueService (app/services/tts_queue_service.rb)
        **Manages per-character audio queues for sequential playback.**
  
        **Queue Structure:**
        - Each CharacterInstance has its own queue
        - Queue stored in Redis: `tts_queue:#{character_instance.id}`
        - Each item: `{ content:, type:, voice:, timestamp: }`
  
        **Content Type to Voice Mapping:**
        ```ruby
        CONTENT_VOICES = {
          narrator: :narrator,    # Room descriptions, system messages
          room: :narrator,         # Room-specific narration
          speech: :character,      # Character dialogue
          action: :narrator,       # Emotes, actions
          system: :narrator        # System messages, help text
        }
        ```
  
        **Key Methods:**
        - `queue_narration(character_instance, content, type:)` → Audio URL
          - Synthesizes audio via TtsService
          - Saves MP3 to public/audios/
          - Enqueues with metadata
          - Broadcasts to WebSocket
        - `queue_speech(character_instance, content, speaker:, speech_type:)` → Audio URL
          - Uses speaker's configured voice
          - Falls back to character's voice if speaker voice unavailable
        - `get_queue(character_instance)` → Array of queue items
        - `clear_queue(character_instance)` → Boolean
        - `skip_to_latest(character_instance)` → Boolean (removes all but last item)
  
        **WebSocket Integration:**
        - Broadcasts to `character_#{id}` channel
        - Event: `{ type: 'tts_audio', audio_url:, queue_length: }`
        - Client uses AudioQueueManager.js to play sequentially
  
        ### AccessibilityOutputService (app/services/accessibility_output_service.rb)
        **Transforms visual/spatial output into linear screen-reader-friendly text.**
  
        **Transformation Methods:**
  
        **`transform_room(room_data, viewer)`**
        - Input: Room display hash from RoomDisplayService
        - Output: Linear text description
        - Transformations:
          - Removes ASCII art, spatial layouts
          - Converts exit arrows to "north to [room]" format
          - Lists characters sequentially
          - Lists objects/furniture sequentially
          - Preserves room name and description
  
        **`transform_combat(combat_data, viewer)`**
        - Input: Combat display hash from CombatDisplayService
        - Output: Linear combat status
        - Transformations:
          - Removes battle map hex grid
          - Converts positions to "You are at [coords]"
          - Lists enemies with distance: "[Name] at [coords], [X] hexes away"
          - Lists allies similarly
          - Turn order becomes sequential list
          - Available actions listed clearly
  
        **`transform_character(data, viewer)`**
        - Input: Character display hash from CharacterDisplayService
        - Output: Linear character profile
        - Transformations:
          - Removes visual formatting
          - Sequential attribute list
          - Equipment as bulleted list
          - Status effects as comma-separated list
  
        **`transform_generic(text)`**
        - Strips emojis, visual decorators
        - Removes color codes
          - Simplifies tables to lists
          - Preserves semantic content
  
        **Detection Logic:**
        - Checks `viewer.accessibility_mode?`
        - If enabled, passes output through transform methods
        - Fallback: Returns original output if no transformer available
  
        ### CharacterInstance Accessibility Fields
  
        **Database Columns (character_instances table):**
        ```ruby
        t.boolean :accessibility_mode, default: false
        t.boolean :pause_tts_on_typing, default: false
        t.boolean :auto_resume_tts, default: false
        t.float :tts_playback_speed, default: 1.0
        t.string :tts_voice, default: 'Achernar'
        t.integer :tts_pitch, default: 0
        t.string :tts_locale, default: 'en-US'
        t.boolean :narrate_speech, default: true
        t.boolean :narrate_actions, default: true
        t.boolean :narrate_rooms, default: true
        t.boolean :narrate_system, default: true
        t.boolean :tts_enabled, default: false
        t.string :tts_queue_id  # Redis key for audio queue
        ```
  
        **Instance Methods:**
        - `accessibility_mode?` → Boolean
        - `tts_enabled?` → Boolean
        - `pause_tts!` → Sets paused state
        - `resume_tts!` → Clears paused state
        - `skip_to_latest!` → Calls TtsQueueService.skip_to_latest
        - `clear_tts_queue!` → Calls TtsQueueService.clear_queue
  
        ### User-Level Accessibility Fields
  
        **Database Columns (users table):**
        ```ruby
        t.boolean :high_contrast, default: false
        t.boolean :reduced_effects, default: false
        t.string :screen_reader_type  # jaws, nvda, voiceover, talkback, narrator, other
        ```
  
        **These are user-wide settings (affect all characters):**
        - `high_contrast` → Enables high-contrast CSS theme
        - `reduced_effects` → Disables animations, transitions
        - `screen_reader_type` → Optimizes output format for specific screen readers
  
        ### Accessibility Command Implementation
  
        **File:** `plugins/core/system/commands/accessibility.rb` (440 lines)
  
        **Subcommands:**
        1. **mode** (`accessibility mode on/off`) → Toggles `accessibility_mode`
        2. **reader** (`accessibility reader <type>`) → Sets `screen_reader_type`
        3. **contrast** (`accessibility contrast on/off`) → Toggles `high_contrast`
        4. **effects** (`accessibility effects on/off`) → Toggles `reduced_effects`
        5. **typing** (`accessibility typing on/off`) → Toggles `pause_tts_on_typing`
        6. **resume** (`accessibility resume on/off`) → Toggles `auto_resume_tts`
        7. **speed** (`accessibility speed <rate>`) → Sets `tts_playback_speed` (0.5-2.0)
        8. **help** → Shows detailed usage
        9. **status** (default) → Shows all current settings
  
        **Form for Comprehensive Settings:**
        - Opens when `accessibility` called with no args (or invalid args)
        - 7 fields matching the 7 settings
        - Uses QuickmenuService for form handling
        - Validates speed (0.5-2.0), reader type (enum)
        - Updates both character_instance and user fields
  
        ### Narrate Command Implementation
  
        **File:** `plugins/core/system/commands/narrate.rb` (369 lines)
  
        **Subcommands:**
        1. **on/off** → Enables/disables TTS (`tts_enabled`)
        2. **config** → Opens voice/content configuration form
          - Voice selection (30 Chirp 3 HD voices)
          - Pitch (-20 to +20)
          - Speed (0.5 to 2.0)
          - Locale (en-US, en-GB, en-AU, en-IN)
          - Content type toggles (speech, actions, rooms, system)
        3. **pause** → Pauses playback (`pause_tts!`)
        4. **resume** → Resumes playback (`resume_tts!`)
        5. **skip** → Skips to latest (`skip_to_latest!`)
        6. **current** → Shows currently playing audio
        7. **clear** → Clears queue (`clear_tts_queue!`)
        8. **queue** → Shows all queued items
        9. **help** → Shows detailed usage
        10. **status** (default) → Shows TTS settings and queue status
  
        **Config Form Fields:**
        - `tts_voice` (dropdown of 30 voices, grouped by gender)
        - `tts_pitch` (number input, -20 to +20)
        - `tts_playback_speed` (number input, 0.5 to 2.0)
        - `tts_locale` (dropdown: en-US, en-GB, en-AU, en-IN)
        - `narrate_speech` (checkbox)
        - `narrate_actions` (checkbox)
        - `narrate_rooms` (checkbox)
        - `narrate_system` (checkbox)
  
        ### Output Transformation Flow
  
        **1. Command generates output:**
        ```ruby
        result = success_result("You look around.", type: :room, data: room_data)
        ```
  
        **2. WebSocket handler checks accessibility mode:**
        ```ruby
        if character_instance.accessibility_mode?
          output = AccessibilityOutputService.transform_room(room_data, character_instance)
        else
          output = RoomDisplayService.build_display(room_data)
        end
        ```
  
        **3. TTS queue check:**
        ```ruby
        if character_instance.tts_enabled?
          content_type = determine_content_type(result[:type])
          if should_narrate?(character_instance, content_type)
            TtsQueueService.queue_narration(character_instance, output, type: content_type)
          end
        end
        ```
  
        **4. Content type filtering:**
        ```ruby
        def should_narrate?(char, type)
          case type
          when :speech then char.narrate_speech?
          when :action then char.narrate_actions?
          when :room then char.narrate_rooms?
          when :system then char.narrate_system?
          else true
          end
        end
        ```
  
        **5. Audio playback:**
        - WebSocket sends `{ type: 'tts_audio', audio_url: '/audios/tts_xyz.mp3' }`
        - Client AudioQueueManager.js plays sequentially
        - Respects pause/resume state
        - Removes from queue after playback
  
        ### Edge Cases and Implementation Notes
  
        **TTS Unavailable:**
        - Commands check `TtsService.available?` before enabling
        - Returns error if GOOGLE_APPLICATION_CREDENTIALS missing
        - Gracefully degrades (no crash, just error message)
  
        **Audio File Management:**
        - Saved to `public/audios/tts_<hash>_<timestamp>.mp3`
        - Hash prevents duplicates
        - Timestamp for uniqueness
        - **TODO**: Cleanup job for old files (currently grows unbounded)
  
        **Queue Management:**
        - Max queue length: 50 items (configurable)
        - Auto-skip if queue exceeds max
        - Cleared on logout
        - Persists across page refreshes (Redis)
  
        **Screen Reader Optimization:**
        - JAWS: Use clear headings, semantic structure
        - NVDA: Similar to JAWS
        - VoiceOver: Optimize for macOS conventions
        - TalkBack: Mobile-friendly output
        - Narrator: Windows-specific optimizations
        - Other: Generic linear output
  
        **Accessibility Mode Transform Gotchas:**
        - Must handle nil data gracefully (some displays incomplete)
        - Preserve essential info (don't strip too much)
        - Fallback to original output if transform fails
        - Test with actual screen readers!
  
        **Performance Considerations:**
        - TTS synthesis ~300-500ms per request (Google Cloud latency)
        - Queue in background (async job)
        - Redis queue fast (sub-ms)
        - Audio file I/O minimal (local disk)
        - Transformation adds ~5-10ms (negligible)
  
        **Testing:**
        - Mock TtsService in specs (don't hit Google Cloud API)
        - Test queue ordering, skip, clear
        - Test accessibility transformations
        - Test content type filtering
        - Verify WebSocket broadcasts
  
        **Future Enhancements:**
        - Offline TTS support (browser Speech Synthesis API fallback)
        - Voice cloning for NPCs (unique voices per NPC)
        - Audio file cleanup job
        - Queue priority (e.g., combat actions first)
        - Stereo positioning (directional audio)
        - Background music/ambient sound integration
      NOTES
      display_order: 25
    },
    {
      name: 'roleplaying',
      display_name: 'Roleplaying',
      summary: 'Scenes, posture, social interactions, restraints, and consent',
      description: "Tools for immersive roleplaying. Scene tracking marks the start and end of RP sessions for world memory capture. Posture commands (sit, stand, lie) affect how your character appears in rooms. Social commands manage friendships and check-ins. The prisoner system provides consent-based restraint mechanics for dramatic scenarios. All interactions respect the permissions and consent system.",
      command_names: ['say', 'emote', 'whisper', 'think', 'attempt', 'semote', 'subtle', 'summon', 'smoke', 'eat', 'drink', 'sit', 'stand', 'lie', 'check in', 'private', 'blindfold', 'gag', 'tie', 'untie', 'drag', 'carry', 'release', 'search', 'wake', 'helpless', 'roll', 'undo'],
      related_systems: %w[communication permissions character_customization cards_games],
      key_files: [
        'plugins/core/communication/commands/say.rb',
        'plugins/core/communication/commands/emote.rb',
        'plugins/core/communication/commands/whisper.rb',
        'plugins/core/communication/commands/think.rb',
        'plugins/core/communication/commands/attempt.rb',
        'plugins/core/communication/commands/semote.rb',
        'plugins/core/communication/commands/subtle.rb',
        'plugins/core/posture/commands/sit.rb',
        'plugins/core/posture/commands/stand.rb',
        'plugins/core/posture/commands/lie.rb',
        'plugins/core/social/commands/check_in.rb',
        'plugins/core/social/commands/private.rb',
        'plugins/core/navigation/commands/summon.rb',
        'plugins/core/prisoner/commands/blindfold.rb',
        'plugins/core/prisoner/commands/gag.rb',
        'plugins/core/prisoner/commands/tie.rb',
        'plugins/core/prisoner/commands/untie.rb',
        'plugins/core/prisoner/commands/drag.rb',
        'plugins/core/prisoner/commands/carry.rb',
        'plugins/core/prisoner/commands/drop_prisoner.rb',
        'plugins/core/prisoner/commands/search.rb',
        'plugins/core/prisoner/commands/wake.rb',
        'plugins/core/prisoner/commands/helpless.rb',
        'plugins/core/consumption/commands/smoke.rb',
        'plugins/core/consumption/commands/eat.rb',
        'plugins/core/consumption/commands/drink.rb',
        'app/services/prisoner_service.rb',
        'app/services/semote_interpreter_service.rb',
        'app/services/emote_rate_limit_service.rb',
        'app/helpers/message_persistence_helper.rb',
        'app/models/relationship.rb',
        'app/models/block.rb'
      ],
      player_guide: <<~'GUIDE',
        # Roleplaying Commands
  
        Firefly provides comprehensive roleplaying tools for immersive character interaction, including **speech**, **emotes**, **posture**, **consent-based restraints**, and **consumption**.
  
        ## Speaking and Communication
  
        ### Say - Public Speech
  
        `say <message>` - Speak aloud to everyone in the room
          - Everyone present hears what you say
          - Shorthand: `"<message>` or `'<message>`
          - Aliases: yell, shout, mutter, grumble, scream, moan, gasp, sob, stutter, murmur, flirt, lecture, argue, confess
  
        `say <adverb> <message>` - Speak with emotion
          - Adverbs: quietly, loudly, nervously, excitedly, sadly, angrily, softly, cheerfully
          - Any word ending in 'ly' works
          - Examples: `say quietly I have a secret`, `say excitedly Did you hear?!`
  
        `say to <target> <message>` - Directed speech
          - Everyone hears, but it's clear you're speaking to someone specific
          - Aliases: tell, order, instruct, beg, demand, tease, mock, taunt
          - Examples: `say to Alice Hello there!`, `tell Bob Come with me`
          - If you recently spoke to someone, you can omit their name: `say to I agree`
  
        `reply <message>` or `respond <message>` - Reply to last person who spoke to you
          - Automatic targeting based on conversation context
          - Example: Alice says to you, "How are you?" → `reply I'm doing well!`
  
        `say through <exit>, <message>` - Yell through a door or exit
          - People in the adjacent room hear you
          - Example: `say through north, Hello in there!`
          - Use `yell through` or `shout through` for louder delivery
  
        ### Whisper - Private Speech
  
        `whisper <target> <message>` - Whisper privately to someone
          - Only the target hears the full message
          - Others see "[Name] whispers something to [Target]"
          - Supports adverbs: `whisper Bob quietly How are you?`
          - Short form: `whi Bob Hello`
          - No arguments shows quickmenu of people in the room
  
        ### Think - Internal Thoughts
  
        `think <thought>` - Express internal thoughts
          - Only you see your thoughts
          - Observers watching you see your thoughts (if you're being observed)
          - Telepaths reading your mind see your thoughts
          - Aliases: hope, ponder, wonder, worry, wish, feel, remember
          - Examples: `think I wonder what she meant`, `ponder the mysteries of life`
  
        ## Emotes and Actions
  
        ### Emote - Express Actions
  
        `emote <action>` - Perform an action or express emotion
          - Shows to everyone in the room
          - Your name is prepended automatically when text starts with a **lowercase** letter
          - Shorthand: `:<action>` or `.<action>`
          - Aliases: pose, emit (staff only)
          - Examples:
            - `emote waves hello` → "Alice waves hello."
            - `:smiles warmly` → "Alice smiles warmly."
            - `pose stretches` → "Alice stretches."
  
        ### Emote Syntax Options
  
        **1. Lowercase start (default)** — Your name is automatically prepended:
          - `emote waves` → "Alice waves."
          - `:nods thoughtfully` → "Alice nods thoughtfully."
  
        **2. Starting with a capital letter** — Your name is NOT prepended, but you **must include your own name** somewhere in the text. This lets you control exactly where your name appears:
          - `emote With a sigh, Alice sits down` → "With a sigh, Alice sits down."
          - `emote The room falls silent as Alice enters` → "The room falls silent as Alice enters."
          - If you forget your name, you'll get a helpful error reminding you.
  
        **3. Possessive emotes** — Start with lowercase so your name is prepended, then use possessive grammar:
          - `emote 's eyes light up` → "Alice's eyes light up."
          - `:'s hands tremble slightly` → "Alice's hands tremble slightly."
          - The system prepends your name and the `'s` attaches naturally.
  
        **4. Referencing other characters** — Use other characters' names in your emote text:
          - `emote glances at Bob Jones and smiles` → "Alice glances at Bob Jones and smiles."
          - Each viewer sees names replaced with whatever they know that person as
          - Viewers who don't know Bob might see "a tall man" instead
  
        **5. Adverbs** — Start with a word ending in "ly" for automatic adverb placement:
          - `emote gracefully bows` → "Gracefully Alice bows." or "Alice gracefully bows." (randomly placed)
          - `emote quietly slips away` → "Quietly Alice slips away." or "Alice quietly slips away."
  
        **6. Including speech in emotes** — Use quotes for dialogue within actions:
          - `emote says "Hello!" and waves` → Speech is colored with your speech color
          - `emote leans in and whispers "Follow me" before walking away`
          - Double quotes take priority; single quotes work as fallback (but apostrophes in contractions like "don't" are handled correctly)
  
        **7. Emit (staff/GM only)** — Text appears without any character name:
          - `emit A mysterious figure appears in a flash of light.`
          - Only available to staff and GMs
  
        **Rate limiting:** In very crowded rooms (15+ people), emotes are rate limited to prevent spam (max 3 emotes per 20 seconds).
  
        ### Names in Emotes
  
        **Your name is prepended automatically** (when starting with lowercase). When you type `emote waves`, others see "Alice waves." You don't need to type your own name.
  
        **Mentioning other characters:** You can use other characters' names in your emote text. Each viewer sees those names replaced with whatever they know that person as:
          - If the viewer knows "Bob Jones", they see "Bob Jones"
          - If the viewer has never learned Bob's name, they see Bob's short description (e.g. "a tall man") or "someone"
          - You always see your own name as-is
  
        **Automatic name learning:** When you mention someone's name in an emote, everyone else in the room learns that name. For example:
          - `emote waves at Bob Jones` → Everyone who didn't know Bob now learns he's "Bob Jones"
          - This also works in speech: `say Hello Bob Jones!` → Others learn Bob's name
  
        **Examples of name personalization:**
        ```
        You type: emote waves at Bob Jones and smiles.
        Bob sees: Alice waves at Bob Jones and smiles.
        Charlie (knows both): Alice waves at Bob Jones and smiles.
        Dave (doesn't know Alice): A red-haired woman waves at Bob Jones and smiles.
        Eve (doesn't know either): Someone waves at a tall man and smiles.
        ```
  
        ### Semote - Smart Emote
  
        `semote <action>` - Smart emote with automatic game command extraction
          - Works just like `emote`, shows immediately
          - AI automatically extracts game commands from your emote and executes them
          - Example:
            - `semote stands up and walks to the door` → Shows the emote, then AI extracts "stand" and "walk to door" commands and executes them
          - Only works outside combat
          - Asynchronous: emote shows immediately, commands execute after
  
        ### Subtle - Proximity-Based Action
  
        `subtle <action>` - Perform a subtle action visible only nearby
          - **At a place (table, booth, etc.):** Only others at the same place see the full action
          - **Not at a place:** Only other ungrouped characters see it
          - Others see: "[Someone at table] does something quietly" or "[Someone nearby] does something quietly"
          - Great for covert actions or small-scale interactions
          - Examples: `subtle slides a note across the table`, `subtle winks conspiratorially`
  
        ### Attempt - Consent-Based Actions
  
        `attempt <character> <action>` - Request permission for an action
          - Target receives a quickmenu to allow or deny
          - If allowed, the action is performed as an emote
          - If denied, nothing happens
          - Prevents unwanted physical contact
          - Aliases: propose, request
          - Examples:
            - `attempt Alice hugs warmly` → Alice gets: "Bob wants your permission: *Bob* hugs warmly. [Allow/Deny]"
            - `attempt Bob kisses on the cheek` → Bob chooses to allow or deny
  
        ## Posture Commands
  
        ### Sit
  
        **sit** or **sit down** - Sit on the ground
          - Changes your stance to "sitting"
          - Shows in room descriptions: "Alice is sitting here."
  
        `sit on <furniture>` - Sit on furniture
          - Aliases: sit at, sit in, sit beside, sit by
          - Examples: `sit on couch`, `sit at bar`, `sit in booth`
          - Special aliases: lean on, lean against, sprawl, get in, relax on, lounge on, kneel, crouch, straddle, exercise, work out, study
          - Furniture has capacity limits (shows error if full)
  
        ### Stand
  
        **stand** or **stand up** - Stand up from sitting/lying
          - Changes stance to "standing"
          - If you were at furniture, you step away
          - Aliases: get up
  
        `stand at <furniture>` - Stand at a specific place
          - Aliases: stand by, stand beside, stand near
          - Examples: `stand at bar`, `stand by window`
          - Special aliases: dance on, pace at
  
        ### Lie
  
        **lie down** - Lie on the ground
          - Changes stance to "lying"
          - Aliases: lay, lay down
  
        `lie on <furniture>` - Lie on furniture
          - Examples: `lie on bed`, `lay on couch`
  
        **Stance affects room descriptions:**
          - Standing: "Alice is standing here."
          - Sitting: "Alice is sitting here." or "Alice is sitting at the bar."
          - Lying: "Alice is lying here." or "Alice is lying on the bed."
  
        ## Social Commands
  
        ### Check In - Locatability
  
        **check in** - Set who can find you in the `where` list
          - **yes** - Anyone can find you (default)
          - **favorites** - Only players you've marked as a favorite can see you
          - **no** - Hidden from where list (except those with special visibility permissions)
          - Aliases: locatability, wherevis
          - Examples: `check in yes`, `check in no`, `check in favorites`
  
        ### Private - Adult Content Mode
  
        **private** - Toggle private mode
          - **Private mode ON:** Adult content becomes visible when viewing others who are also in private mode
          - **Private mode OFF:** Adult content is hidden
          - Room sees: "Alice enters/leaves private mode."
  
        `private <target> <emote>` - Private emote
          - Perform an action visible **only** to you and the target
          - No one else sees it (not even observers)
          - Great for covert gestures, secret signals
          - Examples:
            - `private Bob winks knowingly` → Only Bob sees: "(Privately) Alice winks knowingly at you."
            - `private to Alice makes a subtle gesture` → Only Alice sees it
  
        ### Summon - Call NPCs
  
        `summon <npc> = <message>` - Send a message summoning an NPC
          - NPCs use AI to decide whether to come based on your message and their personality
          - Example: `summon Merchant = I need to buy supplies`
          - NPC must be within summon range
          - Cooldown if NPC declines
  
        ## Consumption Commands
  
        ### Smoke
  
        `smoke <item>` - Light up and smoke an item
          - Starts smoking animation
          - Item must be in your inventory
          - Aliases: puff, light up
          - Examples: `smoke cigarette`, `puff pipe`
  
        ### Eat
  
        `eat <item>` - Eat food from inventory
          - Starts eating animation
          - Aliases: consume, taste, swallow
          - Examples: `eat apple`, `eat sandwich`
  
        ### Drink
  
        `drink <item>` - Drink a beverage from inventory
          - Starts drinking animation
          - Aliases: sip, gulp, quaff
          - Examples: `drink water`, `sip wine`, `quaff beer`
  
        **Note:** Consumption commands use ConsumableConcern for consistent behavior across smoke/eat/drink.
  
        ## Prisoner System (Consent-Based Restraints)
  
        The prisoner system provides **consent-based restraint mechanics** for dramatic RP scenarios. All actions require the target to be **helpless** first.
  
        ### Helpless State
  
        **helpless** or **helpless on** - Voluntarily become helpless
          - Allows others to restrain you, search you, or move you
          - **Consent required:** You must explicitly enable this
          - Room sees: "Alice becomes helpless and vulnerable."
  
        **helpless off** - Remove voluntary helplessness
          - Room sees: "Alice is no longer helpless."
  
        **Note:** You can also become helpless involuntarily:
          - Knocked unconscious in combat (0 HP)
          - Hands bound by another character
  
        ### Restraining Actions (Require Target to be Helpless)
  
        `tie <character> [hands/feet]` - Bind someone's hands or feet
          - Aliases: bind, restrain
          - Examples: `tie Bob`, `tie Alice hands`, `bind Bob feet`
          - Hands bound = target becomes/stays helpless and cannot use most commands
          - Feet bound = target cannot move
  
        `gag <character>` - Gag someone to prevent speech
          - Aliases: muzzle
          - Target can no longer speak (say, whisper, etc.)
          - Target sees: "Bob gags you. You can no longer speak."
  
        `blindfold <character>` - Blindfold someone to block vision
          - Aliases: hood
          - Target cannot see room descriptions or visual emotes
          - Target sees: "Bob blindfolds you. Everything goes dark."
  
        `untie <character> [hands/feet/gag/blindfold/all]` - Remove restraints
          - Aliases: unbind, free
          - Default: removes ALL restraints
          - Examples:
            - `untie Alice` → Removes all restraints
            - `untie Bob hands` → Only removes hand bindings
            - `free Alice gag` → Only removes gag
  
        ### Moving Helpless Characters
  
        `drag <character>` - Drag a helpless character
          - Aliases: haul
          - Target follows you as you move (slower movement speed)
          - Target sees: "Bob drags you along."
  
        `carry <character>` - Pick up and carry a helpless character
          - Aliases: pickup, lift
          - Target is carried with you as you move
          - Target sees: "Bob picks you up and carries you."
  
        **release** - Put down or release a character you're dragging/carrying
          - Aliases: letgo, putdown
          - Target is released at your current location
  
        ### Other Prisoner Actions
  
        `search <character>` - Search a helpless character's belongings
          - Aliases: frisk, rob
          - Shows their worn items, carried items, and money
          - Target sees: "Bob searches your belongings."
          - Example output:
            ```
            You search Alice:
  
            Wearing:
              - leather jacket
              - blue jeans
  
            Carrying:
              - wallet
              - keys
  
            Money:
              - 50 dollars
            ```
  
        `wake <character>` - Wake an unconscious character
          - Aliases: rouse, awaken
          - Only works on unconscious characters (knocked out in combat)
          - Character regains consciousness
          - Example: `wake Bob` → "You shake Bob until he regains consciousness."
  
        ### Prisoner System Notes
  
        - **Timeline restriction:** Prisoner mechanics are disabled in past timelines
        - **Consent first:** Target must be helpless (voluntary or unconscious) before restraints can be applied
        - **Helpless penalties:**
          - Cannot use most commands
          - Cannot move if hands bound
          - Cannot see if blindfolded
          - Cannot speak if gagged
        - **Auto-wake:** Unconscious characters automatically wake after a delay (unless still in active combat)
  
        ## Undo - Fix Mistakes
  
        **undo** - Delete your last message from everyone's screen
          - `undo` - Removes your most recent say, emote, whisper, or channel message
          - Must be used within **60 seconds** of sending
          - Works on both panels:
            - **Right panel**: Undoes say, emote, whisper, and other IC messages
            - **Left panel**: Undoes channel messages and OOC chat
          - The message is deleted from the database and disappears for all viewers
          - Only affects your single most recent message — you can't undo further back
          - Type `undo` in the same panel where you sent the message
  
        **Common uses:**
          - Fix a typo in an important emote
          - Take back an accidental message
          - Remove a message sent to the wrong panel
  
        ## Character Recognition & The Remember System
  
        Firefly uses an organic name-learning system. Characters don't automatically know each other — you discover names through roleplay, just as you would in real life. This creates natural moments for introductions and adds depth to character interactions.
  
        ### How You See Others
  
        When another character appears in a room description, emote, or speech, the name you see depends on whether you've learned who they are:
  
        | Your Knowledge | What You See |
        |----------------|-------------|
        | You know them | Their name (e.g. "Bob Jones") |
        | You don't know them | Their short description (e.g. "a tall man") or "someone" |
        | It's yourself | Always your own name |
  
        This means two people can read the same emote and see different names. If Alice waves at Bob, someone who knows Alice sees "Alice waves at Bob" while a stranger might see "A red-haired woman waves at Bob."
  
        ### How You Learn Names
  
        Names are learned **automatically** through roleplay — no special command needed:
  
        **Through emotes:** When someone mentions a character by name in an emote, everyone in the room learns that name.
          - `emote waves at Bob Jones` → Everyone now knows that person is "Bob Jones"
  
        **Through speech:** Saying someone's name out loud teaches it to listeners.
          - `say Hey, have you met Bob Jones?` → Everyone in the room learns Bob's name
  
        **Through introduction:** When a character performs any action that contains their own name (in speech or action text), others learn it.
          - `say My name is Alice Smith, nice to meet you.` → Everyone learns your name
  
        ### How Memory Works
  
        - **Persistent:** Once you learn a character's name, you remember it forever — across sessions, across logins
        - **Per-character:** Each character has their own separate knowledge. Your alt doesn't know the people your main knows
        - **First meeting tracked:** The system remembers when you first met someone and when you last saw them
        - **Organic discovery:** There's no "scan" or "identify" — you learn names the way you would in real life
  
        ### Tips for Roleplaying with Names
        - **Introduce yourself in speech** to let others learn your name naturally: `say "I'm Alice Smith, nice to meet you."`
        - **Use full names** when referring to someone — this helps other characters learn who you're talking about
        - **Pay attention to descriptions** — if you see "a scarred woman" instead of a name, your character hasn't been introduced yet
        - **This creates natural RP moments** — you can play out introductions, ask someone's name, or remain mysterious
  
        ## Tips for Effective Roleplaying
  
        ### Speech and Emotes
        - **Use adverbs** to add flavor: `say nervously I'm not sure`, `emote gracefully bows`
        - **Include speech in emotes** for complex actions: `emote says "Watch this!" and jumps`
        - **Use whisper** for private conversations in public spaces
        - **Use private emotes** for covert signals only one person should see
        - **Use `undo`** within 60 seconds to delete a message with a typo or mistake
        - **Possessive emotes:** `emote 's eyes narrow` → "Alice's eyes narrow."
        - **Capital-letter emotes** for creative sentence structure: `emote With a flourish, Alice bows`
  
        ### Posture and Presence
        - **Sit at places** to join conversations: `sit at table`
        - **Stand at landmarks** to show where you are: `stand at bar`
        - **Lie on beds** to indicate resting or sleeping
  
        ### Consent and Boundaries
        - **Use attempt** for any physical contact: `attempt Alice hugs gently`
        - **Enable helpless** only when you consent to restraint RP
        - **Respect denials:** If someone denies your attempt, don't retry immediately
  
        ### Consumption
        - **Smoke, eat, drink** add atmosphere to scenes
        - **Emote with consumption:** Combine with emotes for richer description
  
        ## Examples
  
        **Social gathering:**
        ```
        sit at table
        say Hello everyone!
        emote leans back in her chair and smiles
        drink wine
        say to Bob How have you been?
        ```
  
        **Covert action:**
        ```
        subtle slides a note to Alice under the table
        whisper Alice quietly Read this when you're alone
        ```
  
        **Consent-based restraint scene:**
        ```
        (Alice): helpless on
        (Bob): tie Alice hands
        (Bob): blindfold Alice
        (Bob): carry Alice
        walk north
        (Bob): release
        ```
  
        **Combat aftermath:**
        ```
        wake Bob
        untie Bob all
        say Welcome back, you were knocked out
        ```
  
        ## Dice Rolling
  
        Roll dice based on your character's stats for checks, saves, and contests.
  
        - `roll` — Show menu of your stats to roll
        - `roll <STAT>` — Roll using a specific stat
        - `roll <STAT>+<STAT>` — Combine multiple stats
  
        **How it works:**
        - Rolls **2d8 exploding** (8s are rerolled and added)
        - Adds your stat value(s) as a modifier
        - Results broadcast to everyone in the room
  
        **Examples:**
        ```
        roll STR
        → Bob rolls STR (3): [6, 4] +3 = 13
  
        roll STR+DEX
        → Bob rolls STR (3) + DEX (2): [8, 5] EXPLODE!+6 +5 = 24
  
        roll INT+WIS+CHA
        → Bob rolls INT (4) + WIS (3) + CHA (1): [7, 2] +8 = 17
        ```
  
        **Exploding dice:** When you roll an 8, you roll again and add the new result. This can chain multiple times.
  
        **Combining stats:** Use `+` to combine multiple stat modifiers. Can't use the same stat twice.
  
        **Auto-GM integration:** If an Auto-GM has requested a roll, your roll is automatically evaluated against the DC.
      GUIDE
      staff_notes: <<~'NOTES',
        ## Communication Commands Architecture
  
        ### Say Command (plugins/core/communication/commands/say.rb - 407 lines)
        **Unified say command handling three modes:**
  
        **1. Basic Say:**
        - Extracts adverbs from message text (any word ending in 'ly')
        - Formats with MessageFormattingHelper: `format_narrative_message`
        - Persists via MessagePersistenceHelper: `persist_room_message`
        - Validates with `validate_message_content` (spam/abuse checking)
        - Broadcasts to room with `broadcast_to_room`
        - Logs roleplay with `log_roleplay`
  
        **2. Say To (Directed Speech):**
        - Parses `<target> <message>` format
        - Uses `CharacterLookupHelper.find_character_in_room`
        - Checks IC permission with `check_ic_permission`
        - Updates conversation context:
          ```ruby
          character_instance.set_last_spoken_to(target)
          target.set_last_speaker(character_instance)
          ```
        - Everyone hears, but message is directed
        - Supports implicit targeting via context (last_speaker/last_spoken_to)
  
        **3. Reply/Respond:**
        - Auto-targets based on `character_instance.last_speaker`
        - Falls back with error if no recent speaker
        - Same mechanics as Say To
  
        **4. Say Through (Cross-Room):**
        - Parses `<exit>, <message>` format
        - Finds exit via `find_exit_by_name` (supports direction or room name)
        - Broadcasts to current room AND target room
        - Target room hears from opposite direction: "Someone says from north, '...'"
        - Uses spatial exit data from `location.spatial_exits`
  
        **Aliases:**
        - Emotion variants: yell, shout, mutter, grumble, scream, moan, gasp, sob, stutter, murmur
        - Social variants: flirt, lecture, argue, confess, order, instruct, beg, demand, tease, mock, taunt
        - Quick shortcuts: `"` and `'` prefixes
  
        **Key Helpers:**
        - `extract_adverb(text)` → Returns [adverb, clean_text]
        - `format_say_message(text, adverb)` → Formatted output
        - `check_not_gagged(action)` → Error if gagged
  
        ### Emote Command (plugins/core/communication/commands/emote.rb - 288 lines)
        **Standard emote with personalization and name learning.**
  
        **Processing Flow:**
        1. Extract emote text and adverb
        2. Process standard emote: `#{character_name} #{adverb} #{text}`
        3. Add punctuation via `process_punctuation`
        4. Persist with MessagePersistenceHelper
        5. Broadcast with personalization
  
        **Broadcast Personalization:**
        ```ruby
        broadcast_personalized_emote(base_message, is_spotlighted)
          - EmoteFormatterService.format_for_viewer (name substitution + speech coloring)
          - NameLearningService.process_emote (teaches names)
          - Apply wrapper styling (spotlight CSS if active)
        ```
  
        **Spotlight System:**
        - Checks `character_instance.spotlighted?`
        - Wraps emote in `<div class="spotlight-emote">` for CSS highlighting
        - Decrements spotlight counter after broadcast
  
        **Speech Coloring:**
        - EmoteParserService.parse extracts speech segments
        - Applies `character.speech_color` to quoted text
        - Viewers see speaker's speech color
  
        **Name Learning:**
        - NameLearningService detects character names in emotes
        - Creates CharacterKnowledge records for learning
        - Example: `emote waves at Bob` → Others learn Bob's name
  
        **Rate Limiting:**
        - EmoteRateLimitService checks crowded rooms (15+ people)
        - Max 3 emotes per 20 seconds per character
        - Only active in crowded rooms to prevent spam
  
        **Emit Mode (Staff Only):**
        - `emit` alias (staff only via `can_emit?` check)
        - Text appears without character name
        - Wrapped in `<fieldset>` for styling
  
        **Offline Mentions:**
        - `notify_offline_mentions(emote_text)` checks for character name mentions
        - Sends Discord notifications to offline characters who are mentioned
        - Uses NotificationService.notify_mention
  
        ### Whisper Command (plugins/core/communication/commands/whisper.rb - 212 lines)
        **Private speech with obscured broadcast.**
  
        **Target Resolution:**
        - Uses TargetResolverService.resolve_character_with_disambiguation
        - min_prefix_length: 4 for fuzzy matching
        - Shows quickmenu if ambiguous matches
  
        **Broadcast Logic:**
        ```ruby
        broadcast_whisper(full_message, target_instance, adverb)
          # Target sees full message (personalized)
          send_to_character(target, personalized_message)
  
          # Others see obscured: "Alice quietly whispers to Bob."
          obscured_message = format_obscured_message(...)
          broadcast_to_observers_personalized(obscured, exclude: [sender, target])
        ```
  
        **Adverb Placement:**
        - Adverb placed BEFORE verb: "quietly whispers" not "whispers quietly"
        - Uses `format_narrative_message` with `adverb_before_verb: true`
  
        **No-Argument Menu:**
        - Shows quickmenu of characters in room
        - Character short_desc shown as description
  
        ### Think Command (plugins/core/communication/commands/think.rb - 116 lines)
        **Internal thoughts visible to observers and telepaths.**
  
        **Visibility:**
        1. **Self:** Always sees own thoughts
        2. **Observers:** `character_instance.current_observers` see thoughts
        3. **Telepaths:** `character_instance.mind_readers` see with "[Telepathy]" prefix
  
        **Formatting:**
        ```ruby
        format_thought(verb, thought)
          "*#{character.full_name}* #{verb}, \"#{thought}\""
        ```
  
        **Verb Variants:**
        - Aliases map to different verbs: hope→hopes, ponder→ponders, worry→worries, etc.
        - Default: thinks
  
        **Broadcast:**
        - Uses BroadcastService.to_character directly (not room-wide)
        - Type: `:think` for UI filtering
  
        ### Attempt Command (plugins/core/communication/commands/attempt.rb - 112 lines)
        **Consent-based action requests.**
  
        **Flow:**
        1. Parse `<target> <action>` format
        2. Check if target is helpless (alive characters only)
        3. Check if target has pending attempt (1 at a time)
        4. Submit attempt: `character_instance.submit_attempt!(target, emote_text)`
        5. Send quickmenu to target with Allow/Deny options
  
        **Quickmenu Context:**
        ```ruby
        context: {
          handler: 'attempt',
          attempter_id: character_instance.id,
          emote_text: emote_text,
          sender_name: sender_name
        }
        ```
  
        **QuickmenuService Handler:**
        - Attempt handler processes Allow/Deny response
        - If allowed: executes emote as if attempter performed it
        - If denied: notifies both parties, clears attempt
  
        ### Semote Command (plugins/core/communication/commands/semote.rb - 292 lines)
        **Smart emote with async LLM command extraction.**
  
        **Synchronous Phase:**
        1. Validate and persist emote (same as regular emote)
        2. Broadcast to room immediately
        3. Log roleplay
  
        **Asynchronous Phase:**
        ```ruby
        spawn_llm_processing(emote_text) unless character_instance.in_combat?
          Thread.new do
            # Interpret emote to extract actions
            result = SemoteInterpreterService.interpret(emote_text, ci)
  
            # Execute actions sequentially
            SemoteExecutorService.execute_actions_sequentially(...)
          end
        ```
  
        **SemoteInterpreterService:**
        - Uses LLM (Gemini Flash) to extract game commands from emote
        - Prompt: "Extract game commands from this emote: '...'"
        - Returns: `{ success: true, actions: ['stand', 'walk to door'] }`
        - Creates SemoteLog record for tracking
  
        **SemoteExecutorService:**
        - Executes extracted commands sequentially
        - Uses CommandHandler to execute each command
        - Logs results to SemoteLog
        - Stops on first error
  
        **Skip Combat:**
        - Semote interpretation disabled in combat (too chaotic)
        - Emote still shows, but no command extraction
  
        ### Subtle Command (plugins/core/communication/commands/subtle.rb - 165 lines)
        **Proximity-based visibility.**
  
        **Visibility Rules:**
        ```ruby
        partition_recipients(room_characters, current_place)
          if current_place
            # Actor at a place: same place sees full, others see obscured
            same_place → full message
            different_place → obscured
          else
            # Actor not at a place: other ungrouped see full
            no_place → full message
            at_place → obscured
          end
        ```
  
        **Obscured Message:**
        - At place: "[Someone at table] does something quietly."
        - Not at place: "[Someone nearby] does something quietly."
  
        **Styling:**
        - Full message: `<span class="subtle-emote">...</span>`
        - Obscured: `<span class="subtle-emote muted">...</span>`
  
        ## Posture Commands
  
        ### Sit/Stand/Lie Commands
        **Common pattern across all posture commands:**
  
        **Database Fields:**
        ```ruby
        character_instance.stance # 'standing', 'sitting', 'lying'
        character_instance.current_place_id # Furniture/place ID or nil
        ```
  
        **Sit Command (plugins/core/posture/commands/sit.rb - 121 lines):**
        - Aliases include prepositions: "sit on", "sit at", "sit in", etc.
        - Extracts preposition from either command alias or text
        - `extract_preposition_from_command(command_word)` checks alias
        - Checks `place.full?` for capacity
        - Uses `place.default_sit_action` as fallback preposition (or 'on')
        - Creative aliases: sprawl, lean on, lean against, get in, relax on, lounge on, kneel, crouch, straddle, exercise, work out, study
  
        **Stand Command (plugins/core/posture/commands/stand.rb - 144 lines):**
        - Simple stand: clears place, sets stance to 'standing'
        - Stand at place: moves to place while standing
        - Aliases: dance, pace (with "dance on stage", "pace at window")
  
        **Lie Command (plugins/core/posture/commands/lie.rb - 84 lines):**
        - Simplest posture command
        - Sets stance to 'lying', optionally at place
        - Alias: lay, lay down
  
        **Room Display Impact:**
        - Look command shows stance in character list:
          - "Alice is sitting here."
          - "Bob is sitting at the bar."
          - "Charlie is standing at the window."
          - "Diana is lying on the bed."
  
        ## Social Commands
  
        ### Check In Command (plugins/core/social/commands/check_in.rb - 86 lines)
        **Locatability settings for `where` command visibility.**
  
        **Settings:**
        - **yes:** Appear in where list for everyone (default)
        - **favorites:** Only appear for players who marked you as favorite
        - **no:** Hidden from where list (except those with special visibility)
  
        **Storage:**
        ```ruby
        character_instance.locatability # 'yes', 'no', 'favorites'
        ```
  
        **Quickmenu:**
        - No argument shows quickmenu with current setting
        - Direct arguments accepted: `check in yes`, `check in no`, `check in favorites`
  
        **Who Command Integration:**
        - Who command checks `UserPermission.can_see_in_where?(viewer, target)`
        - UserPermission considers locatability + special permissions + user always sees own alts
  
        ### Private Command (plugins/core/social/commands/private.rb - 144 lines)
        **Two modes: toggle private mode OR perform private emote.**
  
        **Mode Toggle (no args):**
        ```ruby
        character_instance.toggle_private_mode!
        if private_mode?
          # Adult content visible when viewing others in private mode
        else
          # Adult content hidden
        end
        ```
  
        **Private Emote (with args):**
        ```ruby
        perform_private_emote(text)
          # Parse <target> <emote>
          # Send to ONLY sender and target (not observers)
          send_to_character(sender, "(Private to Bob) Alice winks knowingly.")
          send_to_character(target, "(Privately) Alice winks knowingly at you.")
  
          # Persist with message_type: 'private_emote' (not broadcast to room)
          persist_targeted_message(..., message_type: 'private_emote')
        ```
  
        **Name Substitution:**
        - `substitute_target_with_you(text, target_character)` replaces target's name with "you"
        - Example: "Alice winks at Bob" → "Alice winks at you" (for Bob)
  
        **Logging:**
        - Private emotes logged with `log_roleplay(message, private: true, target_id: ...)`
        - Not broadcast to observers or room
  
        ### Summon Command (plugins/core/navigation/commands/summon.rb - 83 lines)
        **NPC summoning with AI decision-making.**
  
        **Format:** `summon <npc> = <message>`
  
        **NpcLeadershipService Methods:**
        ```ruby
        find_npc_in_summon_range(pc_instance:, name:)
          # Finds NPCs within range (same zone, certain distance)
  
        can_be_summoned?(npc)
          # Checks NPC flags (some NPCs cannot be summoned)
  
        on_summon_cooldown?(npc:, pc:)
          # Checks if NPC recently declined this PC's summons
  
        request_summon(npc_instance:, pc_instance:, message:)
          # Async LLM decision: NPC decides whether to come based on message and personality
        ```
  
        **AI Decision:**
        - NPC uses LLM to read message and decide
        - Considers: relationship with PC, current task, personality, message content
        - If accepts: NPC pathfinds to PC's location
        - If declines: Cooldown starts (prevents spam)
  
        **Cooldown:**
        - Stored in Redis: `summon_cooldown:#{npc.id}:#{pc.id}`
        - Duration from GameConfig::Npc::SUMMON_COOLDOWN_MINUTES
  
        ## Prisoner System
  
        ### PrisonerService (app/services/prisoner_service.rb)
        **Core service managing all restraint mechanics.**
  
        **Helpless State:**
        ```ruby
        make_helpless!(character_instance, reason:)
          # reason: 'unconscious', 'bound_hands', 'voluntary'
          character_instance.update(is_helpless: true, helpless_reason: reason)
          character_instance.update(following_id: nil) # Stop following
  
        clear_helpless!(character_instance)
          # Checks if should remain helpless (unconscious or hands_bound)
          # Clears if neither condition met
  
        can_restrain?(target)
          # Returns true if target.helpless?
  
        can_manipulate?(actor, target)
          # Checks: target helpless, same room, not self
        ```
  
        **Restraint Types:**
        ```ruby
        character_instance.hands_bound? # Boolean
        character_instance.feet_bound? # Boolean
        character_instance.gagged? # Boolean
        character_instance.blindfolded? # Boolean
        ```
  
        **Apply/Remove Restraints:**
        ```ruby
        apply_restraint!(actor, target, type:)
          # type: 'hands', 'feet', 'gag', 'blindfold'
          # Checks can_restrain?, same room, timeline permissions
          # Updates target's restraint flags
          # If hands_bound: makes/keeps target helpless
  
        remove_restraint!(actor, target, type:)
          # type: 'hands', 'feet', 'gag', 'blindfold', 'all'
          # Removes specified restraints
          # Calls clear_helpless! if hands unbound
        ```
  
        **Transport:**
        ```ruby
        drag!(actor, target)
          # Sets actor.dragging_prisoner_id = target.id
          # Target follows actor on movement (slower speed via DRAG_SPEED_MODIFIER)
  
        carry!(actor, target)
          # Sets actor.carrying_prisoner_id = target.id
          # Target moves with actor (normal speed, but target is carried)
  
        stop_drag!(actor)
          # Clears dragging_prisoner_id
          # Returns { success:, released: character }
  
        put_down!(actor)
          # Clears carrying_prisoner_id
          # Returns { success:, released: character }
        ```
  
        **Search Inventory:**
        ```ruby
        search_inventory(actor, target)
          # Returns { success:, worn:, items:, money: }
          # Checks can_manipulate?
          # Uses Inventory methods to list target's belongings
        ```
  
        **Unconsciousness:**
        ```ruby
        in_active_combat?(character_instance)
          # Checks if knocked out in an ongoing fight
  
        wake!(character_instance, waker:)
          # Revives unconscious character
          # Checks: not in active combat, minimum wake delay passed
          # Clears unconscious flag, updates stance to 'lying'
  
        auto_wake_timer!(character_instance)
          # Background job: auto-wake after AUTO_WAKE_SECONDS
          # Only if not in active combat
        ```
  
        **Timeline Restrictions:**
        ```ruby
        character_instance.can_be_prisoner?
          # Returns false in past timelines (prisoner mechanics disabled)
          # Present/future timelines: true
        ```
  
        ### Prisoner Commands
        **All prisoner commands use shared helpers from Base::Command:**
  
        **apply_restraint_action (Base::Command helper):**
        ```ruby
        apply_restraint_action(
          target_name:,
          restraint_type:,
          action_verb:,
          target_msg_template:,
          other_msg_template: nil,
          self_msg_template: nil,
          empty_error: nil,
          check_timeline: false
        )
          # Resolves target with disambiguation
          # Calls PrisonerService.apply_restraint!
          # Broadcasts formatted messages
        ```
  
        **remove_restraint_action (Base::Command helper):**
        ```ruby
        remove_restraint_action(target_name:, restraint_type:)
          # Similar pattern for untie command
        ```
  
        **transport_action (Base::Command helper):**
        ```ruby
        transport_action(target_name:, action_type:, check_timeline:)
          # action_type: :drag or :carry
          # Calls PrisonerService.drag! or carry!
        ```
  
        **Blindfold Command:**
        - Sets `blindfolded: true`
        - Victim cannot see room descriptions or visual emotes
        - Look command returns: "You can't see anything. You are blindfolded."
  
        **Gag Command:**
        - Sets `gagged: true`
        - Victim cannot use say, whisper, shout, etc.
        - Commands check with `check_not_gagged(action)` helper
  
        **Tie Command:**
        - Binds hands (default) or feet
        - Hands bound: target becomes/stays helpless
        - Feet bound: target cannot move
  
        **Untie Command:**
        - Removes restraints (hands, feet, gag, blindfold, or all)
        - If hands unbound: calls `clear_helpless!` (may restore non-helpless state)
  
        **Drag/Carry Commands:**
        - Drag: slower movement, target dragged along
        - Carry: normal movement, target carried
        - Both: target moves with actor automatically via MovementHandler integration
  
        **Search Command:**
        - Returns formatted inventory list
        - Shows worn, carried, and money
        - Broadcasts to room and target
  
        **Wake Command:**
        - Only works on unconscious characters
        - Checks WAKE_DELAY_SECONDS minimum (30 seconds)
        - Cannot wake during active combat
  
        **Helpless Command:**
        - Toggle: `helpless`, `helpless on`, `helpless off`
        - Voluntary helplessness for RP scenarios
        - Timeline check: disabled in past timelines
  
        ### Restraint Effects Matrix
  
        | Restraint | Effect |
        |-----------|--------|
        | Hands Bound | Helpless, cannot use most commands, cannot flee |
        | Feet Bound | Cannot move (walk, run, etc.) |
        | Gagged | Cannot speak (say, whisper, shout, yell, etc.) |
        | Blindfolded | Cannot see room descriptions, visual emotes |
        | Unconscious | Helpless, auto-wakes after delay |
  
        ## Consumption Commands
  
        ### ConsumableConcern (plugins/core/consumption/concerns/consumable_concern.rb)
        **Shared concern for smoke/eat/drink commands.**
  
        **Configuration DSL:**
        ```ruby
        consumable_config(
          consume_type: 'smoke',      # Item type to consume
          verb: 'smoking',             # Present participle
          verb_past: 'smoke',          # Past tense
          state_check: :smoking?,      # CharacterInstance method
          item_accessor: :smoking_item,# CharacterInstance method
          start_method: :start_smoking!, # CharacterInstance method
          default_action: 'Wisps of smoke curl upward.',
          broadcast_verb: 'lights up'
        )
        ```
  
        **Flow:**
        1. Find item in inventory: `find_consumable_item(item_name)`
        2. Start consumption: `character_instance.start_smoking!(item)`
        3. Broadcast: "Alice lights up a cigarette."
        4. Set state: `smoking_item_id = item.id`, `smoking?: true`
        5. Background job: ConsumptionService.process_tick (decrements item, applies effects)
        6. Finish: Item consumed or dropped
  
        **Item Fields:**
        - `consumable_type`: 'smoke', 'food', 'drink'
        - `consumption_ticks`: Number of ticks to consume
        - `effects`: JSONB hash of effects per tick
  
        **CharacterInstance State:**
        ```ruby
        smoking_item_id # ID of item being smoked
        eating_item_id  # ID of item being eaten
        drinking_item_id # ID of item being drunk
  
        smoking? # Boolean check
        eating?  # Boolean check
        drinking? # Boolean check
        ```
  
        **Consumption Ticks:**
        - Background job (Rufus::Scheduler) runs every N seconds
        - Each tick: apply effects, decrement counter
        - On finish: clear state, remove item if depleted
  
        ## Message Personalization and Name Learning
  
        ### EmoteFormatterService
        **Personalizes emotes for each viewer with name substitution and speech coloring.**
  
        ```ruby
        format_for_viewer(base_message, speaker, viewer_instance, room_characters)
          # 1. Parse emote to extract speech segments
          segments = EmoteParserService.parse(base_message)
  
          # 2. Substitute names for viewer
          personalized = substitute_names_for_viewer(base_message, viewer_instance)
  
          # 3. Apply speech coloring
          if speaker.speech_color?
            # Wrap speech segments in <span style="color:...">
          end
  
          # Return personalized message
        ```
  
        ### NameLearningService
        **Teaches character names when mentioned in emotes.**
  
        ```ruby
        process_emote(speaker, emote_text, room_characters)
          room_characters.each do |viewer|
            # Check if emote mentions any characters viewer doesn't know
            room_characters.each do |mentioned|
              if mentioned_in_emote?(mentioned.name, emote_text)
                if !viewer.knows?(mentioned)
                  CharacterKnowledge.create(
                    knower: viewer.character,
                    known: mentioned.character,
                    known_name: mentioned.character.full_name
                  )
                end
              end
            end
          end
        ```
  
        **CharacterKnowledge Model:**
        - `knower_id`: Character who learns the name
        - `known_id`: Character whose name is learned
        - `known_name`: The name they learned (usually full_name)
  
        **Name Substitution in Display:**
        - If viewer knows character: shows `known_name`
        - If viewer doesn't know character: shows `short_desc` or "someone"
        - Viewer always sees own name as self (no substitution for self)
  
        ### EmoteRateLimitService
        **Prevents emote spam in crowded rooms.**
  
        ```ruby
        RATE_LIMIT_THRESHOLD = 15 # People in room
        MAX_EMOTES = 3
        RATE_WINDOW_SECONDS = 20
  
        check(character_instance, location)
          # If room has < 15 people: { allowed: true }
          # If room has >= 15 people:
          #   - Check Redis: emote_count:#{char_id} (20 second window)
          #   - If < 3 emotes: { allowed: true }
          #   - If >= 3 emotes: { allowed: false, message: 'Slow down...' }
  
        record_emote(character_instance_id)
          # Increment Redis counter: emote_count:#{char_id}
          # Set 20 second expiry
        ```
  
        ## Edge Cases and Gotchas
  
        **Gag Persistence:**
        - Gag blocks say, whisper, shout, yell, scream, moan, etc.
        - Does NOT block emotes (you can still gesture)
        - Check with `check_not_gagged(action)` in commands
  
        **Blindfold Vision:**
        - Blindfold blocks look, visual emotes
        - Does NOT block whisper (hearing still works)
        - Does NOT block think (internal thoughts)
  
        **Helpless State Hierarchy:**
        - Unconscious → helpless (can't be cleared until conscious)
        - Hands bound → helpless (can't be cleared until unbound)
        - Voluntary → helpless (can be cleared anytime with `helpless off`)
  
        **Posture and Furniture Capacity:**
        - `place.capacity` vs `place.current_occupants.count`
        - Full check: `place.full?` helper
        - No overbooking allowed
  
        **Say Through and Spatial Exits:**
        - Uses `location.spatial_exits` from RoomAdjacencyService
        - Exit must be passable (not blocked by wall)
        - Opposite direction calculated via geometry
  
        **Semote LLM Extraction:**
        - Only works outside combat (skip if `in_combat?`)
        - Thread-local Sequel connections (re-fetch character_instance in thread)
        - SemoteLog tracks all interpretations for debugging
  
        **Private Emotes and Logging:**
        - Private emotes persisted with `message_type: 'private_emote'`
        - NOT broadcast to observers or room
        - Logged with `log_roleplay(message, private: true, target_id: ...)`
  
        **Consumption State Conflicts:**
        - Can only smoke OR eat OR drink at a time (not multiple)
        - Attempting second consumption stops first
        - State cleared on logout/disconnect
  
        **Attempt Quickmenu Expiry:**
        - Pending attempts expire after timeout (QuickmenuService.QUICKMENU_TIMEOUT)
        - Cleanup job removes stale attempt states
  
        **Name Learning Performance:**
        - O(n²) in room size (check each character vs each mentioned name)
        - Skipped for very large rooms (>50 people) to prevent lag
        - Uses eager loading to minimize queries
      NOTES
      display_order: 30
    },
    {
      name: 'local_movement',
      display_name: 'Within-Location Movement',
      summary: 'Moving between rooms, looking around, maps, and room access',
      description: "Commands for moving within a location — walking between rooms, looking around, checking exits, and viewing maps. Movement uses spatial adjacency: rooms connect based on shared walls and openings. Use cardinal directions (north, south, east, west, up, down) or 'walk to <place>' for named destinations. Followers automatically move with their leader. Room access controls let you lock doors and manage who can enter your spaces.",
      command_names: ['walk', 'follow', 'lead', 'stop', 'map', 'places', 'exits', 'home', 'north', 'south', 'east', 'west', 'up', 'down', 'northeast', 'northwest', 'southeast', 'southwest', 'in', 'out', 'directory', 'landmarks', 'drive', 'taxi'],
      related_systems: %w[world_travel combat building],
      key_files: [
        'plugins/core/navigation/commands/walk.rb',
        'plugins/core/navigation/commands/follow.rb',
        'plugins/core/navigation/commands/lead.rb',
        'plugins/core/navigation/commands/stop.rb',
        'plugins/core/navigation/commands/map.rb',
        'plugins/core/navigation/commands/places.rb',
        'plugins/core/navigation/commands/exits.rb',
        'plugins/core/navigation/commands/home.rb',
        'plugins/core/navigation/commands/directions.rb',
        'plugins/core/navigation/commands/landmarks.rb',
        'plugins/core/navigation/commands/taxi.rb',
        'plugins/core/vehicles/commands/drive.rb',
        'plugins/core/info/commands/directory.rb',
        'app/services/movement_service.rb',
        'app/handlers/movement_handler.rb',
        'app/services/pathfinding_service.rb',
        'app/services/room_adjacency_service.rb',
        'app/services/room_passability_service.rb',
        'app/services/target_resolver_service.rb'
      ],
      player_guide: <<~'GUIDE',
        # Local Movement Commands
  
        Firefly provides comprehensive navigation tools for moving between rooms, following others, viewing maps, and finding destinations. Movement uses **spatial adjacency** - rooms connect based on their physical layout, not manual exits.
  
        ## Basic Movement
  
        ### Walk - Universal Movement Command
  
        `walk <target>` - Move to a destination
          - **Direction:** `walk north`, `walk south`, `walk east`, `walk west`
          - **Room name:** `walk to Main Street`, `walk to tavern`
          - **Character:** `walk to John` (follow them to their room)
          - **Furniture:** `walk to bar`, `walk to table` (approach furniture)
          - Aliases: run, jog, crawl, limp, strut, meander, stroll, sneak, sprint, fly, swagger, stride, march, hike, creep, shuffle, amble, trudge, wander, lumber, pad, skip, plod, shamble, patrol, sashay, stalk, stomp, pace, scramble, stagger, prowl, traipse, drift, saunter
  
        **Movement verbs affect description and speed:**
          - `walk north` → "Alice walks north."
          - `run north` → "Alice runs north." (faster)
          - `sneak north` → "Alice sneaks north." (slower)
          - `crawl east` → "Alice crawls east." (much slower)
  
        **Adverbs add flavor:** You can add an adverb (any word ending in -ly) to describe how you move:
          - `angrily run north` → "Alice angrily runs north."
          - `quietly sneak to tavern` → "Alice starts quietly sneaking toward the tavern."
          - `hastily walk to Main Street` → "Alice starts hastily walking toward Main Street."
  
        **Multi-room pathfinding:**
          - `walk to tavern` → Finds the shortest path and moves you there automatically
          - Shows progress: "You start walking toward the tavern..."
          - Stops at each intermediate room briefly
          - Type `stop` to cancel mid-journey
  
        ### Cardinal Direction Commands
  
        **north** or **n** - Move north
        **south** or **s** - Move south
        **east** or **e** - Move east
        **west** or **w** - Move west
        **up** or **u** - Move upstairs/climb
        **down** or **d** - Move downstairs/descend
  
        **Diagonal directions:**
        - **northeast** (ne), **northwest** (nw)
        - **southeast** (se), **southwest** (sw)
  
        **Interior movement:**
        - **in** or **enter** - Enter a building or interior room
        - **out** or **exit** - Leave to exterior
  
        **Note:** Direction commands are shortcuts for `walk <direction>`. They use the same pathfinding system.
  
        ### Stop - Cancel Movement
  
        **stop** - Stop whatever you're doing
          - Cancels multi-room walking
          - Stops following someone
          - Stops observing
          - Cancels a world journey
          - Aliases: halt
  
        **stop following** - Stop following (keeps moving if you were moving)
        **stop observing** - Stop observing
        **stop journey** - Cancel world journey
  
        ## Following and Leading
  
        ### Follow - Track Another Character
  
        `follow <character>` - Follow someone as they move
          - You automatically move with them when they change rooms
          - Works across multiple rooms
          - Continues until you type `stop` or `stop following`
          - Requires permission (they must allow you to follow)
  
        **Example:**
        ```
        follow Alice
        > You start following Alice.
  
        (Alice moves north)
        > You follow Alice north.
        ```
  
        ### Lead - Grant Follow Permission
  
        **lead** - Show who's currently following you
  
        `lead <character>` - Grant permission for someone to follow you
          - **PC (player character):** Grants follow permission
          - **NPC:** Asks the NPC to follow you (AI decides)
          - Aliases: allow, permit
  
        `lead stop <character>` - Revoke follow permission
          - Stops them from following you
          - Aliases: lead revoke
  
        **NPC leading:**
          - NPCs use AI to decide whether to follow you
          - Based on their relationship with you, personality, current task
          - Cooldown if they decline (prevents spam)
  
        ## Room Information
  
        ### Exits - View Available Directions
  
        **exits** - Show all passable exits from current room
          - Shows direction, arrow, and destination
          - Example: "↑ North (Main Street), ↓ South (Park)"
          - Includes "enter" exits for contained rooms
          - Only shows passable exits (no walls blocking)
  
        **Exit types:**
          - **Spatial exits:** Directions to adjacent rooms (north, south, etc.)
          - **Contained rooms:** Rooms inside this one (enter <name>)
  
        ### Places - View Furniture and Locations
  
        **places** - Show all furniture and notable locations in room
          - Aliases: furniture, spots
          - Shows name, description, capacity, occupants
          - Example: "Places: bar, booth, stage, pool table"
  
        ## Maps
  
        ### Map - Visual Room and Area Maps
  
        **map** - Show quickmenu of map types
          - Aliases: viewmap, maps
  
        **map room** - View interior layout of current room
          - Shows room boundaries, furniture, characters, exits
          - Canvas-based rendering
          - Blocked if blindfolded
          - Aliases: map interior, map floorplan, map rm
  
        **map area** - View surrounding terrain (hex-based world map)
          - Shows nearby terrain hexes
          - Requires location with world coordinates
          - Radius-based view centered on your location
          - Blocked if blindfolded
          - Aliases: map zone, map hex, map zonemap, map nearby
  
        **map city** - View city/zone overview
          - Shows your position on the city map
          - Displays map image with pin marker
          - Zone name displayed
  
        **map mini** - Toggle persistent minimap
          - Enables/disables small corner minimap
          - Stays visible as you move
  
        ## Finding Destinations
  
        ### Landmarks - List Public Places
  
        **landmarks** - Show all public places in your zone
          - Lists public rooms (no owner)
          - Grouped by location
          - Room type indicators: [Shop], [Bank], [Park], [Street], etc.
          - Aliases: public, locations, destinations
          - Use `walk <place name>` to travel there
  
        **Example output:**
        ```
        Public Places in Downtown
  
        Main Street:
          [Street] Main Street and 1st Avenue
          [Shop] General Store
          [Bank] First National Bank
  
        City Park:
          [Park] City Park Entrance
          [Water] Park Fountain
  
        Use 'walk <place name>' to travel there.
        ```
  
        ### Directory - Business Listings
  
        **directory** - View business directory for your area
          - Lists all shops in your zone
          - Grouped by location
          - Shows shop name and room name
          - Aliases: businesses, shops, yellowpages
          - Optional category filter: `directory food`, `directory clothing`
  
        **Example:**
        ```
        directory
        > Business Directory - Downtown
        > ========================================
        >
        > Main Street:
        >   General Store (Main Street and 1st)
        >   Coffee Shop (5th Avenue Cafe)
        >
        > Shopping District:
        >   Clothing Boutique (Fashion District)
        >
        > 3 business(es) listed.
        > Visit a shop and use 'list' to see their goods.
        ```
  
        ## Quick Travel
  
        ### Home - Head Home
  
        **home** - Walk home via pathfinding
          - Your character walks home through the game world (not instant)
          - Requires home to be set (use `sethome` in a room you own)
          - Cannot use while in combat
          - Falls back to instant teleport if no walkable route exists
          - Staff characters teleport instantly
          - Aliases: gohome
  
        ### Taxi - Call a Ride
  
        **taxi** - Call a taxi or view destination menu
          - Era-dependent (modern/sci-fi only)
          - Shows quickmenu of nearby public destinations
          - Aliases: hail, hail taxi, hail cab, call taxi, rideshare, uber, lyft, autocab
  
        `taxi to <destination>` - Travel by taxi to a destination
          - Finds destination by name
          - Starts automated journey
          - Example: `taxi to Main Street`, `taxi to park`
  
        **Era availability:**
          - **Modern/Contemporary:** Taxis, rideshares, autocabs
          - **Sci-fi/Future:** Autocabs, hover taxis
          - **Historical/Fantasy:** Not available (use walk or own transportation)
  
        ### Drive - Use Your Vehicle
  
        `drive to <destination>` - Drive your vehicle to a destination
          - Requires you to own a vehicle
          - Vehicle must be in current room (or you're inside it)
          - Starts automated journey
          - Cannot use while in combat
          - Examples: `drive to market`, `drive home`, `drive to 5th and oak`
  
        **Vehicle location:**
          - If your vehicle isn't here, error shows where it's parked
          - Example: "Your sedan is not here. It's parked at Main Street."
  
        ## Movement Mechanics
  
        ### Spatial Adjacency
  
        Rooms connect based on **physical layout**, not manual exits:
          - Rooms with shared edges are adjacent
          - Walls block passage unless there's an opening
          - Doors must be open to pass through
          - Archways and openings are always passable
  
        **Passability rules:**
          - **No wall:** Always passable (open plan)
          - **Wall with door:** Passable only if door is open
          - **Wall with archway:** Always passable
          - **Outdoor rooms:** Always passable to each other
  
        ### Pathfinding
  
        When you walk to a named destination:
          1. System finds shortest path using pathfinding algorithm
          2. Movement starts automatically
          3. You move through each room sequentially
          4. Brief pause at each room
          5. Arrival message when you reach destination
  
        **Pathfinding features:**
          - Avoids blocked paths (walls, closed doors)
          - Finds shortest route
          - Handles multi-floor navigation (up/down)
          - Stops if path becomes blocked mid-journey
  
        ### Followers
  
        When you move, your followers automatically move with you:
          - Followers see departure/arrival messages
          - Followers move to same room you entered
          - Followers stop if you stop
          - Multiple characters can follow you at once
  
        **Follower chain:**
          - Alice follows Bob, Bob follows Charlie
          - When Charlie moves, Bob follows, then Alice follows
          - Entire chain moves together
  
        ### Prisoners (Dragged/Carried)
  
        If you're dragging or carrying someone (prisoner mechanics):
          - They automatically move with you
          - **Drag:** Slower movement speed
          - **Carry:** Normal movement speed
          - Broadcasts show you dragging/carrying them
          - Use `release` to put them down
  
        ## Examples
  
        **Basic navigation:**
        ```
        exits
        > Main Street Exits: ↑ North (City Park), ↓ South (Downtown Square)
  
        north
        > You walk north.
        > City Park
  
        walk to tavern
        > You start walking toward the Old Tavern...
        > You arrive at the Old Tavern.
        ```
  
        **Following:**
        ```
        lead Alice
        > You grant Alice permission to follow you.
  
        (Alice types: follow Bob)
        > Alice starts following you.
  
        north
        > You walk north.
        > Alice follows you north.
        ```
  
        **Finding places:**
        ```
        landmarks
        > Public Places in Downtown
        > Main Street:
        >   [Street] Main Street and 1st Avenue
        >   [Shop] General Store
        >
        > Use 'walk <place name>' to travel there.
  
        walk to General Store
        > You start walking toward the General Store...
        > You arrive at the General Store.
        ```
  
        **Maps:**
        ```
        map room
        > (Shows ASCII art room layout with furniture and characters)
  
        map area
        > (Shows hex terrain map of surrounding area)
  
        map mini
        > Minimap enabled. A small map will be displayed in the corner.
        ```
  
        **Quick travel:**
        ```
        taxi
        > (Shows quickmenu of destinations)
  
        taxi to park
        > A taxi arrives. You hop in and head to City Park.
        > (Automated journey begins)
        > You arrive at City Park.
  
        home
        > You head home to Your Apartment.
        ```
  
        ## Tips
  
        - **Use exits** to see where you can go before moving
        - **Use landmarks** to discover new places in your area
        - **Use map room** to understand room layout and find furniture
        - **Follow others** to explore new areas together
        - **Set your home** with `sethome` in a room you own for quick returns
        - **Stop mid-journey** with `stop` if you change your mind
        - **Multi-room paths** show progress messages - don't panic if you see several rooms flash by
      GUIDE
      staff_notes: <<~'NOTES',
        ## Movement System Architecture
  
        ### Spatial Navigation Overview
        Firefly uses **spatial adjacency** for room connections. Rooms connect based on polygon geometry - if two rooms share an edge, players can move between them (subject to passability rules).
  
        **No manual exit creation required.** The system automatically calculates adjacency from room polygons.
  
        ### Core Services
  
        **RoomAdjacencyService (app/services/room_adjacency_service.rb):**
        ```ruby
        adjacent_rooms(room) → { north: [rooms], south: [rooms], ... }
          # Detects adjacent rooms by finding shared polygon edges
          # Groups by cardinal direction based on edge angle
          # Returns hash of direction → array of rooms
  
        resolve_direction_movement(room, direction) → room or nil
          # Finds the passable room in the specified direction
          # Checks RoomPassabilityService for each candidate
          # Returns first passable room, or nil if none
  
        contained_rooms(room) → [rooms]
          # Finds rooms geometrically inside this room
          # Checks if room polygon is entirely within parent polygon
          # Used for "enter <room>" navigation
        ```
  
        **RoomPassabilityService (app/services/room_passability_service.rb):**
        ```ruby
        can_pass?(from_room, to_room, direction) → Boolean
          # Checks if passage is allowed between adjacent rooms
          # Rules:
          # - No wall in direction → always passable
          # - Wall exists → check for opening (door/archway/gate)
          # - Door/gate → passable only if is_open: true
          # - Archway/opening → always passable
          # - Outdoor rooms → always passable to each other
  
        wall_in_direction?(room, direction) → Boolean
          # Checks if room has a wall feature in the specified direction
  
        opening_in_direction?(room, direction) → RoomFeature or nil
          # Finds door/archway/gate in the specified direction
          # Returns the feature if found, nil otherwise
        ```
  
        **MovementService (app/services/movement_service.rb):**
        ```ruby
        start_movement(character_instance, target:, adverb:)
          # Unified entry point for all movement
          # Uses TargetResolverService to interpret target
          # Routes to appropriate movement type:
          # - :exit → start_exit_movement (single room)
          # - :room → start_pathfind_movement (multi-room)
          # - :character → start_character_movement (follow to their room)
          # - :furniture → approach_furniture (same room, just reposition)
  
        start_exit_movement(character_instance, exit, adverb)
          # Single-room movement (no pathfinding)
          # Queues MovementAction in Redis
          # MovementHandler processes action and calls complete_room_transition
  
        start_pathfind_movement(character_instance, destination_room, adverb)
          # Multi-room movement with pathfinding
          # PathfindingService.find_path(from, to) → array of rooms
          # Stores final_destination_id
          # Starts movement to first room in path
          # After each room, continue_to_destination checks if more steps needed
  
        complete_room_transition(character_instance, room_exit)
          # Core transition logic (called by MovementHandler)
          # 1. Broadcast departure from old room
          # 2. Update room_players Redis set
          # 3. Update character_instance: current_room_id, x, y, z
          # 4. Broadcast arrival in new room
          # 5. Clear interaction context
          # 6. Move followers
          # 7. Move prisoners (dragged/carried)
          # 8. Check if need to continue to final destination
        ```
  
        **PathfindingService (app/services/pathfinding_service.rb):**
        ```ruby
        find_path(from_room, to_room) → [rooms] or nil
          # A* pathfinding algorithm
          # Uses RoomAdjacencyService for neighbors
          # Checks RoomPassabilityService for each edge
          # Returns array of rooms (including start and end)
          # Returns nil if no path exists
  
        # Cost function: 1 per room (uniform cost)
        # Heuristic: Euclidean distance based on room coordinates
        ```
  
        **TargetResolverService (app/services/target_resolver_service.rb):**
        ```ruby
        resolve_movement_target(target_string, character_instance)
          # Interprets target string and returns resolution result
          # Priority order:
          # 1. Direction words (north, south, etc.) → :exit
          # 2. Room name match → :room
          # 3. Character name match → :character
          # 4. Furniture/place name match → :furniture
          # 5. Exit name match → :exit
  
        # Result struct:
        Result = Struct.new(:type, :target, :error, :exit, keyword_init: true)
          # type: :exit, :room, :character, :furniture, :error, :ambiguous
          # target: The matched object (room, character, furniture)
          # exit: SpatialExit struct (for :exit type)
          # error: Error message (for :error type)
        ```
  
        ### MovementHandler (app/handlers/movement_handler.rb)
  
        **Background job system for movement processing:**
        ```ruby
        # Redis queue: movement_actions:#{character_instance.id}
        # Each action: { action: 'move', exit_id:, direction:, adverb:, timestamp: }
  
        process_action(character_instance, action_data)
          # Retrieves action from Redis
          # Validates character can still move
          # Constructs SpatialExit from action data
          # Calls MovementService.complete_room_transition
          # Removes action from Redis on completion
        ```
  
        **Action lifecycle:**
        1. Command calls MovementService.start_movement
        2. MovementService queues action in Redis
        3. MovementHandler background job polls Redis
        4. MovementHandler processes action
        5. MovementService.complete_room_transition executes transition
        6. Action removed from Redis
  
        **Why Redis queue?**
        - Decouples command execution from movement processing
        - Allows cancellation (clear queue to stop movement)
        - Enables synchronized movement for followers/prisoners
        - Prevents race conditions during multi-room pathfinding
  
        ### SpatialExit Struct
  
        **Lightweight exit representation for spatial navigation:**
        ```ruby
        SpatialExit = Struct.new(:to_room, :direction, :from_room, keyword_init: true)
          # No database record - constructed on-the-fly
          # Provides interface compatibility with legacy RoomExit code
  
        Methods:
          can_pass? → delegates to RoomPassabilityService
          locked? → always false (locks are on RoomFeatures, not exits)
          opposite_direction → calculates reverse direction
        ```
  
        **Direction opposites:**
        - north ↔ south
        - east ↔ west
        - northeast ↔ southwest
        - northwest ↔ southeast
        - up ↔ down
  
        ### Commands Implementation
  
        **Walk Command (plugins/core/navigation/commands/walk.rb - 115 lines):**
        ```ruby
        # Already read in previous system
        # Uses MovementService.start_movement
        # 35+ adverb aliases (walk, run, jog, crawl, etc.)
        # Handles disambiguation with quickmenus
        # Strips "to " prefix from input
        # Returns movement_data with duration, destination, path_length
        ```
  
        **Direction Commands (plugins/core/navigation/commands/directions.rb - 184 lines):**
        ```ruby
        # Base class: DirectionCommand
        # Subclasses: North, South, East, West, Up, Down, NE, NW, SE, SW, In, Out
        # Each delegates to Move command: move_command.execute("move #{direction}")
        # All registered individually
  
        # Pattern:
        class North < DirectionCommand
          command_name 'north'
          aliases 'n'
          def self.direction; 'north'; end
        end
        ```
  
        **Follow Command (plugins/core/navigation/commands/follow.rb - 67 lines):**
        ```ruby
        perform_command(parsed_input)
          # Find target with disambiguation
          # Check lead/follow permission (UserPermission.lead_follow_allowed?)
          # Call MovementService.start_following(actor, target)
          # Sets character_instance.following_id = target.id
  
        # Permission check:
        UserPermission.lead_follow_allowed?(actor_user, target_user)
          # Checks if target has blocked actor from following
        ```
  
        **Lead Command (plugins/core/navigation/commands/lead.rb - 164 lines):**
        ```ruby
        # Two modes: PC lead vs NPC lead
  
        handle_pc_lead(target)
          # Grants follow permission to PC
          # Calls MovementService.grant_follow_permission
          # Stores permission grant (not explicit DB record, just not blocked)
  
        handle_npc_lead(npc_instance)
          # Asks NPC to follow via NpcLeadershipService
          # NpcLeadershipService.request_lead (async LLM decision)
          # NPC decides based on relationship, personality, current task
          # Cooldown if NPC declines
  
        revoke_permission(target_name)
          # Calls MovementService.revoke_follow_permission
          # If target is currently following, stops them
          # Adds block for future follow attempts
  
        show_current_followers()
          # Queries CharacterInstance.where(following_id: self.id, online: true)
          # Shows list of current followers
        ```
  
        **Stop Command (plugins/core/navigation/commands/stop.rb - 122 lines):**
        ```ruby
        # Multi-purpose stop command
  
        stop_movement() → MovementService.stop_movement
          # Cancels movement action in Redis
          # Sets movement_state = 'idle'
          # Clears final_destination_id
          # Broadcasts stop message
  
        stop_following() → MovementService.stop_following
          # Clears character_instance.following_id
          # Broadcasts stop message
  
        stop_observing()
          # Calls character_instance.stop_observing!
          # Clears observing_id, observing_type, observed_place_id
  
        stop_journey()
          # Calls WorldTravelService.cancel_journey
          # For world map travel (different from local movement)
        ```
  
        **Exits Command (plugins/core/navigation/commands/exits.rb - 96 lines):**
        ```ruby
        perform_command(_parsed_input)
          # Gets passable_spatial_exits from room
          # Also checks contained_rooms (enterable via "enter")
          # Builds display strings with arrows and room names
  
        DIRECTION_ARROWS = {
          'north' => '↑', 'south' => '↓', 'east' => '→', 'west' => '←',
          'northeast' => '↗', 'northwest' => '↖', 'southeast' => '↘', 'southwest' => '↙',
          'up' => '⇑', 'down' => '⇓'
        }
  
        # Structured data for client includes:
        # - direction, direction_arrow, to_room_name, to_room_id, distance, exit_type
        ```
  
        **Map Command (plugins/core/navigation/commands/map.rb - 353 lines):**
        ```ruby
        # Four map types: room, area, city, mini
  
        render_room_map()
          # Uses RoommapRenderService if available
          # Fallback: generate_room_canvas (canvas commands)
          # Shows room boundaries, furniture, characters, exits
          # Canvas format: "width|||height|||command1;;;command2;;;..."
          # Commands: line, rect, frect, circle, fcircle, text
  
        render_zone_map()
          # Uses ZonemapService for hex terrain rendering
          # Requires location.has_hex_coords? and world_id
          # Shows surrounding terrain hexes
          # Center: location longitude/latitude
          # Radius: ZonemapService::RADIUS
  
        render_city_map()
          # Generates HTML with background map image
          # Shows pin marker at character position
          # Calculates position percentage from zone bounds
          # Map images: /images/maps/#{zone_name}.png
  
        toggle_minimap()
          # character_instance.toggle_minimap!
          # Enables/disables minimap_enabled flag
          # Client shows persistent corner minimap when enabled
        ```
  
        **Places Command (plugins/core/navigation/commands/places.rb - 55 lines):**
        ```ruby
        # Simple listing of room.visible_places
        # Shows capacity and current occupants
        # Structured data includes: id, name, description, is_furniture, capacity, occupants
        ```
  
        **Home Command (plugins/core/navigation/commands/home.rb):**
        ```ruby
        # Non-staff: Uses MovementService.move_to_room for pathfinding walk home
        # Staff: Instant teleport (direct coordinate update)
        # Falls back to teleport if no walkable route exists
        # Checks character.home_room (set with sethome command)
        # Blocked during combat
        ```
  
        **Landmarks Command (plugins/core/navigation/commands/landmarks.rb - 100 lines):**
        ```ruby
        find_public_rooms(zone)
          # Queries rooms in zone with owner_id = nil
          # Public rooms only (no private ownership)
          # Grouped by location name
  
        room_type_icon(room_type)
          # Maps room types to display icons
          # [Shop], [Bank], [Park], [Water], [Street], [Building], etc.
        ```
  
        **Directory Command (plugins/core/info/commands/directory.rb - 96 lines):**
        ```ruby
        find_shops_in_zone(zone)
          # Queries Shop.where(room_id: room_ids_in_zone)
          # Returns all shops in the zone
          # Grouped by location name
  
        # Optional category filter (not currently implemented)
        # Future: filter by shop category (food, clothing, etc.)
        ```
  
        **Taxi Command (plugins/core/navigation/commands/taxi.rb - 100+ lines):**
        ```ruby
        # Era check: EraService.taxi_available?
        # Not available in historical/fantasy eras
  
        show_taxi_menu()
          # Finds public rooms in zone (limit 8)
          # Creates quickmenu with destinations
          # Option to "just call a taxi" without destination
  
        travel_by_taxi(destination)
          # TaxiService.start_journey (not shown in excerpt)
          # Automated journey to destination
          # Similar to world travel but local (within zone)
        ```
  
        **Drive Command (plugins/core/vehicles/commands/drive.rb - 100 lines):**
        ```ruby
        find_vehicle_here()
          # Checks current_vehicle_id (already in vehicle)
          # Or finds owned vehicle in current room
          # Status must be 'parked'
  
        resolve_destination(target)
          # Uses TargetResolverService.resolve_movement_target
          # Returns room from :room or :exit result types
  
        # VehicleTravelService.start_journey (not shown)
        # Automated journey with vehicle
        ```
  
        ### Follower Movement
  
        **MovementService.move_followers:**
        ```ruby
        def move_followers(leader_instance, room_exit, adverb)
          followers = CharacterInstance.where(following_id: leader_instance.id, online: true).all
  
          followers.each do |follower|
            # Skip if follower can't move (in combat, knocked out, etc.)
            next unless can_follow?(follower)
  
            # Move follower through same exit
            follower_exit = SpatialExit.new(
              from_room: follower.current_room,
              to_room: room_exit.to_room,
              direction: room_exit.direction
            )
  
            complete_room_transition(follower, follower_exit)
          end
        end
        ```
  
        ### Prisoner Movement
  
        **MovementService.move_prisoners:**
        ```ruby
        def move_prisoners(leader_instance, new_room, adverb)
          # Check if dragging someone
          if leader_instance.dragging_prisoner_id
            prisoner = CharacterInstance[leader_instance.dragging_prisoner_id]
            move_prisoner(prisoner, new_room, leader_instance, type: :drag)
          end
  
          # Check if carrying someone
          if leader_instance.carrying_prisoner_id
            prisoner = CharacterInstance[leader_instance.carrying_prisoner_id]
            move_prisoner(prisoner, new_room, leader_instance, type: :carry)
          end
        end
  
        def move_prisoner(prisoner, new_room, leader, type:)
          old_room = prisoner.current_room
  
          # Broadcast drag/carry messages
          if type == :drag
            MovementBroadcaster.broadcast_dragging(leader, prisoner, old_room, new_room)
          else
            MovementBroadcaster.broadcast_carrying(leader, prisoner, old_room, new_room)
          end
  
          # Move prisoner to new room
          prisoner.update(current_room_id: new_room.id, x: 50.0, y: 50.0, z: 0.0)
        end
        ```
  
        ### Movement Speed Modifiers
  
        **Config (config/movement.rb):**
        ```ruby
        module MovementConfig
          BASE_SPEED = 1.0
          DRAG_SPEED_MODIFIER = 0.5  # Dragging is 50% slower
          RUN_SPEED_MODIFIER = 1.5   # Running is 50% faster
          CRAWL_SPEED_MODIFIER = 0.7 # Crawling is 30% slower
          # ... other adverb modifiers
        end
        ```
  
        **Applied in MovementService:**
        - Affects duration of movement action
        - Stored in Redis action: `duration: base_time * speed_modifier`
        - MovementHandler waits for duration before processing
  
        ### Edge Cases and Gotchas
  
        **Spatial adjacency edge cases:**
        - Rooms with shared corners (not edges) are NOT adjacent
        - Diagonal walls can create unexpected adjacency (geometry-based)
        - Contained rooms detected by full containment (partial overlap ignored)
  
        **Pathfinding failure scenarios:**
        - No path exists (disconnected areas)
        - All paths blocked by closed doors
        - Target room not in same zone (pathfinding zone-scoped)
  
        **Follow chain limits:**
        - No hard limit on follower count
        - Performance degrades with 10+ followers (broadcasts multiply)
        - Consider adding follower limit per character
  
        **Movement state cleanup:**
        - movement_state cleared on: successful arrival, stop command, disconnect
        - final_destination_id cleared on: arrival at destination, stop command
        - following_id cleared on: stop following, leader disconnect, follower disconnect
  
        **Direction resolution:**
        - Multiple rooms in same direction → returns first (arbitrary)
        - Ambiguous matches show quickmenu for disambiguation
        - Direction names are fuzzy matched (min 4 chars: "nort" matches "north")
  
        **Taxi/Drive era restrictions:**
        - EraService.taxi_available? checks current timeline's era
        - Historical/fantasy eras return false
        - Modern/sci-fi eras return true
        - Prevents anachronistic transportation
  
        **Home command behavior:**
        - Non-staff: Pathfinds home (walks through rooms, takes time)
        - Staff: Instant teleport
        - Falls back to teleport if no walkable route exists
        - Blocked during combat
        - Requires ownership of home room
  
        **Map rendering performance:**
        - Room maps: O(places + characters) complexity
        - Zone maps: O(hex_count) complexity (radius-based)
        - Canvas generation is CPU-intensive for large rooms
        - Consider caching canvas strings for static rooms
      NOTES
      display_order: 35
    },
    {
      name: 'world_travel',
      display_name: 'World Travel',
      summary: 'Long-distance journeys, taxis, vehicles, weather, and time',
      description: "Commands for traveling between locations across the world map. The journey system uses hex-grid pathfinding with terrain-based travel costs. Taxis and vehicles provide transportation between landmarks. The flashback system rewards active roleplay by letting characters skip travel time. Three flashback modes offer different tradeoffs. Vehicles (cars, boats, aircraft) can be owned and operated. Time and weather commands show current world conditions.",
      command_names: %w[journey eta],
      related_systems: %w[local_movement timelines world_memory],
      key_files: [
        'plugins/core/navigation/commands/journey.rb',
        'plugins/core/navigation/commands/eta.rb',
        'app/services/world_travel_service.rb',
        'app/services/flashback_travel_service.rb',
        'app/services/flashback_time_service.rb',
        'app/services/journey_service.rb',
        'app/services/world_travel_processor_service.rb',
        'app/services/globe_pathfinding_service.rb',
        'app/models/world_journey.rb',
        'app/models/world_journey_passenger.rb',
        'app/models/travel_party.rb',
        'app/models/travel_party_member.rb',
        'app/models/world_hex.rb',
        'app/lib/world_hex_grid.rb'
      ],
      player_guide: <<~'GUIDE',
        # World Travel Commands
  
        Firefly provides long-distance travel between cities and locations across the game world. The journey system uses a globe hex grid with realistic terrain-based pathfinding. Travel can be done solo or with a party, and the **flashback time system** rewards active roleplay by letting you reduce or skip journey time.
  
        ## Journey Command
  
        **journey** - Main world travel command with multiple subcommands:
          - **journey** - Shows journey status if traveling, otherwise opens world map GUI
          - `journey to <destination>` - Plan travel to a city or location
          - **journey party** - View travel party status (while assembling)
          - **journey passengers** - View who's on your current journey (while traveling)
          - `journey invite <name>` - Invite someone to your travel party
          - **journey launch** - Start party journey once assembled
          - **journey cancel** - Disband your travel party
          - **journey return** - Return from flashback instance to origin
          - **journey disembark** - Leave your current journey early (wilderness)
          - Aliases: world_travel, voyage, travel
  
        ### Planning a Journey
  
        `journey to <destination>` - Shows travel options quickmenu:
  
        **Standard Travel:**
          - Normal journey time based on distance and vehicle
          - All passengers travel together in a shared vehicle room
          - Can see ETA with `eta` command during journey
          - Vehicle type depends on game era and route:
            - **Land:** horse, carriage, car, maglev, hovercar
            - **Water:** ferry, steamship, hydrofoil, hovercraft
            - **Rail:** steam train, train, maglev
            - **Air:** airplane, aircraft, shuttle (modern+ eras only)
  
        **Flashback Travel:**
          - Uses accumulated flashback time to reduce/eliminate journey time
          - Three modes with different tradeoffs (see Flashback System below)
          - Flashback time accumulates while you're not actively RPing
          - Rewards active players who spend time roleplaying
  
        ### Journey Segments
  
        Some journeys have **multiple segments** with transfers:
          - **Rail journeys:** If rail doesn't reach destination, transfers to land vehicle partway
          - **Water journeys:** If water route impossible, falls back to land
          - Message shows: "Horse to transfer point, then continue by coach."
          - Transfer happens automatically when you reach the transfer hex
  
        ### ETA Command
  
        **eta** - Check journey status while traveling
          - Aliases: arrival, travel_status, journey_status
          - Shows:
            - Destination name
            - Vehicle type (horse, ship, train, etc.)
            - Current terrain you're passing through
            - Distance remaining in hexes
            - Estimated arrival time
  
        Example:
        ```
        eta
        > === Journey Status ===
        > Destination: Ravencroft
        > Vehicle: Carriage
        > Current terrain: rolling grasslands
        > Distance remaining: 15 hexes
        > Estimated arrival: 22 minutes
        ```
  
        ### Disembarking Early
  
        **journey disembark** - Leave your journey before arriving:
          - Aliases: journey leave, journey exit
          - Drops you in wilderness at current hex
          - Creates a temporary waypoint room based on terrain
          - Other passengers are notified you left
          - If you're the only passenger, journey is cancelled
  
        ## Party Travel
  
        Travel with friends! Assemble a group, invite members, and journey together.
  
        ### Creating a Travel Party
  
        1. **Plan destination:** `journey to Ravencroft`
        2. **Select travel mode** from quickmenu
        3. **Choose "Assemble Party"** option
        4. **Invite members:** `journey invite Alice`, `journey invite Bob`
        5. **Wait for acceptances** - Members receive quickmenu invites
        6. **Launch when ready:** `journey launch`
  
        **Party commands:**
          - **journey party** - View party status, members, acceptances
          - `journey invite <name>` - Invite someone in your location
          - **journey launch** - Start the journey (leader only)
          - **journey cancel** - Disband party (leader only)
  
        **Member responses:**
          - Members receive quickmenu: Accept or Decline
          - Can also type `accept` or `decline` directly
          - Leader can launch with only accepted members
          - Declined/pending invites are left behind
  
        **During party travel:**
          - All members travel in the same vehicle
          - Use `journey passengers` to see who's aboard
          - Anyone can disembark early (but leader continues)
          - If everyone disembarks, journey is cancelled
  
        ## Flashback System
  
        **Flashback time** accumulates when you're **not actively roleplaying**. It represents downtime your character has "offscreen" that can be spent on travel.
  
        ### How Flashback Time Works
  
        **Accumulation:**
          - Time accumulates while you're logged in but not RPing
          - Resets when you perform IC actions (say, emote, whisper, etc.)
          - Caps at 12 hours maximum
          - Check with `/status` or in journey planning menu
  
        **Usage:**
          - Spend flashback time to reduce journey time
          - Three modes with different tradeoffs
          - Party travel uses **minimum flashback time** across all members
  
        ### Flashback Mode: Basic
  
        **How it works:**
          - Spends your flashback time to reduce journey time
          - If you have enough, arrival is **instant**
          - If partial coverage, journey time is reduced
          - **Not instanced** - you arrive in the normal world
  
        **Example:**
          - Journey to Ravencroft: 30 minutes
          - You have 45 minutes flashback time
          - Result: **Instant arrival**, 30 minutes consumed, 15 minutes remain
  
        **Example (partial):**
          - Journey to Ravencroft: 30 minutes
          - You have 10 minutes flashback time
          - Result: Journey takes 20 minutes, 10 minutes consumed
  
        ### Flashback Mode: Return
  
        **How it works:**
          - Reserves **half** your flashback time for the return trip
          - Uses the other half to travel there
          - You arrive in an **instanced version** of the destination
          - Can only interact with party members (if any)
          - Use **journey return** to go back to origin
  
        **Instancing:**
          - You're in a private instance of the destination
          - NPCs and other players can't see you
          - Only you and your co-travelers exist there
          - Useful for quick visits without affecting the live world
  
        **Example:**
          - Journey to Ravencroft: 20 minutes
          - You have 40 minutes flashback time
          - Uses 20 minutes for travel (instant arrival)
          - Reserves 20 minutes for return (instant return)
          - Result: Instant arrival in instanced Ravencroft
  
        **Returning:**
          - **journey return** - Return to your exact origin room
          - Uses reserved flashback time
          - If not enough reserved, creates a reduced-time journey back
          - Clears instanced state, returns you to normal world
  
        ### Flashback Mode: Backloaded
  
        **How it works:**
          - **Instant arrival** at destination (no flashback time spent)
          - You're **instanced** like Return mode
          - When you return, it takes **2x the normal journey time**
          - Creates a "time debt" that must be paid on return
  
        **Use case:**
          - Emergency travel when you don't have flashback time
          - Quick visit knowing return will be slow
          - Works for journeys up to 12 hours maximum
  
        **Example:**
          - Journey to Ravencroft: 30 minutes
          - You have 0 minutes flashback time
          - Result: Instant arrival in instanced Ravencroft
          - Return journey will take 60 minutes (2x)
  
        **Returning:**
          - **journey return** - Starts return journey
          - Takes double the original journey time
          - No flashback time used (debt was the instant arrival)
  
        ### Flashback Time Tips
  
        - **Plan ahead:** Accumulate time before long journeys
        - **Check before traveling:** Journey menu shows your available time
        - **Party travel:** Uses minimum time across all members
        - **Basic mode is safest:** No instancing, just time savings
        - **Return mode for quick visits:** Good for instanced exploration
        - **Backloaded for emergencies:** Instant there, slow return
  
        ## Travel Modes
  
        Different terrain and infrastructure support different travel modes:
  
        **Land Travel (always available):**
          - Vehicle: Horse, carriage, car, hovercar (depends on era)
          - Travels overland avoiding water
          - Automatically finds roads/paths when available
          - Slower through mountains, faster on roads
  
        **Water Travel:**
          - Requires: **Port** at origin and destination
          - Vehicle: Ferry, steamship, hydrofoil, hovercraft
          - Travels across oceans and lakes
          - Faster than land for long sea routes
  
        **Rail Travel:**
          - Requires: **Train station** at origin and destination
          - Vehicle: Steam train, train, maglev
          - Follows railway networks
          - Very fast, but limited coverage
          - If rail doesn't reach destination, transfers to land
  
        **Air Travel:**
          - Requires: Modern+ era (not available in medieval/gaslight)
          - Vehicle: Airplane, aircraft, shuttle
          - Fastest travel mode
          - Direct routes ignoring terrain
  
        **Multi-segment journeys:**
          - System plans optimal route
          - May combine rail + land, or water + land
          - Transfer happens automatically at connection points
          - Message shows full route when planning
  
        ## During a Journey
  
        While traveling, you're in a **vehicle room** with other passengers:
          - Can talk, emote, roleplay with passengers
          - Use **journey passengers** to see who's aboard
          - Use **eta** to check progress
          - Use **journey disembark** to leave early
          - Can't interact with the outside world (you're in motion)
  
        **Journey progression:**
          - Journey moves one hex at a time
          - WorldTravelProcessorService advances every minute
          - Time per hex depends on vehicle speed and era
          - Terrain affects speed (mountains slower, roads faster)
  
        **Arrival:**
          - Automatically placed in destination city
          - Usually a street or plaza (public room)
          - Broadcast message to passengers
          - Journey record marked as 'arrived'
  
        ## Examples
  
        **Solo standard travel:**
        ```
        journey to Ravencroft
        > Journey to Ravencroft?
        > [Standard Travel (25 minutes)] - Travel normally to Ravencroft
        > [Flashback (Instant)] - Arrive instantly using 25 minutes flashback time
        > [Cancel]
  
        (Select Standard Travel)
        > You begin your journey to Ravencroft by carriage.
  
        eta
        > === Journey Status ===
        > Destination: Ravencroft
        > Vehicle: Carriage
        > Distance remaining: 18 hexes
        > Estimated arrival: 22 minutes
        ```
  
        **Party travel:**
        ```
        journey to Ravencroft
        > (Select "Assemble Party")
  
        journey invite Alice
        > Invited Alice to the travel party.
  
        journey invite Bob
        > Invited Bob to the travel party.
  
        journey party
        > Travel Party to Ravencroft:
        > Members:
        >   Charlie [LEADER]: ✓ accepted
        >   Alice: ✓ accepted
        >   Bob: ... pending
  
        journey launch
        > Your party of 2 begins the journey to Ravencroft.
        > (Bob was pending, left behind)
  
        journey passengers
        > === Passengers aboard the Carriage ===
        > - Charlie (you, driving)
        > - Alice
        > Destination: Ravencroft
        > ETA: 25 minutes
        ```
  
        **Flashback return travel:**
        ```
        journey to Ravencroft
        > (Select "Flashback Return (Instanced)")
        > You arrive at Ravencroft via flashback return travel.
        > You are instanced and can only interact with your co-travelers.
        > Use 'journey return' to travel back.
  
        (Explore instanced Ravencroft)
  
        journey return
        > Using reserved flashback time, you return instantly to Main Street.
        ```
  
        **Disembarking early:**
        ```
        (During journey)
        journey disembark
        > You disembark and find yourself in Open Plains.
        > (Wilderness waypoint room created at current hex)
        ```
  
        ## Tips
  
        - **Use flashback for long trips:** Accumulate time, then travel instantly
        - **Party travel for groups:** Assemble before launching to travel together
        - **Check eta during journey:** See progress and estimated arrival
        - **Multi-segment routes:** Rail or water may transfer to land partway
        - **Return mode for quick visits:** Good for instanced exploration without affecting live world
        - **Basic mode is simplest:** No instancing, just time reduction
        - **Disembark if needed:** Can leave journey early in wilderness
        - **Plan ahead:** Long journeys take real time, use flashback to skip
      GUIDE
      staff_notes: <<~'NOTES',
        ## World Travel System Architecture
  
        The world travel system handles long-distance journeys across a **globe hex grid**. Locations have globe_hex_id coordinates (latitude/longitude) and journeys pathfind across WorldHex terrain. Three travel options: standard (normal journey time), flashback (use accumulated time), and party (group travel).
  
        ### Core Services
  
        **WorldTravelService (app/services/world_travel_service.rb - 857 lines):**
        ```ruby
        # Handles long-distance travel between locations on globe hex grid
        # Characters on journey are placed in shared "traveling room"
        # Travel speed affected by era, vehicle type, terrain, roads
  
        start_journey(character_instance, destination:, travel_mode:, vehicle_type:)
          # Validates locations have globe_hex_id
          # Plans journey segments (handles partial rail/water with land fallback)
          # Creates WorldJourney record with path_remaining (array of globe_hex_id)
          # Adds character as passenger and driver
          # Returns { success:, journey:, message: }
  
        plan_journey_segments(origin:, destination:, travel_mode:)
          # Returns array of segments: [{ mode:, vehicle:, path:, start_hex:, end_hex: }]
          # Calls plan_rail_segments, plan_water_segments, or plan_land_segments
          # Rail segments: find furthest rail point via BFS, then land for remainder
          # Water segments: try full water path, fallback to land if impossible
          # Land segments: always works, GlobePathfindingService.find_path
  
        board_journey(character_instance, journey)
          # Add character to existing journey as passenger
          # Must be at same globe_hex_id as journey.current_globe_hex_id
          # Creates WorldJourneyPassenger record
  
        disembark(character_instance)
          # Remove passenger from journey
          # Find/create waypoint room at current hex (wilderness location)
          # Teleports character to waypoint
          # Cancels journey if no passengers remain
  
        journey_eta(journey)
          # Returns hexes_remaining, time_remaining, arrival_time, destination
          # Uses journey.time_remaining_display
  
        estimate_arrival_time(journey)
          # total_seconds = path_remaining.length * journey.time_per_hex_seconds
          # Returns Time.now + total_seconds
  
        cancel_journey(character_instance, reason:)
          # Only driver or solo passenger can cancel
          # Calls journey.cancel! (moves all passengers to waypoint)
  
        calculate_route(origin:, destination:, travel_modes:)
          # Returns { success:, routes: [] } with multiple route options
          # Each route: { travel_mode:, vehicle:, path_length:, estimated_seconds:, path_preview: }
          # Sorts by estimated_seconds (fastest first)
  
        # Private helpers:
        find_or_create_waypoint_room(world, globe_hex_id)
          # Finds existing location at hex, or creates wilderness location
          # Creates Room in location with terrain-appropriate name/description
          # Returns room for disembark or journey cancellation
  
        plan_rail_segments(world, origin, destination)
          # Try full rail path first via GlobePathfindingService
          # If fails, find furthest_rail_point via BFS (explore all reachable railway hexes)
          # Return closest reachable hex to destination
          # Split into rail segment + land segment
  
        find_furthest_rail_point(world, origin, destination)
          # BFS to find ALL reachable railway hexes from origin
          # Railway hexes have directional_feature == 'railway'
          # Returns reachable hex closest to destination (great circle distance)
          # Uses WorldHex.neighbors_of and direction_between_hexes
  
        direction_between_hexes(from_hex, to_hex)
          # Calculate direction from lat/lon difference
          # Returns one of: 'n', 'ne', 'se', 's', 'sw', 'nw'
          # Uses atan2 angle calculation
        ```
  
        **FlashbackTravelService (app/services/flashback_travel_service.rb - 486 lines):**
        ```ruby
        # Handles three flashback travel modes:
        # 1. Basic - Use flashback time to reduce journey, travel normally
        # 2. Return - Reserve time for return, traveler instanced at destination
        # 3. Backloaded - Instant arrival, return takes 2x time
  
        start_flashback_journey(character_instance, destination:, mode:, co_travelers:)
          # Calculates journey_seconds via estimate_journey_time
          # Calls FlashbackTimeService.calculate_flashback_coverage
          # Routes to start_basic_journey, start_return_journey, or start_backloaded_journey
          # Returns { success:, message:, journey:, instanced: }
  
        start_basic_journey(character_instance, destination, coverage, co_travelers)
          # If coverage[:can_instant] → instant_arrival (teleport)
          # Else → start_reduced_journey (WorldTravelService with speed boost)
  
        start_return_journey(character_instance, destination, coverage, co_travelers, journey_seconds)
          # Requires coverage[:can_instant] (needs 2x journey time)
          # Enters instanced state via character_instance.enter_flashback_instance!
          # Sets mode: 'return', reserved_time: coverage[:reserved_for_return]
          # Teleports to destination (instanced)
          # Co-travelers also instanced with cross-references
  
        start_backloaded_journey(character_instance, destination, coverage, co_travelers, journey_seconds)
          # Instant arrival, no flashback time check
          # Enters instanced state with mode: 'backloaded', return_debt: journey_seconds * 2
          # Teleports to destination (instanced)
  
        end_flashback_instance(character_instance)
          # Ends instanced state and returns to origin
          # For 'return' mode → handle_return_with_reserved_time (instant if enough time)
          # For 'backloaded' mode → handle_backloaded_return (start 2x journey back)
          # Clears character_instance.flashback_instanced state
  
        estimate_journey_time(character_instance, destination)
          # Calculate hex distance via calculate_hex_distance (great circle)
          # base_time_per_hex = WorldJourney::BASE_TIME_PER_HEX
          # vehicle_multiplier = 3.0 (modern car estimate)
          # era_multiplier = 2.0 (modern)
          # Returns (hex_distance * effective_time).round
  
        travel_options(character_instance, destination)
          # Returns { journey_time:, flashback_available:, basic:, return:, backloaded: }
          # Each mode has { success:, can_instant:, time_remaining:, flashback_used:, ... }
  
        # Private helpers:
        instant_arrival(character_instance, destination, co_travelers)
          # Teleport to destination (not instanced)
          # Touch RP activity timestamp
  
        start_reduced_journey(character_instance, destination, remaining_time_seconds, co_travelers)
          # Start WorldTravelService journey
          # Apply speed_boost: base_time / remaining_time
          # Update journey.speed_modifier and estimated_arrival_at
  
        handle_return_with_reserved_time(character_instance, origin_room)
          # Check if reserved_time >= return_journey_time
          # If yes → instant return (teleport)
          # If no → start journey with speed boost for time saved
          # Sets journey.return_to_room_id = origin_room.id for exact return
  
        handle_backloaded_return(character_instance, origin_room)
          # Start journey with return_debt time (2x original)
          # Calculate speed_modifier to achieve debt time
          # Sets journey.return_to_room_id = origin_room.id
  
        calculate_hex_distance(origin, destination)
          # WorldHex.great_circle_distance_rad(lat1, lon1, lat2, lon2)
          # Returns (distance_rad * 6371 / 5).round
          # Earth radius 6371km, 1 hex ~5km
        ```
  
        **JourneyService (app/services/journey_service.rb - 402 lines):**
        ```ruby
        # Unified facade coordinating WorldTravelService, FlashbackTravelService, TravelParty
        # Single interface for journey command and API
  
        travel_options(character_instance, destination)
          # Combines flashback options with travel mode detection
          # Returns { success:, destination:, origin:, hex_distance:, journey_time:,
          #           available_modes:, flashback:, standard: }
  
        start_journey(character_instance, destination:, travel_mode:, flashback_mode:)
          # If flashback_mode → FlashbackTravelService.start_flashback_journey
          # Else → WorldTravelService.start_journey
  
        start_party_journey(travelers:, destination:, travel_mode:, flashback_mode:, co_traveler_ids:)
          # Multi-traveler journey
          # For return/backloaded → start_instanced_party_journey (all enter instance)
          # For basic → start_basic_party_journey (instant if min flashback covers)
          # For standard → start_standard_party_journey (all board same journey)
  
        world_map_data(character_instance)
          # Returns { world:, current_location:, bounds:, locations:, terrain:, flashback_available: }
          # For world map GUI
  
        available_destinations(character_instance)
          # Returns array of destinations with hex_distance, journey_time
          # Sorted by distance
  
        # Private helpers:
        determine_available_modes(origin, destination)
          # Returns ['land'] always
          # Adds 'water' if both have_port
          # Adds 'rail' if both have_train_station
          # Adds 'air' if modern+ era
  
        start_instanced_party_journey(travelers, destination, mode, coverage)
          # All travelers enter_flashback_instance! with co_traveler cross-refs
          # All teleport to arrival room
          # Returns { success:, message:, instanced:, traveler_count: }
  
        start_basic_party_journey(travelers, destination)
          # Use minimum flashback across party
          # If can_instant → all teleport
          # Else → start_standard_party_journey
  
        start_standard_party_journey(travelers, destination, travel_mode)
          # Leader starts journey via WorldTravelService
          # Remaining travelers board via WorldTravelService.board_journey
        ```
  
        **FlashbackTimeService (app/services/flashback_time_service.rb - 184 lines):**
        ```ruby
        # Manages flashback time accumulation and calculation
  
        FLASHBACK_MAX_SECONDS = GameConfig::Journey::FLASHBACK_MAX_SECONDS
  
        touch_room_activity(room_id, exclude:)
          # Updates last_rp_activity_at for all online characters in room
          # Called by BroadcastService for IC message types
          # Resets flashback accumulation
  
        available_time(character_instance)
          # Returns character_instance.flashback_time_available
          # Calculated from last_rp_activity_at in CharacterInstance model
  
        calculate_flashback_coverage(character_instance, journey_seconds, mode:)
          # Routes to calculate_basic_coverage, calculate_return_coverage, or calculate_backloaded_coverage
          # Returns { success:, can_instant:, time_remaining:, flashback_used:, reserved_for_return:, return_debt:, mode: }
  
        # Private:
        calculate_basic_coverage(available, journey_seconds)
          # flashback_used = min(available, journey_seconds)
          # remaining = journey_seconds - flashback_used
          # can_instant = (remaining == 0)
  
        calculate_return_coverage(available, journey_seconds)
          # usable = available / 2 (reserve half for return)
          # flashback_used = min(usable, journey_seconds)
          # reserved_for_return = usable
  
        calculate_backloaded_coverage(journey_seconds)
          # Must be <= 12 hours
          # can_instant = true, return_debt = journey_seconds * 2
        ```
  
        **WorldTravelProcessorService (app/services/world_travel_processor_service.rb):**
        ```ruby
        # Scheduled job (runs every minute via Sidekiq)
        # Processes all active journeys (status: 'traveling')
  
        process!
          # Find all WorldJourney.where(status: 'traveling')
          # For each journey:
          #   - Check if next_hex_at <= Time.now
          #   - If yes, call advance_journey(journey)
  
        advance_journey(journey)
          # Remove first hex from path_remaining
          # Update current_globe_hex_id to next hex
          # Check if path_remaining empty → call complete_arrival!
          # Else → update next_hex_at and estimated_arrival_at
          # Broadcast progress to passengers
  
        complete_arrival!(journey)
          # If return_to_room_id set → teleport all to exact room
          # Else → find arrival room at destination (street/plaza)
          # Teleport all passengers
          # Update journey status to 'arrived'
          # Broadcast arrival message
        ```
  
        ### Models
  
        **WorldJourney (app/models/world_journey.rb):**
        ```ruby
        # Represents an active journey in progress
  
        Columns:
          world_id, current_globe_hex_id, path_remaining (JSONB array of globe_hex_id),
          origin_location_id, destination_location_id, travel_mode, vehicle_type,
          segments (JSONB), current_segment_index, started_at, next_hex_at,
          estimated_arrival_at, status, speed_modifier, return_to_room_id
  
        BASE_TIME_PER_HEX = 60 seconds (base)
        VEHICLE_SPEEDS = { horse: 1.0, carriage: 1.5, car: 3.0, train: 5.0, ... }
  
        Methods:
          calculate_next_hex_time() → Time for next hex movement
          time_per_hex_seconds() → effective time considering speed, era, terrain
          time_remaining_display() → "25 minutes" or "2h 15m"
          terrain_description() → current hex terrain ("rolling grasslands")
          traveling?() → status == 'traveling'
          arrived?() → status == 'arrived'
          passengers() → WorldJourneyPassenger eager(:character_instance)
          driver() → WorldJourneyPassenger.first(is_driver: true)
          current_hex() → WorldHex for current_globe_hex_id
          cancel!(reason:) → Move all passengers to waypoint, update status
  
        # Era speed modifiers:
        era_speed_modifier() → medieval: 0.5, gaslight: 1.0, modern: 2.0, near_future: 2.5, scifi: 3.0
  
        # Terrain modifiers (hypothetical):
        terrain_speed_modifier() → mountain: 0.7, plains: 1.0, road: 1.3
        ```
  
        **TravelParty (app/models/travel_party.rb - 221 lines):**
        ```ruby
        # Manages group journey assembly before departure
  
        Columns:
          leader_id (CharacterInstance), destination_id (Location),
          origin_room_id, travel_mode, flashback_mode, status
  
        STATUSES = %w[assembling departed cancelled]
  
        create_for(character_instance, destination, travel_mode:, flashback_mode:)
          # Creates party with leader as first member (auto-accepted)
          # Returns TravelParty
  
        invite!(character_instance)
          # Creates TravelPartyMember with status: 'pending'
          # Sends quickmenu invite via OutputHelper.store_agent_interaction
          # Broadcasts invitation message
  
        launch!()
          # Get all accepted_character_instances
          # Call JourneyService.start_party_journey with travelers
          # Update status to 'departed' if successful
  
        cancel!()
          # Update status to 'cancelled'
  
        Methods:
          member?(character_instance) → Boolean
          accepted_members() → TravelPartyMember.where(status: 'accepted')
          accepted_character_instances() → [CharacterInstance]
          pending_invites() → TravelPartyMember.where(status: 'pending')
          can_launch?() → status == 'assembling' && accepted_members.any?
          minimum_flashback_time() → min across accepted members
          status_summary() → Hash with members, counts, flashback time
        ```
  
        **TravelPartyMember (app/models/travel_party_member.rb):**
        ```ruby
        # Individual member of a travel party
  
        Columns:
          party_id, character_instance_id, status, responded_at
  
        Statuses: 'pending', 'accepted', 'declined'
  
        Methods:
          pending?(), accepted?(), declined?()
          leader?() → party.leader_id == character_instance_id
        ```
  
        **WorldJourneyPassenger (app/models/world_journey_passenger.rb):**
        ```ruby
        # Links CharacterInstance to WorldJourney
  
        Columns:
          world_journey_id, character_instance_id, is_driver, boarded_at, disembarked_at
  
        board!(journey, character_instance, is_driver:)
          # Creates passenger record
          # Sets character_instance.current_world_journey_id = journey.id
          # Moves character to journey interior room (if exists)
  
        disembark!()
          # Sets disembarked_at
          # Clears character_instance.current_world_journey_id
        ```
  
        **WorldHex (app/models/world_hex.rb):**
        ```ruby
        # Hex on the globe grid representing terrain
  
        Columns:
          world_id, globe_hex_id (unique ID), latitude, longitude,
          terrain_type, traversable, directional_features (JSONB)
  
        DIRECTIONS = %w[n ne se s sw nw]
  
        terrain_type values:
          ocean, lake, rocky_coast, sandy_coast, grassy_plains, rocky_plains,
          light_forest, dense_forest, jungle, swamp, mountain, grassy_hills,
          rocky_hills, tundra, desert, volcanic, urban, light_urban
  
        directional_feature(direction)
          # Returns feature in direction: 'road', 'railway', 'river', nil
          # directional_features is JSONB: { "n": "road", "se": "railway" }
  
        neighbors_of(hex)
          # Returns 6 adjacent hexes in all directions
  
        find_by_globe_hex(world_id, globe_hex_id)
          # Finds hex by globe_hex_id
  
        great_circle_distance_rad(lat1, lon1, lat2, lon2)
          # Haversine formula, returns distance in radians
        ```
  
        ### Command Implementation
  
        **Journey Command (plugins/core/navigation/commands/journey.rb - 604 lines):**
        ```ruby
        # Main world travel command with multiple subcommands
  
        perform_command(parsed_input)
          # Routes to different handlers based on text input:
          # '' → show_journey_status (GUI or current status)
          # 'to <dest>' → show_travel_options(destination)
          # 'party' or 'passengers' → show_party_or_passengers
          # 'return', 'freturn', 'fr' → flashback_return
          # 'disembark', 'leave', 'exit' → disembark
          # 'invite <name>' → invite_to_party(name)
          # 'launch' → launch_party
          # 'cancel' → cancel_party
  
        show_journey_status()
          # If traveling → show_current_journey_menu (quickmenu)
          # If flashback_instanced → show_flashback_status_menu (quickmenu)
          # Else → success_result(type: :open_gui, data: { gui: 'travel_map' })
  
        show_travel_options(destination_text)
          # Resolve destination by name (city_name or location name)
          # Call JourneyService.travel_options
          # Build quickmenu with standard + flashback options
          # Options: standard, flashback_basic, flashback_return, flashback_backloaded, cancel
  
        show_party_status()
          # Find TravelParty for leader
          # Show members, statuses (pending/accepted/declined)
          # Instructions for invite/launch/cancel
  
        invite_to_party(name)
          # Find character in same location
          # Call party.invite!(target)
  
        launch_party()
          # Check party.can_launch?
          # Call party.launch! → JourneyService.start_party_journey
          # Broadcast departure message
  
        flashback_return()
          # Check character_instance.flashback_instanced?
          # Call FlashbackTravelService.end_flashback_instance
          # Returns to origin room
  
        disembark()
          # Check character_instance.traveling?
          # Call WorldTravelService.disembark
          # Notify other passengers
  
        show_passengers()
          # Get journey.passengers
          # Build list with driver indicator
          # Show destination and ETA
  
        find_destination(text)
          # Try city_name exact match
          # Try city_name partial match
          # Try location name partial match
          # Try zone name → first location
        ```
  
        **ETA Command (plugins/core/navigation/commands/eta.rb - 69 lines):**
        ```ruby
        # Check journey status and ETA
  
        perform_command(_parsed_input)
          # Check character_instance.traveling?
          # Get journey = character_instance.current_world_journey
          # Call WorldTravelService.journey_eta(journey)
          # Build message with destination, vehicle, terrain, distance, ETA
          # Returns success_result with structured data
        ```
  
        ### Globe Hex Grid
  
        **WorldHexGrid (app/lib/world_hex_grid.rb):**
        ```ruby
        # Extends HexGrid with globe-specific conversions
  
        lonlat_to_hex(longitude, latitude)
          # Convert geographic coords to hex offset coords
          # Longitude → x, Latitude → y
          # Returns [hex_x, hex_y]
  
        hex_to_lonlat(hex_x, hex_y)
          # Convert hex offset coords to geographic coords
          # Returns [longitude, latitude]
  
        hex_distance_miles(x1, y1, x2, y2)
          # Distance between hexes in miles
          # ~3 miles per hex (world scale)
        ```
  
        **GlobePathfindingService:**
        ```ruby
        # A* pathfinding on globe hex grid
  
        find_path(world:, start_globe_hex_id:, end_globe_hex_id:, avoid_water:, travel_mode:)
          # Returns array of globe_hex_id representing path
          # Costs based on terrain, directional features (roads/railways)
          # avoid_water: true for land travel, false for water travel
          # travel_mode: 'land', 'water', 'rail' affects cost calculation
        ```
  
        ### Key Patterns
  
        **Globe Hex ID:**
          - Every hex has unique globe_hex_id (integer)
          - Locations reference globe_hex_id for world position
          - Journeys use arrays of globe_hex_id for paths
          - WorldHex records map globe_hex_id → lat/lon/terrain
  
        **Journey Lifecycle:**
          1. JourneyService.travel_options → show options
          2. User selects mode → JourneyService.start_journey
          3. WorldJourney created with path_remaining
          4. WorldTravelProcessorService advances every minute
          5. Each advance: pop hex, update current_globe_hex_id, check arrival
          6. Arrival: teleport passengers, update status to 'arrived'
  
        **Flashback Instancing:**
          - Return/backloaded modes set character_instance.flashback_instanced = true
          - Fields: flashback_travel_mode, flashback_origin_room_id, flashback_time_reserved, flashback_return_debt
          - Co-travelers stored in flashback_co_traveler_ids (JSONB array)
          - Instanced characters exist in private version of destination
          - journey return clears state and returns to origin
  
        **Party Assembly:**
          - TravelParty created with status: 'assembling'
          - Leader invites members → TravelPartyMember records
          - Members respond via quickmenu → status: 'accepted' or 'declined'
          - Leader launches → JourneyService.start_party_journey with all accepted
          - Party status → 'departed'
  
        **Segment Transfers:**
          - Journey has segments array: [{ mode, vehicle, path, start_hex, end_hex }]
          - current_segment_index tracks which segment
          - When path_remaining for segment empty → advance to next segment
          - Load new path_remaining from segments[current_segment_index + 1]
          - Change vehicle_type to next segment vehicle
          - Broadcast transfer message to passengers
  
        ### Testing Considerations
  
        **Journey creation:**
          - Validate locations have globe_hex_id
          - Validate same world_id
          - Check GlobePathfindingService returns valid path
          - Verify segments created for partial rail/water coverage
  
        **Flashback time:**
          - Accumulates from last_rp_activity_at
          - Touch activity resets accumulation
          - Three modes calculate coverage differently
          - Party uses minimum across members
  
        **Instancing:**
          - Verify flashback_instanced flag set
          - Check co_traveler cross-references
          - Ensure instanced characters isolated
          - Test journey return clears state correctly
  
        **Advancement:**
          - WorldTravelProcessorService runs every minute
          - Each advance pops one hex from path
          - Arrival when path_remaining empty
          - return_to_room_id ensures exact origin return
      NOTES
      display_order: 40
    },
    {
      name: 'combat',
      display_name: 'Combat',
      summary: 'Fighting, abilities, battle maps, and tactical combat',
      description: "The combat system uses tactical hex-based battle maps with a damage threshold system. Initiate fights with 'fight' or 'attack'. Combat resolves in rounds using a 100-segment timing system. Abilities provide special attacks, defenses, and status effects. The damage threshold system converts raw damage into HP loss — higher damage crosses higher thresholds for more HP lost. Wounded characters become more vulnerable as thresholds shift downward.",
      command_names: %w[attack fight combat spar],
      related_systems: %w[missions delves local_movement],
      key_files: [
        'plugins/core/combat/commands/fight.rb',
        'plugins/core/combat/commands/attack.rb',
        'plugins/core/combat/commands/spar.rb',
        'plugins/core/combat/commands/combat_info.rb',
        'plugins/core/combat/commands/done.rb',
        'app/services/fight_service.rb',
        'app/services/combat_resolution_service.rb',
        'app/services/combat_ai_service.rb',
        'app/services/ability_processor_service.rb',
        'app/services/status_effect_service.rb',
        'app/services/battle_map_combat_service.rb',
        'app/services/monster_combat_service.rb',
        'app/models/fight.rb',
        'app/models/fight_participant.rb',
        'app/models/ability.rb',
        'app/models/character_ability.rb'
      ],
      player_guide: <<~'GUIDE',
        # Combat Commands
  
        Firefly's combat system combines tactical hex-based battle maps with a dynamic damage threshold system. Combat flows through rounds where you choose actions via quickmenus, then watch dramatic narratives unfold. The system rewards clever positioning, ability choices, and tactical thinking.
  
        ## Starting Combat
  
        ### Fight Command
  
        `fight <target>` - Start combat with another character or NPC
          - Aliases: combat, engage
          - **fight** (no target) - Shows quickmenu of available targets
          - **fight Bob** - Engages Bob in combat immediately
          - Broadcasts fight initiation to the room
          - Opens combat quickmenu for your first action
  
        **You must be:**
          - Alive (not knocked out or dead)
          - Standing (not sitting, lying down, etc.)
          - Not already in combat
  
        ### Attack Command
  
        `attack <target>` - Attack someone (starts fight if not in combat)
          - Aliases: hit, att
          - **attack** (in combat) - Confirm attack on current target
          - **attack goblin** (not in combat) - Starts fight with goblin
          - **attack Bob** (in combat) - Changes target to Bob for this round
  
        **If already in combat:**
          - Changes your target for the current round
          - Sets your main action to "attack"
          - Can be changed until you submit with `done`
  
        ### Spar Command
  
        `spar <target>` - Challenge someone to friendly sparring
          - Aliases: sparring
          - **spar** (no target) - Shows quickmenu of available sparring partners
          - **spar Alice** - Challenges Alice to a sparring match
          - Works like combat but tracks "touches" instead of HP damage
          - Great for practice without real consequences
          - No death, no injury, just tactical fun
  
        **Sparring differences:**
          - Damage doesn't reduce HP
          - "Touches" count as hits
          - Fight ends when someone yields or time limit
          - No knockout, no lasting effects
  
        ## Combat Flow
  
        Combat proceeds in **rounds**. Each round follows this flow:
  
        1. **Input Phase** - Choose your actions via quickmenu
        2. **Resolution Phase** - All actions resolve in 100-segment order
        3. **Narrative Phase** - See dramatic narrative of what happened
        4. **Next Round** - Repeat until fight ends
  
        ### The Combat Quickmenu
  
        When combat starts, you receive a **combat quickmenu** — a hub menu where you configure your round. Each choice is independent, and you can set them in any order:
  
        **Attack / Target** - Choose your main action and who you're targeting
          - **Attack** - Basic attack with equipped weapon
          - **Defend** - Focus on defense, harder to hit
          - **Dodge** - Attempt to evade incoming attacks
          - **Ability** - Use a combat ability (if you have any)
          - **Sprint** - Extra movement (+3 hexes), but no attack or other action
          - **Pass** - Take no action this round
  
        **Tactic** - Choose a tactical stance or use a tactical ability
          - **Aggressive** - +1 damage dealt, +1 damage taken
          - **Defensive** - -1 damage dealt, -1 damage taken
          - **Quick** - +1 movement, -1 damage dealt, +1 damage taken
          - **Guard** - Protect an ally (redirect attacks to you)
          - **Back to Back** - Mutual protection with an ally
          - Tactical abilities (healing spells, buffs) also appear here if available
          - **None** - No stance
  
        **Movement** - Choose how to move on the battle map
          - **Move toward** a target (get closer for melee)
          - **Move away** from a target (retreat)
          - **Maintain distance** from a target
          - **Stand still** - Don't move
          - **Flee** - Attempt to leave combat entirely
  
        **Use Willpower** - Allocate willpower dice to boost your rolls
          - Spend dice on **attack** (extra d8s added to damage roll)
          - Spend dice on **defense** (d8s rolled as armor)
          - Spend dice on **ability** (extra d8s added to ability roll)
          - Spend dice on **movement** (d8s rolled, half total = bonus hexes)
          - Each willpower die rolls a d8 that explodes on 8
          - Max 2 dice per action type per round
  
        **Options** - Additional settings
          - **Select weapons** - Switch between melee and ranged weapons
  
        **Done** - Submit your choices
          - Type **done** (or use `ready`, `submit`) to lock in choices
          - Can change choices until you submit
          - Round resolves when all participants submit or timeout
  
        ### Combat Info Command
  
        **combat** - Get combat information (accessibility friendly)
          - Aliases: cb, ci, fight status, battle
          - **combat** or **combat status** - Full combat status
          - **combat enemies** - List all enemies with HP and distance
          - **combat allies** - List all allies with HP and distance
          - **combat recommend** - Get AI target recommendation
          - **combat actions** - Show available actions
          - **combat help** - Show all combat subcommands
  
        **Screen-reader friendly:**
          - All info presented as clear text
          - Distances shown in hexes
          - HP shown as current/max
          - Recommendations based on tactical situation
  
        ### Done Command
  
        **done** - Submit your combat choices and lock them in
          - Aliases: ready, submit
          - Marks your input as complete
          - Applies default choices for any options you skipped
          - Triggers round resolution if all participants ready
          - Shows narrative and starts next round
  
        ## How Damage Works
  
        Firefly uses a **damage threshold system**, NOT direct HP subtraction. This creates dramatic swings and realistic combat.
  
        ### Damage Thresholds (at full HP):
  
        | Raw Damage | HP Lost | Result |
        |------------|---------|---------|
        | 0-9        | 0 HP    | Miss - no effect |
        | 10-17      | 1 HP    | Glancing blow |
        | 18-29      | 2 HP    | Solid hit |
        | 30-99      | 3 HP    | Heavy strike |
        | 100-199    | 4 HP    | Critical hit |
        | 200-299    | 5 HP    | Devastating blow |
        | 300+       | 6+ HP   | Massive damage |
  
        ### Wound Penalty
  
        **As you take damage, thresholds shift DOWN:**
          - Each HP lost = -1 to all thresholds
          - Makes you more vulnerable as you get wounded
          - Example: At 4/6 HP (2 HP lost):
            - Miss threshold: ≤7 damage (was ≤9)
            - 1 HP threshold: 8-15 damage (was 10-17)
            - 2 HP threshold: 16-27 damage (was 18-29)
            - 3 HP threshold: 28-97 damage (was 30-99)
          - Wounded characters go down faster!
  
        **Example scenario:**
          - You're at full HP (6/6)
          - Enemy rolls 15 damage → 1 HP lost (you're now 5/6 HP)
          - Next round, enemy rolls 8 damage → normally a miss, but wound penalty makes it 1 HP lost!
          - You're now 4/6 HP, and each hit hurts more
  
        ### Willpower System
  
        **Gain willpower when wounded:**
          - +0.25 dice per HP lost
          - Maximum 3.0 willpower dice
          - At 6/6 HP → 0.0 willpower
          - At 4/6 HP → 0.5 willpower (2 HP lost)
          - At 0/6 HP → 1.5 willpower (6 HP lost, but knocked out)
          - Start each fight with 1.0 willpower die
  
        **Spend willpower dice to boost rolls:**
          - Choose "Use Willpower" in the combat quickmenu
          - Allocate dice to **attack**, **defense**, **ability**, or **movement**
          - Each die rolls an extra d8 (explodes on 8) added to that roll
          - Movement dice: roll d8s, half total = bonus movement hexes
          - Max 2 dice per action type per round
          - Dice are spent when used — manage them carefully
  
        ### Knockout
  
        **At 0 HP, you're knocked out:**
          - Fall unconscious
          - Removed from combat automatically
          - Wake up after fight ends (unless killed)
          - Can't take actions while knocked out
  
        **Death:**
          - In normal combat: knockout only
          - In dangerous situations: death possible
          - Sparring: never causes death
  
        ## Battle Map Positioning
  
        Combat takes place on a **hex grid** (4 feet per hex):
  
        ### Hex Positioning
  
        **Starting position:**
          - Based on your room position when combat starts
          - Converted from feet to hex coordinates
          - Sides assigned automatically (attackers vs defenders)
  
        **Movement:**
          - Choose "Movement" from the combat quickmenu hub
          - **Move toward** a target - Get closer for melee attacks
          - **Move away** from a target - Retreat from enemies
          - **Maintain distance** - Keep current range from a target
          - **Stand still** - Hold position
          - **Flee** - Attempt to leave the fight
  
        **Distance affects combat:**
          - **Melee attacks:** Must be adjacent (1 hex away)
          - **Ranged attacks:** Can target from distance
          - Cover bonuses apply based on hex type
  
        ### Hex Types
  
        Different hexes provide different benefits:
          - **Normal** - Standard terrain
          - **Cover** - Bonus to defense
          - **High ground** - Bonus to attacks
          - **Difficult terrain** - Slows movement
          - **Hazards** - Damage per round (fire, water, traps)
  
        ## Abilities
  
        **Combat abilities** are special moves with unique effects:
  
        ### Using Abilities
  
        **During quickmenu:**
          1. Choose "Abilities" as your main action
          2. Select ability from your available list
          3. Choose target (if required)
          4. Submit with `done`
  
        **Ability types:**
          - **Attack abilities** - Special attacks (Fireball, Chain Lightning, etc.)
          - **Defense abilities** - Protective moves (Shield Wall, Dodge Roll, etc.)
          - **Buff abilities** - Boost allies (Inspire, Heal, etc.)
          - **Debuff abilities** - Weaken enemies (Slow, Poison, etc.)
          - **Tactical abilities** - Special maneuvers (Charge, Disarm, etc.)
  
        **Cooldowns:**
          - Most abilities have cooldown periods
          - Can't use again until cooldown expires
          - Shown as "rounds remaining" in menu
  
        **Resource costs:**
          - Abilities do not cost willpower to activate
          - Willpower can be allocated to empower ability rolls
          - Some abilities cost HP
          - Some abilities require specific equipment
  
        ## Multi-Faction Combat
  
        Fights support **multiple sides** (not just 1v1):
  
        ### Side System
  
        **Automatic side assignment:**
          - First participant → Side 1
          - Target of first participant → Side 2
          - Late joiners → oppose their target's side
          - Auto-balancing: join side with fewer fighters
  
        **Example: 3-way fight:**
          - Alice attacks Bob → Alice (Side 1), Bob (Side 2)
          - Charlie attacks Alice → Charlie joins Side 2 (Bob's side)
          - Dave attacks Bob → Dave joins Side 1 (Alice's side)
          - Result: Alice & Dave vs Bob & Charlie
  
        **Targeting:**
          - Can only target participants on opposing sides
          - Can't attack your own side
          - Sides can be manually changed (staff command)
  
        ## Examples
  
        **Starting a fight:**
        ```
        fight goblin
        > You engage Goblin in combat! Choose your target.
        > (Combat quickmenu appears)
  
        (Select "Attack" and choose target)
        (Optionally set tactic, movement, willpower)
        done
        > Your choices are locked in. Waiting for other combatants...
  
        (When all ready, round resolves)
        > === Round 1 Resolution ===
        > You swing your sword at the goblin! (Rolls: 15 damage)
        > The goblin strikes back with its rusty blade! (Rolls: 8 damage)
        > You take 1 HP damage. (5/6 HP remaining)
  
        (Next round quickmenu appears)
        ```
  
        **Using combat info:**
        ```
        combat enemies
        > === Enemies ===
        > Goblin - 4/5 HP - 2 hexes away
        > Orc Warrior - 6/6 HP - 5 hexes away
  
        combat recommend
        > Recommendation: Target Goblin
        > Reason: Already wounded, close range, within melee distance
  
        attack goblin
        > You target Goblin.
  
        done
        > Your choices are locked in.
        ```
  
        **Sparring match:**
        ```
        spar Alice
        > You challenge Alice to a sparring match!
  
        (Combat proceeds normally, but tracks touches)
  
        > === Round 3 Resolution ===
        > You land a clean touch on Alice! (Touch #3)
        > Alice concedes the match!
        > The sparring session is over. You scored 3 touches, Alice scored 1.
        ```
  
        **Changing tactics mid-fight:**
        ```
        attack
        > You prepare to attack Goblin.
  
        (Realize you want to defend instead)
        attack
        > Reopening your combat menu. You can change your choices until the round resolves.
  
        (Select "Defend" instead)
        done
        > Your choices are locked in.
        ```
  
        ## Tips
  
        - **Use combat enemies** to track opponents' HP before targeting
        - **Spend willpower strategically** - it's finite per fight
        - **Wound penalty accelerates** - finish weak enemies fast
        - **Position matters** - ranged characters stay back, melee move in
        - **Abilities have cooldowns** - plan ahead for multiple rounds
        - **Sparring is great practice** - no risk, learn mechanics
        - **Watch for side assignments** - make sure you're targeting the right side
        - **Done locks in choices** - think before submitting
        - **Quickmenu can be reopened** - type command again before round resolves
        - **NPCs act instantly** - they don't wait for quickmenu, decisions are immediate
      GUIDE
      staff_notes: <<~'NOTES',
        ## Combat System Architecture
  
        Combat uses **tactical hex-based battle maps** with a **damage threshold system**. Rounds resolve via a **100-segment timing system** where actions execute in order based on character speed, initiative, and action type. The threshold system creates dramatic combat where wounded characters become increasingly vulnerable.
  
        ### Core Services
  
        **FightService (app/services/fight_service.rb - 450+ lines):**
        ```ruby
        # Orchestrates combat sessions - starting, managing participants, processing choices
  
        start_fight(room:, initiator:, target:, mode: 'normal')
          # Creates Fight record or joins existing fight in room
          # mode: 'normal' (default) or 'spar'
          # Ensures battle map ready via ensure_battle_map_ready
          # Snapshots distances for FightEntryDelayService
          # Adds both participants with side assignment
          # NPCs call CombatAIService.apply_decisions! immediately
          # Returns FightService instance
  
        find_active_fight(character_instance)
          # Finds ongoing fight for a character
          # Returns Fight or nil
  
        add_participant(character_instance, target_instance: nil)
          # Adds character to fight
          # Blocks re-entry if fled or surrendered
          # Finds equipped weapons (melee/ranged)
          # Calculates starting hex from character's x/y position
          # Ensures no hex collision via find_unoccupied_hex
          # Determines side via determine_side_for_new_participant
          # Creates FightParticipant record
          # NPCs apply AI decisions immediately
  
        determine_side_for_new_participant(target_instance)
          # First participant → side 1
          # If targeting someone → join opposite side
          # Otherwise → join side with fewer fighters (auto-balance)
  
        process_choice(participant, stage, choice)
          # Routes to specific handlers based on stage:
          # target, main, ability, tactical_ability, tactical, willpower, movement, weapon_melee, weapon_ranged
  
        ready_to_resolve?()
          # Returns true if all inputs complete or input timed out
  
        resolve_round!()
          # Applies defaults for incomplete inputs via CombatAIService
          # Advances fight to 'resolving' status
          # Calls CombatResolutionService.resolve!
          # Returns { events:, roll_display: }
  
        generate_narrative()
          # Calls CombatNarrativeService.generate
          # Returns formatted narrative string
  
        should_end?()
          # Checks if only one side remains active
          # Or if all participants knocked out
  
        end_fight!()
          # Calls fight.complete!
          # Sets winner if applicable
          # Marks participants as knocked out (real combat only, not spar)
          # Resets knockout wake timers via PrisonerService
        ```
  
        **CombatResolutionService (app/services/combat_resolution_service.rb):**
        ```ruby
        # Handles round resolution using 100-segment timing system
  
        resolve!()
          # Builds action queue from all participant choices
          # Sorts actions by timing segment (speed + initiative + action type)
          # Processes each action in order:
          #   - Attacks → damage calculation → threshold lookup → HP reduction
          #   - Movement → hex pathfinding → position update
          #   - Abilities → AbilityProcessorService execution
          #   - Defend/dodge → applies status effects
          # Creates FightEvent records for each action
          # Updates participant states (HP, willpower, status effects)
          # Returns { events:, roll_display: }
  
        # Action timing:
        Base segment = 50 (mid-round)
        Modifiers:
          - Character speed stat
          - Initiative bonus
          - Action type (attack/defend/ability)
          - Weapon speed modifier
  
        # Damage calculation:
        calculate_damage(attacker, defender, weapon, ability)
          # Base damage from weapon/ability
          # Apply attacker stats (strength/dexterity)
          # Apply defender armor/shields
          # Apply status effect modifiers
          # Apply willpower boosts
          # Roll dice (2d8 exploding for attacks)
          # Return raw damage value
  
        # Threshold conversion:
        apply_damage_to_hp(participant, raw_damage)
          # Get current damage_thresholds from participant
          # Thresholds shift based on wound_penalty (HP lost)
          # Find which threshold raw damage crosses
          # Return HP lost (0-6+)
        ```
  
        **CombatAIService (app/services/combat_ai_service.rb):**
        ```ruby
        # Drives NPC combat behavior and provides intelligent defaults
  
        apply_decisions!()
          # For NPCs: full AI decision-making
          # For idle PCs: sensible defaults
          # Selects target via target_selection
          # Selects main action (attack/defend/ability)
          # Selects tactical stance, movement action
          # Allocates willpower dice
          # Marks input_complete = true
  
        target_selection()
          # Prioritizes:
          # 1. Lowest HP enemy (finish off wounded)
          # 2. Closest enemy (minimize movement)
          # 3. Highest threat enemy (damage dealers)
          # Returns target participant or monster
  
        action_selection()
          # Decision tree:
          # - If HP < 30% → defend or use healing ability
          # - If high willpower → use powerful ability
          # - If ability off cooldown → use ability
          # - Default → attack
  
        movement_decision()
          # For melee: move toward target if not adjacent
          # For ranged: maintain distance, move to cover if available
          # For low HP: retreat to safer position
        ```
  
        **AbilityProcessorService (app/services/ability_processor_service.rb):**
        ```ruby
        # Executes data-driven combat abilities
  
        process_ability(participant, ability, target)
          # Validates ability can be used (cooldown, resource costs)
          # Consumes resources (willpower, HP, etc.)
          # Executes ability effects via ability.data (JSONB):
          #   damage: { type: :fire, base: 20, dice: '3d8' }
          #   status_effect: { type: :burn, duration: 3, damage_per_round: 5 }
          #   heal: { amount: 15, target: :self }
          #   area: { shape: :circle, radius: 2, center: :target }
          # Creates FightEvent for ability use
          # Sets cooldown_until on CharacterAbility
          # Returns effect results for narrative
  
        # Ability data structure (JSONB):
        {
          damage: { type: :fire, base: 20, dice: '3d8', armor_piercing: true },
          status_effect: { type: :burn, duration: 3, damage_per_round: 5 },
          area: { shape: :circle, radius: 2, center: :target },
          cooldown: 3,  # rounds
          cost: { willpower: 1, hp: 0 }
        }
        ```
  
        **StatusEffectService (app/services/status_effect_service.rb):**
        ```ruby
        # Manages buffs, debuffs, and shields
  
        apply_status_effect(participant, effect_data)
          # Creates StatusEffect record
          # Types: burn, poison, slow, shield, buff, debuff
          # Duration: number of rounds or until removed
          # Effects per type:
          #   burn/poison → damage_per_round
          #   slow → movement_penalty
          #   shield → absorb_damage
          #   buff → stat_modifier
          #   debuff → stat_penalty
  
        process_status_effects(participant)
          # Called at start of each round
          # Applies damage from burn/poison
          # Applies stat modifiers from buffs/debuffs
          # Decrements durations
          # Removes expired effects
  
        remove_status_effect(participant, effect_type)
          # Removes specific effect type
          # Used by dispel abilities
        ```
  
        **BattleMapCombatService (app/services/battle_map_combat_service.rb):**
        ```ruby
        # Handles hex-grid positioning, cover, elevation, line of sight
  
        # Hex scale: 4 feet per hex (HEX_SIZE_FEET constant)
  
        calculate_distance(hex_x1, hex_y1, hex_x2, hex_y2)
          # Uses HexGrid.hex_distance (offset coordinates)
          # Returns distance in hexes
  
        can_attack_melee?(attacker, defender)
          # Checks if distance <= 1 hex (adjacent)
          # Returns true/false
  
        can_attack_ranged?(attacker, defender, weapon)
          # Checks if distance <= weapon.range
          # Checks line of sight via has_line_of_sight?
          # Returns true/false
  
        has_line_of_sight?(from_hex, to_hex)
          # Raycasts between hexes
          # Checks for blocking terrain (walls, solid objects)
          # Returns true/false
  
        get_cover_bonus(hex_x, hex_y, direction)
          # Checks RoomHex.hex_type
          # cover → +2 defense
          # partial_cover → +1 defense
          # no_cover → 0
  
        get_elevation_modifier(attacker_hex, defender_hex)
          # Higher elevation → +1 attack
          # Lower elevation → -1 attack
          # Same elevation → 0
  
        find_path(from_hex, to_hex)
          # Uses HexPathfindingService for movement
          # Avoids walls, difficult terrain
          # Returns array of hex coordinates
  
        apply_movement(participant, destination_hex_x, destination_hex_y)
          # Validates path exists
          # Updates participant.hex_x, participant.hex_y
          # Creates FightEvent for movement
        ```
  
        **MonsterCombatService (app/services/monster_combat_service.rb):**
        ```ruby
        # Handles multi-segment monster fights
  
        # Monsters have multiple body parts (segments)
        # Each segment can be targeted separately
        # Defeating all segments defeats the monster
  
        process_monster_actions(fight, monster)
          # Each segment can take independent actions
          # Segments have separate HP pools
          # Different attack patterns per segment
          # Coordinates multi-target attacks
  
        apply_segment_damage(segment, raw_damage)
          # Uses same threshold system as characters
          # Segment-specific HP pool
          # Segment dies when HP reaches 0
          # Monster dies when all segments dead
  
        select_monster_targets(fight, monster)
          # AI target selection for each segment
          # Can split focus across multiple PCs
          # Prioritizes based on segment role:
          #   - Head → highest threat
          #   - Claws → nearest targets
          #   - Tail → flanking attacks
        ```
  
        ### Models
  
        **Fight (app/models/fight.rb):**
        ```ruby
        # Represents active combat session in a room
  
        Columns:
          room_id, mode ('normal' or 'spar'), status, round_number, started_at,
          last_action_at, combat_ended_at, input_deadline_at, round_started_at,
          arena_width, arena_height, has_monster, winner_id
  
        STATUSES = %w[input resolving narrative complete]
        INPUT_TIMEOUT_SECONDS = 60 (humans), NPC_ONLY_TIMEOUT_SECONDS = 10
        STALE_TIMEOUT_SECONDS = 300 (5 minutes of inactivity)
  
        Methods:
          has_human_participants?() → Boolean (check if any non-NPC)
          effective_timeout_seconds() → shorter for NPC-only fights
          reset_input_deadline!() → recalculates based on participants
          input_timed_out?() → Time.now > input_deadline_at
          all_inputs_complete?() → all active participants done
          active_participants() → not knocked out
          participants_needing_input() → not done, not knocked out
          advance_to_resolution!() → status = 'resolving'
          complete_round!() → increment round, reset choices, reset deadline
          complete!() → status = 'complete', mark participants knocked out
          ongoing?() → status in ['input', 'resolving', 'narrative']
          spar_mode?() → mode == 'spar'
          round_locked?() → status == 'resolving'
  
        # Arena dimensions:
        before_create → calculate arena_width/height from room bounds
          room_width/height in feet → HexGrid.arena_dimensions_from_feet
          Default: 10x10 hexes if no room bounds
        ```
  
        **FightParticipant (app/models/fight_participant.rb):**
        ```ruby
        # Character participating in a fight
  
        Columns:
          fight_id, character_instance_id, side, hex_x, hex_y,
          current_hp, max_hp, melee_weapon_id, ranged_weapon_id,
          target_participant_id, targeting_monster_id,
          main_action, tactic_choice, willpower_attack, willpower_defense,
          willpower_ability, willpower_movement, movement_action,
          input_stage, input_complete, is_knocked_out,
          touches_landed (spar mode), touches_received (spar mode)
  
        # Side system:
        side → 1, 2, 3, ... (multi-faction support)
  
        # Input stages (hub menu - any order):
        main_menu → main_action/tactical_action/movement/willpower/options → done
  
        Methods:
          damage_thresholds() → calculates current thresholds with wound penalty
          calculate_hp_from_damage(raw_damage) → converts via thresholds
          take_damage(raw_damage) → applies damage, updates HP, returns HP lost
          wound_penalty() → max_hp - current_hp (shifts thresholds down)
          knocked_out?() → current_hp <= 0
          character_name() → character_instance.character.full_name
          complete_input!() → sets input_complete = true
        ```
  
        **Ability (app/models/ability.rb):**
        ```ruby
        # Ability template defining effects and costs
  
        Columns:
          name, description, ability_type, data (JSONB), cooldown,
          resource_cost (JSONB), creator_id, is_public
  
        ability_type values:
          attack, defense, buff, debuff, heal, tactical, area, summon
  
        data JSONB structure:
          {
            damage: { type: :fire, base: 20, dice: '3d8', armor_piercing: true },
            status_effect: { type: :burn, duration: 3, damage_per_round: 5 },
            area: { shape: :circle, radius: 2, center: :target },
            heal: { amount: 15, target: :self },
            buff: { stat: :strength, amount: 2, duration: 5 }
          }
  
        resource_cost JSONB:
          { willpower: 1, hp: 0, mana: 0 }
        ```
  
        **CharacterAbility (app/models/character_ability.rb):**
        ```ruby
        # Links characters to abilities with cooldown tracking
  
        Columns:
          character_id, ability_id, cooldown_until, times_used
  
        Methods:
          off_cooldown?() → !cooldown_until || Time.now > cooldown_until
          set_cooldown!(rounds) → cooldown_until = rounds from now
          increment_usage!() → times_used += 1
        ```
  
        ### Damage Threshold System
  
        **Configuration (config/game_config.rb):**
        ```ruby
        DAMAGE_THRESHOLDS = [
          { min: 0, max: 9, hp_lost: 0 },    # miss
          { min: 10, max: 17, hp_lost: 1 },  # glancing
          { min: 18, max: 29, hp_lost: 2 },  # solid
          { min: 30, max: 99, hp_lost: 3 },  # heavy
          { min: 100, max: 199, hp_lost: 4 }, # critical
          { min: 200, max: 299, hp_lost: 5 }, # devastating
          { min: 300, max: Float::INFINITY, hp_lost: 6 } # massive
        ]
        ```
  
        **Implementation (app/models/fight_participant.rb:88-107):**
        ```ruby
        def damage_thresholds
          # Get base thresholds from config
          base = GameConfig::Combat::DAMAGE_THRESHOLDS
  
          # Calculate wound penalty (HP lost)
          penalty = wound_penalty
  
          # Shift thresholds down by wound penalty
          base.map do |threshold|
            {
              min: [threshold[:min] - penalty, 0].max,
              max: threshold[:max] - penalty,
              hp_lost: threshold[:hp_lost]
            }
          end
        end
  
        def calculate_hp_from_damage(raw_damage)
          thresholds = damage_thresholds
          threshold = thresholds.find { |t| raw_damage >= t[:min] && raw_damage <= t[:max] }
          threshold ? threshold[:hp_lost] : 0
        end
  
        def take_damage(raw_damage)
          hp_lost = calculate_hp_from_damage(raw_damage)
          self.current_hp = [current_hp - hp_lost, 0].max
          save_changes
          hp_lost
        end
        ```
  
        ### 100-Segment Timing System
  
        **Segment calculation:**
        ```ruby
        # Base segment = 50 (mid-round)
        # Faster actions happen earlier (lower segment number)
        # Slower actions happen later (higher segment number)
  
        def calculate_action_segment(participant, action_type)
          base = 50
  
          # Speed stat modifier (0-10)
          speed_modifier = participant.character_instance.stats.speed || 5
          base -= speed_modifier
  
          # Initiative bonus (character trait)
          initiative = participant.character_instance.initiative_bonus || 0
          base -= initiative
  
          # Action type modifier
          case action_type
          when 'attack' then base += 0
          when 'defend' then base -= 5  # defensive actions faster
          when 'dodge' then base -= 10  # dodging is fastest
          when 'ability' then base += ability_speed_modifier(ability)
          when 'movement' then base += 5
          end
  
          # Weapon speed modifier
          if weapon
            base += weapon.speed_penalty || 0
          end
  
          # Clamp to valid range
          [base, 0].max
        end
        ```
  
        **Resolution order:**
        ```ruby
        # Sort all actions by segment
        actions = []
        fight.active_participants.each do |p|
          segment = calculate_action_segment(p, p.main_action)
          actions << { participant: p, action: p.main_action, segment: segment }
        end
  
        actions.sort_by! { |a| a[:segment] }
  
        # Process in order
        actions.each do |action_data|
          process_action(action_data[:participant], action_data[:action])
        end
        ```
  
        ### Command Implementation
  
        **Fight Command (plugins/core/combat/commands/fight.rb - 143 lines):**
        ```ruby
        perform_command(parsed_input)
          # Check if already in fight → reopen menu or error
          # If no target specified → show_fight_menu (quickmenu)
          # Find target via find_combat_target (includes NPCs)
          # Call FightService.start_fight
          # Broadcast fight initiation
          # Show combat quickmenu via CombatQuickmenuHandler
  
        show_fight_menu()
          # Get all characters in room (excluding self)
          # Build quickmenu with targets
          # Context: { command: 'fight', stage: 'select_target', targets: [...] }
        ```
  
        **Attack Command (plugins/core/combat/commands/attack.rb - 209 lines):**
        ```ruby
        perform_command(parsed_input)
          # If in fight → handle_combat_attack (change target/reopen menu)
          # If not in fight → handle_start_fight (like Fight command but sets target immediately)
  
        handle_combat_attack(fight, target_name)
          # Check if round locked (can't change during resolution)
          # If input_complete but not locked → reopen menu
          # If target specified → change target (participant or monster)
          # If no target → confirm attack on current target
          # Update participant.main_action = 'attack'
  
        handle_start_fight(target_name)
          # Check timeline death restrictions
          # Find combat target
          # Start fight via FightService
          # Set initial target
          # Set input_stage = 'main_action' (skip target selection)
          # Show quickmenu
        ```
  
        **Spar Command (plugins/core/combat/commands/spar.rb - 127 lines):**
        ```ruby
        perform_command(parsed_input)
          # Check not already in fight
          # If no target → show_spar_menu
          # Find target via find_combat_target
          # Check target not in fight
          # Start fight with mode: 'spar'
          # Broadcast spar initiation
          # Show combat quickmenu
  
        # Spar mode differences:
        # - Fight.mode = 'spar'
        # - Damage doesn't reduce HP
        # - Tracks touches_landed / touches_received
        # - No knockout, no death
        # - Fight ends on yield or time limit
        ```
  
        **CombatInfo Command (plugins/core/combat/commands/combat_info.rb - 173 lines):**
        ```ruby
        # Accessibility-focused combat info
  
        perform_command(parsed_input)
          # Routes to different views based on subcommand:
          # enemies → list_enemies (with HP, distance)
          # allies → list_allies (with HP, distance)
          # recommend → recommend_target (AI suggestion)
          # status → combat_status (full overview)
          # actions → available_actions (menu options)
          # help → show_help
  
        # All output uses AccessibleCombatService
        # Returns screen-reader friendly text
        # Includes structured data for client rendering
        ```
  
        **Done Command (plugins/core/combat/commands/done.rb - 120 lines):**
        ```ruby
        perform_command(_parsed_input)
          # Find active fight and participant
          # Check if already input_complete
          # Apply defaults via fight_service.apply_default_choices
          # Mark participant.input_complete!
          # Check if ready_to_resolve?
          # If yes:
          #   - Call fight_service.resolve_round!
          #   - Broadcast roll_display
          #   - Broadcast narrative
          #   - Check if should_end?
          #   - If end → fight_service.end_fight!, broadcast winner
          #   - Else → fight_service.next_round!, show new menu
          # If no:
          #   - Show "waiting for others" message
        ```
  
        ### Key Patterns
  
        **Multi-phase combat flow:**
          1. Input phase (status: 'input') - participants choose actions
          2. Resolution phase (status: 'resolving') - actions execute in segment order
          3. Narrative phase (status: 'narrative') - generate descriptive text
          4. Complete round → return to input or end fight
  
        **Quickmenu (hub menu):**
          main_menu → attack/tactic/movement/willpower/options (any order) → done
          Each stage updates participant.input_stage
          Can navigate back/forward until input_complete
  
        **NPC instant decisions:**
          NPCs don't use quickmenus
          CombatAIService.apply_decisions! called immediately on add_participant
          Marks input_complete instantly
  
        **Timeout handling:**
          INPUT_TIMEOUT_SECONDS for human fights (60s)
          NPC_ONLY_TIMEOUT_SECONDS for pure AI fights (10s)
          Auto-applies defaults via CombatAIService when timeout
  
        **Side assignment:**
          First participant → side 1
          Target of first → side 2
          New joiners → opposite their target's side, or auto-balance
  
        **Damage flow:**
          Roll dice → calculate raw damage → look up threshold → convert to HP lost → apply to participant → check knockout
  
        **Willpower accumulation:**
          Gain 0.25 dice per HP lost (start with 1.0)
          Max 3.0 willpower dice
          Allocate to attack/defense/ability/movement (each adds d8s, explodes on 8)
          Max 2 dice per action type per round
  
        ### Testing Considerations
  
        **Fight creation:**
          - Verify battle map initialization
          - Check side assignment logic
          - Test multi-faction scenarios
  
        **Damage thresholds:**
          - Verify threshold shifting with wound penalty
          - Test edge cases (exactly on threshold boundary)
          - Confirm knockout at 0 HP
  
        **Timing system:**
          - Verify segment calculation
          - Test action ordering
          - Confirm fast actions execute first
  
        **Abilities:**
          - Test cooldown tracking
          - Verify resource costs deducted
          - Test area effects
  
        **Spar mode:**
          - Verify no HP damage
          - Test touch tracking
          - Confirm no knockout
      NOTES
      display_order: 45
    },
    {
      name: 'missions',
      display_name: 'Missions',
      summary: 'Structured missions, heists, and group challenges',
      description: "The mission/activity system provides structured gameplay scenarios like heists, missions, and group challenges. Activities have multiple rounds with branching choices, skill checks, rest periods, and free-form actions. Players choose actions, spend willpower dice, and work together or help teammates. Round types include standard menus, group voting branches, rest periods, free-form rolls evaluated by AI, and social persuasion encounters. Competitive activity types (competitions, elimination) are in the Events & Competitions & Media system.",
      command_names: %w[activity aobserve],
      related_systems: %w[combat cards_games events_media],
      key_files: [
        'plugins/core/activity/commands/activity.rb',
        'plugins/core/activity/commands/observe.rb',
        'app/services/activity_service.rb',
        'app/services/activity_resolution_service.rb',
        'app/services/activity_branch_service.rb',
        'app/services/activity_rest_service.rb',
        'app/services/activity_free_roll_service.rb',
        'app/services/activity_persuade_service.rb',
        'app/services/observer_effect_service.rb',
        'app/models/activity.rb',
        'app/models/activity_instance.rb',
        'app/models/activity_participant.rb',
        'app/models/activity_round.rb',
        'app/models/activity_action.rb',
        'app/models/activity_remote_observer.rb'
      ],
      player_guide: <<~'GUIDE',
        # Missions & Activities System
  
        The activity system provides structured group challenges like heists, missions, competitions, and social encounters. Activities progress through rounds where you make choices, roll dice, vote on decisions, and work together to succeed.
  
        ## Activity Types
  
        Activities come in various types, each with different goals and mechanics:
  
        - **Mission**: Story-driven challenges with branching paths and consequences
        - **Task**: Simple skill-based challenges with clear objectives
        - **Collaboration**: Pure cooperative challenges where everyone works toward a shared goal
        - **Adventure**: Exploration-based activities with discovery and choices
        - **Encounter**: Social or combat encounters with NPCs
        - **Survival**: Endurance challenges where you try to last as long as possible
  
        Competitive activity types (**Competition**, **Team Competition**, **Elimination**) are covered in the **Events & Competitions & Media** system.
  
        ## Starting and Joining Activities
  
        Use the `activity` command to interact with the system:
  
        - `activity list` - Show available activities in your current location
        - `activity start <name>` - Begin an activity (you become the leader)
        - `activity join` - Join an activity that's being set up in your room
        - `activity leave` - Leave an activity you've joined
        - `activity status` - See your current activity status and round information
  
        Once an activity starts, everyone who joined becomes a participant. The activity progresses through rounds, and you'll need to make choices each round to continue.
  
        ## Round Types
  
        Activities use different round types for variety and different gameplay experiences:
  
        ### Standard Rounds
  
        The most common type. You're presented with a menu of action choices:
  
        1. Read the round description (what's happening)
        2. Review available actions (what you can do)
        3. Choose an action: `activity choose <number>`
        4. Optionally set willpower to spend: `activity willpower <0-2>`
        5. Wait for everyone to choose
        6. Dice are rolled and results are narrated
  
        **Example:**
        ```
        Round 3: You approach the locked vault door. Time is running out.
  
        Available actions:
        1. Pick the lock (Dexterity + Lockpicking)
        2. Blow the door with explosives (Strength + Demolitions)
        3. Search for another entrance (Intelligence + Investigation)
  
        activity choose 1
        activity willpower 2  (spend 2 willpower dice for a better roll)
        ```
  
        ### Branch Rounds
  
        Decision points where the group votes on which path to take:
  
        - Each participant votes: `activity vote <number>`
        - Majority wins (ties go to the first option to reach majority)
        - No dice rolling, just group consensus
        - The chosen path determines which rounds come next
  
        **Example:**
        ```
        Round 5: The guards are alerted! What's your plan?
  
        Branches:
        1. Fight your way through (leads to combat)
        2. Hide and wait for them to pass (stealth route)
  
        activity vote 2  (vote for option 2)
        ```
  
        ### Rest Rounds
  
        Recovery periods where you can heal damage and catch your breath:
  
        - **Healing**: `activity heal` - Heals you based on damage taken
          - Every 2 HP you've lost = 1 permanent damage that can't be healed back
          - Example: Lost 1 HP → heal to full. Lost 4 HP → heal to max-2 permanently
        - **Continuing**: `activity continue` - Vote to proceed
        - When majority votes to continue, the activity advances
        - No time limit - rest as long as you need
  
        **Example:**
        ```
        Round 7: You've escaped the guards and found a safe room to rest.
  
        Your HP: 4/6 (lost 2 HP total → 1 is permanent)
  
        activity heal      (heals you to 5/6 - best possible)
        activity continue  (vote to move on when ready)
        ```
  
        ### Free Roll Rounds
  
        Open-ended problem solving where an AI Game Master evaluates your actions:
  
        - Describe what you want to do in your own words
        - **Assess first** (optional): `activity assess <description>` - Gather information
          - Can only assess once per action
          - Roll to see what you learn about the situation
        - **Take action**: `activity action <description>` - Describe what you do
          - The AI GM picks which stats apply and sets the difficulty
          - Your dice are rolled automatically
          - The AI narrates the outcome based on your roll
  
        **Example:**
        ```
        Round 9: A massive chasm blocks your path. There's no obvious way across.
  
        activity assess I look for anchor points and measure the distance
        → You successfully spot a sturdy pillar across the gap, about 40 feet away.
  
        activity action I tie rope to my grappling hook and throw it across to the pillar
        → Roll: 2d8 (Strength + Athletics) = 16 vs DC 12
        → Success! Your hook catches firmly. The rope holds as you swing across.
        ```
  
        ### Persuade Rounds
  
        Social encounters where you roleplay with an AI-controlled NPC:
  
        - The AI plays an NPC with a specific personality and goal
        - Use regular RP commands (`say`, `emote`) to talk to the NPC
        - The NPC will respond to you in character
        - When ready, roll to persuade: `activity persuade`
          - The AI evaluates how convincing your conversation was
          - Rating 1-5 affects the difficulty: +10 DC (terrible) to -10 DC (excellent)
          - Roll Charisma (or specified stat) against the adjusted DC
          - Success: You've convinced them! Failure: Keep trying with another attempt
  
        **Example:**
        ```
        Round 11: Guard Captain Thorne eyes you suspiciously.
        NPC Thorne: "State your business. This area is restricted."
  
        say We're here on official guild business, investigating the theft
        emote shows Thorne the forged investigation papers
        NPC Thorne: "These look legitimate... but I'm not convinced."
        say The guildmaster herself sent us. Every hour counts - lives are at stake!
  
        activity persuade
        → Evaluation: Rating 4 (Good arguments) = -5 DC
        → Roll: 2d8 (Charisma) + willpower = 18 vs DC 10
        → Success! Thorne nods. "Very well. I'll let you pass, but be quick."
        ```
  
        ### Combat Rounds
  
        The activity pauses and spawns a fight:
  
        - NPCs appear and combat begins (see Combat system)
        - Use regular combat commands: `fight`, `attack <target>`, `done`
        - When combat ends, the activity automatically resumes
        - Victory/defeat may affect the story or difficulty
  
        ### Reflex Rounds
  
        Fast-reaction tests with a shorter timeout (2 minutes instead of 8):
  
        - Tests a specific stat (usually Agility or Reflex)
        - Everyone must choose - no helping or recovering allowed
        - Quick decisions matter!
  
        ### Group Check Rounds
  
        Everyone rolls individually against the same challenge:
  
        - All participants must make their own roll
        - No helping or recovering allowed
        - Each person's result is evaluated separately
        - May require minimum number of successes to pass
  
        ## Dice Mechanics
  
        Understanding how rolls work helps you make better decisions:
  
        ### Base Roll
        - **2d8 exploding**: Roll two 8-sided dice
        - **Exploding**: Any die showing 8 is rolled again and added to the total
          - Example: Roll 8 → reroll 6 → total 14 from that die
          - Can chain indefinitely: 8, 8, 5 = 21!
        - **Critical failure**: If a die shows 1 on advantage, must take the 1
  
        ### Stat Bonuses
        - Each action uses 1-3 character stats
        - Your stat values are added to the dice roll
        - Higher stats = higher totals
  
        ### Willpower Dice
        - Spend 0-2 willpower to add extra d8 dice to your roll
        - Set with: `activity willpower <0-2>`
        - Each willpower die explodes on 8 just like base dice
        - Powerful but limited - use wisely!
        - Regain willpower with the Recover action
  
        ### Risk Dice
        - Some actions have risk/reward
        - Adds a d4 with values: -4, -3, -2, -1, +1, +2, +3, +4
        - Can help or hurt your total!
  
        ### Help and Advantage
        - If someone helps you, you get advantage on dice
        - **Advantage**: Roll 2 dice, take the higher result
          - **Exception**: If either die is 1, you MUST take the 1 (critical failure)
        - Two helpers = advantage on both base dice
  
        ### Success Calculation
        - **Your total** = Highest participant roll + Average of all risk rolls
        - **Success** if total ≥ Difficulty Class (DC)
        - DC varies by round and situation
  
        ## Choosing Actions
  
        Each round, you pick what to do:
  
        ### Regular Actions
        1. View options: `activity status` (shows available actions)
        2. Choose: `activity choose <number>`
        3. Set willpower: `activity willpower <0-2>` (optional)
        4. Wait for everyone to choose
  
        ### Special Actions
  
        **Help Another Player:**
        - `activity help <player name>`
        - You don't roll yourself - instead you give them advantage
        - Your choice of who to help is your action for the round
        - Can have multiple people help the same player
        - Advantage: They roll 2 dice and take higher (unless either is 1)
  
        **Recover Willpower:**
        - `activity recover`
        - Skip rolling this round to regain 1 willpower
        - Use when you're low on willpower and need to build it back up
        - Important for long activities with many rounds
  
        ## Remote Observation
  
        Watch activities from outside and help or hinder participants:
  
        ### Requesting to Observe
        1. Go to the room where an activity is running
        2. `observe support <player>` - Request to help them
        3. `observe oppose <player>` - Request to hinder them
        4. Player must accept: They use `observe accept <your name>`
        5. You now observe their activity remotely
  
        ### As an Observer
        - `observe status` - See activity status and your queued action
        - `observe actions` - List actions available for current round type
        - `observe action <type> <target>` - Submit an action
        - `observe leave` - Stop observing
  
        ### Observer Actions
  
        **Support actions:**
        - **stat_swap**: Let them use your stat instead of theirs for a roll
        - **reroll_ones**: Reroll any dice showing 1
        - **block_damage**: Reduce damage they take in combat
        - **halve_damage** (combat): Cut damage taken in half
        - **expose_targets** (combat): Make enemies easier to hit
        - **distraction** (persuade): Distract the NPC to make persuasion easier
  
        **Oppose actions:**
        - **block_explosions**: Their 8s don't explode (capped at 8)
        - **damage_on_ones**: If any die shows 1, they take 1 damage
        - **block_willpower**: Prevent willpower dice from being added
        - **redirect_npc** (combat): Make an NPC attack them
        - **aggro_boost** (combat): Increase enemy aggression
        - **npc_damage_boost** (combat): Enemies hit harder
        - **draw_attention** (persuade): Make the NPC focus on them negatively
  
        **Example:**
        ```
        observe support Alice
        → Alice accepts your request
  
        observe actions
        → Available support actions: stat_swap, reroll_ones
  
        observe action reroll_ones Alice
        → Queued: reroll_ones on Alice
        → When the round resolves, any of Alice's dice showing 1 will be rerolled
        ```
  
        ## Activity Progress
  
        Track how far you've come:
  
        - `activity status` - Current round, progress percentage, participants
        - Round counter shows: "Round 5 / 12" (current / total)
        - Progress bar: "Progress: [=========>    ] 75%"
        - Rounds done accumulates even on branching paths
        - Some activities have variable length based on choices
  
        ## Tips for Success
  
        1. **Communication**: Coordinate with your team about who does what
        2. **Manage willpower**: Don't spend it all early - you might need it later
        3. **Help synergy**: Multiple helpers on one person = very high success chance
        4. **Recovery timing**: Use rest rounds to heal and recover willpower
        5. **Branch votes**: Discuss before voting - wrong path can be dangerous
        6. **Free rolls**: Be creative and specific in your descriptions
        7. **Persuade rounds**: Roleplay genuinely - the AI evaluates your arguments
        8. **Observer coordination**: Remote supporters can turn the tide
  
        ## Advanced: Activity Mechanics
  
        For those who want to understand the math:
  
        ### Resolution Formula
        ```
        Individual Total = 2d8 (exploding) + stat bonuses + willpower dice
        Risk Average = Sum of all risk rolls / number of risk rolls
        Final Total = Highest individual total + Risk average
        Success = Final Total >= DC
        ```
  
        ### Permanent Damage (Rest Rounds)
        ```
        Permanent Damage = Total HP Lost / 2 (integer division)
        Max Healable HP = Max HP - Permanent Damage
  
        Examples:
        - Lost 1 HP: Permanent = 0, heal to full
        - Lost 2 HP: Permanent = 1, heal to max-1
        - Lost 4 HP: Permanent = 2, heal to max-2
        - Lost 5 HP: Permanent = 2, heal to max-2
        ```
  
        ### Observer Effect Stacking
        - Multiple supporters can use different effects
        - Multiple opposers can use different effects
        - Same effect from multiple observers: Only strongest applies
        - Effects resolve in order during dice rolling
  
        ## Troubleshooting
  
        **"No activity running"**: Use `activity list` to see available activities, then `activity start <name>`
  
        **"You haven't chosen yet"**: Use `activity choose <number>` to pick an action
  
        **"Not all participants ready"**: Wait for everyone to make their choice, or they'll time out (8 minutes default)
  
        **"Can't help yourself"**: Help action requires targeting another player: `activity help <name>`
  
        **"Observe request expired"**: Requests expire after 2 minutes - send a new one
  
        **"Already used assess"**: You can only assess once before each action in free roll rounds
  
        **Branch round stuck**: Encourage everyone to vote! Majority needed, or timeout will pick first option.
  
        ## Command Quick Reference
  
        **Basic:**
        - `activity list` - Show available activities
        - `activity start <name>` - Start an activity
        - `activity join` - Join setup activity
        - `activity leave` - Leave activity
        - `activity status` - Show current status
  
        **Standard rounds:**
        - `activity choose <number>` - Choose an action
        - `activity help <player>` - Help another player
        - `activity recover` - Skip roll, gain willpower
        - `activity willpower <0-2>` - Spend willpower dice (adds d8s to roll)
  
        **Branch rounds:**
        - `activity vote <number>` - Vote for a branch
  
        **Rest rounds:**
        - `activity heal` - Heal damage
        - `activity continue` - Vote to proceed
  
        **Free roll rounds:**
        - `activity assess <description>` - Gather information (once per action)
        - `activity action <description>` - Take an action
  
        **Persuade rounds:**
        - Use `say` and `emote` for RP with the NPC
        - `activity persuade` - Attempt the persuasion roll
  
        **Observation:**
        - `observe support <player>` - Request to support
        - `observe oppose <player>` - Request to oppose
        - `observe accept <player>` - Accept an observe request
        - `observe reject <player>` - Reject an observe request
        - `observe status` - Show observation status
        - `observe actions` - List available actions
        - `observe action <type> <target>` - Submit action
        - `observe leave` - Stop observing
      GUIDE
      staff_notes: <<~'STAFF',
        # Missions/Activities System - Technical Implementation
  
        The activity system provides structured multi-round gameplay scenarios with dice rolling, branching paths, AI-powered resolution, and remote observation mechanics.
  
        ## Architecture Overview
  
        **Service Layer:**
        - `ActivityService`: Lifecycle orchestration (start, join, resolve, advance)
        - `ActivityResolutionService`: Dice mechanics and standard round resolution
        - `ActivityBranchService`: Group voting and branch selection
        - `ActivityRestService`: Healing mechanics and continue voting
        - `ActivityFreeRollService`: LLM-based open-ended action evaluation (Claude Sonnet 4.5)
        - `ActivityPersuadeService`: LLM-based social encounters (DeepSeek v3.2)
        - `ObserverEffectService`: Remote observer action processing
  
        **Model Layer:**
        - `Activity`: Template definition with activity type, rounds, and configuration
        - `ActivityInstance`: Running activity instance with state tracking
        - `ActivityParticipant`: Individual participant with choices and willpower
        - `ActivityRound`: Round definition with type-specific configuration
        - `ActivityAction`: Menu choice options with stat requirements
        - `ActivityRemoteObserver`: Support/oppose observers with consent tracking
  
        **Command Layer:**
        - `Commands::Activity::Activity`: Main activity command with 20+ subcommands
        - `Commands::Activity::Observe`: Remote observation command
  
        ## Activity Lifecycle
  
        ### 1. Activity Creation (ActivityService.start_activity)
        ```ruby
        instance = ActivityInstance.create(
          activity_id: activity.id,
          room_id: room.id,
          initiator_id: character.id,
          running: false,
          setup_stage: 0,
          rounds_done: 0,
          branch: 0
        )
        ```
  
        ### 2. Participant Addition (ActivityService.add_participant)
        ```ruby
        participant = ActivityParticipant.create(
          instance_id: instance.id,
          char_id: character.id,
          continue: true,
          willpower: 5,  # Starting willpower
          willpower_ticks: 0
        )
        ```
  
        ### 3. Setup Progression
        - Stage 0: Created, accepting joins
        - Stage 1: Locked, no more joins
        - Stage 2: Started (running = true), first round begins
        - Stage 3: Completed
  
        ### 4. Round Resolution Loop
        1. Broadcast round description (`emit_text`)
        2. Wait for all participants to choose (or timeout)
        3. Call appropriate resolution service based on round type
        4. Apply consequences (damage, willpower changes, scoring)
        5. Advance to next round or complete activity
        6. Reset participant choices for next round
  
        ## Round Type Implementations
  
        ### Standard Rounds (ActivityResolutionService)
  
        **Resolution Algorithm:**
        ```ruby
        def resolve(instance, round)
          # Process recoveries first (gain willpower, no roll)
          process_recoveries(participants)
  
          # Calculate help bonuses (who's helping whom)
          help_map = calculate_help_bonuses(participants)
  
          # Roll for each participant
          participants.each do |p|
            next unless p.has_chosen?
  
            action_type = determine_action_type(p)
            next if action_type == 'help' || action_type == 'recover'
  
            action = p.chosen_action
            roll_result = roll_for_participant(p, action, help_map[p.id])
  
            participant_rolls << roll_result
            roll_totals << roll_result.total
            risk_totals << roll_result.risk_result if roll_result.risk_result
          end
  
          # Calculate success
          highest_roll = roll_totals.max || 0
          avg_risk = risk_totals.sum.to_f / risk_totals.size
          final_total = highest_roll + avg_risk
  
          dc = round.difficulty_class || instance.current_difficulty || 10
          success = final_total >= dc
        end
        ```
  
        **Dice Rolling Implementation:**
        ```ruby
        def roll_for_participant(participant, action, help_bonus)
          # Get observer effects
          effects = ObserverEffectService.effects_for(participant, round_type: :standard)
  
          # Calculate stat bonus (or use stat_swap if present)
          stat_bonus = if effects[:stat_swap]
            # Use observer's specified stat instead
            character_instance.get_stat_value(effects[:stat_swap])
          else
            action.stat_bonus_for(character_instance)
          end
  
          # Roll base 2d8 with help advantage
          helper_count = help_bonus&.dig(:helper_count) || 0
          if effects[:block_explosions]
            dice_results = roll_base_dice_no_explode(helper_count)
          else
            dice_results = roll_base_dice_with_help(helper_count)
          end
  
          # Add willpower dice (unless blocked by observer)
          unless effects[:block_willpower]
            willpower_to_spend = [participant.willpower_to_spend.to_i, 2].min
            willpower_to_spend.times do
              dice_results << roll_exploding_d8
              participant.use_willpower!(1)
            end
          end
  
          # Apply reroll_ones effect
          if effects[:reroll_ones]
            dice_results = reroll_ones(dice_results, explode: !effects[:block_explosions])
          end
  
          # Apply damage_on_ones effect
          if effects[:damage_on_ones] && dice_results.any? { |d| d == 1 }
            character_instance.take_damage(1)
          end
  
          # Roll risk dice if action has risk
          risk_result = action.risk_dice? ? roll_risk_dice : nil
  
          # Calculate total
          dice_total = dice_results.sum
          total = dice_total + stat_bonus
        end
        ```
  
        **Exploding Dice:**
        ```ruby
        def roll_exploding_d8
          total = 0
          loop do
            roll = rand(1..8)
            total += roll
            break unless roll == 8  # Keep rolling on 8
          end
          total
        end
        ```
  
        **Advantage with Critical Failure:**
        ```ruby
        def roll_with_advantage
          roll1 = roll_exploding_d8_check_one
          roll2 = roll_exploding_d8_check_one
  
          # If either is 1, must take 1 (critical failure precedence)
          return 1 if roll1 == 1 || roll2 == 1
  
          [roll1, roll2].max  # Otherwise take higher
        end
        ```
  
        **Risk Dice:**
        ```ruby
        RISK_VALUES = [-4, -3, -2, -1, 1, 2, 3, 4].freeze
  
        def roll_risk_dice
          RISK_VALUES.sample  # Random element from array
        end
        ```
  
        ### Branch Rounds (ActivityBranchService)
  
        **Voting and Resolution:**
        ```ruby
        def resolve(instance, round)
          choices = round.expanded_branch_choices
          votes = instance.branch_votes  # Hash of branch_id => count
  
          # Find winning branch
          winning_branch_id = nil
          winning_count = 0
  
          choices.each_with_index do |choice, idx|
            branch_id = choice[:branch_to_round_id] || idx
            count = votes[branch_id] || 0
  
            if count > winning_count
              winning_count = count
              winning_branch_id = branch_id
              winning_text = choice[:text]
            end
          end
  
          # Handle no votes (timeout) - pick first choice
          if winning_branch_id.nil? && choices.any?
            winning_branch_id = choices.first[:branch_to_round_id] || 0
          end
        end
        ```
  
        **Branch Tracking:**
        - `ActivityInstance.branch`: Current branch number (0 = main)
        - `ActivityInstance.branch_round_at`: Round number when branch was entered
        - `ActivityRound.branch_to`: Target round ID for branch transition
        - Branch choices stored in JSONB: `[{text, branch_to_round_id, description}]`
  
        ### Rest Rounds (ActivityRestService)
  
        **Permanent Damage Calculation:**
        ```ruby
        def heal_at_rest(participant)
          character_instance = participant.character_instance
          previous_hp = character_instance.current_hp
          max_hp = character_instance.max_hp
  
          # Every 2 HP lost = 1 permanent damage
          damage_taken = max_hp - previous_hp
          permanent_damage = damage_taken / 2  # Integer division
  
          # Calculate healable maximum
          healable_to = max_hp - permanent_damage
  
          # Already at or above healable max
          return if previous_hp >= healable_to
  
          # Heal to max healable
          character_instance.update(current_hp: healable_to)
          healed_amount = healable_to - previous_hp
        end
        ```
  
        **Continue Voting:**
        ```ruby
        def majority_wants_continue?(instance)
          total = instance.active_participants.count
          return false if total.zero?
  
          continue_votes = instance.continue_votes
          continue_votes > (total / 2.0)  # More than 50%
        end
        ```
  
        ### Free Roll Rounds (ActivityFreeRollService)
  
        **LLM Integration (Claude Sonnet 4.6):**
        ```ruby
        FREE_ROLL_MODEL = 'claude-sonnet-4-6'
        FREE_ROLL_PROVIDER = 'anthropic'
  
        def take_action(participant, description, round)
          # Build prompt from GamePrompts.yml
          prompt = GamePrompts.get('activities.free_roll.action',
                                    activity_name: activity.display_name,
                                    round_description: round.emit_text,
                                    participant_name: participant.character.full_name,
                                    action_text: description)
  
          # Call LLM with JSON mode
          result = LLM::Client.generate(
            prompt: prompt,
            model: FREE_ROLL_MODEL,
            provider: FREE_ROLL_PROVIDER,
            json_mode: true,
            options: { max_tokens: 500, temperature: 0.7 }
          )
  
          # Parse LLM response
          evaluation = parse_evaluation(result[:text])
          # Expected JSON: {stat_names: [], dc: N, success_desc: "", failure_desc: ""}
  
          # Roll for the action
          roll_total = roll_for_stats(participant, evaluation.stat_ids)
          success = roll_total >= evaluation.dc
  
          # Get narration from LLM
          narration = success ? evaluation.success_desc : evaluation.failure_desc
        end
        ```
  
        **Assess Mechanic:**
        ```ruby
        def assess(participant, description, round)
          # Can only assess once per action
          raise FreeRollError, 'Already used assess' if participant.assess_used?
  
          # LLM evaluates what they're assessing
          evaluation = call_llm_for_assessment(description, round)
  
          # Roll the assess check
          roll_result = roll_for_stats(participant, evaluation.stat_ids)
  
          # Determine what they learn based on roll
          context = if roll_result >= evaluation.dc
            evaluation.context_revealed  # Success - they learn something
          else
            'You fail to discern anything useful.'  # Failure
          end
  
          # Mark assess as used
          participant.use_assess!
        end
        ```
  
        ### Persuade Rounds (ActivityPersuadeService)
  
        **LLM Integration (DeepSeek):**
        ```ruby
        PERSUADE_MODEL = 'deepseek/deepseek-v3.2'
        PERSUADE_PROVIDER = 'openrouter'
  
        PERSUASION_RATINGS = {
          1 => { modifier: 10, label: 'Not at all convincing' },
          2 => { modifier: 5, label: 'Weak attempt' },
          3 => { modifier: 0, label: 'Reasonable' },
          4 => { modifier: -5, label: 'Good arguments' },
          5 => { modifier: -10, label: 'Excellent, nearly convinced' }
        }
        ```
  
        **Conversation Tracking:**
        - Uses `LLMConversation` and `LLMMessage` models
        - Conversation stored with purpose: 'activity_persuade'
        - System prompt defines NPC personality from `round.persuade_npc_personality`
        - Each player message and NPC response tracked
        - Full transcript sent to LLM for evaluation
  
        **NPC Response Generation:**
        ```ruby
        def npc_respond(instance, round, player_message, speaker)
          conversation = get_or_create_conversation(instance, round)
  
          # Add player message
          add_message(conversation, 'user', "#{speaker.full_name} says: #{player_message}")
  
          # Get NPC response from LLM
          response = call_llm_for_response(conversation, round)
          npc_text = response[:text] || 'The NPC considers your words.'
  
          # Store NPC response
          add_message(conversation, 'assistant', npc_text)
        end
        ```
  
        **Evaluation and Roll:**
        ```ruby
        def evaluate_persuasion(instance, round)
          transcript = build_transcript(conversation)
  
          # LLM evaluates conversation
          result = call_llm_for_evaluation(transcript, round)
          # Expected JSON: {rating: 1-5, feedback: ""}
  
          rating = result['rating'].to_i.clamp(1, 5)
          dc_modifier = PERSUASION_RATINGS[rating][:modifier]
  
          # Calculate final DC with observer effects
          base_dc = round.persuade_base_dc || 15
          observer_modifier = ObserverEffectService.persuade_dc_modifier(instance)
          adjusted_dc = (base_dc + dc_modifier + observer_modifier).clamp(5, 30)
        end
        ```
  
        ## Observer Effect System (ObserverEffectService)
  
        **Effect Processing:**
        ```ruby
        def effects_for(participant, round_type:)
          instance = participant.instance
          observers = instance.remote_observers.active.all
  
          effects = {}
  
          observers.each do |obs|
            next unless obs.has_action?
            next unless obs.action_target_id == participant.id
  
            action_type = obs.action_type
  
            case action_type
            when 'stat_swap'
              # Observer provides their stat value
              effects[:stat_swap] = determine_stat_for_swap(obs)
            when 'reroll_ones'
              effects[:reroll_ones] = true
            when 'block_explosions'
              effects[:block_explosions] = true
            when 'damage_on_ones'
              effects[:damage_on_ones] = true
            when 'block_willpower'
              effects[:block_willpower] = true
            # ... more effects
            end
          end
  
          effects
        end
        ```
  
        **Observer Actions by Role:**
  
        Support actions (help participant):
        - `stat_swap`: Use observer's stat instead of action's stat
        - `reroll_ones`: Reroll any dice showing 1
        - `block_damage`: Reduce damage in combat
        - `halve_damage`: Cut combat damage in half
        - `expose_targets`: Make NPCs easier to hit
        - `distraction`: -5 DC on persuade checks
  
        Oppose actions (hinder participant):
        - `block_explosions`: 8s don't explode (capped at 8)
        - `damage_on_ones`: Take 1 damage if any die shows 1
        - `block_willpower`: Can't add willpower dice
        - `redirect_npc`: Make NPC attack this participant
        - `aggro_boost`: Increase NPC aggression
        - `npc_damage_boost`: NPCs deal more damage
        - `draw_attention`: +5 DC on persuade checks
  
        ## Models and Schema
  
        ### Activity (Template)
        ```sql
        activity_id SERIAL PRIMARY KEY
        activity_type VARCHAR  -- mission, competition, task, etc.
        display_name VARCHAR
        location_id INTEGER   -- Default room for this activity
        total_rounds INTEGER
        wins INTEGER          -- Success count
        losses INTEGER        -- Failure count
        ```
  
        **Activity Types:**
        - mission, competition, tcompetition, task, elimination, collaboration
        - adventure, encounter, survival, intersym, interasym
  
        ### ActivityInstance (Running Activity)
        ```sql
        id SERIAL PRIMARY KEY
        activity_id INTEGER
        room_id INTEGER
        initiator_id INTEGER
        running BOOLEAN
        setup_stage INTEGER  -- 0=created, 1=locked, 2=started, 3=completed
        rounds_done INTEGER
        branch INTEGER       -- Current branch (0 = main)
        branch_round_at INTEGER  -- Round when branched
  
        -- Difficulty tracking
        this_enemy INTEGER   -- Base difficulty
        inc_difficulty INTEGER  -- Accumulated difficulty modifier
  
        -- Combat integration
        paused_for_fight_id INTEGER
  
        -- Persuade tracking
        persuade_attempts INTEGER
  
        -- Timing
        round_started_at TIMESTAMP
        last_round TIMESTAMP
        ```
  
        ### ActivityParticipant
        ```sql
        id SERIAL PRIMARY KEY
        instance_id INTEGER
        char_id INTEGER
        continue BOOLEAN     -- Active status
        team VARCHAR         -- 'one' or 'two' for competitions
        role VARCHAR         -- Optional role restriction
  
        -- Choice tracking
        action_chosen INTEGER  -- ActivityAction ID
        special_action VARCHAR  -- 'help' or 'recover' special actions
        risk_chosen VARCHAR
        action_target INTEGER  -- Target participant ID for help
        willpower_to_spend INTEGER
        chosen_when TIMESTAMP
  
        -- Results
        roll_result INTEGER
        expect_roll INTEGER  -- DC they rolled against
        score NUMERIC
  
        -- Willpower
        willpower INTEGER
        willpower_ticks INTEGER
  
        -- Branch voting
        branch_vote INTEGER
  
        -- Rest voting
        voted_continue BOOLEAN
  
        -- Free roll
        assess_used BOOLEAN
        action_count INTEGER  -- Number of actions taken in free roll
        ```
  
        ### ActivityRound
        ```sql
        id SERIAL PRIMARY KEY
        activity_id INTEGER
        round_number INTEGER
        branch INTEGER  -- 0 = main branch
        rtype VARCHAR   -- Round type
  
        -- Standard round
        actions INTEGER[]  -- Array of ActivityAction IDs
        emit VARCHAR       -- Description text
        succ_text VARCHAR  -- Success narration
        fail_text VARCHAR  -- Failure narration
  
        -- Difficulty
        difficulty_class INTEGER
  
        -- Branch round
        branch_choices JSONB  -- [{text, branch_to_round_id, description}]
        branch_to INTEGER     -- Legacy single branch target
        fail_branch_to INTEGER
  
        -- Combat round
        combat_npc_ids INTEGER[]
        combat_difficulty VARCHAR
        combat_is_finale BOOLEAN
        battle_map_room_id INTEGER
  
        -- Reflex round
        reflex_stat_id INTEGER
  
        -- Persuade round
        persuade_npc_name VARCHAR
        persuade_npc_personality TEXT
        persuade_goal TEXT
        persuade_base_dc INTEGER
        persuade_stat_id INTEGER
  
        -- Free roll round
        free_roll_context TEXT
  
        -- Media
        media_url VARCHAR
        media_type VARCHAR
        media_display_mode VARCHAR
        media_duration_mode VARCHAR
  
        -- Canvas positioning (for activity builder UI)
        canvas_x INTEGER
        canvas_y INTEGER
  
        -- Room assignment
        round_room_id INTEGER
        use_activity_room BOOLEAN
  
        -- Timing
        timeout_seconds INTEGER
        ```
  
        **Round Types:**
        - `standard`: Menu choices with dice rolling
        - `reflex`: Fast stat check (2-minute timeout)
        - `group_check`: Everyone rolls separately
        - `branch`: Group voting on path
        - `combat`: Spawn fight
        - `free_roll`: LLM-evaluated open actions
        - `persuade`: LLM-driven social encounter
        - `rest`: Healing and recovery
        - `break`: Narrative pause (no mechanics)
  
        ### ActivityAction (Choice Option)
        ```sql
        id SERIAL PRIMARY KEY
        activity_parent INTEGER
        choice_string VARCHAR  -- Display text
        output_string VARCHAR  -- Success text
        fail_string VARCHAR    -- Failure text
  
        -- Stat requirements
        skill_one INTEGER
        skill_two INTEGER
        skill_three INTEGER
        skill_four INTEGER
        skill_five INTEGER
        skill_list INTEGER[]  -- Modern array approach
  
        -- Role restriction
        allowed_roles VARCHAR  -- Comma-separated role names
  
        -- Risk
        risk_dice BOOLEAN
        ```
  
        ### ActivityRemoteObserver
        ```sql
        id SERIAL PRIMARY KEY
        activity_instance_id INTEGER
        character_instance_id INTEGER
        consented_by_id INTEGER  -- Who accepted the request
        role VARCHAR  -- 'support' or 'oppose'
        active BOOLEAN
  
        -- Current action
        action_type VARCHAR
        action_target_id INTEGER  -- Target participant
        action_secondary_target_id INTEGER
        action_message TEXT
        action_submitted_at TIMESTAMP
        ```
  
        ## Configuration
  
        **GamePrompts Integration:**
        ```yaml
        activities:
          free_roll:
            assess: "You are the GM... [assessing %{assessment_text}]"
            action: "You are the GM... [action: %{action_text}]"
          persuade:
            npc_system: "You are %{npc_name}... personality: %{npc_personality}"
            evaluation: "Evaluate this conversation... goal: %{persuade_goal}"
            success_response: "Generate NPC accepting..."
            failure_response: "Generate NPC rejecting (rating %{rating})..."
        ```
  
        **GameSettings Flags:**
        - `activity_free_roll_enabled`: Enable LLM-based free roll rounds
        - `activity_persuade_enabled`: Enable LLM-based persuade rounds
  
        ## Performance Considerations
  
        **Batch Operations:**
        - Reset participant choices: Batch update instead of N queries
        - Reset continue votes: Batch update all participants at once
        - Clear observer actions: Single UPDATE statement for all observers
  
        **Caching:**
        - Activity template loaded once per instance
        - Round definitions cached during resolution
        - Participant list fetched once per round
  
        **LLM Rate Limiting:**
        - Free roll rounds: Max 500 tokens per action evaluation
        - Persuade rounds: Max 300 tokens per NPC response
        - Temperature varies: 0.7 for actions, 0.5 for evaluations
  
        ## Testing Patterns
  
        **ActivityService specs:**
        - Test lifecycle: start → join → setup → run → complete
        - Test round advancement and branch tracking
        - Test timeout handling
  
        **ActivityResolutionService specs:**
        - Test dice mechanics: exploding, advantage, critical failure
        - Test willpower spending
        - Test help bonuses
        - Test observer effects
        - Test risk dice averaging
  
        **Round-specific service specs:**
        - Branch: Test voting, majority, timeout
        - Rest: Test healing formulas, continue voting
        - Free Roll: Mock LLM responses, test parsing
        - Persuade: Mock conversation flow, test rating calculations
  
        **Observer specs:**
        - Test consent flow (request → accept/reject)
        - Test action submission and clearing
        - Test effect application during resolution
  
        ## Common Patterns
  
        **Starting an activity:**
        ```ruby
        instance = ActivityService.start_activity(activity, room, initiator)
        ActivityService.add_participant(instance, character1)
        ActivityService.add_participant(instance, character2)
        instance.update(setup_stage: 2, running: true)
        instance.start_round_timer!
        ```
  
        **Resolving a round:**
        ```ruby
        round = instance.current_round
  
        result = case round.round_type.to_sym
        when :standard, :reflex, :group_check
          ActivityResolutionService.resolve(instance, round)
        when :branch
          ActivityBranchService.resolve(instance, round)
        when :rest
          ActivityRestService.resolve(instance, round)
        when :free_roll
          # Free roll rounds don't auto-resolve - wait for all actions
          ActivityFreeRollService.check_round_complete(instance, round)
        when :persuade
          # Persuade rounds need explicit persuade attempts
          nil
        end
        ```
  
        **Advancing to next round:**
        ```ruby
        instance.advance_round!  # Increments rounds_done, resets choices
        instance.start_round_timer!
  
        # Handle branching
        if result[:chosen_branch_id]
          instance.switch_branch!(result[:chosen_branch_id])
        end
  
        # Check completion
        if instance.rounds_done >= instance.total_rounds
          instance.complete!(success: result[:success])
        end
        ```
  
        ## Debugging
  
        **Common issues:**
        - "Not all participants ready": Check `participant.has_chosen?` logic
        - "No actions available": Verify round.actions array is populated
        - "Observer effects not applying": Check target_id matches participant.id
        - "LLM timeout": Check GameSettings flags and API credentials
        - "Healing not working": Verify permanent damage calculation
        - "Branch not advancing": Check majority_branch_vote calculation
  
        **Useful queries:**
        ```ruby
        # Find stuck activities
        ActivityInstance.where(running: true).where { round_started_at < Time.now - 3600 }
  
        # Check participant choices
        instance.active_participants.map { |p| [p.character.full_name, p.has_chosen?] }
  
        # View branch votes
        instance.branch_votes  # => {0 => 2, 1 => 3}
  
        # Check observer coverage
        instance.remote_observers.active.map { |o| [o.role, o.character_instance.character.full_name] }
        ```
      STAFF
      display_order: 50
    },
    {
      name: 'items_economy',
      display_name: 'Items & Economy',
      summary: 'Items, inventory, shopping, banking, clothing, eating, and storage',
      description: "Everything related to items and money. Pick up, drop, and give items. Browse and buy from shops. Manage your bank account. Wear and remove clothing with layering, outfits, and body positions. Consume food, drinks, and smokables. Store items and save locations and gradients for later use. Property purchases include houses, shops, and vehicles.",
      command_names: ['get', 'drop', 'give', 'inventory', 'hold', 'pocket', 'show', 'trash', 'use', 'equipment', 'balance', 'shop', 'buy', 'deposit', 'withdraw', 'preview', 'wear', 'remove', 'outfit', 'dress', 'strip', 'cover', 'expose', 'flash', 'unzip', 'zipup', 'wardrobe'],
      related_systems: %w[character_customization crafting combat],
      key_files: [
        'plugins/core/inventory/commands/get.rb',
        'plugins/core/inventory/commands/drop.rb',
        'plugins/core/inventory/commands/give.rb',
        'plugins/core/inventory/commands/inventory.rb',
        'plugins/core/inventory/commands/trash.rb',
        'plugins/core/inventory/commands/use.rb',
        'plugins/core/economy/commands/shop.rb',
        'plugins/core/economy/commands/buy.rb',
        'plugins/core/economy/commands/balance.rb',
        'plugins/core/clothing/commands/wear.rb',
        'plugins/core/clothing/commands/remove.rb',
        'plugins/core/clothing/commands/outfit.rb',
        'plugins/core/storage/commands/wardrobe.rb',
        'app/models/item.rb',
        'app/models/pattern.rb',
        'app/models/wallet.rb',
        'app/models/shop.rb',
        'app/models/shop_item.rb',
        'app/models/bank_account.rb',
        'app/models/outfit.rb',
        'app/services/wardrobe_service.rb',
        'app/models/item_body_position.rb'
      ],
      player_guide: <<~'GUIDE',
        # Items & Economy System
  
        The items and economy system covers everything related to objects and money: picking up items, managing inventory, shopping, banking, wearing clothing, and storing items across locations.
  
        ## Inventory Basics
  
        ### Viewing Your Inventory
  
        - `inventory` (or `inv` or `i`) - See everything you're carrying
          - Shows wallet balance
          - Items in hand (held)
          - Items carrying (in pockets/bags)
          - Items wearing (on your body)
  
        **Example:**
        ```
        inventory
  
        === Inventory ===
  
        Wallet:
          $250
  
        In Hand:
          flashlight
  
        Carrying:
          (3) energy bars
          water bottle
          notebook
  
        Wearing:
          leather jacket
          blue jeans
          sneakers
        ```
  
        ### Picking Up Items
  
        - `get <item>` - Pick up an item from the ground
        - `get all` - Pick up everything in the room
        - `get money` - Pick up money from the ground
        - `get 50` - Pick up a specific amount of money
  
        **Aliases:** `take`, `pickup`, `grab`, `pick up`
  
        **Examples:**
        ```
        get sword
        → You pick up the ancient sword.
  
        get all
        → You pick up: backpack, water bottle, 3 energy bars.
  
        get 100
        → You pick up $100.
        ```
  
        ### Dropping Items
  
        - `drop <item>` - Drop an item on the ground
        - `drop all` - Drop everything you're carrying
  
        **Examples:**
        ```
        drop flashlight
        → You drop the flashlight.
  
        drop all
        → You drop everything you're carrying (12 items).
        ```
  
        ### Giving Items
  
        - `give <item> to <person>` - Give an item to another player
  
        **Examples:**
        ```
        give sword to Alice
        → You give the ancient sword to Alice.
        ```
  
        ### Showing Items
  
        - `show <item> to <person>` - Show item without giving
        - `show <item>` - Show to everyone in the room
  
        ### Holding and Pocketing
  
        - `hold <item>` - Move item to your hand
        - `pocket <item>` - Move item from hand to inventory
  
        ### Destroying Items
  
        - `trash <item>` - Permanently destroy an item (no getting it back!)
  
        ## Shopping System
  
        ### Browsing Shops
  
        When you're in a room with a shop:
  
        - `shop` - Open the shop menu
        - `shop list` (or just `list`) - View items for sale
        - `shop buy <item>` - Purchase an item
        - `buy <item>` - Quick purchase
  
        **Examples:**
        ```
        shop
        → Opens interactive menu with shop options
  
        shop list
        → Shows all items for sale with prices
  
        shop buy leather jacket
        → You buy a leather jacket for $75.
  
        buy 3 energy bars
        → You buy 3 energy bars for $12 ($4 each).
        ```
  
        ### Payment
  
        Shops automatically deduct from:
        1. Your **bank account** first (if the shop accepts bank cards)
        2. Your **wallet** second (cash on hand)
  
        **Cash-only shops** only accept wallet money.
  
        ### Shop Ownership
  
        If you own a shop (own the building), you can manage stock:
  
        - `shop stock` - View your inventory
        - `shop add <price> <item>` - Add item from your inventory to shop
        - `shop remove <item>` - Remove item from shop
  
        **Examples:**
        ```
        shop add 50 leather jacket
        → Added leather jacket to shop at $50.
  
        shop remove old boots
        → Removed old boots from shop.
        ```
  
        ## Money Management
  
        ### Checking Balance
  
        - `balance` - Check your wallet and bank account balances
  
        **Example:**
        ```
        balance
  
        === Balance ===
  
        Wallet: $125
        Bank Account (First National): $1,542
        Total Available: $1,667
        ```
  
        ### Banking
  
        At a bank location:
  
        - `deposit <amount>` - Deposit money from wallet to bank
        - `withdraw <amount>` - Withdraw money from bank to wallet
  
        **Examples:**
        ```
        deposit 100
        → You deposit $100 into your bank account.
        → Wallet: $25 | Bank: $1,642
  
        withdraw 50
        → You withdraw $50 from your bank account.
        → Wallet: $75 | Bank: $1,592
        ```
  
        ## Clothing System
  
        ### Wearing Clothing
  
        - `wear <item>` - Put on clothing or jewelry
        - `wear <item1>, <item2>, <item3>` - Wear multiple items
        - `wear` - Show menu of wearable items
  
        **Aliases:** `don`, `put on`
  
        **Examples:**
        ```
        wear jacket
        → You put on a leather jacket.
  
        wear hat, scarf, gloves
        → You put on a winter hat, scarf, and gloves.
        ```
  
        ### Removing Clothing
  
        - `remove <item>` - Take off clothing
        - `remove all` - Remove everything
  
        **Aliases:** `take off`, `doff`
  
        **Examples:**
        ```
        remove jacket
        → You remove your leather jacket.
  
        remove all
        → You remove everything you're wearing.
        ```
  
        ### Piercings (Special Handling)
  
        Piercings need a body position:
  
        - `wear <piercing> on <position>` - Wear at specific position
        - `remove <piercing>` - Remove from piercing hole
  
        **Example:**
        ```
        wear gold ring on left ear
        → You put the gold ring in your left ear piercing.
  
        remove gold ring
        → You remove the gold ring from your left ear.
        ```
  
        ### Clothing Layers
  
        Clothing has different layers (underwear, shirt, jacket, etc.). The system tracks what goes over what for realistic layering.
  
        ### Outfit System
  
        Save complete outfits for quick dressing:
  
        **Saving Outfits:**
        - `outfit save <name>` - Save what you're currently wearing
        - `outfit save <name> as <type>` - Save as partial outfit
  
        **Types:**
        - `full` - Complete outfit (removes everything when worn)
        - `underwear` - Just underwear
        - `top` - Just shirts/tops
        - `bottom` - Just pants/skirts
        - `overwear` - Just jackets/coats
        - `jewelry` - Just jewelry
        - `accessories` - Just accessories
  
        **Wearing Outfits:**
        - `outfit wear <name>` - Wear a saved outfit
        - `dress <name>` - Quick wear outfit
  
        **Managing Outfits:**
        - `outfit list` - View saved outfits
        - `outfit delete <name>` - Delete an outfit
  
        **Examples:**
        ```
        outfit save casual
        → Saved current outfit as "casual" (6 items).
  
        outfit save work jewelry as jewelry
        → Saved jewelry outfit "work jewelry" (necklace, earrings, bracelet).
  
        dress casual
        → You remove what you're wearing and put on: jeans, t-shirt, sneakers, jacket, cap, watch.
  
        outfit list
        → Your outfits:
          1. casual (6 items) - full
          2. formal (8 items) - full
          3. work jewelry (3 items) - jewelry
        ```
  
        ### Coverage and Exposure
  
        Some clothing covers body parts. Commands for adjusting coverage:
  
        - `cover <position>` - Cover a body part
        - `expose <position>` - Expose a body part
        - `flash <position>` - Briefly expose then re-cover
  
        ### Zippers
  
        Some clothing has zippers:
  
        - `unzip <item>` - Unzip clothing
        - `zipup <item>` - Zip up clothing
  
        ## Wardrobe (Cross-Location Storage)
  
        The wardrobe system lets you store items and transfer them between locations.
  
        ### Requirements
  
        - Must be in your **home** or a **storage facility**
        - Each location has separate storage
  
        ### Basic Storage
  
        - `wardrobe` - Open wardrobe menu
        - `wardrobe store <item>` - Store item from inventory
        - `wardrobe store all` - Store all inventory items
        - `wardrobe retrieve <item>` - Get item from wardrobe
        - `wardrobe retrieve all` - Get everything stored here
        - `wardrobe list` - View stored items at this location
  
        **Aliases:** `closet`, `vault`
        **Store aliases:** `store`, `stash`
        **Retrieve aliases:** `retrieve`, `ret`, `fetch`
  
        **Examples:**
        ```
        wardrobe store sword
        → You store the ancient sword in your wardrobe.
  
        wardrobe list
        → Your Wardrobe Here (3 items):
          ancient sword
          leather jacket
          winter coat
  
        wardrobe retrieve jacket
        → You retrieve the leather jacket from your wardrobe.
        ```
  
        ### Transferring Between Locations
  
        Move items from one storage location to another (12-hour delay):
  
        - `wardrobe transfer` - List locations with stored items
        - `wardrobe transfer from <location>` - Start transfer
        - `transfer from <location>` - Quick transfer command
        - `wardrobe status` - Check transfer progress
  
        **Aliases:** `transfer`, `ship`, `summon`
  
        **How it works:**
        1. Items are marked as "in transit" when you start transfer
        2. After 12 real-time hours, items arrive at destination
        3. Check `wardrobe status` to see time remaining
        4. When ready, items automatically appear in new location's wardrobe
  
        **Examples:**
        ```
        wardrobe transfer from apartment
        → Transfer initiated: 8 items from Downtown Apartment.
        → Items will be available here in 12 hours.
  
        wardrobe status
        → Transfers In Progress:
          To Beach House: 8 items - 7h 23m remaining
  
        [12 hours later]
  
        wardrobe status
        → Transfers Completed (8 items now available):
          * winter coat
          * formal suit
          * dress shoes
          [... 5 more items]
        ```
  
        ### Storage Tips
  
        - **Organize by location**: Keep seasonal items where you need them
        - **Transfer ahead**: Start transfers before you travel
        - **Check status**: Use `wardrobe status` to track deliveries
        - **Quick retrieve**: `retrieve all` when you arrive somewhere
  
        ## Using Consumables
  
        ### Eating, Drinking, Smoking
  
        - `eat <item>` - Consume food
        - `drink <item>` - Consume drinks
        - `smoke <item>` - Smoke tobacco/other
  
        Consumable items are used up when consumed and may provide buffs or effects.
  
        ### Generic Use
  
        - `use <item>` - Use an item (activates special abilities)
  
        ## Item Conditions
  
        Items have condition states that affect value:
        - **Excellent** - Pristine condition
        - **Good** - Normal wear
        - **Fair** - Shows wear
        - **Poor** - Damaged
        - **Broken** - Non-functional
  
        Items can also be damaged (torn levels 1-10+):
        - **Slightly damaged** (1-3)
        - **Damaged** (4-6)
        - **Heavily damaged** (7-9)
        - **Destroyed** (10+)
  
        ## Quick Reference
  
        **Inventory:**
        - `inventory` / `inv` / `i` - View inventory
        - `get <item>` - Pick up
        - `drop <item>` - Drop
        - `give <item> to <person>` - Give
        - `show <item>` - Show to room
        - `trash <item>` - Destroy permanently
  
        **Shopping:**
        - `shop` - Open shop menu
        - `shop list` / `list` - Browse items
        - `buy <item>` - Purchase
        - `balance` - Check money
  
        **Banking:**
        - `deposit <amount>` - Put money in bank
        - `withdraw <amount>` - Take money out
  
        **Clothing:**
        - `wear <item>` - Put on
        - `remove <item>` - Take off
        - `outfit save <name>` - Save outfit
        - `dress <name>` - Wear saved outfit
        - `unzip <item>` - Unzip
        - `zipup <item>` - Zip up
  
        **Wardrobe:**
        - `wardrobe` - Open menu
        - `store <item>` - Store item
        - `retrieve <item>` - Get item
        - `transfer from <location>` - Move items (12 hours)
        - `wardrobe status` - Check transfers
  
        ## Troubleshooting
  
        **"You don't have that."** - Item might be worn or in wardrobe. Check `inventory` and `wardrobe list`.
  
        **"You can't afford that."** - Check `balance`. Shops deduct from bank first, then wallet.
  
        **"Remove it first."** - Item is worn. Use `remove <item>` before storing or dropping.
  
        **"No vault access."** - Wardrobe only works in your home or storage facilities.
  
        **"Item went out of stock."** - Someone else bought it. Check `shop list` for alternatives.
  
        **Can't wear piercing:** - Need a piercing hole first. Use `pierce <position> with <item>`.
  
        **Transfer not showing:** - Transfers take 12 real-time hours. Use `wardrobe status` to check.
      GUIDE
      staff_notes: <<~'STAFF',
        # Items & Economy System - Technical Implementation
  
        The items and economy system manages object lifecycle, ownership, shopping, banking, clothing, and cross-location storage.
  
        ## Architecture Overview
  
        **Model Layer:**
        - `Item` (table: objects): Instantiated objects with owner and location
        - `Pattern`: Template defining item properties (type, category, price, etc.)
        - `Wallet`: Cash on character's person (per currency)
        - `BankAccount`: Savings account (per currency)
        - `Shop`: Store attached to a room with inventory
        - `ShopItem`: Item for sale (links Pattern to Shop with price/stock)
        - `Outfit`: Saved clothing combination for quick dressing
        - `OutfitItem`: Individual item in an outfit
        - `ItemBodyPosition`: Worn item position tracking
  
        **Service Layer:**
        - `WardrobeService`: Storage, retrieval, and pattern creation
        - `TargetResolverService`: Item matching and disambiguation
  
        **Command Layer:**
        - Inventory plugin: get, drop, give, inventory, trash, use, etc.
        - Economy plugin: shop, buy, balance, deposit, withdraw
        - Clothing plugin: wear, remove, outfit, dress, strip, cover, expose, zip
        - Storage plugin: wardrobe (store, retrieve, transfer)
  
        ## Item Lifecycle
  
        ### 1. Pattern to Item Instantiation
  
        ```ruby
        # Pattern is the template
        pattern = Pattern[145]  # "leather jacket" template
  
        # Create instance owned by character
        item = pattern.instantiate(character_instance: character_instance)
        # Creates Item with:
        #   name: pattern.description
        #   pattern_id: pattern.id
        #   character_instance_id: ci.id
        #   quantity: 1
        #   condition: 'good'
  
        # Create instance in room
        item = pattern.instantiate(room: room)
        ```
  
        ### 2. Ownership States
  
        Items must belong to **either** a character or a room (not both, not neither):
  
        ```ruby
        # Validation in Item model
        if character_instance_id && room_id
          errors.add(:base, "Object cannot belong to both")
        elsif !character_instance_id && !room_id
          errors.add(:base, "Object must belong to either character or room")
        end
        ```
  
        **Movement:**
        ```ruby
        item.move_to_character(character_instance)
        # Sets: character_instance_id, room_id: nil, equipped: false
  
        item.move_to_room(room)
        # Sets: room_id, character_instance_id: nil, equipped: false
        ```
  
        ### 3. Item States
  
        **Flags:**
        - `worn`: On character's body (clothing/jewelry)
        - `equipped`: In equipment slot (weapons, tools)
        - `held`: In character's hand
        - `stored`: In wardrobe storage
        - `holstered_in_id`: In a holster/sheath item
  
        **Storage Fields:**
        - `stored_room_id`: Room where item is stored
        - `transfer_started_at`: When 12-hour transfer began
        - `transfer_destination_room_id`: Where item is transferring to
  
        ## Pattern System
  
        ### Pattern Categories
  
        Patterns delegate to `UnifiedObjectType` for categorization:
  
        ```ruby
        # Category hierarchies
        CLOTHING_CATEGORIES = %w[Top Pants Dress Skirt Underwear Outerwear Swimwear Fullbody Shoes Accessory Bag]
        JEWELRY_CATEGORIES = %w[Ring Necklace Bracelet Piercing]
        WEAPON_CATEGORIES = %w[Sword Knife Firearm]
        TATTOO_CATEGORIES = %w[Tattoo]
        CONSUMABLE_CATEGORIES = %w[consumable]
        ```
  
        ### Pattern Properties
  
        ```ruby
        pattern.description      # Display name
        pattern.category         # Top-level category (from unified_object_type)
        pattern.subcategory      # Subcategory (e.g., "t-shirt" under "Top")
        pattern.layer            # Clothing layer for stacking
        pattern.covered_positions  # Body parts covered
        pattern.zippable_positions # Positions with zippers
        pattern.price            # Base price (can be overridden in ShopItem)
        pattern.consume_type     # 'food', 'drink', 'smoke'
        ```
  
        ### Type Checks
  
        ```ruby
        pattern.clothing?   # In CLOTHING_CATEGORIES
        pattern.jewelry?    # In JEWELRY_CATEGORIES
        pattern.weapon?     # In WEAPON_CATEGORIES or has is_melee/is_ranged
        pattern.tattoo?     # In TATTOO_CATEGORIES
        pattern.piercing?   # category == 'Piercing'
        pattern.consumable? # Has consume_type
        ```
  
        ## Shopping System
  
        ### Shop Model
  
        ```sql
        shops
          id SERIAL PRIMARY KEY
          room_id INTEGER UNIQUE  -- One shop per room
          name VARCHAR
          shopkeeper_name VARCHAR
          is_open BOOLEAN         -- Public directory visibility
          free_items BOOLEAN      -- Everything is free
          cash_shop BOOLEAN       -- Cash only (no bank cards)
        ```
  
        ### ShopItem Model
  
        ```sql
        shop_items
          id SERIAL PRIMARY KEY
          shop_id INTEGER
          pattern_id INTEGER      -- What's being sold
          price INTEGER           -- Override pattern price
          stock INTEGER           -- nil or -1 = unlimited
          category VARCHAR        -- For grouping display
        ```
  
        **Stock Management:**
        ```ruby
        shop_item.available?        # stock > 0 or unlimited
        shop_item.unlimited_stock?  # stock nil or < 0
        shop_item.effective_price   # Uses price or pattern.price or 0
        ```
  
        ### Purchase Flow
  
        ```ruby
        def handle_buy(shop, item_text)
          # 1. Parse quantity and item name
          quantity, item_name = parse_buy_input(item_text)
  
          # 2. Find shop item
          shop_item = find_shop_item(shop, item_name)
  
          # 3. Check stock
          return error if !shop_item.available?
          return error if shop_item.stock < quantity
  
          # 4. Calculate total
          total_price = shop_item.effective_price * quantity
  
          # 5. Process payment (bank first, then wallet)
          payment_result = process_payment(shop, total_price)
  
          # 6. Decrement stock
          quantity.times do
            shop.decrement_stock(shop_item.pattern_id)
            item = shop_item.pattern.instantiate(character_instance: ci)
          end
        end
        ```
  
        ### Payment Processing
  
        ```ruby
        def process_payment(shop, amount)
          currency = default_currency
          wallet = character_instance.wallets_dataset.first(currency_id: currency.id)
          bank_account = character_instance.character.bank_accounts_dataset.first(currency_id: currency.id)
  
          wallet_balance = wallet&.balance || 0
          bank_balance = bank_account&.balance || 0
  
          # Cash shops ignore bank
          total_available = wallet_balance + (shop.cash_shop ? 0 : bank_balance)
  
          return error if total_available < amount
  
          remaining = amount
  
          # Deduct from bank first (unless cash shop)
          unless shop.cash_shop
            if bank_account && bank_account.balance > 0
              bank_debit = [remaining, bank_account.balance].min
              bank_account.withdraw(bank_debit)
              remaining -= bank_debit
            end
          end
  
          # Deduct remaining from wallet
          wallet.remove(remaining) if remaining > 0 && wallet
        end
        ```
  
        ## Wallet and Banking
  
        ### Wallet Model
  
        ```ruby
        # One wallet per currency per character
        class Wallet < Sequel::Model
          many_to_one :character_instance
          many_to_one :currency
  
          def add(amount)
            update(balance: balance + amount)
          end
  
          def remove(amount)
            return false if amount > balance
            update(balance: balance - amount)
          end
  
          def transfer_to(other_wallet, amount)
            return false unless currency_id == other_wallet.currency_id
            remove(amount) && other_wallet.add(amount)
          end
        end
        ```
  
        ### BankAccount Model
  
        ```ruby
        # One account per currency per character
        class BankAccount < Sequel::Model
          many_to_one :character
          many_to_one :currency
  
          def deposit(amount)
            update(balance: balance + amount)
          end
  
          def withdraw(amount)
            return false if amount > balance
            update(balance: balance - amount)
          end
        end
        ```
  
        ## Clothing System
  
        ### Wearing Mechanics
  
        ```ruby
        def wear!(position: nil)
          return false unless character_instance_id
  
          if piercing?
            # Piercings require body position
            return "Specify a body position" if position.nil?
  
            normalized = position.to_s.downcase.strip
            return "Not pierced there" unless character_instance.pierced_at?(normalized)
  
            # Check for existing piercing at position
            existing = character_instance.piercings_at(normalized)
            return "Already wearing piercing there" if existing.any? { |p| p.id != id }
  
            update(worn: true, piercing_position: normalized)
          else
            # Regular clothing
            update(worn: true)
          end
          true
        end
        ```
  
        ### Clothing Classes
  
        Items are categorized into clothing classes for outfit system:
  
        ```ruby
        CATEGORY_TO_OUTFIT_CLASS = {
          'underwear' => 'underwear',
          'jacket' => 'overwear', 'coat' => 'overwear',
          'pants' => 'bottoms', 'skirt' => 'bottoms',
          'shirt' => 'top', 'blouse' => 'top',
          'ring' => 'jewelry', 'necklace' => 'jewelry',
          'hat' => 'accessories', 'scarf' => 'accessories'
        }.freeze
  
        def clothing_class
          # Check pattern category/subcategory against mapping
          # Returns: underwear, overwear, bottoms, top, jewelry, accessories, other
        end
        ```
  
        ### Outfit System
  
        ```ruby
        class Outfit < Sequel::Model
          CLASSES = %w[full underwear overwear bottoms top jewelry accessories other]
  
          def save_from_worn!(character_instance)
            outfit_items_dataset.delete  # Clear existing
  
            character_instance.worn_items.each do |item|
              OutfitItem.create(
                outfit_id: id,
                pattern_id: item.pattern_id,
                display_order: item.display_order || 0
              )
            end
          end
  
          def apply_to!(character_instance)
            # Remove items based on outfit_class
            items_to_remove = items_to_remove_for_class(character_instance)
            items_to_remove.each(&:remove!)
  
            # Create and wear outfit items
            outfit_items.each do |oi|
              item = oi.pattern.instantiate(character_instance: ci)
              item.update(worn: true, display_order: oi.display_order)
            end
          end
  
          def items_to_remove_for_class(ci)
            worn = ci.worn_items.all
  
            case outfit_class
            when 'full'
              worn  # Remove everything
            when 'other'
              []    # Remove nothing
            else
              # Remove only items of same class
              worn.select { |item| item.clothing_class == outfit_class }
            end
          end
        end
        ```
  
        ## Wardrobe System
  
        ### Storage Mechanics
  
        ```ruby
        # Store item in room
        item.store!(room)
        # Sets: stored: true, stored_room_id: room.id
  
        # Retrieve item
        item.retrieve!
        # Sets: stored: false, stored_room_id: nil
        ```
  
        ### Cross-Location Transfer (12-hour delay)
  
        ```ruby
        # Start transfer
        item.start_transfer!(destination_room)
        # Sets:
        #   transfer_started_at: Time.now
        #   transfer_destination_room_id: destination_room.id
  
        # Check if ready
        item.transfer_ready?
        # Returns: (Time.now - transfer_started_at) >= 12.hours
  
        # Complete transfer
        item.complete_transfer!
        # Updates:
        #   stored_room_id: transfer_destination_room_id
        #   transfer_started_at: nil
        #   transfer_destination_room_id: nil
        ```
  
        ### Vault Access
  
        ```ruby
        # Room must be owned by character or be a vault
        def vault_accessible?(character)
          owned_by?(character) || has_vault?
        end
        ```
  
        ### Scopes for Storage Queries
  
        ```ruby
        # All stored items for a character
        Item.stored_items_for(character_instance)
        # WHERE character_instance_id = ? AND stored = true
  
        # Items stored in specific room
        Item.stored_in_room(character_instance, room)
        # WHERE character_instance_id = ? AND stored = true AND stored_room_id = ?
  
        # Items in transit
        Item.in_transit_for(character_instance)
        # WHERE character_instance_id = ? AND transfer_started_at IS NOT NULL
        ```
  
        ## WardrobeService
  
        **Purpose:** Provides wardrobe operations and pattern creation at half cost.
  
        ```ruby
        class WardrobeService
          PATTERN_CREATE_COST_MULTIPLIER = 0.5
  
          def vault_accessible?
            @room.vault_accessible?(@ci.character)
          end
  
          def stored_items_by_category
            items = Item.stored_in_room(@ci, @room)
            {
              clothing: items.where(is_clothing: true).all,
              jewelry: items.where(is_jewelry: true).all,
              general: items.where(is_clothing: false, is_jewelry: false).all
            }
          end
  
          def eligible_patterns
            # Patterns from items character has owned
            owned_pattern_ids = @ci.objects_dataset
                                   .exclude(pattern_id: nil)
                                   .select_map(:pattern_id)
                                   .uniq
            Pattern.where(id: owned_pattern_ids)
          end
  
          def fetch_and_wear(item_id)
            # Retrieve from storage and immediately wear
            # Handles piercing position selection if needed
          end
        end
        ```
  
        ## Item Disambiguation
  
        Uses `TargetResolverService` for fuzzy matching:
  
        ```ruby
        item = TargetResolverService.resolve(
          query: 'sword',
          candidates: items,
          name_field: :name,
          min_prefix_length: 3
        )
        # Matches by prefix, contains, or exact match
        # Returns single item or nil
        ```
  
        ## Command Patterns
  
        ### Standard Item Command
  
        ```ruby
        standard_item_command(
          input: text,
          items_getter: -> { wearable_items },
          action_method: :wear!,
          action_name: 'wear',
          menu_prompt: 'What would you like to wear?',
          self_verb: 'put on',
          other_verb: 'puts on',
          allow_multiple: true  # Supports comma-separated lists
        )
        ```
  
        ### Multi-Item Support
  
        ```ruby
        # Parse "wear hat, scarf, gloves"
        item_names = parse_multi_item_input(text)
        # => ["hat", "scarf", "gloves"]
  
        # Process each
        item_names.each do |name|
          item = find_item(name)
          item.wear!
        end
        ```
  
        ## Database Schema
  
        ### Items (objects table)
  
        ```sql
        objects
          id SERIAL PRIMARY KEY
          pattern_id INTEGER
          character_instance_id INTEGER
          room_id INTEGER
          name VARCHAR
          quantity INTEGER DEFAULT 1
          condition VARCHAR DEFAULT 'good'
          worn BOOLEAN DEFAULT FALSE
          equipped BOOLEAN DEFAULT FALSE
          held BOOLEAN DEFAULT FALSE
          stored BOOLEAN DEFAULT FALSE
          stored_room_id INTEGER
          transfer_started_at TIMESTAMP
          transfer_destination_room_id INTEGER
          piercing_position VARCHAR
          holstered_in_id INTEGER
          properties JSONB
          torn INTEGER  -- Damage level 0-10+
        ```
  
        ### Patterns
  
        ```sql
        patterns
          id SERIAL PRIMARY KEY
          unified_object_type_id INTEGER
          description VARCHAR  -- Display name
          price INTEGER
          consume_type VARCHAR  -- food, drink, smoke
          is_melee BOOLEAN
          is_ranged BOOLEAN
          attack_speed INTEGER
          weapon_range VARCHAR  -- melee, short, medium, long
          image_url VARCHAR
        ```
  
        ### Wallets
  
        ```sql
        wallets
          id SERIAL PRIMARY KEY
          character_instance_id INTEGER
          currency_id INTEGER
          balance INTEGER DEFAULT 0
          UNIQUE(character_instance_id, currency_id)
        ```
  
        ### Shops
  
        ```sql
        shops
          id SERIAL PRIMARY KEY
          room_id INTEGER UNIQUE
          name VARCHAR
          shopkeeper_name VARCHAR
          is_open BOOLEAN
          free_items BOOLEAN
          cash_shop BOOLEAN
        ```
  
        ### ShopItems
  
        ```sql
        shop_items
          id SERIAL PRIMARY KEY
          shop_id INTEGER
          pattern_id INTEGER
          price INTEGER
          stock INTEGER  -- nil or -1 = unlimited
          category VARCHAR
        ```
  
        ### Outfits
  
        ```sql
        outfits
          id SERIAL PRIMARY KEY
          character_instance_id INTEGER
          name VARCHAR
          outfit_class VARCHAR  -- full, underwear, top, etc.
          UNIQUE(character_instance_id, name)
        ```
  
        ### OutfitItems
  
        ```sql
        outfit_items
          id SERIAL PRIMARY KEY
          outfit_id INTEGER
          pattern_id INTEGER
          display_order INTEGER
        ```
  
        ## Performance Considerations
  
        **Eager Loading:**
        ```ruby
        # Load items with patterns in one query
        items.eager(:pattern).all
  
        # Load shop items with patterns
        shop.shop_items_dataset.eager(:pattern).all
        ```
  
        **Batch Operations:**
        ```ruby
        # Store all items at once
        items.each { |item| item.store!(room) }
        # Could be optimized to single UPDATE
  
        # Transfer all items
        Item.where(id: item_ids).update(
          transfer_started_at: Time.now,
          transfer_destination_room_id: dest_id
        )
        ```
  
        ## Testing Patterns
  
        **Item lifecycle:**
        - Test instantiation from patterns
        - Test ownership transfer (character ↔ room)
        - Test worn/equipped state changes
        - Test storage and retrieval
  
        **Shopping:**
        - Test stock depletion
        - Test payment processing (bank + wallet)
        - Test cash-only shops
        - Test free item shops
  
        **Wardrobe:**
        - Test vault access validation
        - Test 12-hour transfer timing
        - Test cross-location retrieval
        - Test transfer status display
  
        **Outfits:**
        - Test saving from worn items
        - Test applying outfit (removes correct items)
        - Test partial outfits (only removes same class)
        - Test full outfits (removes everything)
  
        ## Common Patterns
  
        **Creating items:**
        ```ruby
        # From pattern
        item = pattern.instantiate(character_instance: ci)
  
        # Manual creation
        item = Item.create(
          name: 'custom item',
          character_instance: ci,
          quantity: 1,
          condition: 'good'
        )
        ```
  
        **Shop stock management:**
        ```ruby
        # Add to shop
        shop_item = ShopItem.create(
          shop: shop,
          pattern: pattern,
          price: 50,
          stock: 10  # or nil for unlimited
        )
  
        # Update existing
        shop_item.update(price: 45, stock: shop_item.stock + 5)
        ```
  
        ## Debugging
  
        **Common issues:**
        - "Can't belong to both character and room": Item has both IDs set
        - "Must belong to either character or room": Item has neither ID
        - "No vault access": Room not owned and doesn't have vault flag
        - "Transfer not ready": Less than 12 hours elapsed
        - "Item not found": Might be stored or in transit
  
        **Useful queries:**
        ```ruby
        # Find orphaned items (neither character nor room)
        Item.where(character_instance_id: nil, room_id: nil)
  
        # Find items in limbo (both set)
        Item.where { character_instance_id.is_not_null & room_id.is_not_null }
  
        # Find stuck transfers (>24 hours)
        Item.where { transfer_started_at < Time.now - 86400 }
  
        # Check character's total items
        Item.where(character_instance_id: ci.id).count
  
        # Check wardrobe distribution
        Item.stored_items_for(ci).group_and_count(:stored_room_id).all
        ```
      STAFF
      display_order: 55
    },
    {
      name: 'cards_games',
      display_name: 'Cards & Games',
      summary: 'Card games, interactive games on items and room fixtures',
      description: "Card games with full deck manipulation — dealing, drawing, discarding, playing to a shared center area, and turning cards over. Interactive games can be attached to items or room fixtures, with weighted random outcomes, optional stat influence, and scoring. Use items with games to play them (e.g., dartboards, slot machines, arcade cabinets).",
      command_names: %w[cards use],
      related_systems: %w[roleplaying],
      key_files: [
        'plugins/core/cards/commands/cards.rb',
        'plugins/core/inventory/commands/use.rb',
        'app/models/deck.rb',
        'app/models/card.rb',
        'app/models/deck_pattern.rb',
        'app/models/game_pattern.rb',
        'app/models/game_pattern_branch.rb',
        'app/models/game_pattern_result.rb',
        'app/models/game_instance.rb',
        'app/models/game_score.rb',
        'app/services/game_play_service.rb'
      ],
      player_guide: <<~'GUIDE',
        # Cards & Games System
  
        The cards and games system lets you play card games with other players and interact with game objects in the world.
  
        ## Games
  
        Games are interactive objects attached to **items** you carry or **room fixtures** (like a dartboard on a wall or an arcade cabinet). Each game has one or more play styles (branches) with different weighted outcomes.
  
        ### Playing a Game
  
        - `use <item>` — Play a game on an item you're carrying or a fixture in the room
        - `use <item> <style>` — Play a specific style/mode
        - `use <item> reset` — Reset your score
  
        **Examples:**
        ```
        use dartboard
        → [ Darts - Play Normal ]
        → Good shot! +5 points | Your score: 15 points
  
        use dartboard aggressive
        → [ Darts - Aggressive Throw ]
        → BULLSEYE! +10 points | Your score: 25 points
  
        use slot machine
        → (Shows menu of play styles if multiple available)
  
        use dartboard reset
        → Your score for Darts has been reset.
        ```
  
        If a game has multiple play styles, you'll see a menu to choose from. If it only has one style, it plays directly.
  
        ### How Results Work
  
        Each game has a set of possible outcomes ordered from best (rarest) to worst (most common). The system uses **weighted random selection** — better outcomes are harder to get.
  
        - **Position 1** (best result): Rarest, highest points
        - **Position 2**: Less rare
        - **Position 3+** (worst result): Most common, lowest points
  
        The weighting uses an exponential curve, so the best outcome is significantly rarer than the worst.
  
        ### Stat Influence
  
        Some games are linked to a character stat (like DEX for darts). If a game uses a stat:
  
        - Your stat is compared to the **room average** and **world average**
        - Higher than average = slightly better chance at good outcomes
        - Lower than average = slightly worse chance
        - The effect is subtle — skill helps but doesn't guarantee results
  
        ### Scoring
  
        Games can optionally track scores:
  
        - Each outcome awards a number of points (can be positive or negative)
        - Your cumulative score is tracked per game
        - Scores persist as long as you're in the room (for room fixtures) or have the item
        - Use `use <item> reset` to reset your score
        - Scores are personal — each player has their own
  
        ### Game Types
  
        Games can be placed on:
  
        - **Items**: Portable games you carry (dice sets, handheld games, card decks with special rules)
        - **Room fixtures**: Stationary games placed in rooms (dartboards, arcade cabinets, slot machines, billiard tables)
  
        Games are created by players and can be shared:
        - **Private**: Only you can attach instances
        - **Public**: Anyone can attach instances
        - **Purchasable**: Available for others to buy
  
        ## Card Games
  
        Play card games with other players using virtual decks.
  
        ### Opening the Card Menu
  
        - `cards` - Open the card game interface
  
        **Aliases:** `card`, `cardgame`, `cardmenu`
  
        This opens an interactive menu with options for:
        - Starting a new game
        - Joining an existing game
        - Viewing your hand
        - Playing cards
        - Drawing cards
        - Managing the deck
  
        ### Card Game Basics
  
        **Deck Structure:**
        - **Main deck**: Cards to be drawn
        - **Player hands**: Each player's cards (faceup or facedown)
        - **Center area**: Shared space for tricks, community cards, revealed cards
        - **Discard pile**: Used cards
  
        **Card Positions:**
        - **In deck**: Not yet drawn
        - **In hand (facedown)**: Secret from others
        - **In hand (faceup)**: Visible to all
        - **Center (facedown)**: Played but not revealed
        - **Center (faceup)**: Played and visible
        - **Discarded**: Out of play
  
        ### Common Actions
  
        Through the card menu you can:
  
        **Drawing Cards:**
        - Draw cards from the deck to your hand
        - Choose whether cards go faceup or facedown
        - Number of cards specified
  
        **Playing Cards:**
        - Play from hand to center area
        - Can play faceup (revealed) or facedown (hidden)
        - Center area shared by all players
  
        **Revealing Cards:**
        - Flip facedown cards to faceup
        - In your hand or in the center
        - Shows the card to all players
  
        **Discarding:**
        - Send cards from hand to discard pile
        - Discard pile separate from main deck
        - Can be reshuffled into deck if needed
  
        **Deck Management:**
        - **Shuffle**: Randomize card order
        - **Reshuffle discard**: Return discarded cards to deck
        - **Collect all**: Gather all cards back to deck
        - **Deal**: Distribute cards to players
  
        ### Multiple Games
  
        - Each room can have multiple active card games
        - Players join specific deck instances
        - Games don't interfere with each other
        - Useful for multiple tables at a casino or game night
  
        ### Supported Deck Types
  
        The system supports various deck patterns:
        - **Standard 52-card deck**: Hearts, Diamonds, Clubs, Spades
        - **Tarot deck**: Major and Minor Arcana
        - **Custom decks**: Any card design
        - **Jokers**: Optional inclusion
  
        Cards display with:
        - **Full name**: "Ace of Spades"
        - **Short symbol**: "A♠" (for compact display)
        - **Suit symbol**: ♥ ♦ ♣ ♠
  
        ### Card Values
  
        For games that need card values:
        - **Number cards**: Face value (2-10)
        - **Jack**: 11
        - **Queen**: 12
        - **King**: 13
        - **Ace**: 14 (high) or 1 (low, game-dependent)
  
        ### Tips for Playing
  
        **Communication:**
        - Use `say` to announce your plays
        - Coordinate with other players via chat
        - Establish house rules before starting
  
        **Fair Play:**
        - Cards in your hand facedown are secret
        - Don't meta-game with out-of-character knowledge
        - Respect the game state (don't cheat)
  
        **Game Flow:**
        1. One player starts a game (creates deck)
        2. Others join the game
        3. Dealer deals initial cards
        4. Players take turns playing cards
        5. Use center area for tricks/community cards
        6. Discard as needed
        7. Reshuffle when deck runs out
  
        ## Quick Reference
  
        **Games:**
        - `use <item>` — Play a game
        - `use <item> <style>` — Play specific style
        - `use <item> reset` — Reset your score
        - Weighted random outcomes, stat influence, scoring
  
        **Card Games:**
        - `cards` - Open card interface
        - Interactive menu for all actions
        - Deck, hand, center, discard tracking
        - Multiple simultaneous games per room
  
        ## Troubleshooting
  
        **"This game has no playable options."** - The game pattern has no branches configured. Contact the game owner.
  
        **"You don't have enough willpower."** - Only applies to activities, not games.
  
        **Can't see card menu:** - Make sure you're in a room that supports card games. Some areas restrict games.
  
        **Cards not appearing:** - Check if you've joined the game. Open `cards` menu and select "Join Game".
  
        **Deck empty:** - Use the reshuffle option to return discarded cards to the deck.
      GUIDE
      staff_notes: <<~'STAFF',
        # Cards & Games System - Technical Implementation
  
        The cards and games system provides card game mechanics and interactive game objects with weighted outcomes.
  
        ## Architecture Overview
  
        **Game System:**
        - `GamePattern`: Reusable game template (e.g., "Darts")
        - `GamePatternBranch`: Play style within a game (e.g., "Normal", "Aggressive")
        - `GamePatternResult`: Possible outcome with position, message, and points
        - `GameInstance`: Attachment of a pattern to an item or room
        - `GameScore`: Per-player score tracking
        - `GamePlayService`: Weighted random selection with stat influence
  
        **Card System:**
        - `Deck`: Instance of a deck in play (per room/game)
        - `Card`: Individual card with suit, rank, name
        - `DeckPattern`: Template defining deck composition
        - `CardsQuickmenuHandler`: Interactive menu for card operations
  
        **Command Layer:**
        - `Commands::Inventory::Use`: Plays games on items/room fixtures
        - `Commands::Cards::Cards`: Card game menu interface
  
        ## Game System
  
        ### Data Model
  
        ```
        GamePattern (template)
        ├── name, description, has_scoring, share_type
        ├── created_by → Character
        └── branches → GamePatternBranch[]
            ├── name, display_name, description
            ├── stat_id → Stat (optional, for stat influence)
            └── results → GamePatternResult[]
                ├── position (1=best/rarest, higher=worse/more common)
                ├── message (text shown to player)
                └── points (score awarded, can be negative)
  
        GameInstance (placed in world)
        ├── game_pattern_id → GamePattern
        ├── item_id → Object (portable game) XOR room_id → Room (fixture)
        └── custom_name (optional override)
  
        GameScore (per-player tracking)
        ├── game_instance_id + character_instance_id (unique)
        └── score (cumulative points)
        ```
  
        ### GamePlayService
  
        **Weighted result selection:**
  
        ```ruby
        # Exponential weighting: position 1 (best) = rarest
        # base=5.0, growth=2.0
        # 3 results: weights ≈ [14%, 29%, 57%]
        # 5 results: weights ≈ [3%, 6%, 13%, 26%, 52%]
        weights = GamePlayService.calculate_weights(results)
        ```
  
        **Stat influence (bump mechanic):**
  
        ```ruby
        # Compare player stat to room average and world average
        modifier = GamePlayService.calculate_stat_modifier(branch, ci, room)
        # Returns float capped at ±MODIFIER_CAP
  
        # During selection, modifier gives chance to bump result up/down
        # Higher stat = chance to shift one position toward better result
        # Lower stat = chance to shift toward worse result
        ```
  
        **Play flow:**
        ```ruby
        result = GamePlayService.play(game_instance, branch, character_instance)
        # => {
        #   success: true,
        #   result: GamePatternResult,
        #   message: "BULLSEYE!",
        #   points: 10,
        #   total_score: 25,
        #   game_name: "Darts",
        #   branch_name: "Aggressive Throw"
        # }
        ```
  
        ### Use Command Game Resolution
  
        The `use` command finds games by progressively matching input:
  
        ```ruby
        # "dartboard aggressive" → try "dartboard aggressive", then "dartboard"
        # Found "dartboard" as game → "aggressive" becomes branch name
        parts.length.downto(1) do |i|
          potential_name = parts[0...i].join(' ')
          game_instance = find_game_instance(potential_name)
          # ...
        end
        ```
  
        Search order: inventory items first, then room fixtures.
  
        ### Score Cleanup
  
        Scores are ephemeral and cleaned up automatically:
        - `GameScore.clear_for_room(room_id, ci_id)` — when leaving a room
        - `GameScore.clear_for_items(ci_id)` — when items change ownership
  
        ## Card System
  
        ### Deck Model
  
        **Purpose:** Instance of a deck in play, tracks all card positions.
  
        ```sql
        deck
          id SERIAL PRIMARY KEY
          deck_pattern_id INTEGER  -- Template (52-card, Tarot, etc.)
          dealer_id INTEGER        -- CharacterInstance who created/controls
          card_ids INTEGER[]       -- Cards in main deck (PGArray)
          center_faceup INTEGER[]  -- Center cards visible
          center_facedown INTEGER[] -- Center cards hidden
          discard_pile INTEGER[]   -- Discarded cards
        ```
  
        **Key Operations:**
  
        ```ruby
        # Shuffle
        deck.shuffle!
        # Randomizes card_ids array
  
        # Draw cards
        drawn_ids = deck.draw(5)
        # Removes 5 cards from card_ids, returns their IDs
  
        # Return cards
        deck.return_cards([15, 23, 42])
        # Adds card IDs back to card_ids
  
        # Center management
        deck.add_to_center_faceup([card1_id, card2_id])
        deck.add_to_center_facedown([card3_id])
        deck.flip_center_cards(2)  # Flip 2 facedown to faceup
  
        # Discard
        deck.add_to_discard([card4_id, card5_id])
        deck.return_from_discard(10)  # Return 10 cards from discard to bottom of deck
  
        # Reset (collect all cards back)
        deck.collect_all_cards!
        # Clears all player hands, center, discard; reshuffles all into deck
        ```
  
        **Player Tracking:**
  
        ```ruby
        # Players join by setting current_deck_id
        character_instance.update(current_deck_id: deck.id)
  
        # Get all players
        deck.players
        # => CharacterInstance.where(current_deck_id: deck.id)
        ```
  
        **Card Storage in Hands:**
  
        Characters hold cards via arrays on CharacterInstance:
  
        ```sql
        character_instances
          cards_faceup INTEGER[]    -- Visible to all
          cards_facedown INTEGER[]  -- Secret
        ```
  
        ### Card Model
  
        **Purpose:** Individual card definition.
  
        ```sql
        cards
          id SERIAL PRIMARY KEY
          deck_pattern_id INTEGER
          name VARCHAR           -- "Ace of Spades", "The Fool"
          suit VARCHAR(50)       -- "Hearts", "Major Arcana", "Joker"
          rank VARCHAR(50)       -- "Ace", "2", "King", etc.
          display_order INTEGER  -- Sort order in deck
        ```
  
        **Display Methods:**
  
        ```ruby
        card = Card.find(name: 'Ace', suit: 'Spades')
  
        card.display_name
        # => "Ace of Spades"
  
        card.short_display
        # => "A♠"
  
        card.numeric_value
        # => 14 (Ace high)
  
        card.face_card?
        # => false (only J, Q, K are face cards)
        ```
  
        **Suit Symbols:**
        - Hearts: ♥ (U+2665)
        - Diamonds: ♦ (U+2666)
        - Clubs: ♣ (U+2663)
        - Spades: ♠ (U+2660)
  
        ### DeckPattern Model
  
        **Purpose:** Template defining deck composition.
  
        ```sql
        deck_patterns
          id SERIAL PRIMARY KEY
          name VARCHAR  -- "Standard 52-Card Deck", "Tarot Deck"
          description TEXT
        ```
  
        One-to-many relationship with Cards:
        ```ruby
        deck_pattern.cards_dataset.order(:display_order, :id)
        # Returns all cards for this pattern
        ```
  
        When a Deck is created, it initializes with all card IDs from the pattern:
  
        ```ruby
        deck.reset!
        # Collects all card IDs from pattern, shuffles, sets as card_ids
        all_card_ids = deck_pattern.cards_dataset.select_map(:id)
        update(card_ids: Sequel.pg_array(all_card_ids.shuffle, :integer))
        ```
  
        ### PostgreSQL Array Handling
  
        Critical: All array fields must be wrapped as `PGArray` for Sequel:
  
        ```ruby
        def before_save
          # Ensure proper wrapping
          if card_ids.nil?
            self.card_ids = Sequel.pg_array([], :integer)
          elsif !card_ids.is_a?(Sequel::Postgres::PGArray)
            self.card_ids = Sequel.pg_array(Array(card_ids), :integer)
          end
        end
        ```
  
        **Why:** Prevents type errors when persisting to PostgreSQL integer[] columns.
  
        ### CardsQuickmenuHandler
  
        **Purpose:** Generate interactive card game menu.
  
        ```ruby
        menu_result = CardsQuickmenuHandler.show_menu(character_instance)
        # Returns:
        # {
        #   prompt: "What would you like to do?",
        #   options: [
        #     { key: 'draw', label: 'Draw Cards', description: '...' },
        #     { key: 'play', label: 'Play Card', description: '...' },
        #     ...
        #   ],
        #   context: { deck_id: 42, player_hand: [...] }
        # }
        ```
  
        Menu stored as pending interaction for async processing.
  
        ## Multiple Game Support
  
        Each Deck instance is independent:
  
        ```ruby
        # Room can have multiple decks
        room.decks  # Multiple Deck records
  
        # Players join specific deck
        player1.current_deck_id = deck1.id
        player2.current_deck_id = deck2.id
        player3.current_deck_id = deck1.id  # Joins same game as player1
        ```
  
        Games don't interfere because:
        - Each Deck has separate card_ids, center, discard
        - Players track which deck they're in via current_deck_id
        - Commands filter by player's current_deck_id
  
        ## Testing Patterns
  
        **Game system:**
        - Test weighted result distribution (best = rare, worst = common)
        - Test stat modifier bump mechanic
        - Test scoring accumulation and reset
        - Test game discovery (item name parsing with branch suffix)
        - Test room fixture vs item attachment
  
        **Card operations:**
        - Test draw reducing deck size
        - Test shuffle randomization
        - Test center faceup/facedown transitions
        - Test discard → deck reshuffling
        - Test collect_all_cards (clears hands, center, discard)
        - Test PGArray wrapping on all array fields
  
        **Edge cases:**
        - Game with no results configured
        - Game with single branch (plays directly, no menu)
        - Empty deck (draw returns [])
        - Draw more than available (returns what's left)
        - Multiple players in same game
        - Player hands with mix of faceup/facedown
  
        ## Performance Considerations
  
        **PGArray operations:**
        - Array modifications require full UPDATE (not append)
        - Minimize updates by batching operations
        - Consider deck size limits (standard = 52-78 cards)
  
        **Game scoring:**
        - GameScore uses find_or_create (upsert pattern)
        - Scores cleaned on room departure and item transfer
        - World average stat query hits all online characters (consider caching)
  
        **Multiple decks per room:**
        - Each deck is separate DB record
        - No current limit on simultaneous games
        - Consider UI/UX when many games active
  
        ## Debugging
  
        **Common issues:**
        - "PGArray type error": Array not wrapped with Sequel.pg_array
        - "Can't draw from empty deck": Check remaining_count, reshuffle discard if needed
        - "Player not in game": current_deck_id must match deck.id
        - "No results configured": GamePatternBranch has no GamePatternResult records
  
        **Useful queries:**
        ```ruby
        # Check deck state
        deck.remaining_count  # Cards left to draw
        deck.center_count     # Cards in center
        deck.discard_count    # Cards discarded
  
        # Find player's cards
        player.cards_faceup   # Visible cards
        player.cards_facedown # Hidden cards
  
        # Get all cards in game
        all_ids = deck.card_ids + deck.center_faceup + deck.center_facedown + deck.discard_pile
        all_ids += deck.players.flat_map { |p| Array(p.cards_faceup) + Array(p.cards_facedown) }
        Card.where(id: all_ids.flatten.uniq).all
  
        # Check for lost cards (should equal pattern total)
        pattern.cards.count == all_ids.flatten.uniq.count
        ```
      STAFF
      display_order: 60
    },
    {
      name: 'delves',
      display_name: 'Delves',
      summary: 'Procedural dungeon exploration with traps, puzzles, monsters, and treasure',
      description: "Delves are procedurally generated dungeon crawls with time limits, fog of war, traps, puzzles, monsters, and treasure. Explore generated levels, study traps to learn their pulse patterns, solve puzzles, fight monsters for XP and loot, and collect treasure before time runs out. Rest to heal or focus to regain willpower. Flee to exit with whatever loot you've collected.",
      command_names: %w[delve],
      related_systems: %w[combat missions],
      key_files: [
        'plugins/core/delve/commands/delve.rb',
        'app/models/delve.rb',
        'app/models/delve_room.rb',
        'app/models/delve_participant.rb',
        'app/models/delve_blocker.rb',
        'app/models/delve_monster.rb',
        'app/models/delve_puzzle.rb',
        'app/models/delve_treasure.rb',
        'app/models/delve_trap.rb',
        'app/services/delve_generator_service.rb',
        'app/services/delve_movement_service.rb',
        'app/services/delve_action_service.rb',
        'app/services/delve_trap_service.rb',
        'app/services/delve_puzzle_service.rb',
        'app/services/delve_combat_service.rb',
        'app/services/delve_treasure_service.rb',
        'app/services/delve_map_service.rb',
        'app/services/delve_skill_check_service.rb',
        'app/services/delve_monster_service.rb',
        'app/services/delve_visibility_service.rb'
      ],
      player_guide: <<~'GUIDE',
        # Delves - Procedural Dungeon Exploration
  
        Delves are procedurally generated dungeon crawls where you explore grid-based levels against a 60-minute time limit. Navigate fog-of-war maps, solve timing-based traps, overcome skill check obstacles, solve puzzles, fight roving monsters, and collect treasure from terminal rooms before extracting or running out of time.
  
        ## Getting Started
  
        ### Entering a Delve
  
        ```
        delve enter Dark Cave
        ```
  
        Creates a new procedural dungeon and places you at the entrance. Each delve generates uniquely based on a random seed.
  
        **Initial State:**
        - **HP:** 6/6
        - **Willpower:** 0 dice
        - **Time:** 60:00 remaining
        - **Loot:** 0 gold
        - **Level:** 1
  
        ### Contextual Commands
  
        When inside a delve, movement and action commands work **without** the `delve` prefix:
  
        ```
        n              # Instead of: delve n
        look           # Instead of: delve look
        map            # Instead of: delve map
        ```
  
        ## Core Mechanics
  
        ### Time Management
  
        Actions consume time from your 60-minute limit:
  
        | Action | Time Cost |
        |--------|-----------|
        | **Movement** (n/s/e/w/down) | 10 seconds |
        | **Fight** | 10 seconds (per combat round) |
        | **Recover** (rest to full HP) | 5 minutes |
        | **Focus** (gain willpower die) | 30 seconds |
        | **Study** (monster for +2 bonus) | 1 minute |
        | **Easier** (lower blocker DC) | 30 seconds |
        | **Listen** (extend trap sequence) | 10 seconds |
        | **Solve** (puzzle attempt) | 15 seconds |
        | **Grab** (loot treasure) | **Free** |
  
        **Time runs out?** You collapse from exhaustion, lose 50% of collected loot, and are ejected with status `fled`.
  
        ### Health & Willpower
  
        **HP System:**
        - Start: 6/6 HP
        - Traps deal 1 HP per dungeon level
        - Combat uses standard damage threshold system
        - **Recover:** Rest to full HP (costs 5 minutes)
  
        **Willpower Dice:**
        - Start: 0 dice
        - **Focus:** Gain 1 die (costs 30 seconds, max 3 dice)
        - Use in skill checks for rerolls/advantages
        - Not consumed in delves (permanent until extraction)
  
        ### Loot & Extraction
  
        **Gold Collection:**
        - Treasure found in terminal rooms (dead ends)
        - Value doubles each level: Level 1 = 5-10g, Level 2 = 10-20g, Level 3 = 20-40g
        - **grab** collects treasure (free action)
        - Monster kills award bonus gold (half their difficulty value)
  
        **Extraction Methods:**
        - **flee** - Exit immediately, keep all collected loot
        - **Time expired** - Lose 50% loot, ejected
        - **Defeated in combat** - Lose 50% loot, ejected
        - **Complete dungeon** - Descend to final level and extract
  
        ## Movement & Navigation
  
        ### Basic Movement
  
        ```
        n / north      # Move north
        s / south      # Move south
        e / east       # Move east
        w / west       # Move west
        down / d       # Descend to next level (at exit room)
        ```
  
        **Room Types:**
        - **Corridor** - Empty passage
        - **Chamber** - Large space, may contain treasure
        - **Treasure** - Terminal room with loot
        - **Monster** - Contains hostile creature
        - **Trap** - Trapped exit
        - **Puzzle** - Logic puzzle blocks progress
        - **Boss** - Powerful enemy before exit
        - **Exit** - Stairs down to next level
  
        ### Fog of War
  
        You can only see:
        - **Current room** - Full details
        - **Adjacent rooms** - Direction availability only
        - **Explored rooms** - Shown on minimap
  
        **Visibility:**
        ```
        look           # Inspect current room
        map            # Show explored area minimap
        fullmap        # Show all explored rooms
        ```
  
        ## Obstacles & Challenges
  
        ### Timing Traps
  
        Traps block movement in specific directions using **coprime pulse patterns**. You must observe the trap's rhythm and time your passage through safe pulses.
  
        **How Traps Work:**
  
        1. **Observe the pattern:**
           ```
           study n        # Study north trap
           ```
  
           Output example:
           ```
           1. quiet
           2. quiet
           3. TRAP!
           4. quiet
           5. TRAP!
           6. quiet
           7. TRAP!
           8. quiet
           ```
  
        2. **Extend observation if needed:**
           ```
           listen n       # See more pulses (costs 10 sec)
           ```
  
        3. **Time your passage:**
           ```
           go n 2         # Pass through at pulse #2
           ```
  
        **First-Time vs Experienced:**
  
        - **First passage:** BOTH your chosen pulse AND the next pulse must be safe
          - Example: Choose pulse 2 → pulses 2 AND 3 must both be "quiet"
  
        - **Repeat passage:** Only your chosen pulse needs to be safe
          - After passing once, you're "experienced" with that trap
          - Example: Choose pulse 2 → only pulse 2 needs to be "quiet"
  
        **Failed Timing:**
        - Take damage equal to dungeon level (Level 3 trap = 3 HP damage)
        - Still move through (you're not blocked, just hurt)
  
        ### Skill Check Blockers
  
        Obstacles require stat checks to pass:
  
        | Blocker Type | Stat | Description |
        |--------------|------|-------------|
        | **Barricade** | STR | Heavy obstacle to break through |
        | **Locked Door** | DEX | Lock to pick |
        | **Gap** | AGI | Dangerous jump across |
        | **Narrow Ledge** | AGI | Balance required |
  
        **Commands:**
        ```
        study n          # View blocker details, DC, stat
        easier n         # Lower DC by 1 (costs 30 sec)
        n                # Attempt to pass (auto skill check)
        ```
  
        **Failure Results:**
        - **Barricade/Locked Door:** Blocked, no damage
        - **Gap/Narrow:** Take damage AND blocked
  
        **Making It Easier:**
        ```
        easier n         # Costs 30 sec, reduces DC by 1
        easier n         # Can use multiple times
        n                # Then attempt passage
        ```
  
        ### Puzzles
  
        Three puzzle types block progression:
  
        1. **Symbol Grid** - Deduce symbols from clues
        2. **Pipe Network** - Rotate pipes to connect source to drain
        3. **Toggle Matrix** - Click cells to reach target state
  
        **Commands:**
        ```
        study puzzle     # View puzzle details
        solve <answer>   # Attempt solution (costs 15 sec)
        ```
  
        **Difficulty Scaling:**
        - **Easy** (Levels 1-2): More clues, smaller grids
        - **Medium** (Levels 3-4): Moderate challenge
        - **Hard** (Levels 5-6): Few clues, larger grids
        - **Expert** (Levels 7+): Maximum difficulty
  
        **Accessibility Mode:**
        If you have accessibility mode enabled, puzzles are replaced with an alternative obstacle — a trap, stat check, or blocker — so you still face a challenge without needing to solve the puzzle directly.
  
        ## Combat & Monsters
  
        ### Roving Monsters
  
        Monsters patrol the dungeon and move every 10 seconds when you perform time-consuming actions (10+ second cost). They move randomly through adjacent rooms.
  
        **Monster Encounters:**
        - Monsters in your room are **immediately visible**
        - Combat initiates automatically when you collide
        - Uses standard combat system (see `help system combat`)
  
        **Monster Types (by level):**
        - Level 1-2: Rat, Spider, Goblin
        - Level 3-4: Skeleton, Orc
        - Level 5-6: Troll, Ogre
        - Level 7+: Demon, Dragon
  
        ### Study System
  
        **Gain +2 combat bonus** by studying a monster type before fighting:
  
        ```
        study goblin     # Costs 1 minute
        fight            # +2 attack and defense vs goblins
        ```
  
        - Study bonus applies to ALL instances of that monster type
        - Persists for entire delve
        - Stacks with other bonuses
  
        **When to Study:**
        - Before first fight with a monster type
        - When you have spare time (>5 minutes remaining)
        - Not worth studying if time is critical
  
        ### Combat Integration
  
        - Uses existing fight system
        - Each round costs ~10 seconds of delve time
        - HP syncs between delve and combat
        - **Victory:** Monster defeated, gain bonus gold
        - **Defeat:** Lose 50% loot, ejected from delve
  
        ## Multi-Level Progression
  
        ### Descending Levels
  
        ```
        down             # At exit room (stairs)
        ```
  
        **Level Generation:**
        - Entrance room at one corner
        - Exit room at opposite corner
        - Boss room before exit (if enough rooms)
        - Increased difficulty per level
  
        **Difficulty Scaling:**
        - Monster power: +20% per level
        - Trap damage: +1 HP per level
        - Puzzle complexity increases
        - Treasure value doubles
  
        ## Strategy Guide
  
        ### Optimal Delve Run
  
        1. **Explore efficiently**
           - Move quickly (10 sec per room)
           - Skip optional fights if low on time
           - Prioritize terminal rooms for treasure
  
        2. **Manage HP carefully**
           - Use **recover** only when below 3 HP
           - Study monsters before fighting (1 min investment pays off)
           - Avoid risky gaps/ledges if low HP
  
        3. **Use willpower strategically**
           - **Focus** early when you have time
           - Save willpower for critical skill checks
           - Max 3 dice = don't over-invest
  
        4. **Trap navigation**
           - Study traps once, remember pattern
           - Use **listen** only if pattern is ambiguous
           - Mark experienced traps (easier second time)
  
        5. **Time budgeting**
           - 10 rooms = ~2 minutes travel
           - 1 fight = ~5 minutes
           - 1 recover = 5 minutes
           - Leave 10 minutes buffer for escape
  
        ### When to Flee
  
        **Flee immediately if:**
        - Time < 10 minutes remaining
        - HP = 1 and no time to recover
        - Surrounded by monsters with no escape route
        - Collected valuable loot and satisfied
  
        **Keep going if:**
        - Time > 20 minutes remaining
        - HP > 3
        - Clear path to more treasure
        - No monster encounters
  
        ## Quick Reference
  
        **Entry & Exit:**
        - `delve enter <name>` - Create and enter dungeon
        - `flee` - Exit, keep loot
  
        **Movement:**
        - `n/s/e/w/down` - Move (10 sec)
        - `look` - Inspect room
        - `map` - Show minimap
  
        **Obstacles:**
        - `study <direction>` - Study trap/blocker
        - `listen <direction>` - Extend trap observation
        - `go <direction> <pulse>` - Pass trap at pulse
        - `easier <direction>` - Lower blocker DC
        - `study puzzle` - View puzzle
        - `solve <answer>` - Attempt puzzle
  
        **Combat:**
        - `study <monster>` - Study for +2 bonus (1 min)
        - `fight` - Engage monster
  
        **Resources:**
        - `grab` - Loot treasure (free)
        - `recover` - Heal to full (5 min)
        - `focus` - Gain willpower die (30 sec)
  
        **Status:**
        - `status` - View current stats
        - (Dashboard shows automatically when in delve)
  
        ## Troubleshooting
  
        **"You can't go that way."** - Exit blocked by trap, blocker, or no room in that direction. Use `look` to see available exits.
  
        **"Trap blocks the way!"** - Use `study n` to see pulse pattern, then `go n <#>` to time your passage.
  
        **"That obstacle has already been cleared."** - Blocker was defeated, move freely now.
  
        **"The puzzle has already been solved."** - Puzzle cleared, continue exploring.
  
        **"You don't have any stats to roll."** - Set up stat block in character customization first.
  
        **"Time has run out!"** - 60 minutes expired, ejected with 50% loot penalty.
  
        **Can't see monster:** Monsters are immediately visible in current room description. Check `look` output.
  
        **Lost in dungeon:** Use `map` to see explored areas. Terminal rooms (dead ends) have treasure.
      GUIDE
      staff_notes: <<~'STAFF',
        # Delves System - Technical Implementation
  
        Procedural dungeon crawl system with grid-based navigation, time-limited exploration, timing-based traps, skill check obstacles, puzzles, roving monsters, and treasure collection.
  
        ## Architecture Overview
  
        **Core Models:**
        - `Delve`: Dungeon instance with seed, difficulty, time limit, grid dimensions
        - `DelveRoom`: Grid-positioned room (x, y, level) with type, explored status, content flags
        - `DelveParticipant`: Player state (HP, willpower, time spent, loot, position, studied monsters)
        - `DelveBlocker`: Skill check obstacle blocking a direction from a room
        - `DelveMonster`: Roving monster with movement AI
        - `DelvePuzzle`: Procedural puzzle with seed-based generation
        - `DelveTreasure`: Loot container in terminal rooms
        - `DelveTrap`: Timing-based trap blocking directional movement
  
        **Service Layer:**
        - `DelveGeneratorService`: Fractal branching level generation
        - `DelveMovementService`: Navigation, time costs, trap/blocker checks
        - `DelveTrapService`: Coprime pulse generation, passage validation
        - `DelveSkillCheckService`: Blocker attempts, DC calculations
        - `DelvePuzzleService`: Puzzle generation/validation
        - `DelveCombatService`: Fight integration, monster encounters
        - `DelveTreasureService`: Loot generation/collection
        - `DelveMonsterService`: Monster spawning, movement AI
        - `DelveMapService`: Minimap rendering, visibility
        - `DelveVisibilityService`: Fog of war, danger warnings
  
        ## Procedural Generation
  
        ### Fractal Branching Algorithm
  
        **Level Generation Process:**
  
        ```ruby
        # 1. Calculate room budget from grid density
        total_budget = (grid_width * grid_height * DENSITY[:room_ratio]).to_i
        main_budget = (total_budget * DENSITY[:main_tunnel_ratio]).to_i  # 25%
        sub_budget = total_budget - main_budget                           # 75%
  
        # 2. Build main tunnel (vertical with wobble)
        main_rooms = build_main_tunnel(grid, width, height, main_budget, rng)
  
        # 3. Branch from main tunnel points
        branch_points = main_rooms.select { rng.rand < BRANCHING[:chance] }
        branch_points.each do |point|
          build_sub_tunnel(grid, point[:x], point[:y], space, sub_budget / branch_points.length, rng)
        end
  
        # 4. Convert grid to DelveRoom records
        # 5. Mark terminal rooms (dead ends with 1 exit)
        # 6. Assign entrance (top-left area), exit (farthest), boss (second-farthest)
        # 7. Add dynamic content (traps, blockers, puzzles, treasures, monsters)
        ```
  
        **Grid Configuration (GameConfig::Delve::DENSITY):**
        ```ruby
        DENSITY = {
          room_ratio: 0.35,          # Use 35% of grid
          main_tunnel_ratio: 0.25,   # 25% of rooms in main tunnel
          min_main_rooms: 8,         # Minimum main tunnel length
          min_boss_rooms: 15         # Min rooms before adding boss
        }
        ```
  
        **Branching Configuration (GameConfig::Delve::BRANCHING):**
        ```ruby
        BRANCHING = {
          chance: 0.4,               # 40% chance to branch from main tunnel
          max_depth: 3,              # Max recursion depth
          min_budget: 3,             # Min rooms per sub-tunnel
          min_space: 5,              # Min available space to branch
          depth_reduction: 0.1       # Reduce chance by 10% per depth
        }
        ```
  
        ### Room Type Assignment
  
        **Weighted Distribution (GameConfig::Delve::ROOM_WEIGHTS):**
  
        ```ruby
        ROOM_WEIGHTS = {
          easy: {
            corridor: 40,
            chamber: 30,
            treasure: 10,
            monster: 10,
            trap: 5,
            puzzle: 5
          },
          normal: {
            corridor: 35,
            chamber: 25,
            treasure: 10,
            monster: 15,
            trap: 10,
            puzzle: 5
          },
          hard: {
            corridor: 30,
            chamber: 20,
            treasure: 10,
            monster: 20,
            trap: 15,
            puzzle: 5
          }
        }
        ```
  
        ## Trap System
  
        ### Coprime Pulse Generation
  
        Traps use two coprime numbers to create timing patterns:
  
        ```ruby
        # Generate coprime timings (3-10 range)
        def generate_timings
          candidates = (3..10).to_a
  
          100.times do
            a = candidates.sample
            b = (candidates - [a]).sample
  
            # Skip if one is multiple of other
            next if (a % b).zero? || (b % a).zero?
  
            # Skip if not coprime
            next if a.gcd(b) > 1
  
            return [a, b].sort
          end
  
          [3, 7]  # Fallback
        end
        ```
  
        **Trap Pattern:**
        ```ruby
        # A tick is "trapped" if divisible by either number
        def trapped_at?(tick)
          (tick % timing_a).zero? || (tick % timing_b).zero?
        end
  
        # Example with timing_a=3, timing_b=7:
        # Tick:    1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21
        # Trapped: . . T . . T T . T .  .  T  .  T  T  .  .  T  .  .  T
        ```
  
        ### Passage Validation
  
        **First-Time Passage:**
        ```ruby
        def safe_at?(tick, experienced: false)
          if experienced
            # Only selected beat needs to be safe
            !trapped_at?(tick)
          else
            # Both selected AND next beat must be safe
            !trapped_at?(tick) && !trapped_at?(tick + 1)
          end
        end
        ```
  
        **Why This Design:**
        - Coprime numbers create complex, non-obvious patterns
        - First-time rule (check 2 beats) prevents lucky guesses
        - Experienced rule rewards observation and memory
        - Deterministic sequence based on trap ID + participant ID
  
        ### Trap Theming
  
        **Era-Based Themes (DelveTrap::THEMES):**
        ```ruby
        THEMES = {
          medieval: %w[wall_crusher spikes pendulum_blade poison_dart arrow_volley],
          gaslight: %w[steam_vent gas_release clockwork_blade pressure_plate tesla_coil],
          modern: %w[laser_grid electrical_surge gas_release motion_turret spike_floor],
          near_future: %w[plasma_burst force_field_pulse nano_swarm stun_field sonic_trap],
          scifi: %w[disintegration_beam gravity_well teleport_trap phase_shift ion_cannon]
        }
        ```
  
        Damage scales: `trap.damage = dungeon_level` (1 HP per level)
  
        ## Blocker System
  
        ### Skill Check Obstacles
  
        **Blocker Types:**
        ```ruby
        BLOCKER_TYPES = %w[barricade locked_door gap narrow]
  
        # Stat mapping (configurable via GameSettings)
        DEFAULT_STATS = {
          'barricade' => 'STR',    # Break through
          'locked_door' => 'DEX',  # Lockpick
          'gap' => 'AGI',          # Jump across
          'narrow' => 'AGI'        # Balance on ledge
        }
        ```
  
        **Difficulty Calculation:**
        ```ruby
        # Base DC from GameSetting
        base_dc = GameSetting.integer('delve_base_skill_dc') || 10
        dc_per_level = GameSetting.integer('delve_dc_per_level') || 2
        difficulty = base_dc + (dc_per_level * level)
  
        # Apply "easier" attempts
        effective_dc = [difficulty - easier_attempts, 1].max
        ```
  
        **Damage on Failure:**
        - `gap` and `narrow` cause damage on failure
        - `barricade` and `locked_door` just block passage
  
        ## Puzzle Generation
  
        ### Seed-Based Determinism
  
        Each puzzle uses a seed for reproducible generation:
  
        ```ruby
        seed = "#{delve.seed}:#{level}:#{room.id}".hash.abs % 2_000_000_000
        rng = Random.new(seed)
        ```
  
        ### Puzzle Types
  
        **1. Symbol Grid:**
        ```ruby
        # Generate NxN grid with symbols A-F
        # Provide clues: {x: 2, y: 3, symbol: 'C'}
        # Solution: Deduce all symbols from clues
  
        # Difficulty scaling:
        easy: 4x4 grid, 10 clues
        medium: 5x5 grid, 8 clues
        hard: 6x6 grid, 6 clues
        ```
  
        **2. Pipe Network:**
        ```ruby
        # Generate pipes with rotations 0-3
        # Source and drain at random edges
        # Scramble rotations
        # Solution: Rotate pipes to connect path
        ```
  
        **3. Toggle Matrix:**
        ```ruby
        # NxN grid of boolean states
        # Clicking cell toggles center + 4 adjacent
        # Scramble with random moves
        # Solution: Get all cells to same state
        ```
  
        **Accessibility Mode:**
        ```ruby
        def replace_puzzle_for_accessibility!(participant, room)
          return unless participant.accessibility_mode?
          # Replace puzzle with alternative obstacle (trap, stat check, or blocker)
          alternative = generate_alternative_obstacle(room.level)
          room.replace_puzzle_with(alternative)
          Result.new(success: true, message: "Puzzle replaced with #{alternative.type}")
        end
        ```
  
        ## Monster System
  
        ### Movement AI
  
        Monsters move when players perform time-consuming actions (≥10 seconds):
  
        ```ruby
        def tick_monster_movement!(time_spent_seconds)
          threshold = GameSetting.integer('delve_monster_move_threshold') || 10
          return [] if time_spent_seconds < threshold
  
          new_counter = (monster_move_counter || 0) + time_spent_seconds
          update(monster_move_counter: new_counter)
  
          # 50% chance to move per threshold crossed
          active_monsters.each do |monster|
            next unless monster.should_move?  # Random.rand < 0.5
  
            moves = monster.available_moves  # Adjacent rooms via exits
            monster.move_to!(moves.sample[:room])
  
            # Check for collisions with participants
            # ...
          end
        end
        ```
  
        **Collision Detection:**
        - Monster enters occupied room → combat starts
        - Monster passes participant moving opposite direction → combat starts
  
        ### Difficulty Scaling
  
        **Power Calculation:**
        ```ruby
        # Base power for generic PC (used as baseline)
        base_power = (base_hp * 10) + ((str + dex - 20) / 2.0 * 15) + (2.5 * 3)
        # = (6 * 10) + 0 + 7.5 = 67.5 ≈ 68
  
        # Monster difficulty per level
        base_mult = GameSetting.get('delve_base_monster_multiplier')&.to_f || 0.5
        level_inc = GameSetting.get('delve_monster_level_increase')&.to_f || 0.2
        party = [party_size || 1, 1].max
        level_mult = 1 + (level_inc * (level - 1))
  
        monster_difficulty = (base_power * base_mult * party * level_mult).round
  
        # Level 1, solo: 68 * 0.5 * 1 * 1 = 34
        # Level 3, solo: 68 * 0.5 * 1 * 1.4 = 48
        # Level 1, party of 3: 68 * 0.5 * 3 * 1 = 102
        ```
  
        ## Treasure System
  
        ### Value Scaling
  
        ```ruby
        # Base value from GameSettings
        base_min = GameSetting.integer('delve_treasure_base_min') || 5
        base_max = GameSetting.integer('delve_treasure_base_max') || 10
  
        # Double each level
        multiplier = 2**(level - 1)
        min_value = base_min * multiplier
        max_value = base_max * multiplier
  
        # Level 1: 5-10g
        # Level 2: 10-20g
        # Level 3: 20-40g
        # Level 4: 40-80g
        ```
  
        ### Container Types by Era
  
        ```ruby
        CONTAINERS = {
          medieval: 'wooden chest',
          gaslight: 'brass strongbox',
          modern: 'metal safe',
          near_future: 'secure container',
          scifi: 'stasis pod'
        }
        ```
  
        Treasure always spawns in **terminal rooms** (dead ends with 1 exit) except the exit path.
  
        ## Time Management
  
        ### Action Costs (Delve::ACTION_TIMES_SECONDS)
  
        ```ruby
        ACTION_TIMES_SECONDS = {
          move: 10,          # Basic movement
          trap_listen: 10,   # Extend trap observation
          recover: 300,      # Full heal (5 minutes)
          focus: 30,         # Gain willpower die
          study: 60,         # Study monster for +2 bonus
          easier: 30,        # Lower blocker DC
          puzzle_attempt: 15 # Solve attempt
        }
        ```
  
        Combat rounds cost ~10 seconds each, managed by `DelveCombatService`.
  
        ### Time Tracking
  
        ```ruby
        class DelveParticipant
          # Time stored in minutes (legacy), consumed in seconds
          def spend_time_seconds!(seconds)
            minutes_to_add = seconds / 60
            remainder = seconds % 60
            minutes_to_add += 1 if remainder >= 30  # Round up at 30 sec
  
            spend_time!(minutes_to_add) if minutes_to_add > 0
            time_expired? ? :time_expired : :ok
          end
  
          def time_remaining
            delve.time_limit_minutes - (time_spent_minutes || 0)
          end
        end
        ```
  
        ## Data Structures
  
        ### JSONB Columns (Sequel Native Handling)
  
        **DelveParticipant:**
        ```ruby
        # Sequel pg_json plugin handles JSONB natively - no serialization needed
        studied_monsters: [],           # Monster types studied for +2 bonus
        cleared_blockers: [],           # Blocker IDs defeated
        passed_traps: []                # Trap IDs passed (experienced)
  
        # Update examples
        def add_study!(monster_type)
          monsters = studied_monsters || []
          return if monsters.include?(monster_type)
          update(studied_monsters: monsters + [monster_type])
        end
        ```
  
        **DelvePuzzle:**
        ```ruby
        puzzle_data: {},     # Seed-generated puzzle config
        current_state: {}    # Player progress
  
        # Access with hash syntax
        puzzle.puzzle_data['solution']
        puzzle.puzzle_data['clues']
        ```
  
        ### Room Content Flags
  
        **DelveRoom Booleans:**
        - `explored` - Player has visited
        - `cleared` - Monster defeated
        - `is_entrance` - Level entry point
        - `is_exit` - Stairs down
        - `is_terminal` - Dead end (1 exit)
        - `has_treasure` - Treasure present
        - `has_puzzle` - Puzzle present
        - `has_trap` - Trap blocking exit
  
        ## Integration Points
  
        ### Combat System Integration
  
        ```ruby
        # DelveCombatService creates standard Fight
        fight = Fight.create(
          status: 'input',
          fight_type: 'delve',
          metadata: { delve_id: delve.id, monster_id: monster.id }.to_json
        )
  
        # Add monster as NPC FightParticipant
        # Add player FightParticipants with study bonuses
  
        # Each combat round:
        process_round_time!(delve, participants)  # Deduct time, tick monsters
  
        # Fight end:
        sync_hp!(fight, delve_participant)  # Sync fight HP back to delve HP
        ```
  
        ### Visibility Service
  
        ```ruby
        # Danger warnings for adjacent rooms
        warnings = DelveVisibilityService.danger_warnings(participant)
        # Returns array of strings:
        # - "You sense danger to the north."
        # - "You hear growling to the east."
        ```
  
        ## Configuration (GameConfig & GameSettings)
  
        **GameConfig::Delve (hardcoded in config/game_config.rb):**
        - `DENSITY` - Room count ratios
        - `BRANCHING` - Tunnel branching parameters
        - `ROOM_WEIGHTS` - Room type probabilities by difficulty
        - `ACTION_TIMES` - Time costs for actions
        - `CONTENT` - Blocker/trap spawn chances
        - `LOOT` - Treasure base values, variance
        - `TRAPS` - Damage scaling, variance
  
        **GameSetting (database-configurable):**
        - `delve_base_monster_multiplier` - Monster power multiplier (default 0.5)
        - `delve_monster_level_increase` - Power increase per level (default 0.2)
        - `delve_base_skill_dc` - Base blocker difficulty (default 10)
        - `delve_dc_per_level` - DC increase per level (default 2)
        - `delve_treasure_base_min` - Min treasure value (default 5)
        - `delve_treasure_base_max` - Max treasure value (default 10)
        - `delve_defeat_loot_penalty` - Loot lost on defeat/timeout (default 0.5 = 50%)
  
        ## Command Routing
  
        **Contextual Aliases (delve.rb:837-839):**
        ```ruby
        # These work WITHOUT 'delve' prefix when participant is in a delve
        %w[n s e w north south east west down d look l map grab take
           fight flee recover rest focus status study easier listen go solve].each do |cmd|
          Commands::Base::Registry.add_alias(cmd, Commands::Delve::DelveCommand, context: :delve)
        end
        ```
  
        Context detection: `participant = DelveParticipant.where(character_instance_id: ci.id, status: 'active').first`
  
        ## Testing Considerations
  
        **RSpec Coverage:**
        - `spec/models/delve_spec.rb` - Model validations, relationships
        - `spec/models/delve_room_spec.rb` - Room state, exits
        - `spec/models/delve_trap_spec.rb` - Coprime generation, timing validation
        - `spec/services/delve_generator_service_spec.rb` - Level generation
        - `spec/services/delve_trap_service_spec.rb` - Passage logic
  
        **Key Test Scenarios:**
        - Trap timing with coprime patterns (first-time vs experienced)
        - Blocker DC scaling and "easier" attempts
        - Monster movement triggers and collision detection
        - Time management and expiration
        - Loot penalty on defeat/timeout
        - Puzzle replacement with alternative obstacle in accessibility mode
      STAFF
      display_order: 65
    },
    {
      name: 'building',
      display_name: 'Building',
      summary: 'World building — rooms, cities, NPCs, and procedural content',
      description: "The building system lets authorized users create and modify the game world. Build rooms, cities, locations, and procedural content. Decorate rooms with furniture, set backgrounds and seasonal themes, manage windows and graffiti. NPC location commands manage patrol paths and spawn points. Generation commands trigger AI-powered content creation. Most commands require building permissions.",
      command_names: ['build', 'build city', 'build location', 'build block', 'build apartment', 'build shop', 'decorate', 'resize room', 'edit room', 'delete room', 'set background', 'set seasonal', 'windows', 'graffiti', 'clean graffiti', 'make home', 'buy house', 'buy shop', 'rename', 'generate', 'npc'],
      related_systems: %w[local_movement staff_tools items_economy],
      key_files: [
        'plugins/core/building/commands/build.rb',
        'plugins/core/building/commands/build_city.rb',
        'plugins/core/building/commands/build_block.rb',
        'plugins/core/building/commands/build_apartment.rb',
        'plugins/core/building/commands/build_shop.rb',
        'plugins/core/building/commands/build_location.rb',
        'plugins/core/building/commands/decorate.rb',
        'plugins/core/building/commands/redecorate.rb',
        'plugins/core/building/commands/edit_room.rb',
        'plugins/core/building/commands/resize_room.rb',
        'plugins/core/building/commands/delete_room.rb',
        'plugins/core/building/commands/rename.rb',
        'plugins/core/building/commands/make_home.rb',
        'plugins/core/building/commands/graffiti.rb',
        'plugins/core/building/commands/clean_graffiti.rb',
        'plugins/core/building/commands/generate.rb',
        'plugins/core/building/commands/npc.rb',
        'app/services/city_builder_service.rb',
        'app/services/block_builder_service.rb',
        'app/services/room_builder_service.rb',
        'app/services/world_builder_orchestrator_service.rb',
        'app/services/generation_pipeline_service.rb',
        'app/services/canvas_builder.rb',
        'app/services/grid_calculation_service.rb',
        'app/services/street_name_service.rb'
      ],
      player_guide: <<~'GUIDE',
        # Building System - World Construction
  
        The building system provides tools for creating and modifying the game world. Build cities with street grids, construct buildings at intersections, customize rooms with decorations and dimensions, manage property ownership, and use AI-powered generation for realistic content.
  
        **Requires:** Staff permissions with `can_build` flag OR creator mode enabled.
  
        ## Getting Started
  
        ### Permissions Check
  
        Most building commands require one of:
        - **Staff role** with `can_build` permission
        - **Admin role** (has all permissions)
        - **Creator mode** enabled (for non-staff building access)
  
        Check your permissions:
        ```
        @check permissions    # View your permission flags
        ```
  
        ### Creator Mode
  
        Creator mode allows rapid iteration on building projects without full staff permissions:
  
        ```
        @creator on           # Enable creator mode
        @creator off          # Disable creator mode
        @creator              # Check current status
        ```
  
        **Creator mode grants:**
        - Access to building commands
        - Ability to modify owned rooms
        - Fast building workflow
  
        **Does NOT grant:**
        - Permission to modify others' rooms
        - Access to admin-only commands
        - Staff privileges
  
        ## City Building
  
        ### Creating a City
  
        Build a city with a grid of streets (E-W) and avenues (N-S):
  
        ```
        build city            # Interactive form
        build city New York   # Quick build with defaults
        ```
  
        **Interactive Form Fields:**
        - **City Name** - Name for the city (e.g., "New York City")
        - **Streets (E-W)** - Number of horizontal streets (2-50, default: 10)
        - **Avenues (N-S)** - Number of vertical avenues (2-50, default: 10)
        - **Max Building Height** - Maximum height in feet (50-500ft, default: 200)
        - **Longitude/Latitude** - Optional coordinates for LLM context
        - **Use AI for Street Names** - Generate realistic names via AI
  
        **What Gets Created:**
        - **Street segments** - E-W passages between avenues
        - **Avenue segments** - N-S passages between streets
        - **Intersections** - Grid points where streets/avenues cross
        - **Sky room** - Elevated room above the entire city
  
        **Example Output:**
        ```
        You have built New York City!
  
        Created:
          - 10 streets (E-W)
          - 10 avenues (N-S)
          - 100 intersections
          - 1 sky room
          - Total: 111 rooms
  
        You are now at 1st Avenue & 1st Street.
        Use 'build block' at intersections to add buildings.
        ```
  
        ### Street Grid Layout
  
        Cities use a **grid coordinate system**:
  
        - **Grid X**: Avenue index (0 to N-1)
        - **Grid Y**: Street index (0 to N-1)
        - **Intersections**: At grid points (x, y)
        - **Streets**: Between avenues on same Y coordinate
        - **Avenues**: Between streets on same X coordinate
  
        **Navigation Example:**
        ```
        1st Ave & 1st St  →  (grid_x: 0, grid_y: 0)
        1st Ave & 2nd St  →  (grid_x: 0, grid_y: 1)
        2nd Ave & 1st St  →  (grid_x: 1, grid_y: 0)
        ```
  
        Movement follows **spatial adjacency** - walk from intersection to street to next intersection.
  
        ### Street Naming
  
        **AI-Generated Names** (realistic):
        - Uses Claude to generate thematic street names
        - Context-aware (considers location, era, theme)
        - Examples: "Broadway", "Park Avenue", "Sunset Boulevard"
  
        **Numbered Names** (default):
        - "1st Street", "2nd Street", etc.
        - "1st Avenue", "2nd Avenue", etc.
        - Fast generation, no API calls
  
        **Configuration:**
        - Set `use_llm_names: true` to force AI generation
        - Set `use_llm_names: false` to force numbered names
        - Leave blank for auto-detection (based on world theme)
  
        ## Building at Intersections
  
        ### Building Blocks
  
        Add buildings to intersections using predefined layouts:
  
        ```
        build block           # Interactive menu (when at intersection)
        build block apartment # Quick build apartment tower
        build block shop      # Quick build shop/cafe
        build block house     # Quick build single house
        ```
  
        **Available Block Types:**
  
        | Type | Description | Rooms Created |
        |------|-------------|---------------|
        | **Apartment Tower** | Multi-story building with rentable units | 6-12 apartments + lobby + roof |
        | **Brownstone** | Classic urban row house | 3-5 floors, private residence |
        | **House** | Detached single home | 1-2 floors, garden |
        | **Shop/Cafe** | Commercial space | Storefront + storage |
        | **Restaurant** | Dining establishment | Dining room + kitchen + office |
        | **Bar** | Drinking establishment | Bar area + storage + office |
        | **Mall** | Shopping center | Multiple storefronts |
        | **Church** | Religious building | Sanctuary + office |
        | **Hospital** | Medical facility | ER + wards + offices |
        | **Police Station** | Law enforcement | Precinct + cells + offices |
  
        **Block Building Process:**
        1. Stand at intersection (room_type = 'intersection')
        2. Run `build block`
        3. Select building type from menu
        4. Building is constructed at that grid position
        5. Interior rooms are created with spatial connections
  
        ### Apartments
  
        Create rentable apartment units:
  
        ```
        build apartment       # At intersection or inside building
        ```
  
        **Apartment Features:**
        - **Rentable** - Can be assigned to characters
        - **Private** - Only owner can enter
        - **Customizable** - Owner can decorate and resize
        - **Storage** - Safe location for items/wardrobe
  
        **Assignment:**
        ```
        make home             # Set apartment as your home
        ```
  
        ### Shops
  
        Create merchant shops:
  
        ```
        build shop            # At intersection
        ```
  
        **Shop Features:**
        - **Merchant Interface** - Stock items for sale
        - **Ownership** - Owner controls inventory
        - **Economy Integration** - Uses currency system
        - **Location-Based** - Customers must be in shop to browse
  
        **Shop Management:**
        - See `help system items_economy` for shop commands
        - `shop stock` - Manage inventory
        - `shop add <price> <item>` - Add item to shop
        - `shop remove <item>` - Remove item from shop
  
        ## Room Customization
  
        ### Decorations
  
        Add descriptive elements to rooms you own:
  
        ```
        decorate A plush velvet couch sits by the window.
        decorate Vintage posters line the walls.
        decorate A crystal chandelier hangs from the ceiling.
        ```
  
        **Each decoration:**
        - Appears in room's long description
        - Has a display order (appears in order added)
        - Can be removed via `redecorate`
  
        **Removing Decorations:**
        ```
        redecorate            # Interactive menu to remove decorations
        ```
  
        ### Resizing Rooms
  
        Change room dimensions (spatial bounds):
  
        ```
        resize room <width> <depth> <height>
        resize room 30 40 12    # 30ft wide, 40ft deep, 12ft tall
        ```
  
        **Dimensions:**
        - **Width** (X-axis): Minimum 10ft, maximum 200ft
        - **Depth** (Y-axis): Minimum 10ft, maximum 200ft
        - **Height** (Z-axis): Minimum 8ft, maximum 50ft
  
        **Use Cases:**
        - Enlarge apartment for more space
        - Create tall ceilings for dramatic effect
        - Adjust room to fit furniture placement
  
        **Spatial Navigation:**
        Resizing updates the room's polygon bounds. Characters navigate via spatial adjacency - if two rooms share an edge, you can move between them.
  
        ### Editing Room Properties
  
        Modify room details:
  
        ```
        edit room             # Interactive form
        ```
  
        **Editable Properties:**
        - **Name** - Room title
        - **Short Description** - Brief description (1 line)
        - **Long Description** - Detailed description (paragraph)
        - **Room Type** - Type identifier (apartment, shop, house, etc.)
        - **Public/Private** - Accessibility settings
        - **Background Image** - Visual theme
        - **Seasonal Variant** - Seasonal background override
  
        ### Renaming Rooms
  
        Quick rename:
  
        ```
        rename My Cozy Apartment
        rename The Crimson Lounge
        ```
  
        Changes the room's display name.
  
        ### Deleting Rooms
  
        Remove rooms you own:
  
        ```
        delete room           # Requires confirmation
        ```
  
        **Safety:**
        - Can only delete owned rooms
        - Cannot delete rooms with characters inside
        - Spatial connections are recalculated
        - Irreversible action - use with caution
  
        ## Property Ownership
  
        ### Making a Home
  
        Set your current apartment as your home:
  
        ```
        make home             # Must be in apartment you own
        ```
  
        **Home Benefits:**
        - Fast travel via `@home` command
        - Safe storage location
        - Privacy controls
        - Customization permissions
  
        ### Buying Property
  
        Purchase buildings for ownership:
  
        ```
        buy house             # Purchase house
        buy shop              # Purchase shop space
        ```
  
        **Requirements:**
        - Must have sufficient currency
        - Property must be available for sale
        - Transaction is final
  
        ## Advanced Features
  
        ### AI Content Generation
  
        Generate world content using AI:
  
        ```
        generate <type> <context>
        generate room modern apartment
        generate npc friendly merchant
        generate description cozy cafe
        ```
  
        **Generation Types:**
        - **room** - Room descriptions
        - **npc** - NPC personalities and backgrounds
        - **description** - Generic descriptive text
        - **street names** - Realistic street names
  
        **Uses LLM** (Claude) for creative content generation.
  
        ### Graffiti
  
        Add temporary markings to public spaces:
  
        ```
        graffiti Was here - Bobby 2025
        ```
  
        **Graffiti Features:**
        - Appears in room description
        - Public visibility
        - Can be cleaned by staff
  
        **Cleaning Graffiti:**
        ```
        clean graffiti        # Remove graffiti from room
        ```
  
        ### NPC Location Management
  
        Set NPC spawn points and patrol paths:
  
        ```
        npc location <npc_name> here   # Set current room as NPC location
        ```
  
        **Use Cases:**
        - Define merchant locations
        - Set guard patrol routes
        - Assign quest giver positions
  
        ## Quick Reference
  
        **City Creation:**
        - `build city` - Create city grid
        - `build city <name>` - Quick build with defaults
  
        **Building Types:**
        - `build block` - Add building at intersection
        - `build apartment` - Create apartment
        - `build shop` - Create shop
        - `build location` - Create standalone room
  
        **Room Editing:**
        - `decorate <text>` - Add decoration
        - `redecorate` - Remove decorations
        - `edit room` - Edit properties
        - `rename <name>` - Rename room
        - `resize room <w> <d> <h>` - Change dimensions
        - `delete room` - Delete room
  
        **Property:**
        - `make home` - Set home location
        - `buy house` - Purchase house
        - `buy shop` - Purchase shop
  
        **Advanced:**
        - `generate <type> <context>` - AI content generation
        - `graffiti <text>` - Add graffiti
        - `clean graffiti` - Remove graffiti
        - `npc location <npc> here` - Set NPC location
  
        ## Troubleshooting
  
        **"Building commands require staff permissions or creator mode."** - Enable creator mode with `@creator on` or contact admin for building permissions.
  
        **"A city has already been built at this location."** - Cities can only be built once per location. Use existing city or choose a different location.
  
        **"You must be at an intersection to build a block."** - Stand at a grid intersection (where street meets avenue) before using `build block`.
  
        **"You don't own this room."** - You can only edit/decorate rooms you own. Use `make home` in apartments you've rented or `buy house` to purchase property.
  
        **"Room dimensions must be at least 10x10x8 feet."** - Minimum room size enforced. Check `resize room` usage.
  
        **"Cannot delete room with characters inside."** - Ask all characters to leave the room before deleting it.
  
        **LLM generation fails:** - Check that ANTHROPIC_API_KEY is configured. LLM features require Claude access.
      GUIDE
      staff_notes: <<~'STAFF',
        # Building System - Technical Implementation
  
        World construction system supporting city grids, building blocks, room customization, property ownership, and AI-powered content generation.
  
        ## Architecture Overview
  
        **Core Services:**
        - `CityBuilderService`: City grid generation (streets, avenues, intersections, sky)
        - `BlockBuilderService`: Building construction with predefined layouts
        - `RoomBuilderService`: Individual room creation and modification
        - `CanvasBuilder`: Spatial polygon manipulation
        - `GridCalculationService`: Grid coordinate to spatial bounds conversion
        - `StreetNameService`: Street/avenue name generation (LLM or numbered)
        - `WorldBuilderOrchestratorService`: Complex generation pipelines
        - `GenerationPipelineService`: Async LLM content generation jobs
  
        **Command Layer:**
        - `Commands::Building::Build`: Main router for building operations
        - `Commands::Building::BuildCity`: City grid creation
        - `Commands::Building::BuildBlock`: Building construction at intersections
        - `Commands::Building::BuildApartment`: Apartment creation
        - `Commands::Building::BuildShop`: Shop creation
        - `Commands::Building::Decorate`: Room decoration system
        - `Commands::Building::EditRoom`: Room property modification
        - `Commands::Building::ResizeRoom`: Spatial dimension changes
        - `Commands::Building::Generate`: LLM content generation
        - `Commands::Building::Npc`: NPC location management
  
        ## City Building
  
        ### Grid Generation Algorithm
  
        **Step 1: Calculate Room Budgets**
        ```ruby
        street_count = params[:horizontal_streets] || 10
        avenue_count = params[:vertical_streets] || 10
  
        # Streets: one room per street (spans full city width)
        # Avenues: one room per avenue (spans full city height)
        # Intersections: street_count × avenue_count (overlaid on streets/avenues)
        intersections = street_count * avenue_count
  
        # Total: streets + avenues + intersections + sky
        total_rooms = street_count + avenue_count + intersections + 1
        ```
  
        **Step 2: Generate Street/Avenue Names**
        ```ruby
        # Via StreetNameService
        street_names = generate_street_names(location, street_count, use_llm)
        avenue_names = generate_avenue_names(location, avenue_count, use_llm)
  
        # LLM generation (if enabled)
        if use_llm
          prompt = GamePrompts.get('street_names.generation',
                                    location: location.name,
                                    count: count,
                                    direction: direction)
          response = LlmService.generate(prompt)
          parse_street_names(response)
        else
          # Numbered fallback
          (1..count).map { |i| "#{i.ordinalize} #{direction.capitalize}" }
        end
        ```
  
        **Step 3: Build Grid Rooms**
        ```ruby
        # Streets (E-W, one room per street spanning full city width)
        street_names.each_with_index do |name, street_index|
          bounds = GridCalculationService.street_bounds(
            grid_index: street_index,
            city_size: avenue_count
          )
  
          Room.create(
            name: name,
            room_type: 'street',
            grid_x: nil,
            grid_y: street_index,
            min_x: bounds[:min_x],
            max_x: bounds[:max_x],
            # ... spatial bounds
          )
        end
  
        # Avenues (N-S, one room per avenue spanning full city height)
        # Similar logic with avenue_bounds
  
        # Intersections (grid points, overlaid on streets/avenues)
        street_names.each_with_index do |street, street_index|
          avenue_names.each_with_index do |avenue, avenue_index|
            Room.create(
              name: "#{street} & #{avenue}",
              room_type: 'intersection',
              grid_x: avenue_index,
              grid_y: street_index,
              # ... spatial bounds
            )
          end
        end
        ```
  
        **Step 4: Create Sky Room**
        ```ruby
        sky_room = Room.create(
          name: "Sky above #{city_name}",
          room_type: 'sky',
          min_z: max_building_height,
          max_z: max_building_height + 100,
          # ... covers entire city X/Y bounds
        )
        ```
  
        ### Grid Calculation
  
        **Street Bounds (E-W, full city width):**
        ```ruby
        def street_bounds(grid_index:, city_size:)
          # Streets span from x=0 to x=city_size * GRID_CELL_SIZE
          {
            min_x: 0,
            max_x: city_size * GRID_CELL_SIZE,
            min_y: grid_index * GRID_CELL_SIZE,
            max_y: grid_index * GRID_CELL_SIZE + STREET_WIDTH,
            min_z: 0,
            max_z: 10
          }
        end
        ```
  
        **Avenue Bounds (N-S, full city height):**
        ```ruby
        def avenue_bounds(grid_index:, city_size:)
          # Avenues span from y=0 to y=city_size * GRID_CELL_SIZE
          {
            min_x: grid_index * GRID_CELL_SIZE,
            max_x: grid_index * GRID_CELL_SIZE + STREET_WIDTH,
            min_y: 0,
            max_y: city_size * GRID_CELL_SIZE,
            min_z: 0,
            max_z: 10
          }
        end
        ```
  
        **Intersection Bounds:**
        ```ruby
        def intersection_bounds(grid_x:, grid_y:)
          size = INTERSECTION_SIZE
  
          {
            min_x: grid_x * (STREET_WIDTH + size),
            max_x: grid_x * (STREET_WIDTH + size) + size,
            min_y: grid_y * (STREET_WIDTH + size),
            max_y: grid_y * (STREET_WIDTH + size) + size,
            min_z: 0,
            max_z: 20
          }
        end
        ```
  
        ## Building Blocks
  
        ### Block Types and Layouts
  
        **Predefined Layouts (BlockBuilderService::LAYOUTS):**
  
        ```ruby
        LAYOUTS = {
          apartment_tower: {
            floors: 6,
            units_per_floor: 2,
            rooms: [:lobby, :apartments, :roof],
            dimensions: { width: 80, depth: 60, height: 20 }
          },
          brownstone: {
            floors: 4,
            rooms: [:entry, :living, :dining, :kitchen, :bedrooms, :roof],
            dimensions: { width: 25, depth: 60, height: 15 }
          },
          house: {
            floors: 2,
            rooms: [:living, :kitchen, :bedroom, :bathroom, :garden],
            dimensions: { width: 40, depth: 50, height: 12 }
          },
          shop: {
            floors: 1,
            rooms: [:storefront, :storage],
            dimensions: { width: 30, depth: 40, height: 15 }
          }
          # ... more layouts
        }
        ```
  
        **Construction Process:**
        ```ruby
        def build_block(intersection:, block_type:, character:)
          layout = LAYOUTS[block_type]
  
          # Create outer building room
          building = Room.create(
            location_id: intersection.location_id,
            name: "#{NamingHelper.titleize(block_type.to_s)} at #{intersection.name}",
            room_type: block_type.to_s,
            grid_x: intersection.grid_x,
            grid_y: intersection.grid_y,
            # Spatial bounds calculated from layout dimensions
            min_x: intersection.min_x,
            max_x: intersection.min_x + layout[:dimensions][:width],
            min_y: intersection.min_y,
            max_y: intersection.min_y + layout[:dimensions][:depth],
            min_z: 0,
            max_z: layout[:dimensions][:height] * layout[:floors]
          )
  
          # Create interior rooms based on layout
          create_interior_rooms(building, layout)
  
          building
        end
        ```
  
        ### Interior Room Generation
  
        ```ruby
        def create_interior_rooms(building, layout)
          case layout[:type]
          when :apartment_tower
            create_lobby(building)
            create_apartments(building, layout[:floors], layout[:units_per_floor])
            create_roof(building)
          when :shop
            create_storefront(building)
            create_storage(building)
          # ... other types
          end
        end
  
        def create_apartments(building, floors, units_per_floor)
          floors.times do |floor_index|
            units_per_floor.times do |unit_index|
              Room.create(
                location_id: building.location_id,
                outer_room_id: building.id,  # Interior of building
                name: "Apartment #{floor_index + 1}#{('A'.ord + unit_index).chr}",
                room_type: 'apartment',
                # Spatial subdivision within building bounds
                min_z: floor_index * 20,
                max_z: (floor_index + 1) * 20
                # X/Y calculated to divide floor space
              )
            end
          end
        end
        ```
  
        ## Spatial Navigation Integration
  
        ### Polygon-Based Adjacency
  
        Rooms connect via **spatial adjacency** (not manual exits):
  
        ```ruby
        # RoomAdjacencyService detects shared edges
        adjacent_rooms = RoomAdjacencyService.adjacent_rooms(room)
        # Returns: { north: [rooms], south: [rooms], east: [rooms], west: [rooms] }
  
        # Passability check
        can_pass = RoomPassabilityService.can_pass?(from_room, to_room, :north)
        # Checks for walls, doors, openings
        ```
  
        **Building Placement:**
        - Building rooms placed at intersection grid positions
        - Interior rooms use `outer_room_id` to reference parent building
        - Spatial bounds subdivide building volume
  
        ## Content Generation
  
        ### LLM Integration
  
        **Street Name Generation:**
        ```ruby
        prompt = GamePrompts.get('street_names.generation',
                                  location: location.name,
                                  era: current_era,
                                  theme: world_theme,
                                  count: count,
                                  direction: direction)
  
        response = LlmService.generate(prompt, model: 'claude-sonnet-4.5')
        names = parse_street_names(response)
        # Returns: ["Broadway", "Park Avenue", "Sunset Boulevard", ...]
        ```
  
        **Room Description Generation:**
        ```ruby
        prompt = GamePrompts.get('room_generation.description',
                                  room_type: 'apartment',
                                  style: 'modern',
                                  size: 'medium')
  
        description = LlmService.generate(prompt)
        room.update(long_description: description)
        ```
  
        ### Generation Pipeline
  
        **Async Job Processing:**
        ```ruby
        # GenerationPipelineService enqueues jobs
        job = GenerationPipelineService.enqueue(
          type: :room_description,
          target_id: room.id,
          context: { style: 'modern', size: 'large' }
        )
  
        # Background worker processes
        # Result stored in job.result_data
        # Notification sent to requester
        ```
  
        ## Permissions & Ownership
  
        ### Permission Checks
  
        **Building Permission:**
        ```ruby
        def can_build?(character, action = :build_city)
          character.admin? ||
            character.staff? && character.has_permission?(:can_build) ||
            character_instance.creator_mode?
        end
        ```
  
        **Room Ownership:**
        ```ruby
        def owned_by?(character)
          owner_id == character.id ||
            character.admin? ||
            (outer_room&.owned_by?(character))
        end
        ```
  
        **Modification Rights:**
        ```ruby
        # requires_can_modify_rooms mixin in commands
        def require_property_ownership
          room = location.respond_to?(:outer_room) ? location.outer_room : location
  
          unless room.owned_by?(character)
            return error_result("You don't own this property.")
          end
  
          nil  # No error
        end
        ```
  
        ### Creator Mode
  
        **Toggle:**
        ```ruby
        character_instance.update(creator_mode: true)
        # Grants building permissions
        # Does NOT grant admin/staff privileges
        # Used for rapid prototyping and testing
        ```
  
        ## Configuration
  
        **GameConfig::CityBuilder:**
        ```ruby
        DEFAULTS = {
          horizontal_streets: 10,
          vertical_streets: 10,
          max_building_height: 200  # feet
        }
  
        LIMITS = {
          min_streets: 2,
          max_streets: 50,
          min_avenues: 2,
          max_avenues: 50,
          min_building_height: 50,
          max_building_height: 500
        }
  
        STREET_WIDTH = 100        # feet
        INTERSECTION_SIZE = 100   # feet
        ```
  
        **GameConfig::BlockBuilder:**
        ```ruby
        DEFAULTS = {
          apartment_floors: 6,
          units_per_floor: 2,
          room_height: 20  # feet per floor
        }
        ```
  
        ## Data Structures
  
        **Room Fields:**
        - `grid_x`, `grid_y` - Grid coordinates for city rooms
        - `city_role` - Role in city ('street', 'avenue', 'intersection', 'sky')
        - `street_name` - Name of street this room belongs to
        - `outer_room_id` - Parent building for interior rooms
        - `owner_id` - Character who owns the room
        - `min_x`, `max_x`, `min_y`, `max_y`, `min_z`, `max_z` - Spatial bounds
  
        **Location Fields:**
        - `city_built_at` - Timestamp when city was constructed
        - `city_name` - Name of the city
        - `max_building_height` - Height limit for buildings
  
        ## Testing Considerations
  
        **RSpec Coverage:**
        - `spec/services/city_builder_service_spec.rb` - City generation
        - `spec/services/block_builder_service_spec.rb` - Building construction
        - `spec/services/grid_calculation_service_spec.rb` - Coordinate math
        - `spec/commands/building/build_city_spec.rb` - Command integration
  
        **Key Test Scenarios:**
        - City grid generation with various dimensions
        - Street/avenue name generation (LLM and numbered)
        - Building block construction at intersections
        - Spatial adjacency after building placement
        - Permission checks (staff, creator mode, ownership)
        - Room resizing and spatial recalculation
        - Decoration creation and ordering
      STAFF
      display_order: 70
    },
    {
      name: 'crafting',
      display_name: 'Crafting',
      summary: 'Pattern-based item fabrication and meta-structure creation',
      player_guide: <<~'GUIDE',
        # Crafting System
  
        Firefly's crafting system consists of two distinct mechanics: **pattern-based fabrication** for physical items, and **meta-structure creation** for game elements like events and notes.
  
        ## Pattern-Based Fabrication
  
        ### Overview
  
        The `fabricate` command lets you create physical items from **patterns** - templates you own that define item properties. Fabrication requires appropriate facilities and takes time based on the current era.
  
        **Basic Usage:**
        ```
        fabricate <pattern name>     # Create an item from a pattern you own
        fabricate                    # View your pending orders
        fabricate orders             # Same as above
        fabricate pickup <id>        # Pick up a ready order
        fabricate deck               # Special: Create a card deck
        ```
  
        **Examples:**
        ```
        fabricate silk dress
        fabricate leather jacket
        fabricate golden ring
        fabricate pickup 1
        ```
  
        **Aliases:** `conjure`, `fab`
  
        ### How Fabrication Works
  
        1. **Find a Facility:** Visit an appropriate workshop, shop, or crafting room for your item type
        2. **Select Your Pattern:** Use `fabricate <name>` with a pattern you own
        3. **Choose Delivery:**
           - **Pickup:** Return to the workshop when ready (default)
           - **Delivery:** Have it delivered to your home room (if you own one)
        4. **Wait:** Fabrication takes time based on era and item complexity
        5. **Collect:** Pick up your item or find it delivered to your home
  
        ### Era-Based Timing
  
        Fabrication speed depends on the current game era:
  
        | Era | Base Time | Example (Clothing) | Technology |
        |-----|-----------|-------------------|------------|
        | **Medieval** | 4 hours | ~4 hours | Handcraft by artisan |
        | **Gaslight** | 2 hours | ~2 hours | Industrial workshops |
        | **Modern** | 30 minutes | ~30 minutes | Automated machinery |
        | **Near-Future** | 1 minute | ~1 minute | 3D printing |
        | **Sci-Fi** | Instant | Instant | Matter replicators |
  
        **Complexity Multipliers:**
        - Clothing: 1.0× (standard)
        - Jewelry: 1.5× (intricate work)
        - Weapons: 2.0× (heavy forging)
        - Tattoos: 0.5× (quick application)
        - Pets: 3.0× (breeding/cloning)
  
        **Examples:**
        - Medieval clothing: 4 hours
        - Modern jewelry: 45 minutes (30 min × 1.5)
        - Sci-Fi weapon: Instant (below 10-second threshold)
  
        ### Facility Requirements
  
        Different item types require specific facilities:
  
        **Clothing & Fashion:**
        - Tailor shops
        - Fashion studios
        - General shops
  
        **Jewelry:**
        - Jeweler shops
        - Crafting studios
        - General shops
  
        **Weapons:**
        - Forges
        - Armories
        - Blacksmiths
  
        **Tattoos:**
        - Tattoo parlors
        - Medical clinics
  
        **Pets:**
        - Pet shops (medieval/modern)
        - Breeders (medieval/modern)
        - Cloning labs (sci-fi)
  
        **Universal Facilities** (any pattern type):
        - Replicators (sci-fi)
        - Materializers (sci-fi)
        - Fabrication bays (sci-fi)
  
        **Tutorial Rooms:** Always allow fabrication regardless of type.
  
        ### Delivery Options
  
        When fabricating an item with significant time requirements, you'll be presented with delivery options:
  
        **Pickup (Default):**
        - Return to the workshop when the item is ready
        - Use `fabricate pickup <id>` or `fabricate pickup <index>` to collect
        - Must be at the fabrication room to pick up
  
        **Delivery (Home Required):**
        - Item is delivered to your home room when complete
        - Requires owning a room (property ownership)
        - Receive notification when delivery arrives
  
        **Checking Orders:**
        ```
        fabricate               # Show all pending orders with:
                                # - Item name
                                # - Time remaining or "Ready"
                                # - Delivery method (pickup/delivery)
                                # - Location (workshop or home)
        ```
  
        ### Instant Fabrication
  
        If fabrication time is under 10 seconds (typically sci-fi era), the item is created instantly in your inventory without delivery options.
  
        ### Patterns
  
        Patterns are templates that define item properties:
        - **Description:** Visual appearance
        - **Type:** Clothing, jewelry, weapon, etc.
        - **Properties:** Layer, coverage, damage, etc.
        - **Era:** Min/max year restrictions
        - **Price:** Shop purchase cost
  
        **Acquiring Patterns:**
        - Purchase from shops
        - Receive as quest rewards
        - Staff creation via admin interface
        - Player-created patterns (future feature)
  
        **Pattern Ownership:**
        - You can only fabricate patterns you own
        - Patterns are stored in your inventory or pattern collection
        - Some patterns may be era-restricted
  
        ### Card Decks
  
        Special fabrication for card decks:
  
        ```
        fabricate deck          # Create a card deck from your owned patterns
        ```
  
        If you own multiple deck patterns (Standard 52-card, Tarot, custom decks), you'll be prompted to choose which one to fabricate.
  
        ### Era-Appropriate Messaging
  
        The system uses era-appropriate language:
  
        **Medieval/Gaslight:**
        > "The craftsman begins work on your silk dress. Return here in 4 hours to collect it."
  
        **Modern:**
        > "Your order has been placed. It will be ready in 30 minutes."
  
        **Near-Future:**
        > "Fabrication initiated. Estimated completion: 1 minute."
  
        **Sci-Fi:**
        > "Synthesizing... ready in 3 seconds."
  
        ## Meta-Structure Creation
  
        ### Overview
  
        The `make` command creates non-physical game elements like events, societies, and personal notes. These are **meta-structures** - organizational and narrative tools rather than physical items.
  
        **Note:** For physical items like weapons, clothing, and objects, use `fabricate` or `design` (staff only).
  
        ### Supported Meta-Structures
  
        **Events & Scheduling:**
        ```
        make event              # Create a scheduled event (redirects to web)
        make calendar           # Same as above
        ```
        Creates events with attendee tracking, decoration, and scheduling. Handled through the web interface at `/calendar/new`.
  
        **Social Groups:**
        ```
        make society            # Create a social group (redirects to web)
        make club               # Same as above
        make group              # Same as above
        ```
        Creates societies/clubs with membership management. Handled through the web interface at `/societies/new`.
  
        **Personal Notes:**
        ```
        make memo <text>        # Create a personal note-to-self
        make note <text>        # Same as above
        ```
  
        **Example:**
        ```
        make memo Remember to visit the library tomorrow at noon
        ```
  
        Creates a memo stored in your character's inbox. Useful for tracking tasks, reminders, or IC notes.
  
        **Roleplay Scenes:**
        ```
        make scene [name]       # Begin a roleplay scene
        make story [name]       # Same as above
        ```
  
        **Examples:**
        ```
        make scene The Tavern Confrontation
        make scene              # Auto-names based on current room
        ```
  
        Marks the start of a roleplay scene for history tracking and narrative continuity.
  
        **Building Elements (Room Ownership Required):**
  
        These require owning the current room:
  
        ```
        make entrance           # Mark this room as an entrance (visitor arrival point)
        make library            # Designate this room as an arcane library
        ```
  
        **Web-Only Building Features:**
  
        These redirect to the building interface:
  
        ```
        make space              # Configure room space properties
        make floor              # Add floors to multi-story buildings
        ```
  
        ### No Arguments
  
        Running `make` with no arguments shows available types:
  
        ```
        make
        ```
  
        Output:
        > Make what? Available types: calendar, club, entrance, event, floor, group, library, memo, note, scene, society, space, story
        >
        > Examples:
        >   make event - Create a scheduled event
        >   make society - Create a social group
        >   make memo - Create a personal note
        >   make scene - Start a roleplay scene
  
        ## Staff Commands
  
        ### Design Command (Staff Only)
  
        The `design` command is a staff tool for creating physical items directly, bypassing the fabrication system:
  
        ```
        design                  # Open design menu
        design item             # Create an item with form interface
        ```
  
        **Aliases:** `create item`, `createitem`, `spawn item`, `item create`
  
        **Item Types:**
        - Generic Item
        - Weapon (with damage properties)
        - Armor (with armor value)
        - Clothing
        - Jewelry
        - Container (with capacity)
        - Food (consumable)
        - Drink (consumable)
        - Key (with unique ID)
        - Furniture
        - Decoration
  
        **Form Fields:**
        - **Name:** Item display name (required, max 200 chars)
        - **Description:** Detailed description (optional, max 2000 chars)
        - **Type:** Item category (affects properties)
        - **Quantity:** Number of items (1-999)
        - **Condition:** Excellent, Good, Fair, Poor, Broken
        - **Image URL:** Optional image URL (must start with http/https)
  
        **Properties by Type:**
        - **Weapons:** Auto-assigned `damage_dice: '1d6'`, `weapon_type: 'melee'`
        - **Armor:** Auto-assigned `armor_value: 1`, `armor_type: 'light'`
        - **Containers:** Auto-assigned `capacity: 10`, `container: true`
        - **Food:** Auto-assigned `consume_type: 'food'`, `consume_time: 5`
        - **Drink:** Auto-assigned `consume_type: 'drink'`, `consume_time: 3`
        - **Keys:** Auto-assigned unique `key_id` (16-char hex)
  
        **Usage:**
        1. Use `design` or `design item` to open the form
        2. Fill in item details
        3. Submit to create the item in your current room
        4. Other players in the room see: "{Your Name} creates {item name}."
  
        **Permissions:**
        - Requires `staff: true` or `admin: true` on character
        - Creator mode does NOT grant access to design command
  
        ## Summary
  
        | Command | Purpose | Access | Creates |
        |---------|---------|--------|---------|
        | `fabricate` | Pattern-based item creation | All players | Physical items from owned patterns |
        | `make` | Meta-structure creation | All players | Events, memos, scenes, building elements |
        | `design` | Direct item spawning | Staff only | Physical items without patterns |
  
        **Key Concepts:**
        - **Patterns** define item templates you can fabricate
        - **Era** determines fabrication speed (medieval hours → sci-fi instant)
        - **Facilities** restrict what can be made where (tailor for clothing, forge for weapons)
        - **Delivery** lets you choose pickup vs home delivery
        - **Meta-structures** are non-physical game elements (events, notes, scenes)
      GUIDE
      command_names: %w[fabricate make design],
      related_systems: %w[items_economy building],
      key_files: [
        'plugins/core/crafting/commands/make.rb',
        'plugins/core/crafting/commands/fabricate.rb',
        'plugins/core/building/commands/design.rb',
        'app/models/pattern.rb',
        'app/models/fabrication_order.rb',
        'app/models/deck_pattern.rb',
        'app/models/memo.rb',
        'app/services/fabrication_service.rb',
        'app/services/pattern_designer_service.rb',
        'app/handlers/fabrication_completion_handler.rb',
        'config/game_config.rb'
      ],
      staff_notes: <<~'STAFF',
        # Crafting System Architecture
  
        ## Overview
  
        Firefly's crafting system is **pattern-based**, NOT recipe/material-based. It consists of three distinct subsystems:
  
        1. **Pattern Fabrication:** Players create items from owned pattern templates
        2. **Meta-Structure Creation:** Players create non-physical game elements
        3. **Staff Item Design:** Staff directly spawn items without patterns
  
        ## 1. Pattern Fabrication (`fabricate` command)
  
        ### Core Models
  
        **Pattern** (`app/models/pattern.rb`):
        - Template defining item properties
        - References `UnifiedObjectType` for category/subcategory/layer
        - Category constants: `CLOTHING_CATEGORIES`, `JEWELRY_CATEGORIES`, `WEAPON_CATEGORIES`, etc.
        - Type checks: `clothing?`, `jewelry?`, `weapon?`, `tattoo?`, `pet?`, `consumable?`
        - `instantiate(options)` creates an Item from the pattern
        - Weapon properties: `melee_weapon?`, `ranged_weapon?`, `dual_mode_weapon?`
        - Combat stats: `attack_interval`, `range_in_hexes`, `melee_reach_value`, `attacks_per_round`
        - Holster system: `holster?`, `accepts_weapon_type?(weapon_pattern)`
  
        **FabricationOrder** (`app/models/fabrication_order.rb`):
        - Tracks pending fabrication jobs
        - Status: `crafting`, `ready`, `delivered`, `cancelled` (from `GameConfig::Fabrication::STATUSES`)
        - Delivery method: `pickup`, `delivery` (from `GameConfig::Fabrication::DELIVERY_METHODS`)
        - Time tracking: `completes_at`, `time_remaining`, `time_remaining_display`
        - State checks: `complete?`, `crafting?`, `ready?`, `delivered?`, `cancelled?`, `pickup?`, `delivery?`
        - Scopes: `ready_to_complete`, `pending_for_character`, `awaiting_pickup_at`, `crafting`, `ready`
        - `create_item(character_instance:, room:)` instantiates from pattern
  
        **DeckPattern** (`app/models/deck_pattern.rb`):
        - Special pattern for card decks (Standard 52-card, Tarot, custom)
        - `create_deck_for(character_instance)` creates Deck instance
        - Ownership: `owned_by?(character)`, `grant_to(character)`
        - Factory methods: `create_standard_deck`, `create_standard_deck_with_jokers`, `create_tarot_deck`
  
        ### FabricationService
  
        **Location:** `app/services/fabrication_service.rb`
  
        **Core Methods:**
  
        ```ruby
        # Permission check
        FabricationService.can_fabricate_here?(character_instance, pattern)
        # Returns true if:
        # - Character is admin
        # - Room is tutorial room
        # - Room is universal facility (replicator, materializer, fabrication_bay)
        # - Room type matches pattern requirements (tailor for clothing, forge for weapons)
  
        # Time calculation
        FabricationService.calculate_time(pattern)
        # Formula: base_time * era_complexity_mult * pattern_type_mult
        # Era times from GameConfig::Fabrication::ERA_TIMES
        # Pattern multipliers from GameConfig::Fabrication::COMPLEXITY_MULTIPLIERS
  
        # Instant check
        FabricationService.instant?(pattern)
        # Returns true if calculate_time < INSTANT_THRESHOLD_SECONDS (10 seconds)
  
        # Start fabrication
        FabricationService.start_fabrication(ci, pattern, delivery_method:, delivery_room:, item_options:)
        # Creates FabricationOrder with calculated completion time
  
        # Process completed orders (scheduled task)
        FabricationService.process_completed_orders
        # Loops through FabricationOrder.ready_to_complete
        # Calls complete_order for each
  
        # Complete individual order
        FabricationService.complete_order(order)
        # If delivery: creates item in delivery_room, marks delivered
        # If pickup: marks ready, notifies player if online
  
        # Pickup ready order
        FabricationService.pickup_order(character_instance, order)
        # Validates order is ready and belongs to character
        # Creates item in character inventory
        # Returns { success:, item:, message: }
        ```
  
        **Era-Appropriate Messaging:**
        - `crafting_started_message(pattern, time_seconds)`
        - `delivery_started_message(pattern, delivery_room, time_seconds)`
        - Uses EraService to adapt language (craftsman vs synthesizing)
  
        ### GameConfig::Fabrication
  
        **Location:** `config/game_config.rb` (lines ~1511-1563)
  
        ```ruby
        # Facility requirements by pattern type
        FACILITY_REQUIREMENTS = {
          'clothing' => %w[tailor shop fashion_studio],
          'jewelry' => %w[jeweler shop crafting_studio],
          'weapon' => %w[forge armory blacksmith],
          'tattoo' => %w[tattoo_parlor clinic],
          'pet' => %w[pet_shop breeder cloning_lab]
        }
  
        # Universal facilities (any pattern type)
        UNIVERSAL_FACILITIES = %w[replicator materializer fabrication_bay]
  
        # Era-based fabrication times
        ERA_TIMES = {
          medieval:    { base_seconds: 14_400, complexity_mult: 1.0 },  # 4 hours
          gaslight:    { base_seconds: 7200,   complexity_mult: 1.0 },  # 2 hours
          modern:      { base_seconds: 1800,   complexity_mult: 1.0 },  # 30 min
          near_future: { base_seconds: 60,     complexity_mult: 1.0 },  # 1 min
          scifi:       { base_seconds: 3,      complexity_mult: 1.0 }   # instant
        }
  
        # Instant threshold
        INSTANT_THRESHOLD_SECONDS = 10
  
        # Pattern complexity multipliers
        COMPLEXITY_MULTIPLIERS = {
          'clothing' => 1.0,
          'jewelry' => 1.5,
          'weapon' => 2.0,
          'tattoo' => 0.5,
          'pet' => 3.0
        }
  
        # Helper method
        def self.pattern_type_key(pattern)
          return 'pet' if pattern.pet?
          return 'weapon' if pattern.weapon?
          return 'jewelry' if pattern.jewelry?
          return 'tattoo' if pattern.tattoo?
          'clothing' # Default
        end
        ```
  
        ### Command Flow (fabricate.rb)
  
        **No Argument:**
        1. Call `show_pending_orders`
        2. Fetch `FabricationService.pending_orders(character)`
        3. Display list with status, time remaining, location
  
        **With Pattern Name:**
        1. Check `FabricationService.can_fabricate_here?(ci, nil)` - facility present?
        2. Find pattern in inventory using `TargetResolverService`
        3. Check `FabricationService.can_fabricate_here?(ci, pattern)` - correct facility?
        4. If instant (`FabricationService.instant?(pattern)`):
           - Call `pattern.instantiate(character_instance: ci)`
           - Return success immediately
        5. Otherwise:
           - Show delivery options quickmenu (pickup vs delivery)
           - Store context with pattern_id, fabrication_time, home_room_id
  
        **Quickmenu Response (handle_quickmenu_response):**
        1. Retrieve pattern from context
        2. If 'pickup': call `start_fabrication_order(pattern, 'pickup', nil)`
        3. If 'delivery': call `start_fabrication_order(pattern, 'delivery', home_room)`
        4. `start_fabrication_order` calls `FabricationService.start_fabrication`
        5. Return success with order details and completion time
  
        **Pickup Order:**
        1. Find order by index (1-based) or ID
        2. Validate order is ready and method is 'pickup'
        3. Check character is at fabrication room
        4. Call `FabricationService.pickup_order(ci, order)`
        5. Return item to inventory
  
        **Deck Fabrication:**
        1. Find owned DeckPatterns (creator, public, or DeckOwnership)
        2. If multiple, show quickmenu
        3. Call `pattern.create_deck_for(character_instance)`
        4. Returns Deck instance with shuffled cards
  
        ### Pattern Finding
  
        Uses `TargetResolverService.resolve`:
        1. Search patterns with `Sequel.ilike(:description, "%#{name}%")`
        2. If empty, search all patterns and strip HTML from descriptions
        3. Resolve using description_field matching
  
        ### Scheduled Task Processing
  
        **Handler:** `app/handlers/fabrication_completion_handler.rb`
  
        Periodic job (likely via Clockwork or similar):
        1. Calls `FabricationService.process_completed_orders`
        2. For each order with `completes_at <= Time.now`:
           - If delivery: creates item in delivery_room, notifies player
           - If pickup: marks ready, notifies player
        3. Broadcasts notifications via `character_instance.send_system_message`
  
        ## 2. Meta-Structure Creation (`make` command)
  
        **Location:** `plugins/core/crafting/commands/make.rb`
  
        **Subcommand Map:**
        ```ruby
        SUBCOMMAND_MAP = {
          'event' => :make_event,        # Redirects to /calendar/new
          'calendar' => :make_event,
          'society' => :make_society,    # Redirects to /societies/new
          'club' => :make_society,
          'group' => :make_society,
          'memo' => :make_memo,          # Creates Memo record
          'note' => :make_memo,
          'scene' => :make_scene,        # Announces scene start
          'story' => :make_scene,
          'entrance' => :make_entrance,  # Marks room as entrance (ownership required)
          'library' => :make_library,    # Designates arcane library (ownership required)
          'space' => :make_space,        # Redirects to /building
          'floor' => :make_floor         # Redirects to /building
        }
        ```
  
        **Memo Creation:**
        ```ruby
        def make_memo(args)
          memo_text = args.strip
          char = character_instance.character
  
          memo = Memo.create(
            sender_id: char.id,
            recipient_id: char.id,  # Self-memo
            subject: memo_text[0..47],  # First 50 chars
            content: memo_text
          )
        end
        ```
  
        **Scene Creation:**
        - Announces scene start with name
        - Returns structured data for scene tracking
        - No database record (future feature?)
  
        **Building Elements:**
        - `make_entrance`: Requires room ownership, marks as entrance
        - `make_library`: Requires room ownership, designates as library
        - Ownership check: `outer_room.owned_by?(character_instance.character)`
  
        ## 3. Staff Item Design (`design` command)
  
        **Location:** `plugins/core/building/commands/design.rb`
  
        **Permission Check:**
        ```ruby
        unless character.staff? || character.admin?
          return error_result('Design commands require staff access.')
        end
        ```
  
        **Note:** Creator mode does NOT grant access.
  
        **Form-Based Creation:**
        1. `show_item_creator_form` creates form with fields
        2. Form submission handled by `handle_form_response`
        3. `process_item_form(form_data, context)`:
           - Validates name (required, max 200 chars)
           - Validates description (max 2000 chars)
           - Validates quantity (1-999)
           - Validates condition (excellent/good/fair/poor/broken)
           - Validates image URL (must start with http/https, max 2048 chars)
           - Calls `build_item_properties(item_type, form_data)` for type-specific props
           - Creates Item record in current room
           - Broadcasts creation to room
  
        **Item Properties by Type:**
        ```ruby
        def build_item_properties(item_type, _form_data)
          case item_type
          when 'weapon'
            { 'damage_dice' => '1d6', 'weapon_type' => 'melee' }
          when 'armor'
            { 'armor_value' => 1, 'armor_type' => 'light' }
          when 'container'
            { 'capacity' => 10, 'container' => true }
          when 'food'
            { 'consume_type' => 'food', 'consume_time' => 5 }
          when 'drink'
            { 'consume_type' => 'drink', 'consume_time' => 3 }
          when 'key'
            { 'key_id' => SecureRandom.hex(8) }
          end
        end
        ```
  
        ## Pattern Designer Service
  
        **Location:** `app/services/pattern_designer_service.rb`
  
        **Purpose:** Create/update/delete Pattern records (admin interface)
  
        **Methods:**
        ```ruby
        # Create pattern
        PatternDesignerService.create(params)
        # Returns { success:, pattern: } or { success: false, error: }
  
        # Update pattern
        PatternDesignerService.update(pattern, params)
  
        # Delete pattern (fails if items reference it)
        PatternDesignerService.delete(pattern)
  
        # Create player pattern (restricted)
        PatternDesignerService.create_player_pattern(user, params)
        # Strips magic_type, sets created_by
        ```
  
        **Extracted Params:**
        - `unified_object_type_id` (required)
        - `description`, `price`
        - Era: `min_year`, `max_year`
        - Clothing: `sheer`, `container`, `arev_one`, `arev_two`, `acon_one`, `acon_two`
        - Jewelry: `metal`, `stone`
        - Weapons: `handle_desc`
        - Consumable: `consume_type`, `consume_time`, `taste`, `effect`
        - Magic: `magic_type` (admin only)
  
        ## Integration Points
  
        **Item Creation:**
        - `fabricate` → Pattern → Item (via `pattern.instantiate`)
        - `design` → Item (direct creation)
  
        **Inventory Management:**
        - Items reference character_instance (inventory)
        - Items reference room (world placement)
        - Ownership tracked via `Item.character_instance_id` or `Item.room_id`
  
        **Permissions:**
        - `fabricate`: All players (requires owned patterns and facilities)
        - `make`: All players (some subcommands require room ownership)
        - `design`: Staff only (`character.staff?` or `character.admin?`)
  
        **Era Service:**
        - Determines fabrication times via `EraService.current_era`
        - Adapts messaging to setting
        - Future: Era-lock patterns via `min_year`/`max_year`
  
        **Scheduled Tasks:**
        - FabricationCompletionHandler processes orders periodically
        - Marks orders ready/delivered, notifies players
        - Uses BroadcastService for online notifications
  
        ## Testing Patterns
  
        **Unit Tests:**
        - Pattern model methods (type checks, instantiation)
        - FabricationOrder state transitions
        - FabricationService calculations and permissions
  
        **Integration Tests:**
        - Full fabricate flow (pattern → order → pickup)
        - Delivery flow (pattern → order → home delivery)
        - Make command subcommands
        - Design command form processing
  
        **Specs:**
        - `spec/models/pattern_spec.rb`
        - `spec/models/fabrication_order_spec.rb`
        - `spec/services/fabrication_service_spec.rb`
        - `spec/commands/crafting/fabricate_spec.rb`
        - `spec/commands/crafting/make_spec.rb`
        - `spec/commands/building/design_spec.rb`
  
        ## Common Issues
  
        **"You don't have a pattern for X":**
        - Character doesn't own the pattern
        - Pattern name mismatch (try shorter/different keywords)
  
        **"This facility cannot create that type of item":**
        - Wrong room type (e.g., tailor needed for clothing)
        - Check FACILITY_REQUIREMENTS in GameConfig
  
        **Instant fabrication not working:**
        - Check era (must be sci-fi or near-future)
        - Check calculation: base_time * complexity_mult * pattern_mult < 10
  
        **Orders not completing:**
        - Check FabricationCompletionHandler is running
        - Verify completes_at timestamp is in past
        - Check scheduled task logs
  
        ## Future Enhancements
  
        - Player pattern creation (PatternDesignerService.create_player_pattern)
        - Material requirements (combine pattern + materials)
        - Skill checks for crafting quality
        - Customization during fabrication (colors, engravings)
        - Pattern modification (tailoring, repair)
        - Crafting XP and progression
      STAFF
      display_order: 75
    },
    {
      name: 'world_memory',
      display_name: 'World Memory/Narrative Intelligence',
      summary: 'Automatic RP capture, NPC memories, relationships, pets, and narrative tracking',
      player_guide: <<~'GUIDE',
        # World Memory & Narrative Intelligence
  
        Firefly automatically captures, remembers, and responds to your roleplay. This system runs behind the scenes with **no player commands** - it just works. Here's what you can expect:
  
        ## World Memory: Automatic RP Capture
  
        ### What Gets Captured
  
        When **2 or more characters** engage in IC (in-character) activity, the system automatically starts a **session** to track the interaction:
  
        **Tracked Message Types:**
        - Say
        - Emote
        - Whisper
        - Think
        - Attempt
        - Pose
        - Action
  
        **Not Tracked:**
        - OOC (out-of-character) communication
        - System messages
        - Solo activity (only 1 character in room)
        - Private mode activity
  
        ### How It Works
  
        1. **Session Start:** When you and another character start interacting, a session begins
        2. **Message Collection:** Your IC messages are logged in a buffer
        3. **Session End:** When characters leave or activity stops for 2 hours, the session finalizes
        4. **AI Summary:** If the session has 5+ messages, an AI generates a summary
        5. **Searchable Memory:** The summary becomes part of the searchable world history
  
        ### Privacy Levels
  
        Sessions are tagged with publicity levels:
  
        - **Private:** Private events, character set to private mode
        - **Secluded:** Small private gatherings
        - **Semi-Public:** Limited public spaces
        - **Public:** Open public areas
        - **Private Event:** Invite-only events
        - **Public Event:** Open events
  
        **Private content is never saved to world memory.**
  
        ### Memory Importance & Decay
  
        Memories have an **importance rating** (1-10) and **decay over time**:
  
        **Relevance Formula:**
        ```
        relevance = (importance * 0.6) + (timeliness * 0.4)
        ```
  
        Where timeliness decreases based on age:
        ```
        timeliness = max(1.0 - (age_days / 365), 0.1)
        ```
  
        **Examples:**
        - Recent important event (importance 9, age 1 day): ~0.94 relevance
        - Old mundane event (importance 3, age 200 days): ~0.26 relevance
  
        ### Memory Abstraction
  
        To prevent database bloat, old memories are progressively abstracted:
  
        **Abstraction Levels:**
        1. **Level 1:** Raw session summaries (original memories)
        2. **Level 2:** 8 Level 1 memories → 1 Level 2 summary
        3. **Level 3:** 8 Level 2 summaries → 1 Level 3 summary
        4. **Level 4:** 8 Level 3 summaries → 1 Level 4 summary (most abstract)
  
        **Raw logs expire after 6 months** to save space (only summaries remain).
  
        ## NPC Memory & Intelligence
  
        NPCs (non-player characters) have their own memory systems powered by semantic search and AI.
  
        ### How NPCs Remember
  
        NPCs store memories about their interactions using **vector embeddings** (Voyage AI) for semantic search:
  
        1. **Memory Storage:** When an NPC interacts with you, they store a memory
        2. **Embedding:** The memory is converted to a vector for similarity search
        3. **Retrieval:** When the NPC needs context, they search memories semantically
        4. **Abstraction:** Like world memory, NPC memories are abstracted over time
  
        **Memory Types:**
        - Interaction (conversations, events)
        - Observation (things they saw)
        - Event (significant occurrences)
        - Secret (hidden knowledge)
        - Goal (objectives and plans)
        - Emotion (feelings about events)
        - Abstraction (compressed summaries)
  
        ### Memory Relevance
  
        NPCs rank memories using the same importance + timeliness formula as world memory. When they respond to you, they:
  
        1. Search their memories for relevant context
        2. Retrieve top 10 most relevant memories
        3. Use those memories to inform their LLM-generated response
  
        **Minimum Age Filter:** Recent memories (< 1 hour old) are excluded to prevent NPCs from echoing just-said information.
  
        ### Over-Fetching for Filtering
  
        The system over-fetches memories (2-3× the limit) to account for filtering:
        - Embedding search returns 20-30 candidates
        - SQL filters by character, abstraction level, minimum age
        - Top 10 remaining memories are used
  
        ## NPC Relationships
  
        NPCs track their relationships with player characters dynamically.
  
        ### Relationship Attributes
  
        **Sentiment** (-1.0 to 1.0):
        - **0.7 to 1.0:** Very fond of
        - **0.3 to 0.7:** Friendly toward
        - **-0.3 to 0.3:** Neutral toward
        - **-0.7 to -0.3:** Wary of
        - **Below -0.7:** Hostile toward
  
        **Trust** (0.0 to 1.0):
        - **0.8 to 1.0:** Completely trusts
        - **0.6 to 0.8:** Trusts
        - **0.4 to 0.6:** Uncertain about
        - **0.2 to 0.4:** Distrusts
        - **Below 0.2:** Deeply distrusts
  
        **Knowledge Tier** (1-3):
        - **Tier 1:** Knows you by reputation only (public knowledge)
        - **Tier 2:** Knows you socially (same circles)
        - **Tier 3:** Close associate (personal details, secrets)
  
        ### How Relationships Change
  
        Relationships update after each interaction:
  
        **Sentiment Delta:** -0.2 to +0.2 per interaction
        **Trust Delta:** -0.1 to +0.1 per interaction
  
        **Notable Events:** Significant interactions are stored in the relationship record (up to 10 most recent events).
  
        **Knowledge Tier Evaluation:** An AI (Gemini) evaluates whether the NPC should know you better based on:
        - Interaction count
        - Sentiment and trust levels
        - Notable events
  
        ### Lead/Summon Cooldowns
  
        NPCs can reject follow requests to prevent abuse:
  
        **Rejection Cooldowns:**
        - If an NPC rejects your follow request, you're on cooldown
        - Cooldown duration configured in `GameConfig::NpcRelationship::REJECTION_COOLDOWN_SECONDS`
        - Rejection counts track how many times you've been rejected
  
        ## Pet Companions
  
        Pets are AI-driven companions that follow you and react to the world.
  
        ### Pet Behavior
  
        **Following:** Pets automatically follow their owner between rooms (if `following = true`)
  
        **Moods:**
        - Happy: Wags tail, plays excitedly, bounds around
        - Content: Rests quietly, watches attentively, sits calmly
        - Hungry: Whines softly, looks around hopefully, paws at ground
        - Playful: Chases tail, pounces at shadows, rolls around
        - Tired/Scared/Aggressive: Various contextual behaviors
  
        **Loyalty:** 0-100 scale
        - Increases when fed or petted
        - Decreases when neglected
        - Affects how responsive the pet is
  
        ### Pet Animations
  
        Pets react to room activity automatically:
  
        **Reaction Triggers:**
        - Say/emote/pose/action messages in the room
        - Idle animations every 2-10 minutes
  
        **Rate Limits:**
        - **Per-Pet Cooldown:** 2 minutes between animations
        - **Room Rate Limit:** Max 3 pet animations per minute (prevents spam)
        - **No Pet-to-Pet Reactions:** Pets don't react to other pets
  
        **Example Reactions:**
        - Owner says something: Pet wags tail
        - Combat starts: Pet gets scared
        - Food mentioned: Pet looks interested
  
        ### Pet Types
  
        - Dog
        - Cat
        - Bird
        - Horse
        - Familiar (magical)
        - Mythical
  
        ## Content Moderation
  
        All player messages are screened for abuse using a **two-tier AI system**.
  
        ### How It Works
  
        **Tier 1: Fast Screening (Gemini Flash-lite)**
        1. Every IC message is checked within seconds
        2. Gemini AI screens for potential abuse
        3. Returns: flagged/not flagged, confidence (0-1), category, reasoning
  
        **Tier 2: Verification (Claude Opus 4.5)**
        1. If Gemini flags a message, Claude verifies it
        2. Claude reviews the message with room context
        3. Distinguishes IC (in-character) conflict from OOC (out-of-character) harassment
        4. Returns: confirmed/not confirmed, confidence, severity, recommended action
  
        ### IC vs OOC
  
        The key distinction:
  
        **IC Conflict (Allowed):**
        - Characters fighting, arguing, threatening each other IN ROLEPLAY
        - Example: "I'll defeat you in combat!" (in a fantasy battle)
  
        **OOC Harassment (Not Allowed):**
        - Personal attacks, hate speech, real-world threats
        - Example: "You're a terrible person" (directed at the player, not character)
  
        ### Abuse Categories
  
        - Harassment
        - Hate speech
        - Threats
        - Doxxing
        - Spam
        - CSAM (child safety)
        - Other
        - False positive
        - None
  
        ### Severity Levels
  
        - Low
        - Medium
        - High
        - Critical
  
        ### Fail-Safe Design
  
        **Tier 1 (Gemini):** Fails open - if API errors, message is not flagged
        **Tier 2 (Claude):** Fails safe - if API errors, abuse is not confirmed
  
        This prevents false positives from blocking legitimate RP.
  
        ## What This Means for You
  
        ### Seamless Experience
  
        You don't need to do anything - the system just works:
  
        1. **RP normally:** Your IC interactions are captured automatically
        2. **NPCs remember:** They'll reference past events naturally
        3. **Pets react:** Your companion will respond to the world
        4. **Safe environment:** Abuse is detected without affecting normal play
  
        ### Privacy
  
        - **Private mode:** Set your character to private mode to opt out of world memory
        - **Private spaces:** Sessions in private rooms/events are not saved
        - **Selective capture:** Only IC messages with 2+ characters are tracked
        - **Raw log expiration:** Detailed logs expire after 6 months
  
        ### Trust the System
  
        - NPCs won't echo your words back (minimum age filter)
        - Relationships develop naturally over multiple interactions
        - Pets won't spam (2-min cooldown + room rate limits)
        - False positives won't block you (fail-safe verification)
  
        ## Summary
  
        | System | What It Does | How It Helps |
        |--------|-------------|--------------|
        | **World Memory** | Captures RP sessions as searchable history | NPCs and systems can reference past events |
        | **NPC Memory** | NPCs remember interactions semantically | NPCs respond contextually and naturally |
        | **NPC Relationships** | Tracks sentiment, trust, knowledge tier | NPCs treat you differently based on history |
        | **Pet Companions** | AI-driven pet behavior and reactions | Immersive, reactive companion animals |
        | **Content Moderation** | Two-tier abuse detection (Gemini → Claude) | Safe environment without false positives |
  
        **No commands required** - it all happens automatically to enhance your roleplay experience.
      GUIDE
      command_names: [],
      related_systems: %w[communication auto_gm staff_tools],
      key_files: [
        'app/services/world_memory_service.rb',
        'app/models/world_memory.rb',
        'app/models/world_memory_session.rb',
        'app/services/npc_animation_service.rb',
        'app/handlers/npc_animation_handler.rb',
        'app/services/npc_memory_service.rb',
        'app/models/npc_memory.rb',
        'app/models/npc_relationship.rb',
        'app/services/pet_animation_service.rb',
        'app/models/pet.rb',
        'app/services/abuse_detection_service.rb',
        'app/models/world_memory_character.rb',
        'app/models/world_memory_location.rb',
        'app/models/world_memory_session_character.rb',
        'app/models/world_memory_session_room.rb',
        'app/models/pet_animation_queue.rb',
        'config/game_config.rb'
      ],
      staff_notes: "World Memory Session Detection: Starts when IC message sent with 2+ online chars in room. Breaks on 2-hour gap or ≤1 char remaining.\nMinimum Threshold: 5 IC messages required before creating a memory.\nSummarization: Uses flash-2.5-lite (Gemini) to generate 2-3 sentence summaries.\nPublicity Levels: private, secluded, semi_public, public, private_event, public_event.\nPrivacy: private_mode content excluded entirely from logging.\nDecay: Linear relevance decay over 365 days (importance 0.6, timeliness 0.4).\nAbstraction: 8 level-N memories → 1 level-(N+1) summary. Max 4 levels.\nRaw Log Retention: Purged after 6 months (summary + embedding kept).\n\nNPC Animation Levels: high (all broadcasts), medium (mentions + LLM probability), low (mentions only), off.\nAnti-Spam: NPCs don't respond to NPCs, 20/hour limit, 2 consecutive max, 3/minute/room.\nMemory Hierarchy: 8 level-N memories → 1 level-(N+1) summary. Max 4 levels.\nRelationships: Sentiment (-1 to 1), Trust (0 to 1), updated per interaction.\nDistance-Based Scoring for NPC context: Same room 1.5x, same location 1.2x, nearby hex 1.0x, farther decreasing.\n\nPet Types: dog, cat, bird, horse, familiar, mythical.\nMoods, Loyalty (0-100), 2-min per-pet cooldown.\nPets can only perform physical actions and creature sounds (no speech).\n\nContent Moderation Two-Tier:\n1. Gemini Flash: Fast initial screening, fails open.\n2. Claude Opus: Verification with context, fails safe.\nCategories: harassment, hate_speech, threats, doxxing, spam, csam.\nIC vs OOC distinction preserved.\n\nScheduler Jobs:\n- finalize_stale_sessions! (every 5 min)\n- purge_expired_raw_logs! (daily 3 AM)\n- check_and_abstract! (every 6 hours)\n- apply_decay! (Sunday 5 AM)",
      display_order: 80
    },
    {
      name: 'auto_gm',
      display_name: 'AutoGM',
      summary: 'AI-driven spontaneous adventures',
      player_guide: <<~'GUIDE',
        # Auto-GM: AI-Driven Spontaneous Adventures
  
        Auto-GM creates unique, dynamic adventures powered by multiple AI models. Based on your location and nearby world history, an AI Game Master designs and runs a complete adventure that reacts to your actions in real-time.
  
        ## Commands
  
        ```
        autogm start                    # Start a new adventure
        autogm start with <names>       # Start with specific party members
        autogm status                   # Check adventure progress
        autogm end                      # Abandon the adventure
        autogm end success              # End with success resolution
        autogm end failure              # End with failure resolution
        ```
  
        **Aliases:** `agm`, `adventure`
  
        **Examples:**
        ```
        autogm start
        autogm start with Alice Bob
        autogm status
        autogm end success
        ```
  
        ## How Auto-GM Works
  
        ### Phase 1: Adventure Design (Automatic)
  
        When you start an adventure, the AI goes through multiple phases:
  
        **1. Context Gathering**
        - Retrieves nearby world memories
        - Identifies interesting locations in the area
        - Analyzes current room and environment
        - Gathers participant information
  
        **2. Brainstorming (Parallel AI)**
        - Two AI models brainstorm independently:
          - **Kimi-k2:** Creative, unconventional ideas
          - **GPT-5.2:** Structured, narrative-focused concepts
        - Each generates multiple adventure possibilities
        - Runs in parallel for speed
  
        **3. Synthesis (Claude Opus 4.5)**
        - Combines brainstorm outputs into a cohesive adventure
        - Generates adventure sketch with:
          - **Title:** Adventure name
          - **Stages:** 3-5 escalating stages
          - **NPCs:** Named characters with motivations
          - **Locations:** Specific places adventure visits
          - **Climax:** Final confrontation or revelation
          - **Stakes:** What's at risk
  
        **4. Inciting Incident**
        - The adventure begins with a dramatic event
        - You're thrust into the action immediately
        - Sets tone and introduces the first challenge
  
        ### Phase 2: GM Loop (Dynamic)
  
        Once the adventure starts, the AI Game Master (Claude Sonnet 4.5) continuously:
  
        1. **Monitors your actions** - Watches what you say, do, and where you go
        2. **Makes decisions** - Determines how NPCs react and what happens next
        3. **Executes actions** - Describes events, NPC dialogue, environmental changes
        4. **Advances the story** - Moves through stages toward climax and resolution
  
        **GM Decision Types:**
        - **Narration:** Describe events and scenery
        - **NPC dialogue:** Characters speak and react
        - **Stage progression:** Advance to next stage
        - **Combat initiation:** Start a fight if appropriate
        - **Random events:** Introduce complications (via chaos system)
        - **Resolution:** Conclude the adventure
  
        ### Phase 3: Resolution
  
        Adventures can end in several ways:
  
        - **Success:** You achieve the goal
        - **Failure:** You don't achieve the goal (but survive)
        - **Abandoned:** You manually end it early
        - **Timeout:** 2 hours of inactivity
  
        **World Memory:** Successful adventures are recorded as world memories, becoming part of the game's history.
  
        ## Chaos Level
  
        Adventures have a chaos level (1-9) that affects randomness:
  
        - **Low Chaos (1-3):** Predictable, straightforward
        - **Medium Chaos (4-6):** Some surprises, moderate complications
        - **High Chaos (7-9):** Frequent twists, unexpected events
  
        Chaos level starts at 5 and can change based on events.
  
        ## Random Event System
  
        The chaos system drives random events during adventures:
  
        - **Fate Questions:** "Does X happen?" with chaos-based probability
        - **Random Events:** Unexpected complications at scene transitions
        - **Event Focus:** NPCs, threads, locations, or new NPCs
  
        Higher chaos = more frequent random events.
  
        ## Participating in Adventures
  
        ### How to Interact
  
        Use normal game commands - the AI watches everything:
  
        **Social Commands:**
        ```
        say "We should investigate the tower"
        emote cautiously approaches the door
        whisper to Alice "I don't trust him"
        ```
  
        **Action Commands:**
        ```
        move north
        examine the mysterious artifact
        attack the bandit leader
        ```
  
        **Combat:**
        - If combat starts, use normal combat commands
        - The GM manages enemy NPCs
        - Combat integrates seamlessly into the adventure
  
        ### What the AI Sees
  
        The GM monitors:
        - Your dialogue and emotes
        - Your movements between rooms
        - Combat actions and outcomes
        - Interactions with NPCs and objects
        - Party dynamics (if multiple participants)
  
        ### What Triggers GM Reactions
  
        The AI acts when:
        - You perform a significant action
        - Enough time has passed since last GM action (30 seconds minimum)
        - You complete a stage objective
        - Random event occurs (chaos system)
        - Combat ends
  
        ## Party Adventures
  
        Start adventures with friends:
  
        ```
        autogm start with Alice Bob Charlie
        ```
  
        **Requirements:**
        - All participants must be in the same room
        - Must be online when adventure starts
        - Participants can be found by partial name match
  
        **During the Adventure:**
        - All participants experience the same events
        - The GM reacts to any participant's actions
        - Everyone sees GM narration and NPC dialogue
        - Party can split up (GM follows all participants)
  
        ## Adventure Status
  
        Check progress with `autogm status`:
  
        **Information Shown:**
        - Adventure title
        - Current status (designing, active, combat, climax, resolved)
        - Progress (Stage 2 of 4)
        - Chaos level
        - Action count (how many GM actions so far)
        - Elapsed time
        - Timeout countdown (time until auto-abandon)
        - Recent events summary
        - Combat status (if in combat)
        - Resolution type (if ended)
  
        **Status Values:**
        - **Gathering:** Collecting context
        - **Sketching:** Brainstorming and synthesizing
        - **Inciting:** Deploying the inciting incident
        - **Running:** Active adventure, GM loop running
        - **Combat:** Currently in combat encounter
        - **Climax:** Final stage, approaching resolution
        - **Resolved:** Adventure complete
        - **Abandoned:** Ended early
  
        ## Ending Adventures
  
        ### Abandoning
  
        ```
        autogm end
        ```
  
        Immediately stops the adventure. No world memory created.
  
        **Only the initiator** (character who started it) can end an adventure. Other participants can leave by moving to different areas.
  
        ### Resolving
  
        Let the adventure reach its natural conclusion, or declare resolution:
  
        ```
        autogm end success      # You achieved the goal
        autogm end failure      # You didn't achieve the goal
        ```
  
        **World Memory:** Success resolutions create world memories with:
        - Adventure summary
        - Participants
        - Key events
        - Resolution outcome
  
        These memories can inspire future Auto-GM adventures!
  
        ## Timeouts
  
        Adventures auto-abandon after **2 hours of inactivity** (no participant actions or GM actions).
  
        **Inactivity means:**
        - No character movement
        - No IC messages
        - No combat actions
        - GM hasn't acted
  
        **Warning:** You won't be notified before timeout - use `autogm status` to check remaining time.
  
        ## Limitations
  
        **One Adventure Per Room:**
        - Only one active Auto-GM session allowed per room
        - Prevents overlapping adventures
  
        **One Adventure Per Character:**
        - You can only participate in one Auto-GM session at a time
        - Must end current adventure before starting a new one
  
        **Requires Location:**
        - Must be in a specific room (not void/OOC areas)
        - Location influences adventure content
  
        **No Save/Resume:**
        - Adventures run continuously until resolved or abandoned
        - Cannot pause and resume later
  
        ## Tips for Great Adventures
  
        **1. Engage Actively**
        - Respond to NPC dialogue with `say`
        - Describe your actions with `emote`
        - Make decisions and take initiative
  
        **2. Follow the Story**
        - Pay attention to GM narration
        - Notice stage progression cues
        - React to environmental changes
  
        **3. Use Combat Wisely**
        - Combat is part of the adventure, not separate
        - Fight when it makes narrative sense
        - The GM manages enemy NPCs
  
        **4. Embrace Chaos**
        - Random events add excitement
        - Complications create memorable moments
        - Roll with unexpected twists
  
        **5. Bring Friends**
        - Party adventures are more dynamic
        - The GM creates interactions between participants
        - Different character skills create options
  
        ## Example Adventure Flow
  
        ```
        > autogm start
        Starting a new Auto-GM adventure...
        Gathering context from nearby memories and locations...
  
        [30 seconds later]
  
        The AI Game Master whispers: "The Haunted Lighthouse"
  
        A sudden storm rolls in from the sea. Through the rain, you spot
        a lighthouse on the cliffs - its light flickering erratically.
        A distant scream echoes from within.
  
        > say "We should investigate that lighthouse"
  
        You say, "We should investigate that lighthouse"
  
        The AI Game Master narrates: As you approach the lighthouse, the
        door creaks open on its own. Inside, the spiral staircase seems
        to descend far deeper than it should...
  
        > move down
  
        You descend the stairs into darkness...
  
        [The adventure continues, reacting to your choices]
  
        > autogm status
        Adventure: The Haunted Lighthouse
        Status: Running
        Progress: Stage 2 of 4
        Chaos Level: 6/9
        Actions: 12
        Elapsed: 15.3 minutes
  
        Recent events:
          You discovered the lighthouse keeper's journal. The last entry
          warns of "something from below"...
        ```
  
        ## Summary
  
        | Aspect | Details |
        |--------|---------|
        | **AI Models** | Kimi-k2, GPT-5.2 (brainstorm), Opus 4.5 (synthesis), Sonnet 4.5 (GM) |
        | **Adventure Length** | Typically 30-90 minutes |
        | **Timeout** | 2 hours of inactivity |
        | **Party Size** | 1+ participants (specify at start) |
        | **Chaos Level** | 1-9, affects randomness |
        | **Stages** | 3-5 escalating challenges |
        | **Resolution** | Success, failure, abandoned, timeout |
        | **World Memory** | Created on successful completion |
  
        Auto-GM brings the magic of tabletop RPGs to the digital realm - a living, breathing Game Master that crafts unique stories just for you.
      GUIDE
      command_names: %w[autogm],
      related_systems: %w[world_memory missions communication],
      key_files: [
        'plugins/core/auto_gm/commands/autogm.rb',
        'app/services/auto_gm/auto_gm_session_service.rb',
        'app/services/auto_gm/auto_gm_brainstorm_service.rb',
        'app/services/auto_gm/auto_gm_synthesis_service.rb',
        'app/services/auto_gm/auto_gm_compression_service.rb',
        'app/services/auto_gm/auto_gm_context_service.rb',
        'app/services/auto_gm/auto_gm_decision_service.rb',
        'app/services/auto_gm/auto_gm_resolution_service.rb',
        'app/services/auto_gm/auto_gm_incite_service.rb',
        'app/services/auto_gm/auto_gm_event_service.rb',
        'app/services/auto_gm/auto_gm_action_executor.rb',
        'app/services/auto_gm/auto_gm_roll_service.rb',
        'app/models/auto_gm_session.rb',
        'app/models/auto_gm_action.rb',
        'app/models/auto_gm_summary.rb',
        'config/game_config.rb'
      ],
      staff_notes: <<~'STAFF',
        # Auto-GM Architecture
  
        ## Overview
  
        Auto-GM is a multi-phase AI pipeline that creates and runs spontaneous adventures using:
        - One Page One Shot framework (adventure structure)
        - Chaos system (random events, event focus)
        - Multiple AI models (brainstorming, synthesis, GM decisions)
  
        ## Session Lifecycle
  
        **Statuses:** gathering → sketching → inciting → running → combat/climax → resolved/abandoned
  
        **Models:**
        - AutoGmSession: Session state, participant tracking, chaos level
        - AutoGmAction: GM actions (narration, dialogue, events)
        - AutoGmSummary: Compressed context snapshots
  
        ## Pipeline Phases
  
        ### Phase 1: Context Gathering (AutoGmContextService)
  
        Gathers adventure ingredients from:
        - World memories (nearby, recent, relevant)
        - Locations (current room, adjacent areas)
        - Participant info (characters, backgrounds)
        - Recent RP sessions in area
  
        Returns context hash with weighted/scored elements.
  
        ### Phase 2: Brainstorming (AutoGmBrainstormService)
  
        Parallel brainstorming with two models:
  
        **Kimi-k2 (Creative):**
        - Unconventional ideas
        - Wild twists
        - Unexpected connections
  
        **GPT-5.2 (Structured):**
        - Narrative coherence
        - Character arcs
        - Plot structure
  
        Both receive same context, generate 3-5 adventure ideas each.
        Runs in parallel via threads for speed (~10-15 seconds total).
  
        ### Phase 3: Synthesis (AutoGmSynthesisService)
  
        Claude Opus 4.5 combines brainstorm outputs into final sketch:
  
        **Sketch Structure (JSON):**
        ```json
        {
          "title": "Adventure name",
          "premise": "Opening situation",
          "stages": [
            {
              "stage_number": 1,
              "name": "Stage name",
              "description": "What happens",
              "objective": "What players must do",
              "location": "Where it occurs",
              "npcs": ["NPC names"],
              "complications": ["Potential issues"]
            }
          ],
          "climax": {
            "description": "Final confrontation",
            "stakes": "What's at risk",
            "resolution_paths": ["Possible endings"]
          },
          "npcs": {
            "NPC Name": {
              "role": "Their function",
              "motivation": "What they want",
              "personality": "Character traits"
            }
          }
        }
        ```
  
        Model: Claude Opus 4.5 (best synthesis quality)
        Time: ~20-30 seconds
  
        ### Phase 4: Inciting Incident (AutoGmInciteService)
  
        Deploys the opening event:
        - Uses sketch.premise
        - Broadcasts dramatic narration
        - Sets session status to 'running'
        - Starts GM loop
  
        ### Phase 5: GM Loop (AutoGmSessionService.run_gm_loop)
  
        Continuous loop that:
        1. Checks if session should continue (status, timeout)
        2. Decides if GM should act (cooldown, player activity)
        3. Gets GM decision (AutoGmDecisionService)
        4. Executes action (AutoGmActionExecutor)
        5. Updates compression (AutoGmCompressionService)
        6. Checks for random events (AutoGmEventService)
        7. Sleeps 2 seconds, repeats
  
        **GM Action Cooldown:** 30 seconds minimum between actions
  
        **Loop Termination:**
        - Session status changes to resolved/abandoned
        - Timeout (2 hours inactivity)
        - Error in GM decision/execution
  
        ### Phase 6: Resolution (AutoGmResolutionService)
  
        Ends session and creates world memory:
        - Gathers all actions and summaries
        - Generates final summary
        - Creates WorldMemory (if success)
        - Sets resolution_type: success, failure, abandoned, timeout
  
        ## GM Decision Making (AutoGmDecisionService)
  
        Claude Sonnet 4.5 makes decisions based on:
  
        **Input Context:**
        - Current sketch and stage
        - Recent compressed summary
        - Recent player actions (last 5-10)
        - Current participant locations
        - Chaos level
        - Time since last GM action
  
        **Decision Types:**
        - `narrate`: Describe events
        - `npc_speak`: NPC dialogue
        - `advance_stage`: Move to next stage
        - `start_combat`: Initiate fight
        - `random_event`: Chaos-driven random event
        - `resolve`: End adventure
  
        **Prompt Engineering:**
        - Uses One Page One Shot framework language
        - Provides stage objectives and complications
        - Reminds GM of chaos level effects
        - Encourages reactive storytelling (respond to player actions)
  
        Model: Claude Sonnet 4.5 (fast, high quality)
        Max tokens: 500
        Temperature: 0.8 (creative)
  
        ## Action Execution (AutoGmActionExecutor)
  
        Executes GM decisions:
  
        **Narration:**
        ```ruby
        BroadcastService.to_room(
          room_id,
          "[The AI Game Master narrates] #{content}",
          type: :gm_narration
        )
        ```
  
        **NPC Dialogue:**
        ```ruby
        BroadcastService.to_room(
          room_id,
          "#{npc_name} says, \"#{dialogue}\"",
          type: :gm_npc_dialogue
        )
        ```
  
        **Combat:**
        - Creates Fight instance
        - Adds participants as player side
        - Spawns enemy NPCs based on sketch
        - Sets session status to 'combat'
  
        **Stage Advancement:**
        - Increments current_stage
        - Broadcasts stage transition
        - If final stage, sets status to 'climax'
  
        All actions stored as AutoGmAction records.
  
        ## Context Compression (AutoGmCompressionService)
  
        Keeps context manageable:
  
        **When to Compress:**
        - Every 10 GM actions
        - Total action count > 20
        - Context window approaching limit
  
        **How:**
        1. Fetch last N actions
        2. Generate summary via Gemini Flash-lite
        3. Store as AutoGmSummary
        4. Mark actions as compressed
  
        **Retrieval:**
        - Latest summary + uncompressed actions = current context
        - Older summaries available for long adventures
  
        ## Random Event System (AutoGmEventService)
  
        Chaos-driven random events:
  
        **Chaos Factor:**
        - Maps to chaos_level (1-9)
        - Higher chaos = more events
  
        **Event Probability:**
        - Calculated per GM action
        - Formula: `(chaos_level / 9.0) * 0.3` (max 30% at chaos 9)
  
        **Event Types:**
        - NPC action
        - New NPC
        - Thread advancement
        - Location change
        - Ambiguous event
  
        **Fate Questions:**
        - "Does X happen?"
        - Odds: impossible, unlikely, 50/50, likely, certain
        - Chaos modifies roll thresholds
  
        ## Timeout and Inactivity
  
        **Timeout:** 2 hours (7200 seconds)
  
        **Inactivity Tracking:**
        - session.last_activity_at updated on:
          - Player IC messages
          - Player movement
          - GM actions
          - Combat actions
  
        **Timeout Check:**
        - Every GM loop iteration
        - If `Time.now - last_activity_at > 7200`, abandon session
  
        ## Party Management
  
        **Participant IDs:**
        - Stored as PostgreSQL array: `participant_ids`
        - Includes all CharacterInstances
  
        **Participant Tracking:**
        ```ruby
        def participant_instances
          CharacterInstance.where(id: participant_ids.to_a).all
        end
        ```
  
        **Adding Participants:**
        - Only at session start
        - Must be in starting room
        - Found by name match
  
        **Removing Participants:**
        - Not implemented (participants can just leave room)
        - Session continues with remaining participants
  
        ## World Memory Integration
  
        **On Success Resolution:**
        - Creates WorldMemory record
        - Summary: Final compressed summary
        - Importance: 7 (high)
        - Publicity: Based on starting room
        - Characters: All participants
        - Locations: All locations_used
  
        **Memory Context:**
        - Title: sketch.title
        - Content: Full adventure summary
        - Source: 'auto_gm'
  
        ## GameConfig Constants
  
        ```ruby
        module GameConfig
          module AutoGm
            INACTIVITY_TIMEOUT_HOURS = 2
            GM_ACTION_COOLDOWN_SECONDS = 30
            GM_LOOP_POLL_INTERVAL = 2
  
            CHAOS = {
              default: 5,
              min: 1,
              max: 9
            }
  
            COMPRESSION = {
              trigger_action_count: 10,
              min_actions_before_compress: 20
            }
  
            BRAINSTORM = {
              kimi_count: 3,     # Ideas from Kimi-k2
              gpt_count: 3,      # Ideas from GPT-5.2
              timeout: 60        # Brainstorm timeout
            }
          end
        end
        ```
  
        ## Command Flow (autogm.rb)
  
        **Start:**
        1. Check for existing session in room (error if exists)
        2. Check if character in any session (error if exists)
        3. Parse participants ("with Alice Bob")
        4. Find participants in room by name
        5. Call AutoGmSessionService.start_session
        6. Return success with session_id
  
        **Status:**
        1. Find active sessions for character
        2. If none, check room for any session
        3. Call AutoGmSessionService.status(session)
        4. Format and display status info
  
        **End:**
        1. Find active session for character
        2. Check if character is initiator (creator)
        3. Parse resolution type (success/failure/abandoned)
        4. Call AutoGmSessionService.end_session
        5. Return resolution message
  
        ## Testing Strategies
  
        **Unit Tests:**
        - Context gathering (mocked world memories)
        - Brainstorm output parsing
        - Synthesis JSON structure
        - Decision type selection
        - Action execution side effects
        - Compression triggers
  
        **Integration Tests:**
        - Full pipeline (context → brainstorm → synthesis → incite)
        - GM loop iteration (decision → execute → compress)
        - Timeout handling
        - Resolution and world memory creation
  
        **LLM Mocking:**
        - Mock brainstorm outputs (fixture JSON)
        - Mock synthesis outputs (fixture adventure sketch)
        - Mock GM decisions (fixture decision types)
        - Test prompt construction without API calls
  
        ## Performance Considerations
  
        **Brainstorm Parallelization:**
        - Kimi-k2 and GPT-5.2 in separate threads
        - ~50% time savings vs sequential
  
        **GM Loop Polling:**
        - 2-second sleep prevents tight loop
        - Cooldown prevents spam
  
        **Compression:**
        - Prevents unbounded context growth
        - Uses cheap model (Gemini Flash)
        - Triggered every 10 actions
  
        **Background Pipeline:**
        - Design phases run in Thread.new
        - Don't block player commands
        - Player can continue playing while AI designs
  
        ## Common Issues
  
        **Adventures Not Starting:**
        - Check existing sessions (one per room/character)
        - Verify participants in room
        - Check LLM API keys/quotas
  
        **GM Not Acting:**
        - Check last_activity_at (may be waiting for player action)
        - Verify cooldown (30 seconds between actions)
        - Check session status (must be 'running' or 'climax')
  
        **Timeout Too Soon:**
        - last_activity_at not updating (check broadcast integration)
        - Player actions not counting as activity
  
        **World Memory Not Created:**
        - Check resolution_type (only 'success' creates memory)
        - Verify WorldMemoryService integration
        - Check session.sketch exists
  
        ## Future Enhancements
  
        - Player control of chaos level
        - Mid-adventure participant joining
        - Save/resume functionality
        - Adventure templates (genres)
        - Multi-session campaigns
        - Branching paths visualization
        - GM personality tuning
      STAFF
      display_order: 85
    },
    {
      name: 'timelines',
      display_name: 'Timelines',
      summary: 'Flashback roleplay via snapshots and historical eras',
      player_guide: <<~'GUIDE',
        # Timelines: Flashback Roleplay
  
        Timelines let you enter the past to roleplay historical moments or revisit captured snapshots - all without affecting your present character.
  
        ## Commands
  
        ```
        timeline                    # Open timeline menu
        timeline "<name>"           # Quick-enter a snapshot by name
        ```
  
        **Aliases:** `timelines`, `tl`, `snapshot`, `snap`
  
        ## What Are Timelines?
  
        Timelines are **past versions of the game world** where you can roleplay without consequences to your main character. Think of them as "flashback scenes" in a movie.
  
        **Two Types:**
  
        1. **Snapshot Timelines:** Frozen moments you've captured
        2. **Historical Timelines:** Shared past eras (specific years + zones)
  
        **Key Feature:** All timelines have **restrictions** that protect your main character - no death, no XP loss, rooms are read-only, etc.
  
        ## Snapshots
  
        ### What is a Snapshot?
  
        A snapshot is a **saved moment in time** - it captures:
        - Your character's exact state (HP, stats, equipment)
        - Your current location
        - Who else was present
        - The exact date/time
  
        ### Creating Snapshots
  
        Use the timeline menu:
  
        ```
        timeline
        > Select "Create Snapshot"
        > Enter snapshot name (e.g., "Before the Battle")
        > Optionally add description
        ```
  
        **What Gets Captured:**
        - Character HP, stats, XP, skills
        - Current room/location
        - Characters present in the room
        - Your inventory (items are cloned when you enter)
        - Timestamp
  
        **Use Cases:**
        - Save dramatic moments for later RP
        - Capture "what if" branching points
        - Record key story beats
        - Preserve state before risky actions
  
        ### Entering Snapshots
  
        **Quick Entry:**
        ```
        timeline "Before the Battle"
        ```
  
        **Menu Entry:**
        ```
        timeline
        > Select "Enter Timeline"
        > Choose from list of snapshots
        ```
  
        **Access Requirements:**
        - You can only enter snapshots where **you were present** when created
        - This prevents meta-knowledge (you can't witness scenes your character didn't experience)
  
        ### What Happens When You Enter
  
        1. **New Instance Created:** You get a separate character instance in the past
        2. **State Restored:** Your snapshot state is loaded (HP, stats, equipment from that moment)
        3. **Inventory Cloned:** Your current items are copied to the timeline (so you can still use gear)
        4. **Restrictions Applied:** Timeline protections activate
  
        **Multi-Tab Play:** You can keep your main character active in one browser tab and play the snapshot in another!
  
        ### Leaving Snapshots
  
        ```
        timeline
        > Select "Leave Timeline"
        ```
  
        Your snapshot instance goes offline, and you return to your main character. All progress in the snapshot is saved.
  
        ## Historical Timelines
  
        ### What Are Historical Timelines?
  
        Historical timelines are **shared past eras** - any character can visit the same historical year/zone combination.
  
        **Example:** Year 1875 in Victorian London - multiple players can all roleplay in this shared historical setting.
  
        **Key Difference from Snapshots:**
        - **Shared:** All characters in Year 1875 London see each other
        - **Persistent:** The timeline exists for all players, not just you
        - **Era-Based:** Configured for specific historical periods (medieval, gaslight, etc.)
  
        ### Entering Historical Timelines
  
        ```
        timeline
        > Select "Enter Timeline"
        > Choose "Historical Timeline"
        > Select year (e.g., 1875)
        > Select zone (e.g., London)
        ```
  
        **Your State:**
        - Uses your **current** character state (not a frozen snapshot)
        - Inventory is cloned from your present self
        - You can interact with other players in the same historical era
  
        ### Shared Historical RP
  
        If multiple players enter the same year/zone:
        - You all share the same timeline reality
        - You can see and interact with each other
        - World events in that timeline affect all participants
        - Ideal for historical campaigns or flashback arcs
  
        ## Timeline Restrictions
  
        All past timelines have built-in protections:
  
        **Default Restrictions:**
  
        | Restriction | What It Means |
        |-------------|---------------|
        | **No Death** | You can't die in a timeline - prevents permanent loss |
        | **No Prisoner** | You can't be imprisoned - prevents getting stuck |
        | **No XP** | You don't gain experience - keeps progression on main character |
        | **Rooms Read-Only** | You can't modify rooms - preserves historical integrity |
  
        **Why Restrictions?**
  
        Timelines are for **consequence-free roleplay**. You can explore dramatic moments, experiment with risky actions, or participate in historical events without worrying about ruining your main character.
  
        ### Viewing Restrictions
  
        While in a timeline:
  
        ```
        timeline
        > Select "Timeline Info"
        ```
  
        Shows all active restrictions for the current timeline.
  
        ## Timeline Management
  
        ### Viewing Your Snapshots
  
        ```
        timeline
        > Select "View Timelines"
        ```
  
        Shows:
        - Your created snapshots
        - Snapshots where you were present
        - Active historical timelines
  
        **Snapshot List Includes:**
        - Name and description
        - When it was created
        - Location where it was captured
        - Who was present
  
        ### Deleting Snapshots
  
        ```
        timeline
        > Select "Delete Snapshot"
        > Choose snapshot to delete
        ```
  
        **Note:** Only delete snapshots you created. Snapshots you were merely present in belong to their creators.
  
        ### Accessibility
  
        **Your Own Snapshots:**
        - Full access to all snapshots you created
        - Can enter, leave, and delete
  
        **Others' Snapshots:**
        - Can enter if you were present when created
        - Cannot delete
        - Access is read-only
  
        ## Eras and Historical Settings
  
        Historical timelines are tied to game eras:
  
        | Era | Years | Characteristics |
        |-----|-------|-----------------|
        | **Medieval** | 500-1500 | Gold currency, messenger system, no phones |
        | **Gaslight** | 1800-1900 | Pounds, telegrams, landline phones, carriages |
        | **Modern** | 1950-2020 | Dollars, mobile phones, cars, rideshare |
        | **Near-Future** | 2030-2100 | Digital credits, implants, autocabs |
        | **Sci-Fi** | 2100+ | Credits, communicators, hovertaxis |
  
        **Era Effects in Timelines:**
        - Currency type matches the era
        - Available technology matches the era
        - Transportation options match the era
        - Messaging systems match the era
  
        See the **EraService** system for full era configurations.
  
        ## Use Cases
  
        ### Flashback Scenes
  
        ```
        # Before a major battle
        timeline "The Night Before"
  
        # Roleplay preparations, last words, dramatic tension
        # No risk - even if battle goes badly, your main character is safe
        ```
  
        ### "What If" Scenarios
  
        ```
        # Create snapshot before a critical choice
        timeline "Before I Chose the Dark Path"
  
        # Play out alternate timeline where you made different choice
        # See what could have been without affecting your real story
        ```
  
        ### Historical Campaigns
  
        ```
        # GM creates historical campaign in Year 1875 London
        # Multiple players enter same historical timeline
        # Shared adventure in the past
        # All return to present when campaign ends
        ```
  
        ### Tutorial Safe Space
  
        ```
        # New players can practice in a historical timeline
        # Learn combat without risk of death
        # Experiment with commands and mechanics
        # Return to present once comfortable
        ```
  
        ## Multi-Character Play
  
        Since timelines create separate character instances, you can:
  
        **Play Multiple Versions Simultaneously:**
        - Browser Tab 1: Your main character in the present
        - Browser Tab 2: Your snapshot character in "Before the Battle"
        - Browser Tab 3: Your historical character in "Year 1875 London"
  
        Each instance is independent, with separate:
        - Location
        - HP/stats (based on when you entered)
        - Inventory (cloned at entry)
        - Active effects
  
        ## Limitations
  
        **Cannot Enter Multiple Past Timelines:**
        - You can only be in ONE past timeline at a time per browser session
        - Must leave current timeline before entering another
        - (But can have main character active in present simultaneously)
  
        **Snapshots Are Static:**
        - Snapshots capture a specific moment
        - World state around you doesn't dynamically update
        - Other players' positions are frozen at creation time
  
        **Rooms Are Read-Only:**
        - You can't build or modify rooms in timelines
        - Prevents historical contamination
        - Keeps timelines pristine for future visitors
  
        **No Permanent Gains:**
        - XP earned in timelines doesn't transfer
        - Items found in timelines don't transfer to present
        - Relationships formed in timelines are timeline-specific
  
        ## Summary
  
        | Feature | Details |
        |---------|---------|
        | **Command** | `timeline` (menu) or `timeline "<name>"` (quick enter) |
        | **Types** | Snapshot (frozen moments) or Historical (shared past eras) |
        | **Restrictions** | No death, no prisoner, no XP, rooms read-only |
        | **Access** | Your snapshots + snapshots where you were present |
        | **Multi-Tab** | Play main character and timeline character simultaneously |
        | **Safety** | All timeline actions are consequence-free |
  
        Timelines give you the freedom to explore "what if" scenarios, roleplay historical moments, and experiment with risky actions - all without jeopardizing your main character's story.
      GUIDE
      command_names: %w[timeline],
      related_systems: %w[world_memory events_media],
      key_files: [
        'plugins/core/timeline/commands/timeline.rb',
        'app/services/timeline_service.rb',
        'app/services/era_service.rb',
        'app/models/timeline.rb',
        'app/models/character_snapshot.rb',
        'config/game_config.rb'
      ],
      staff_notes: <<~'STAFF',
        # Timeline Architecture
  
        ## Overview
  
        Timelines enable flashback RP by creating separate Reality instances for past moments. Two types:
        1. Snapshot timelines (character-created frozen moments)
        2. Historical timelines (shared year/zone combinations)
  
        ## Models
  
        **Timeline:**
        - timeline_type: 'snapshot' or 'historical'
        - reality_id: Links to Reality (separate game world instance)
        - snapshot_id: FK to CharacterSnapshot (if snapshot type)
        - year, zone_id: For historical timelines
        - restrictions: JSONB with protections (no_death, no_prisoner, no_xp, rooms_read_only)
        - is_active: Timeline still exists
  
        **CharacterSnapshot:**
        - Stores captured character state at a moment
        - character_id, room_id, captured_at
        - character_data: JSONB with stats, HP, XP, skills
        - present_character_ids: Array of who was in room
        - name, description
  
        **CharacterInstance:**
        - Characters in timelines get separate instances
        - reality_id links to Timeline's reality
        - timeline_id: Direct FK to Timeline
        - Allows multi-tab play (main + timeline instances)
  
        ## Timeline Creation
  
        **Snapshot Timelines:**
  
        ```ruby
        # CharacterSnapshot.capture
        snapshot = CharacterSnapshot.create(
          character_id: ci.character.id,
          room_id: ci.current_room_id,
          name: name,
          description: description,
          captured_at: Time.now,
          character_data: {
            hp: ci.current_hp,
            max_hp: ci.max_hp,
            stats: ci.character_stats.map { ... },
            xp: ci.xp,
            # ... full state
          },
          present_character_ids: characters_in_room.map(&:id)
        )
  
        # Timeline.find_or_create_from_snapshot
        reality = Reality.create(
          name: "Snapshot: #{snapshot.name}",
          reality_type: 'flashback',
          time_offset: 0
        )
  
        timeline = Timeline.create(
          reality_id: reality.id,
          timeline_type: 'snapshot',
          name: snapshot.name,
          snapshot_id: snapshot.id,
          source_character_id: snapshot.character_id,
          restrictions: DEFAULT_RESTRICTIONS,
          is_active: true,
          rooms_read_only: true
        )
        ```
  
        **Historical Timelines:**
  
        ```ruby
        # Timeline.find_or_create_historical
        # Shared by all characters entering same year/zone
        reality = Reality.create(
          name: "Year #{year} - #{zone.name}",
          reality_type: 'flashback',
          time_offset: 0
        )
  
        timeline = Timeline.create(
          reality_id: reality.id,
          timeline_type: 'historical',
          name: "Year #{year} - #{zone.name}",
          year: year,
          zone_id: zone.id,
          restrictions: DEFAULT_RESTRICTIONS,
          is_active: true,
          rooms_read_only: true
        )
        ```
  
        ## Entering Timelines
  
        **TimelineService.enter_snapshot_timeline:**
  
        1. Check accessibility: `snapshot.can_enter?(character)` (was character present?)
        2. Find or create timeline from snapshot
        3. Check if character already has instance in that reality
        4. If exists: reactivate and teleport to starting room
        5. If not: create new CharacterInstance in timeline's reality
        6. Restore snapshot state: `snapshot.restore_to_instance(instance)`
        7. Clone inventory: `clone_inventory_to_timeline(primary_instance, timeline_instance, timeline)`
        8. Return timeline instance
  
        **TimelineService.enter_historical_timeline:**
  
        1. Find or create historical timeline for year/zone
        2. Check if character already has instance in that reality
        3. If exists: reactivate and teleport
        4. If not: create new CharacterInstance
        5. Copy current character state (not snapshot restore)
        6. Clone inventory
        7. Return timeline instance
  
        **Inventory Cloning:**
  
        Items are cloned to timeline so players can use their gear:
  
        ```ruby
        def clone_inventory_to_timeline(source_instance, dest_instance, timeline)
          source_instance.items.each do |item|
            cloned = item.dup
            cloned.character_instance_id = dest_instance.id
            cloned.reality_id = timeline.reality_id
            cloned.timeline_id = timeline.id
            cloned.save
          end
        end
        ```
  
        ## Restrictions Enforcement
  
        **DEFAULT_RESTRICTIONS:**
  
        ```ruby
        {
          'no_death' => true,
          'no_prisoner' => true,
          'no_xp' => true,
          'rooms_read_only' => true
        }
        ```
  
        **Enforcement Points:**
  
        - **no_death:** DeathService checks `timeline.no_death?` before killing
        - **no_prisoner:** PrisonerService checks `timeline.no_prisoner?`
        - **no_xp:** XPService checks `timeline.no_xp?` before awarding
        - **rooms_read_only:** Building commands check `timeline.rooms_read_only?`
  
        All services respect timeline restrictions via:
  
        ```ruby
        timeline = character_instance.timeline
        return if timeline && timeline.no_death?
        ```
  
        ## Era Service Integration
  
        Historical timelines use EraService for era-appropriate mechanics:
  
        **EraService.current_era:**
  
        Returns symbol: `:medieval`, `:gaslight`, `:modern`, `:near_future`, `:scifi`
  
        Based on global `time_period` setting (future: based on timeline.year).
  
        **Era Configs:**
  
        Each era defines:
        - **Currency:** name, symbol, subunit, digital_allowed
        - **Banking:** ATM availability, digital transfers, physical only
        - **Messaging:** type (messenger/telegram/phone/dm), range, delayed, courier visible
        - **Travel:** taxi type, vehicle types
        - **Phones:** availability, type (landline/mobile/implant/communicator), portable
  
        **Fabrication Example:**
  
        ```ruby
        # Medieval fabrication takes 4 hours
        GameConfig::Fabrication::ERA_TIMES[:medieval][:base_seconds] = 14_400
  
        # Sci-fi fabrication is instant
        GameConfig::Fabrication::ERA_TIMES[:scifi][:base_seconds] = 3
        ```
  
        ## Leaving Timelines
  
        **TimelineService.leave_timeline:**
  
        ```ruby
        def leave_timeline(character_instance)
          return false unless character_instance.in_past_timeline?
  
          character_instance.update(online: false)
          # Instance remains in DB for potential re-entry
          true
        end
        ```
  
        **Re-Entry:**
  
        When re-entering same timeline:
        - Existing instance is reactivated (online: true)
        - Character state is preserved from last exit
        - Inventory is preserved
  
        ## Command Flow
  
        **Main Menu:**
  
        Options dynamically generated based on state:
        - View Timelines (always)
        - Enter Timeline (always)
        - Create Snapshot (always)
        - Leave Timeline (only if in past timeline)
        - Timeline Info (only if in past timeline)
        - Delete Snapshot (always)
  
        **Quick Enter:**
  
        ```ruby
        timeline "Before the Battle"
  
        # Finds snapshot by name
        # Checks accessibility
        # Calls TimelineService.enter_snapshot_timeline
        # Returns success with restrictions notice
        ```
  
        ## Snapshot Accessibility
  
        **CharacterSnapshot.can_enter?(character):**
  
        ```ruby
        def can_enter?(character)
          # Creator always has access
          return true if character_id == character.id
  
          # Others need to have been present
          present_character_ids&.include?(character.id)
        end
        ```
  
        **TimelineService.accessible_snapshots_for(character):**
  
        Returns all snapshots where:
        - Character created it, OR
        - Character was present when created
  
        ## Multi-Tab Play
  
        **How It Works:**
  
        1. Main character: Primary CharacterInstance in main Reality
        2. Timeline character: Separate CharacterInstance in Timeline's Reality
        3. Both instances can be online simultaneously
        4. Separate browser tabs/windows access different instances
        5. Each tab authenticates the same User but connects to different CharacterInstance
  
        **Session Routing:**
  
        WebSocket connections route to correct instance based on reality_id in session.
  
        ## Database Schema
  
        **timelines:**
        - id, reality_id (FK)
        - timeline_type (enum: snapshot, historical)
        - name, description
        - snapshot_id (FK, nullable)
        - year (int, nullable), zone_id (FK, nullable)
        - source_character_id (FK)
        - restrictions (jsonb)
        - is_active (boolean)
        - rooms_read_only (boolean)
        - location_ids_used (integer[])
        - created_at, updated_at
  
        **character_snapshots:**
        - id, character_id (FK), room_id (FK)
        - name, description
        - captured_at (timestamp)
        - character_data (jsonb)
        - present_character_ids (integer[])
        - created_at, updated_at
  
        **character_instances:**
        - ... existing fields ...
        - timeline_id (FK, nullable)
        - (reality_id already links to Timeline's reality)
  
        ## Testing Strategies
  
        **Unit Tests:**
        - Snapshot capture (state serialization)
        - Snapshot accessibility (presence check)
        - Timeline creation (reality + restrictions)
        - Restriction checks
  
        **Integration Tests:**
        - Full cycle: create snapshot → enter → leave → re-enter
        - Historical timeline: multiple characters entering same year/zone
        - Inventory cloning
        - Multi-tab simulation (multiple instances for same character)
  
        ## Performance Considerations
  
        **Snapshot Data:**
        - character_data JSONB can be large
        - Index on character_id, captured_at for fast listing
  
        **Timeline Instances:**
        - Inactive instances accumulate over time
        - Periodic cleanup: DELETE instances offline for >30 days in inactive timelines
  
        **Inventory Cloning:**
        - Can create many item records
        - Items linked to timeline_id for bulk cleanup
  
        ## Common Issues
  
        **Cannot Enter Snapshot:**
        - Check present_character_ids (character must have been there)
        - Verify snapshot still exists (not deleted)
  
        **Stuck in Timeline:**
        - Use 'timeline' → 'Leave Timeline'
        - Admin can force: `instance.update(online: false)`
  
        **Inventory Not Cloned:**
        - Check TimelineService.clone_inventory_to_timeline
        - Verify source_instance.items exist
  
        **Restrictions Not Working:**
        - Check timeline.parsed_restrictions
        - Verify service checks (DeathService, XPService, etc.)
  
        ## Future Enhancements
  
        - Branching timelines (create new timeline from point in existing timeline)
        - Timeline merging (bring timeline events back to present)
        - Persistent historical campaigns (long-running shared timelines)
        - Timeline permissions (public/private/invite-only)
        - Snapshot galleries (browse all accessible snapshots)
      STAFF
      display_order: 90
    },
    {
      name: 'events_media',
      display_name: 'Events & Competitions & Media',
      summary: 'Hosting events, media playback, and shared entertainment',
      player_guide: <<~'GUIDE',
        # Events & Media - Player Guide
  
        Firefly provides powerful tools for hosting scheduled events and sharing media with other players. This system includes **calendar events** with temporary decorations, **Watch2Gether-style media sessions** for synchronized viewing, and **jukebox playlists** for background music.
  
        ---
  
        ## Calendar Events
  
        ### What Are Events?
  
        Events are **scheduled activities** like parties, meetings, competitions, or ceremonies. When you enter an event, you move into a **separate RP space** from the main room. Players outside the event can't see what's happening inside, and vice versa. Events can have:
  
        - **Temporary decorations and furniture** that disappear when the event ends
        - **Room state snapshots** showing the room's condition when the event started
        - **Attendee tracking** with RSVP support
        - **Capacity limits** and **bounce lists** for troublemakers
        - **RP log visibility controls** (public, attendees-only, or organizer-only)
  
        ### Event Types
  
        - **party** - Social gatherings, celebrations
        - **meeting** - Formal assemblies, councils
        - **competition** - Contests, tournaments
        - **concert** - Musical performances
        - **ceremony** - Rituals, weddings, inaugurations
        - **private** - Invitation-only gatherings
        - **public** - Open to everyone
  
        ### Attending Events
  
        **Find upcoming events:**
        - Check the calendar (command not shown in current code, likely web-based)
        - Events appear when you're in the location where they'll happen
  
        **Join an event:**
        ```
        enter event
        join event
        ```
  
        When you enter, you'll:
        - Move into the event's RP space (separate from outside)
        - See only other participants inside the event
        - Receive a notification that you've entered
  
        **Leave an event:**
        ```
        leave event
        exit event
        ```
  
        You'll return to the main room outside the event.
  
        **Event restrictions:**
        - **Bounced players** can't re-enter (kicked by host/staff)
        - **Capacity limits** prevent overcrowding
        - **Auto-start**: When the organizer enters a scheduled event, it starts automatically
  
        ### Hosting Events
  
        **Create an event:**
        Use the web calendar interface to schedule an event. Set:
        - **Name and description**
        - **Start/end times**
        - **Location** (room or general location)
        - **Event type** (party, meeting, competition, etc.)
        - **Public/private** status
        - **Max attendees** (optional capacity limit)
        - **Log visibility** (who can see the RP logs after)
  
        **End your event:**
        ```
        end event
        ```
  
        This:
        - Removes all participants from the event space
        - Cleans up temporary decorations and furniture
        - Marks the event as completed
        - Creates a world memory from the event (for story continuity)
  
        **Event permissions:**
        - **Organizer**: Can end the event, bounce attendees
        - **Staff role**: Attendees marked as "staff" can bounce players
        - **Regular attendees**: Can enter/leave freely
  
        ### Temporary Event Content
  
        **Decorations:**
        Events can have custom decorations visible only to participants. These are automatically cleaned up when the event ends.
  
        **Temporary furniture:**
        Events can add places (seating, tables, stages) that exist only during the event. These follow the same furniture system as permanent places but disappear after the event.
  
        **Room snapshots:**
        When an event starts, the system snapshots the room's state (description, visible objects, etc.). This preserves the "before" state for reference.
  
        ---
  
        ## Competitions
  
        Competitions are structured competitive activities where players compete for the highest score or to be the last one standing. They use the same activity system as missions (dice rolls, rounds, willpower) but with a competitive goal.
  
        ### Competition Types
  
        - **Competition**: Individual contest — everyone rolls each round, and the highest cumulative score wins
        - **Team Competition**: Two teams compete — team scores are combined, and the highest team total wins
        - **Elimination**: Last-person-standing — each round, the lowest scorer is knocked out until one remains
  
        ### How Competitions Work
  
        Competitions use the same commands and mechanics as other activities:
  
        1. `activity list` - Find competitions in your location
        2. `activity join` - Join a competition being set up
        3. Each round, choose actions and roll dice
        4. Your score accumulates across rounds
        5. Winner is determined when all rounds complete
  
        **Key differences from missions:**
        - **Scoring**: Your roll results accumulate as a score rather than determining pass/fail
        - **No helping**: In competitive rounds, you can't help other participants
        - **Elimination**: In elimination competitions, the lowest scorer each round is knocked out
        - **Teams**: In team competitions, you're assigned to a team and your scores are combined
  
        ### Tips for Competitions
        - **Manage willpower carefully** — spending early gives big scores but leaves you dry for later rounds
        - **In elimination**, consistency matters more than one big round
        - **In team competitions**, coordinate with teammates about who spends willpower when
  
        ---
  
        ## Media Sessions (Watch2Gether)
  
        ### YouTube Sync Sessions
  
        **Watch YouTube videos together** with synchronized playback - when the host plays/pauses/seeks, all viewers see the same thing.
  
        **Start a watch party:**
        Not shown in current code - likely via `play <youtube-url>` command or web interface.
  
        **Control playback (host only):**
        ```
        media play              # Resume playback
        media pause             # Pause for everyone
        media seek 1:30         # Skip to 1 minute 30 seconds
        media seek 90           # Skip to 90 seconds
        media stop              # End the session
        ```
  
        **View status:**
        ```
        media status            # Show current playback state
        media                   # Show media menu
        ```
  
        **How it works:**
        - **Host controls** - Only the person who started the video can control playback
        - **Drift correction** - Position is calculated server-side to keep everyone synced
        - **Buffering detection** - If the host buffers, viewers pause automatically
        - **Viewer count** - See how many people are watching
        - **Playback rate** - Support for 0.25x to 2.0x speed (not exposed in commands yet)
  
        **Technical details:**
        - Uses **Redis polling** for real-time sync (until AnyCable is integrated)
        - **PeerJS** for WebRTC connections (screen sharing only)
        - **Heartbeat monitoring** - Sessions end if host disconnects for 2+ minutes
        - **Position tracking** - Server calculates position as: `saved_position + (now - started_at) * playback_rate`
  
        ### Screen/Tab Sharing
  
        **Share your screen or browser tab** with others in the room using WebRTC.
  
        **Start screen sharing:**
        ```
        media share screen      # Share entire screen or window
        share screen            # Alias for media share screen
        ```
  
        **Start tab sharing:**
        ```
        media share tab         # Share a browser tab (audio in Chrome only)
        share tab               # Alias for media share tab
        ```
  
        **Stop sharing:**
        ```
        media share stop        # End the session
        share stop              # Alias
        media stop              # Also works
        ```
  
        **How it works:**
        - **WebRTC peer-to-peer** - Direct connection between host and viewers (no server relay)
        - **PeerJS cloud signaling** - Uses PeerJS's free cloud service to establish connections
        - **Share types**:
          - **screen** - Entire screen or a specific window
          - **tab** - A specific browser tab (with audio in Chrome/Edge)
        - **Audio support** - Tab sharing can capture audio, screen sharing cannot
        - **Viewer joins** - Viewers automatically connect when they poll and see the session
  
        **Browser compatibility:**
        - **Chrome/Edge**: Full support (tab audio works)
        - **Firefox**: Screen/tab sharing works, but tab audio not supported
        - **Safari**: Limited WebRTC support
  
        ### Legacy Room Media
  
        **Simple video playback** (older system, still supported):
  
        **Play a video:**
        ```
        play <youtube-url>      # Start a video (not synced)
        ```
  
        **Stop playback:**
        ```
        media stop              # Stop the current video
        ```
  
        This system doesn't have synchronized playback - each viewer controls their own player.
  
        ---
  
        ## Jukeboxes & Playlists
  
        ### What Are Jukeboxes?
  
        Jukeboxes are **music players** that can be placed in rooms. They play background music from a playlist, with shuffle and loop modes.
  
        **Create a jukebox:**
        ```
        make music player <name>
        ```
  
        Example: `make music player Tavern Jukebox`
  
        ### Managing Playlists
  
        **View the playlist:**
        ```
        media playlist          # Show all tracks
        playlist                # Alias
        ```
  
        **Add tracks:**
        ```
        media playlist add <url>
        playlist add <url>
        ```
  
        Supports any audio URL (YouTube, SoundCloud, direct MP3 links, etc.)
  
        **Remove tracks:**
        ```
        media playlist remove 3    # Remove track #3
        playlist remove 3
        ```
  
        **Clear all tracks:**
        ```
        media playlist clear
        playlist clear
        ```
  
        **Permissions:**
        - **Room owners** can edit playlists in their rooms
        - **Staff** can edit any playlist
  
        ### Playback Controls
  
        **Start/stop playback:**
        ```
        media player play       # Start playing
        player play             # Alias
        jukebox play            # Alias
  
        media player stop       # Stop playback
        player stop             # Alias
        ```
  
        **Toggle shuffle:**
        ```
        media player shuffle    # Toggle shuffle mode
        player shuffle
        ```
  
        **Toggle loop:**
        ```
        media player loop       # Toggle loop (repeat playlist)
        player loop
        ```
  
        **View status:**
        ```
        media player            # Show playback status and modes
        player                  # Alias
        ```
  
        **Playback modes:**
        - **Sequential** - Play tracks in order (default)
        - **Shuffle** - Random track order
        - **Loop** - Repeat playlist when it ends
        - **Shuffle + Loop** - Random infinite playback
  
        ---
  
        ## Metaplot Events (Story Continuity)
  
        ### What Are Metaplot Events?
  
        **Metaplot events** track significant story moments for world continuity. These are different from calendar events - they're historical records of important happenings.
  
        **Event types:**
        - **battle** - Major conflicts
        - **discovery** - Important findings
        - **betrayal** - Significant betrayals
        - **alliance** - Faction agreements
        - **death** - Notable character deaths
        - **resurrection** - Character returns
        - **artifact** - Powerful item appearances
        - **political** - Government changes, treaties
        - **natural_disaster** - Earthquakes, floods, etc.
        - **ceremony** - Major rituals, coronations
        - **revelation** - Shocking truths revealed
  
        **Significance levels:**
        - **minor** - Local impact, few people affected
        - **notable** - Regional impact, widely known
        - **major** - World-changing events
        - **legendary** - Events that define an era
  
        **Visibility:**
        - **Public events** - Visible to all players
        - **Private events** - Hidden from most (GM secrets, unrevealed plots)
  
        **Who creates these?**
        Typically staff-created via admin interface. Players might trigger them through major RP events, completed missions, or Auto-GM adventures.
  
        **Searching metaplot history:**
        - By location: See events that happened at a specific place
        - By character: See events a character was involved in
        - By date: Recent events (last 30 days, etc.)
        - By significance: Major/legendary events only
  
        **Integration with other systems:**
        - **World Memory**: Metaplot events feed into the AI's world knowledge
        - **Auto-GM**: Adventures can create metaplot events on completion
        - **Events**: Completed calendar events can spawn metaplot records
        - **Timelines**: Historical metaplot events shape different eras
  
        ---
  
        ## Media Session Technical Details
  
        ### Polling & Real-Time Updates
  
        Since AnyCable isn't integrated yet, media sessions use **Redis-backed polling**:
  
        - **2-second poll interval** - Clients check for updates every 2 seconds
        - **Event queue** - Redis stores recent events (last 50)
        - **Session cache** - Active sessions cached in Redis with 5-minute TTL
        - **Heartbeat timeout** - Sessions end if host doesn't ping for 2 minutes
  
        **Event types:**
        - `media_session_started` - New session created
        - `media_session_ended` - Session stopped
        - `media_playback_update` - Play/pause/seek/buffering/rate change
  
        ### Viewer Lifecycle
  
        1. **Viewer joins** - Calls `viewer_join` with their PeerJS peer ID
        2. **Connection pending** - Viewer attempts WebRTC connection to host
        3. **Connected** - WebRTC established, viewer receives stream
        4. **Disconnected** - Viewer leaves room or connection fails
        5. **Cleanup** - Stale viewers removed after 2 minutes
  
        ### Buffering Handling
  
        When the host's video buffers:
        1. Host sends `buffering` action with current position
        2. All viewers pause at that position
        3. When host resumes, viewers sync to new position
        4. Drift correction ensures everyone stays aligned
  
        ---
  
        ## Common Use Cases
  
        ### Hosting a Party
  
        1. Create event via web calendar (set start time, location, type: "party")
        2. Add decorations/furniture beforehand (or during event)
        3. When ready, `enter event` to auto-start
        4. Players `enter event` to join your party
        5. Share media: `media share tab` to show a video or presentation
        6. When done, `end event` to conclude
  
        ### Watch Party
  
        1. Start YouTube session: `play <youtube-url>` (or web interface)
        2. Others in room automatically see the video
        3. Control playback: `media pause`, `media seek 2:30`, `media play`
        4. Check viewers: `media status`
        5. End session: `media stop`
  
        ### Setting Up a Tavern Jukebox
  
        1. `make music player The Old Oak Jukebox`
        2. Add tracks:
           - `playlist add https://youtube.com/watch?v=...`
           - `playlist add https://youtube.com/watch?v=...`
        3. Configure: `player shuffle` and `player loop`
        4. Start: `player play`
        5. Players entering the room hear the music
  
        ### Recording a Major Story Event
  
        1. Staff creates metaplot event via admin panel
        2. Set type: "battle", significance: "major"
        3. Tag location and involved characters
        4. Set public/private visibility
        5. Event appears in world history queries
        6. AI systems (Auto-GM, NPC memory) reference it for context
  
        ---
  
        ## Tips & Best Practices
  
        **For event hosts:**
        - Set clear start/end times so players can plan attendance
        - Use capacity limits for intimate gatherings
        - Mark events public vs private based on story needs
        - Use temporary decorations instead of permanently modifying rooms
        - End events properly to clean up temporary content
  
        **For media sessions:**
        - Test your screen share before important presentations
        - Use tab sharing for videos with audio
        - Remember only the host can control playback
        - Close the session when done to free up room resources
  
        **For jukebox owners:**
        - Keep playlists themed to the location (tavern music, club beats, etc.)
        - Enable shuffle + loop for continuous background music
        - Give tracks descriptive titles when adding them
        - Regular attendees appreciate fresh tracks added periodically
  
        **Performance considerations:**
        - Media sessions use polling (2-second intervals) until AnyCable is integrated
        - Screen sharing is peer-to-peer (no server bandwidth used)
        - YouTube sessions sync via server state (minimal bandwidth)
        - Stale sessions auto-cleanup after 2 minutes of inactivity
      GUIDE
      description: "Create and attend scheduled events with decoration and attendee tracking. Play music, videos, and other media in rooms with playlist management and playback controls. Camera and bounce commands help manage event spaces. Share media URLs with the room.",
      command_names: ['events', 'create event', 'enter event', 'leave event', 'start event', 'end event', 'event info', 'bounce', 'camera', 'play', 'media'],
      related_systems: %w[communication timelines missions],
      key_files: [
        'app/models/event.rb',
        'app/models/event_decoration.rb',
        'app/models/event_place.rb',
        'app/models/metaplot_event.rb',
        'app/models/media_session.rb',
        'app/models/media_session_viewer.rb',
        'app/models/room_media.rb',
        'app/services/event_service.rb',
        'app/services/media_sync_service.rb',
        'plugins/core/events/commands/enter_event.rb',
        'plugins/core/events/commands/leave_event.rb',
        'plugins/core/events/commands/end_event.rb',
        'plugins/core/entertainment/commands/media_control.rb'
      ],
      staff_notes: <<~'NOTES',
        # Events & Media - Staff Notes
  
        ## Architecture Overview
  
        The events_media system comprises four main subsystems:
  
        1. **Calendar Events** - Scheduled social gatherings with RP isolation
        2. **Media Sessions** - Watch2Gether-style synchronized viewing (YouTube + WebRTC)
        3. **Room Media** - Legacy URL-based playback (YouTube embeds)
        4. **Jukeboxes** - Playlist-based background music players
        5. **Metaplot Events** - Story continuity tracking
  
        ---
  
        ## Calendar Events Architecture
  
        ### Event Model (`app/models/event.rb`)
  
        **Associations:**
        ```ruby
        many_to_one :location
        many_to_one :room
        many_to_one :organizer, class: :Character
        one_to_many :event_attendees
        one_to_many :event_room_states
        one_to_many :event_decorations
        one_to_many :event_places
        ```
  
        **Event lifecycle:**
        - **scheduled** → **active** → **completed** (normal flow)
        - **scheduled** → **cancelled** (aborted)
  
        **Status transitions:**
        ```ruby
        def start!
          update(status: 'active', started_at: Time.now)
        end
  
        def complete!
          update(status: 'completed', ended_at: Time.now)
        end
  
        def cancel!
          update(status: 'cancelled')
        end
        ```
  
        **Key methods:**
        - `snapshot_room!(room)` - Captures room state when event starts
        - `end_for_all!` - Removes all characters from event, cleans up temporary content, completes event
        - `cleanup_temporary_content!` - Deletes EventDecorations and EventPlaces
        - `characters_in_event` - CharacterInstances where `in_event_id == self.id`
        - `controllable_by?(character)` - Organizer or staff role check
  
        **RP isolation:**
        - CharacterInstance has `in_event_id` field
        - When set, character sees only other characters in the same event
        - Room broadcasts filtered by event ID
  
        ### Event Service (`app/services/event_service.rb`)
  
        **Lifecycle management:**
        ```ruby
        start_event!(event)       # Snapshot room, set status: active
        end_event!(event)         # Cleanup, create world memory (async)
        cancel_event!(event)      # Remove participants, cleanup, cancel
        ```
  
        **Entry/exit:**
        ```ruby
        enter_event!(event:, character_instance:)
          # 1. Check can_enter_event? (capacity, bounce list)
          # 2. Add EventAttendee if missing
          # 3. Update character_instance.in_event_id
          # Returns success/error result
  
        leave_event!(character_instance:)
          # 1. Set in_event_id = nil
          # 2. Set event_camera = false
          # Returns success/error result
        ```
  
        **Queries:**
        - `upcoming_events(limit:, include_private:)` - Future events
        - `events_for_character(character)` - Attending or organizing
        - `events_at_location(location)` / `events_at_room(room)` - By place
        - `find_event_at(room)` - Active event in room
  
        ### Event Commands
  
        **enter_event.rb:**
        ```ruby
        # 1. Check if already in event → error
        # 2. Find active event in room (or scheduled within 1hr, started within 12hr)
        # 3. Check not bounced
        # 4. If organizer and event is scheduled, auto-start
        # 5. Create/update EventAttendee, check_in!
        # 6. Broadcast arrival to room and to event participants
        # 7. Update character_instance.in_event_id
        ```
  
        **leave_event.rb:**
        ```ruby
        # 1. Check in event → error if not
        # 2. Broadcast departure to event participants
        # 3. Update character_instance (leave_event!)
        # 4. Broadcast return to room
        ```
  
        **end_event.rb:**
        ```ruby
        # 1. Check in event → error
        # 2. Check is organizer → error if not
        # 3. Check event not already ended
        # 4. Broadcast end to all event participants
        # 5. Call event.end_for_all!
        # 6. Broadcast to room
        ```
  
        ### Temporary Event Content
  
        **EventDecoration model:**
        - Visible only to event participants
        - Stored with event_id, room_id
        - Auto-deleted when event ends
        - Fields: name, description, image_url, display_order
  
        **EventPlace model:**
        - Mirrors permanent Place model
        - Same fields: capacity, place_type, sit_action, etc.
        - Deleted when event ends
        - Used for temporary seating, stages, bars
  
        **EventRoomState model:**
        - Snapshots room state at event start
        - Preserved after event ends (historical reference)
        - Includes room description, objects, etc.
  
        ### RP Log Integration
  
        **RpLog associations:**
        ```ruby
        many_to_one :event
        ```
  
        **Visibility control:**
        ```ruby
        event.can_view_logs?(character)
          # Checks logs_visible_to field:
          # - 'public': Everyone
          # - 'attendees': Current/past attendees
          # - 'organizer': Organizer only
        ```
  
        **Auto-memory creation:**
        When event ends, EventService spawns thread to call:
        ```ruby
        WorldMemoryService.create_from_event(event)
        ```
  
        This creates a world memory from the event's RP logs for AI context.
  
        ---
  
        ## Media Session Architecture
  
        ### MediaSession Model (`app/models/media_session.rb`)
  
        **Session types:**
        - **youtube** - Synchronized YouTube playback
        - **screen_share** - WebRTC screen/window sharing
        - **tab_share** - WebRTC browser tab sharing (with audio in Chrome)
  
        **Associations:**
        ```ruby
        many_to_one :room
        many_to_one :host, class: :CharacterInstance
        one_to_many :viewers, class: :MediaSessionViewer
        ```
  
        **Playback state fields:**
        - `is_playing` - Boolean
        - `is_buffering` - Boolean (host is buffering)
        - `playback_position` - Float (seconds)
        - `playback_started_at` - Timestamp when playback started (for drift correction)
        - `playback_rate` - Float (0.25 to 2.0, default 1.0)
  
        **Drift correction:**
        ```ruby
        def current_position
          return playback_position unless is_playing && playback_started_at
          elapsed = Time.now - playback_started_at
          playback_position + (elapsed * playback_rate)
        end
        ```
  
        Position calculated server-side: `saved + (now - started) * rate`
  
        **Session lifecycle:**
        ```ruby
        play!(position: nil)      # is_playing = true, record started_at
        pause!                    # is_playing = false, save current_position
        seek!(position)           # Update position, reset started_at if playing
        end_session!              # status = ended, disconnect all viewers
        heartbeat!                # Update last_heartbeat (keep-alive)
        ```
  
        **Stale session cleanup:**
        ```ruby
        MediaSession.cleanup_stale_sessions!
          # Called from scheduler
          # Ends sessions with last_heartbeat > 2 minutes ago
        ```
  
        ### MediaSyncService (`app/services/media_sync_service.rb`)
  
        **Service flow:**
  
        1. **Start session:**
           ```ruby
           start_youtube(room_id:, host:, video_id:, title:, duration:)
             # Creates MediaSession
             # Caches in Redis (SYNC_TTL = 5 minutes)
             # Broadcasts 'media_session_started' event
           ```
  
        2. **Host controls:**
           ```ruby
           play(session, position: nil)
             # session.play!(position)
             # cache_session_state(session)
             # broadcast_to_room(room_id, { type: 'media_playback_update', action: 'play', ... })
           ```
  
           Similar for: `pause`, `seek`, `set_rate`, `buffering`
  
        3. **Viewer management:**
           ```ruby
           viewer_join(session, character_instance, peer_id)
             # Creates MediaSessionViewer record
             # Returns session.to_sync_hash for immediate sync
           ```
  
        4. **Polling endpoints:**
           ```ruby
           get_room_session(room_id)
             # Try Redis cache first
             # Fall back to DB query
             # Returns session.to_sync_hash
  
           get_room_events(room_id, since_timestamp:)
             # Fetch events from Redis list
             # Filter by timestamp
             # Returns array of events
           ```
  
        **Redis schema:**
        ```
        media_sync:session:<session_id> → JSON (session.to_sync_hash)
        media_sync:room:<room_id> → String (session_id)
        media_sync:events:<room_id> → List (last 50 events)
        ```
  
        **Broadcasting:**
        All playback changes broadcast to Redis event queue for polling clients.
  
        ### Screen Sharing Flow (WebRTC)
  
        1. **Host starts share:**
           - Command: `media share screen` or `media share tab`
           - Frontend captures screen via `navigator.mediaDevices.getDisplayMedia()`
           - Frontend calls API with peer_id
           - Server creates MediaSession with peer_id
  
        2. **Viewers connect:**
           - Poll endpoint, see new session with host peer_id
           - Connect to host via PeerJS (cloud signaling)
           - Receive WebRTC stream directly (no server relay)
  
        3. **PeerJS integration:**
           - Uses PeerJS cloud service (free tier)
           - Peer IDs generated client-side
           - STUN/TURN for NAT traversal
           - Fallback to cloud relay if P2P fails
  
        **Audio capture:**
        - Screen sharing: No audio
        - Tab sharing: Audio capture in Chrome/Edge only
        - Firefox: No tab audio support
  
        ### MediaSessionViewer Model
  
        **Fields:**
        - `media_session_id` - Foreign key
        - `character_instance_id` - Viewer
        - `peer_id` - PeerJS peer ID (for WebRTC)
        - `connection_status` - 'pending', 'connected', 'disconnected'
        - `joined_at` - Timestamp
  
        **Methods:**
        ```ruby
        mark_connected!       # connection_status = 'connected'
        mark_disconnected!    # connection_status = 'disconnected'
        ```
  
        **Viewer cleanup:**
        Disconnected viewers kept in DB for analytics, but excluded from `viewer_count`.
  
        ---
  
        ## Room Media (Legacy System)
  
        ### RoomMedia Model (`app/models/room_media.rb`)
  
        **Simple URL-based playback:**
        - Stores URL, media_type (video/audio)
        - Duration-based expiry (ends_at timestamp)
        - YouTube embed URL generation
  
        **Methods:**
        ```ruby
        youtube?              # Checks URL against YOUTUBE_REGEX
        expired?              # ends_at && Time.now > ends_at
        playing?              # !expired?
        time_remaining        # (ends_at - Time.now).to_i
        youtube_video_id      # Extract video ID from URL
        embed_url             # Generate YouTube embed URL with params
        stop!                 # Set ends_at = Time.now
        ```
  
        **Class methods:**
        ```ruby
        RoomMedia.playing_in(room_id)     # Current media
        RoomMedia.stop_all_in(room_id)    # Stop all
        ```
  
        **Limitations:**
        - No synchronization between viewers
        - Each player controls their own playback
        - Being replaced by MediaSession system
  
        ---
  
        ## Jukebox System
  
        **Models:**
        - `Jukebox` - Music player entity (created via `make music player`)
        - `JukeboxTrack` - Individual tracks in playlist
  
        **Jukebox fields:**
        - `name` - Display name
        - `room_id` - Where it's located
        - `playing` - Boolean
        - `shuffle_play` - Boolean
        - `loop_play` - Boolean
        - `current_track_position` - Which track is playing
  
        **JukeboxTrack fields:**
        - `jukebox_id` - Foreign key
        - `position` - Order in playlist (0-indexed)
        - `url` - Media URL
        - `title` - Display title
        - `duration_seconds` - Track length
  
        **Playback logic:**
        ```ruby
        jukebox.play!         # playing = true
        jukebox.stop!         # playing = false
        jukebox.toggle_shuffle!
        jukebox.toggle_loop!
        jukebox.add_track!(url:, title:)
        jukebox.remove_track!(position)
        jukebox.clear_tracks!
        ```
  
        **Permission check:**
        ```ruby
        def can_edit_playlist?
          # Find outermost room (if inside building)
          outer_room = location
          outer_room = outer_room.inside_room while outer_room.inside_room
          # Check ownership or staff
          outer_room.owned_by?(character) || character.staff?
        end
        ```
  
        **Integration:**
        - Created via `make music player` command
        - Controlled via `media player` / `playlist` commands
        - Visible in room description when playing
  
        ---
  
        ## Metaplot Event System
  
        ### MetaplotEvent Model (`app/models/metaplot_event.rb`)
  
        **Purpose:** Track significant story events for continuity and AI context.
  
        **Fields:**
        - `title` - Event name
        - `summary` - Description
        - `event_type` - Category (battle, discovery, betrayal, etc.)
        - `significance` - Impact level (minor, notable, major, legendary)
        - `occurred_at` - When it happened
        - `location_id` - Where it happened
        - `room_id` - Specific room (optional)
        - `characters_involved` - JSON array of character IDs
        - `is_public` - Visibility flag
  
        **Event types:**
        ```ruby
        EVENT_TYPES = %w[
          battle discovery betrayal alliance death resurrection
          artifact political natural_disaster ceremony revelation
        ]
        ```
  
        **Significance levels:**
        ```ruby
        SIGNIFICANCE = %w[minor notable major legendary]
        ```
  
        **Querying:**
        ```ruby
        MetaplotEvent.involving_location(location)
        MetaplotEvent.involving_character(character)
        MetaplotEvent.recent(days: 30)
        MetaplotEvent.major_events  # major + legendary
        ```
  
        **Integration points:**
        - **Auto-GM**: Creates metaplot events on adventure success
        - **World Memory**: Metaplot events feed into AI summaries
        - **NPC Memory**: NPCs can reference metaplot events in conversation
        - **Timeline**: Historical metaplot events define different eras
  
        **Creation:**
        Typically via admin interface. Can also be created programmatically:
        ```ruby
        MetaplotEvent.create(
          title: 'The Battle of Ironforge',
          summary: 'Allied forces repelled the undead invasion...',
          event_type: 'battle',
          significance: 'major',
          occurred_at: Time.now,
          location_id: battle_location.id,
          characters_involved: [hero1.id, hero2.id, villain.id].to_json,
          is_public: true
        )
        ```
  
        ---
  
        ## Command Integration
  
        ### media_control.rb Command Flow
  
        **Alias detection:**
        ```ruby
        # Command can be called as:
        # - media <action>
        # - mc <action>
        # - watchparty <action>
        # - share <args>
        # - player <args>
        # - playlist <args>
        # - jukebox <args>
        ```
  
        **Main menu:**
        ```ruby
        show_media_menu
          # Builds options based on context:
          # - If session exists: play/pause/stop/status
          # - If jukebox: jukebox/playlist controls
          # - Always: share screen/tab options
          # Returns quickmenu or info message
        ```
  
        **Playback control flow:**
        ```ruby
        handle_play_action
          # 1. Find active session in room
          # 2. Check host permission (YouTube only)
          # 3. Check not already playing
          # 4. MediaSyncService.play(session)
          # 5. Broadcast to room
          # 6. Return success with session data
        ```
  
        **Share command flow:**
        ```ruby
        start_screen_share(share_type)
          # 1. Check for existing session
          # 2. Broadcast "starting to share..."
          # 3. Return success with data: { action: 'start_screen_share', ... }
          # 4. Frontend captures screen and calls API with peer_id
          # 5. Server creates MediaSession via MediaSyncService
        ```
  
        **Playlist management:**
        ```ruby
        playlist_add(jukebox, url)
          # 1. Validate URL format
          # 2. Check permission (can_edit_playlist?)
          # 3. jukebox.add_track!(url:, title:)
          # 4. Return success
        ```
  
        ### enter_event.rb Flow
  
        **Detailed command flow:**
        ```ruby
        1. Check character_instance.in_event?
           → error if already in event
  
        2. find_active_event
           # Searches for:
           # - Active events at current room/location
           # - Scheduled events within 1 hour, started within 12 hours
  
        3. Check EventAttendee.bounced_from?(event, character)
           → error if bounced
  
        4. Auto-start if organizer:
           if event.scheduled? && event.organizer_id == character.id
             event.start!
           end
  
        5. Create/update attendee:
           attendee = EventAttendee.find_or_create(...)
           attendee.check_in!
  
        6. Broadcast to room (outside):
           broadcast_to_room("#{character.full_name} enters #{event.name}.")
  
        7. Update character instance:
           character_instance.enter_event!(event)
  
        8. Broadcast to event participants:
           event.characters_in_event.each do |ci|
             BroadcastService.to_character(ci, ...)
           end
        ```
  
        **EventAttendee model:**
        - `event_id` - Foreign key
        - `character_id` - Attendee
        - `status` - 'yes', 'no', 'maybe' (RSVP)
        - `role` - 'host', 'staff', 'attendee'
        - `bounced` - Boolean (kicked from event)
        - `checked_in` - Boolean (physically attended)
        - `checked_in_at` - Timestamp
  
        ---
  
        ## Redis & Polling Architecture
  
        **Why Redis polling?**
        - AnyCable (ActionCable replacement) not integrated yet
        - Need real-time updates for media sync
        - Polling provides acceptable UX (2-second latency)
        - Future: Replace with WebSocket push via AnyCable
  
        **Polling endpoints:**
        ```
        GET /api/media/sync/:room_id/state
          → Returns session.to_sync_hash or nil
  
        GET /api/media/sync/:room_id/events?since=<iso8601>
          → Returns array of events since timestamp
        ```
  
        **Client polling loop:**
        ```javascript
        setInterval(async () => {
          const state = await fetch(`/api/media/sync/${roomId}/state`);
          const events = await fetch(`/api/media/sync/${roomId}/events?since=${lastPoll}`);
          applyStateUpdate(state);
          events.forEach(applyEvent);
          lastPoll = new Date().toISOString();
        }, 2000);
        ```
  
        **Event queue management:**
        ```ruby
        # Add event to room's queue
        redis.rpush("media_sync:events:#{room_id}", event.to_json)
        # Keep only last 50 events
        redis.ltrim("media_sync:events:#{room_id}", -50, -1)
        # Set TTL
        redis.expire("media_sync:events:#{room_id}", SYNC_TTL)
        ```
  
        **Cache invalidation:**
        - Session state cached for 5 minutes
        - Heartbeat refreshes TTL
        - Stale sessions (no heartbeat for 2+ min) cleaned up by scheduler
  
        ---
  
        ## Database Schema Notes
  
        **Event tables:**
        ```
        events
          - id, name, title, description, banner_url
          - event_type, status, is_public
          - starts_at, ends_at, started_at, ended_at
          - organizer_id, location_id, room_id
          - max_attendees, logs_visible_to
  
        event_attendees
          - event_id, character_id
          - status (rsvp), role, bounced, checked_in
  
        event_room_states
          - event_id, room_id
          - snapshot (JSONB - room state at event start)
  
        event_decorations
          - event_id, room_id
          - name, description, image_url, display_order
  
        event_places
          - event_id, room_id
          - name, description, place_type, capacity
          - is_furniture, invisible, default_sit_action
        ```
  
        **Media tables:**
        ```
        media_sessions
          - id, room_id, host_id
          - session_type (youtube/screen_share/tab_share)
          - status (active/paused/ended)
          - is_playing, is_buffering
          - playback_position, playback_started_at, playback_rate
          - youtube_video_id, youtube_title, youtube_duration_seconds
          - peer_id (for WebRTC), share_type, has_audio
          - last_heartbeat, started_at, ended_at
  
        media_session_viewers
          - media_session_id, character_instance_id
          - peer_id, connection_status
          - joined_at
  
        room_media (legacy)
          - room_id, url, media_type
          - started_by_id, started_at, ends_at
          - autoplay
        ```
  
        **Metaplot table:**
        ```
        metaplot_events
          - id, title, summary
          - event_type, significance
          - occurred_at, location_id, room_id
          - characters_involved (JSON array)
          - is_public
        ```
  
        ---
  
        ## Testing Considerations
  
        **Event lifecycle:**
        - Test scheduled → active → completed flow
        - Test auto-start when organizer enters
        - Test bounce list enforcement
        - Test temporary content cleanup
        - Test world memory creation on completion
  
        **Media session sync:**
        - Test drift correction accuracy
        - Test buffering state propagation
        - Test viewer join/disconnect
        - Test heartbeat timeout cleanup
        - Test Redis cache invalidation
  
        **WebRTC screen sharing:**
        - Test peer connection establishment
        - Test host disconnect handling
        - Test viewer count accuracy
        - Test share type detection (screen/tab)
  
        **Permission checks:**
        - Test host-only controls for YouTube
        - Test room ownership for playlist editing
        - Test event organizer/staff permissions
        - Test bounce list restrictions
  
        ---
  
        ## Future Improvements
  
        **AnyCable integration:**
        - Replace Redis polling with WebSocket push
        - Reduce latency from 2 seconds to instant
        - Remove polling overhead from server
  
        **Enhanced sync features:**
        - Voice chat during watch parties
        - Drawing/annotation on shared screens
        - Multiple simultaneous media zones in large events
        - Picture-in-picture for screen shares
  
        **Event enhancements:**
        - Recurring events (weekly meetings, etc.)
        - Event templates (pre-configured decorations/settings)
        - Multi-room events (mansion party spanning floors)
        - Event leaderboards (competition scores)
  
        **Metaplot integration:**
        - Auto-create metaplot events from major RP sessions
        - LLM-powered event summarization
        - Timeline visualization (world history graph)
        - Character involvement tracking (reputation from events)
      NOTES
      display_order: 95
    },
    {
      name: 'permissions',
      display_name: 'Permissions',
      summary: 'Player-to-player permissions and content consent settings',
      player_guide: <<~'GUIDE',
        # Permissions & Consent - Player Guide
  
        Firefly provides **granular control over player interactions** through a multi-tier permission system. You can set default permissions that apply to everyone, then override them for specific players. Content consent settings let you manage what themes you're comfortable with in RP.
  
        ---
  
        ## Quick Overview
  
        **Three permission systems:**
        1. **User Permissions** - Visibility, messaging, and social preferences (generic defaults + per-player overrides)
        2. **Interaction Permissions** - Physical interactions like follow, dress, undress (permanent, temporary, and one-time)
        3. **Content Consent** - Mature themes you consent to (with per-player exceptions)
  
        **Access your settings:**
        ```
        permissions              # Main menu
        perms                    # Alias
        prefs                    # Alias
        ```
  
        ---
  
        ## User Permissions
  
        ### Generic (Default) Settings
  
        Your **generic permissions** apply to everyone by default. Set these once, then override for specific players.
  
        **View/edit your defaults:**
        ```
        permissions general      # Show generic permission form
        ```
  
        **Permission fields:**
  
        **1. Where Visibility**
        - **default** - Follow your locatability setting (most common)
        - **never** - Never appear in others' where list
        - **favorite** - Only appear when they use "where favorites"
        - **always** - Always appear, regardless of your locatability
  
        **2. OOC Messaging**
        - **yes** - Anyone can send you OOC messages (pages, tells, etc.)
        - **no** - Block all OOC messages
        - **ask** - Request consent first (quickmenu prompt)
  
        **3. IC Messaging**
        - **yes** - Anyone can send you IC messages (whispers, etc.)
        - **no** - Block all IC messaging
  
        **4. Lead/Follow**
        - **yes** - Anyone can lead/follow you
        - **no** - Require explicit permission first
  
        **5. Dress/Style**
        - **yes** - Others can dress, tattoo, or style you
        - **no** - Require explicit permission first
  
        **6. Channel Muting**
        - **yes** - See messages from everyone in channels
        - **muted** - Mute specific players (set per-player)
  
        **7. Group Preference**
        - **neutral** - Standard treatment (default)
        - **favored** - Prioritize in matchmaking, etc.
        - **disfavored** - Avoid in automated systems
  
        ### Per-Player Overrides
  
        **Override for a specific player:**
        ```
        permissions Bob          # Show Bob's permission form
        ```
  
        **How overrides work:**
        - Each field defaults to **"generic"** (use your default)
        - Change any field to a specific value to override
        - Example: Generic OOC is "yes", but set Bob to "no" to block him specifically
  
        **Example flow:**
        1. Generic OOC messaging: "yes" (allow everyone)
        2. Override for AnnoyingPlayer: "no" (block them)
        3. Override for BestFriend: "generic" (uses default = yes)
        4. Result: AnnoyingPlayer blocked, BestFriend allowed, everyone else allowed
  
        ---
  
        ## Interaction Permissions (Three-Tier System)
  
        Physical interactions (follow, dress, undress, interact) use a **three-tier permission system**:
  
        ### Tier 1: Permanent Permissions (Database)
  
        Stored in your **Relationship** records. These persist forever unless revoked.
  
        **Permission types:**
        - **follow** - Following your character
        - **dress** - Putting clothes on you, adding tattoos/piercings, styling
        - **undress** - Removing your clothes
        - **interact** - General physical interactions (emotes targeting you, etc.)
  
        **Granting permanent permission:**
        Not exposed via commands yet - typically granted via quickmenu consent prompts (see Tier 3).
  
        **Checking permanent permissions:**
        View via `permissions Bob` - shows if Bob has permanent follow/dress/undress/interact permission.
  
        ### Tier 2: Temporary Permissions (Redis)
  
        **Session-scoped** permissions that expire after **1 hour** or when you leave the room (for room-scoped permissions).
  
        **When used:**
        - Quick one-time permissions for current session
        - Room-scoped: "Bob can follow me while we're in this dungeon"
        - General: "Bob can dress me for the next hour"
  
        **Automatic cleanup:**
        - **1-hour TTL** - All temporary permissions expire after 1 hour
        - **Room-scoped** - Cleared when you leave the room
  
        **Granting temporary permission:**
        Typically granted via quickmenu when someone attempts an action.
  
        ### Tier 3: One-Time Consent (Quickmenu)
  
        When someone tries an action you haven't permitted, they get a **quickmenu consent request**.
  
        **Example flow:**
        1. Bob uses `follow Alice`
        2. Bob doesn't have permission (neither permanent nor temporary)
        3. Bob sees quickmenu: "Request permission to follow Alice?"
        4. Bob selects "Ask" → Alice gets quickmenu: "Bob wants to follow you. Allow?"
        5. Alice chooses:
           - **Allow Once** - Temporary permission (1 hour or room-scoped)
           - **Allow Always** - Permanent permission
           - **Deny** - No permission granted
  
        **Actions that require permission:**
        - `follow <character>`
        - `dress <character>`
        - `undress <character>`
        - Various emotes/interactions targeting others
  
        ---
  
        ## Content Consent (Mature Themes)
  
        ### What Is Content Consent?
  
        Content restrictions define **mature themes** that require player consent before appearing in RP. Admins configure these per universe (e.g., VIOLENCE, MATURE, HORROR, etc.).
  
        **How it works:**
        - You **opt-in** to content types you're comfortable with
        - RP involving restricted content requires **mutual consent** (both parties opted-in)
        - You can grant **per-player exceptions** ("I consent to X content specifically with Character Y")
  
        ### Managing Your Consents
  
        **View/edit content consents:**
        ```
        permissions consent      # Show consent form
        consent                  # Alias
        consents                 # Alias
        ```
  
        **Content types** (examples, varies by universe):
        - **VIOLENCE** - Combat, gore, physical harm
        - **MATURE** - Sexual content, explicit themes
        - **HORROR** - Terror, psychological horror
        - **DRUG_USE** - Drug/alcohol use
        - **DEATH** - Character death scenarios
        - **TORTURE** - Torture, extreme suffering
  
        **Consent form:**
        - Check boxes for content types you consent to
        - Your consents are private (only you and admins see them)
        - Submit to update your settings
  
        ### Room Consent Display
  
        **The 10-minute timer:**
        When room occupancy is stable for **10 minutes**, the "consent room" command shows what content **everyone present** consents to.
  
        **Check room consents:**
        ```
        consent room             # Show what content is allowed in this room
        ```
  
        **How it works:**
        1. Room occupancy changes (someone enters/leaves)
        2. **10-minute timer starts**
        3. If occupancy stays stable for 10 minutes, consent info becomes available
        4. Shows **intersection** of all players' consents (only content ALL consent to)
  
        **Why the timer?**
        - Prevents frequent room changes from triggering constant consent checks
        - Ensures stable RP environment before showing consent info
        - Respects consent privacy (only shows after stable occupancy)
  
        **Example:**
        ```
        Room occupants: Alice, Bob, Carol
        - Alice consents to: VIOLENCE, MATURE
        - Bob consents to: VIOLENCE, HORROR
        - Carol consents to: VIOLENCE, MATURE, HORROR
  
        → consent room shows: VIOLENCE (all three consent)
        ```
  
        ### Per-Player Consent Overrides
  
        **"I consent to X specifically with Character Y"**
  
        Sometimes you want to allow specific content with trusted RP partners that you wouldn't consent to generally.
  
        **Granting an override:**
        Via admin or consent UI (not shown in current commands).
  
        **Example:**
        - General consent: You DON'T consent to MATURE content
        - Override for TrustedPartner: You DO consent to MATURE content
        - Result: MATURE RP is allowed with TrustedPartner, but not others
  
        **Mutual requirement:**
        Overrides still require **mutual consent** - both parties must have the override for each other.
  
        ---
  
        ## Restricting a Player
  
        All restrictions are managed through **per-player permissions**. Open the form for any player and adjust their settings:
  
        ```
        permissions Bob          # Open Bob's permission form
        ```
  
        **What you can restrict per-player:**
        - **OOC Messaging → "no"** - Block their direct messages (pages, tells)
        - **IC Messaging → "no"** - Block their IC messages (whispers)
        - **Channel Muting → "muted"** - Hide their channel messages
        - **Lead/Follow → "no"** - Block them from following you
        - **Dress/Style → "no"** - Block them from dressing/styling you
        - **Visibility → "never"** - Hide from their where list
  
        **Removing restrictions:**
        Set any field back to **"generic"** to use your default setting, or to **"yes"** to explicitly allow.
  
        **Ending a friendship:**
        Use per-player permissions to revoke all access — set each field to "no" or use the relationship options in the form.
  
        ---
  
        ## Permission Checking Flow
  
        **How the system checks permissions:**
  
        ### User Permission Check
        1. Look for **specific permission** for target player
        2. If specific value is "generic" or missing, use **generic default**
        3. Return the resolved value
  
        ### Interaction Permission Check (follow, dress, etc.)
        1. Check **permanent permission** (Relationship.can_follow, etc.)
        2. If not found, check **temporary permission** (Redis, 1-hour TTL)
        3. If room-scoped, check Redis with room ID
        4. If no permission, trigger **quickmenu consent request**
  
        ### Content Consent Check
        1. Check both players' **base consents** (ContentConsent)
        2. If both consent, allow
        3. If one/both don't consent, check **per-player overrides** (ConsentOverride)
        4. If mutual override exists, allow
        5. Otherwise, deny
  
        ---
  
        ## Common Use Cases
  
        ### Setting Restrictive Defaults
  
        **"I don't want random players following me or messaging me OOC"**
  
        1. `permissions general`
        2. Set OOC messaging: "no"
        3. Set lead/follow: "no"
        4. Set dress/style: "no"
        5. Submit
  
        Result: Only players you explicitly allow can interact.
  
        ### Allowing Trusted Friends
  
        **"I want my RP partner to have full access"**
  
        1. `permissions BestFriend`
        2. Set all fields to "yes" (or "generic" if your defaults are permissive)
        3. Grant permanent interaction permissions (via quickmenu when they try actions)
        4. Optionally: Grant content consent overrides for mature themes
  
        ### Restricting an Annoying Player
  
        **"This player won't stop messaging me"**
  
        1. `permissions AnnoyingPlayer`
        2. Set OOC messaging to "no"
        3. Set IC messaging to "no"
        4. Optionally: Set all fields to "no" for complete restriction
  
        ### Managing Mature RP
  
        **"I want to RP mature content with specific partners only"**
  
        1. `permissions consent` - DON'T check MATURE
        2. Via admin/consent UI: Create ConsentOverride for TrustedPartner
        3. TrustedPartner does the same for you
        4. Result: Mature RP allowed with TrustedPartner, blocked with others
  
        ### Checking Room Consent
  
        **"Can we RP violent combat here?"**
  
        1. Wait for room to be stable (10 minutes)
        2. `consent room`
        3. Check if VIOLENCE appears in allowed list
        4. If yes, all present players consent to violence
        5. If no, at least one player doesn't consent
  
        ---
  
        ## Privacy & Safety
  
        **What others can see:**
        - Your **where visibility** setting affects their where list
        - Your **consent room** contributions (after 10-minute timer)
        - Whether you've **blocked them** (they see errors when trying to interact)
  
        **What others can't see:**
        - Your **individual consent settings** (unless mutual)
        - Your **generic permission defaults**
        - Who you've **blocked** (only that they're blocked, not specifics)
        - Your **relationship statuses** with others
  
        **Staff access:**
        - Admins can view all permissions for moderation
        - Consent data visible to resolve disputes
        - Block logs tracked for abuse prevention
  
        ---
  
        ## Technical Details
  
        ### Redis Permissions
  
        **Key format:**
        ```
        permission:<type>:<grantee_id>:<granter_id>[:<room_id>]
        ```
  
        **Example:**
        - `permission:follow:123:456` - User 123 can follow user 456 (1-hour TTL)
        - `permission:follow:123:456:789` - Same, but only in room 789
  
        **Automatic cleanup:**
        - Redis keys expire after 1 hour (TTL)
        - Room-scoped keys cleared on room exit
        - Scheduler periodically cleans stale keys
  
        ### Room Consent Cache
  
        **RoomConsentCache model:**
        - Tracks `occupancy_changed_at` (when last person entered/left)
        - Stores `character_count` (expected occupancy)
        - Caches `allowed_codes` (intersection of all consents)
        - Recalculated if stale (occupancy changed)
  
        **Display ready check:**
        ```ruby
        Time.now - occupancy_changed_at >= 600 # 10 minutes
        ```
  
        **Intersection calculation:**
        1. Get each character's consented restriction IDs
        2. Calculate intersection (codes ALL consent to)
        3. Return ContentRestriction codes for those IDs
  
        ---
  
        ## Tips & Best Practices
  
        **For new players:**
        - Set generic defaults to what you're comfortable with
        - Use quickmenu consents to grant one-time permissions
        - Check `consent room` before starting mature RP
  
        **For privacy-conscious players:**
        - Set visibility to "never" to stay off where lists
        - Set OOC messaging to "no" or "ask"
        - Use perception blocks for complete privacy
  
        **For RP partners:**
        - Grant permanent permissions for frequent partners
        - Use content overrides for trusted partners
        - Communicate OOC about consent boundaries
  
        **For GMs/event hosts:**
        - Check room consent before planning event themes
        - Wait 10 minutes for stable occupancy
        - Communicate content expectations in event descriptions
  
        ---
  
        ## Troubleshooting
  
        **"Someone can't follow me, but I want to allow it"**
        - They need to request permission (via quickmenu)
        - OR grant them permanent permission via relationship
        - OR adjust your generic lead/follow setting to "yes"
  
        **"I can't see consent room info"**
        - Room occupancy must be stable for 10 minutes
        - If someone enters/leaves, timer resets
        - Wait for stable period
  
        **"My restriction isn't working"**
        - Check each field individually via `permissions <name>`
        - Ensure the specific override isn't set to "generic" (which falls back to your default)
        - Set fields to "no" explicitly if your default is "yes"
  
        **"My permission override isn't working"**
        - Specific override must not be "generic"
        - Check generic default isn't overriding specific
        - Use `permissions <name>` to verify settings
      GUIDE
      description: "Granular control over player interactions. Set defaults that apply to everyone, then override per-player. All restrictions (messaging, following, visibility) are managed through per-player permission overrides. Content consent settings manage mature themes. Three permission tiers: permanent database permissions, temporary session-scoped permissions, and one-time consent requests. The 'consent room' command shows what all players in a room consent to.",
      command_names: %w[permissions],
      related_systems: %w[roleplaying communication],
      key_files: [
        'app/services/interaction_permission_service.rb',
        'app/services/content_consent_service.rb',
        'app/models/user_permission.rb',
        'app/models/content_consent.rb',
        'app/models/content_restriction.rb',
        'app/models/consent_override.rb',
        'app/models/relationship.rb',
        'app/models/room_consent_cache.rb',
        'plugins/core/social/commands/permissions.rb',
        'plugins/core/social/commands/consent.rb'
      ],
      staff_notes: <<~'NOTES',
        # Permissions & Consent - Staff Notes
  
        ## Architecture Overview
  
        The permissions system comprises three independent subsystems:
  
        1. **UserPermission** - Generic defaults + per-player overrides for visibility, messaging, social preferences
        2. **InteractionPermissionService** - Three-tier system for physical interactions (permanent DB, temporary Redis, one-time quickmenu)
        3. **ContentConsentService** - Mature theme consent with 10-minute room stability timer
  
        ---
  
        ## UserPermission System
  
        ### Model Structure
  
        **UserPermission model:**
        - Each user has ONE "generic" row (`target_user_id = nil`) with actual default values
        - Can have MANY "specific" rows (one per target user) with per-player overrides
        - Specific rows default all fields to `'generic'` (meaning "use my generic setting")
  
        **Generic row example:**
        ```ruby
        UserPermission.create(
          user_id: 123,
          target_user_id: nil,  # Generic!
          visibility: 'default',
          ooc_messaging: 'yes',
          ic_messaging: 'yes',
          lead_follow: 'yes',
          dress_style: 'yes',
          channel_muting: 'yes',
          group_preference: 'neutral'
        )
        ```
  
        **Specific row example:**
        ```ruby
        UserPermission.create(
          user_id: 123,
          target_user_id: 456,  # Specific override for user 456
          visibility: 'generic',     # Uses generic default
          ooc_messaging: 'no',       # Override: block this user
          ic_messaging: 'generic',   # Uses generic default
          # ... rest default to 'generic'
        )
        ```
  
        ### Permission Resolution
  
        **effective_value algorithm:**
        ```ruby
        def self.effective_value(user, target_user, field, default:)
          1. Find specific permission for (user, target_user)
          2. If found and field value != 'generic':
               return specific value
          3. Find generic permission for user (target_user_id = nil)
          4. If found:
               return generic field value
          5. Return default
        end
        ```
  
        **Example resolution:**
        ```
        User 123's generic ooc_messaging: 'yes'
        User 123's specific override for user 456: 'no'
        User 123's specific override for user 789: 'generic'
  
        effective_value(123, 456, :ooc_messaging)
          → 'no' (specific override)
  
        effective_value(123, 789, :ooc_messaging)
          → 'yes' (specific is 'generic', falls back to generic default)
  
        effective_value(123, 999, :ooc_messaging)
          → 'yes' (no specific row, uses generic default)
        ```
  
        ### Permission Fields
  
        **VISIBILITY_VALUES:** `[generic, default, never, favorite, always]`
        - Controls where list visibility
        - Interacts with locatability setting
  
        **OOC_VALUES:** `[generic, yes, no, ask]`
        - OOC messaging permission (pages, tells)
        - `ask` triggers consent quickmenu
  
        **IC_VALUES:** `[generic, yes, no]`
        - IC messaging permission (whispers, etc.)
  
        **LEAD_FOLLOW_VALUES:** `[generic, yes, no]`
        - Lead/follow command permission
        - Feeds into InteractionPermissionService
  
        **DRESS_STYLE_VALUES:** `[generic, yes, no]`
        - Dress, tattoo, piercing, style commands
        - Feeds into InteractionPermissionService
  
        **CHANNEL_VALUES:** `[generic, yes, muted]`
        - Channel message visibility per-sender
        - `muted` hides their messages in channels
  
        **GROUP_VALUES:** `[generic, favored, neutral, disfavored]`
        - Preference for automated systems (matchmaking, etc.)
  
        ### Database Schema
  
        ```sql
        user_permissions (
          id,
          user_id,                  -- Owner of these permission settings
          target_user_id,           -- NULL for generic, user ID for specific
          display_character_id,     -- Character shown in UI for this user
          visibility,
          ooc_messaging,
          ic_messaging,
          lead_follow,
          dress_style,
          channel_muting,
          group_preference,
          content_consents (JSONB)  -- Per-player content consent overrides
        )
  
        UNIQUE INDEX: (user_id, target_user_id)
        ```
  
        ---
  
        ## InteractionPermissionService (Three-Tier)
  
        ### Architecture
  
        **Tier 1: Permanent Permissions (Database)**
  
        Stored in `Relationship` model:
        ```ruby
        relationships (
          id,
          character_id,        -- Who has permission
          target_character_id, -- Who grants permission
          can_follow,          -- Boolean
          can_dress,           -- Boolean
          can_undress,         -- Boolean
          can_interact,        -- Boolean
          status (pending|accepted|blocked|unfriended)
        )
        ```
  
        **Permission check:**
        ```ruby
        def has_permanent_permission?(actor, target, permission_type)
          rel = Relationship.between(actor.character, target.character)
          return false unless rel && rel.accepted?
  
          field = permission_field(permission_type)
          rel.send(field) == true
        end
        ```
  
        **Tier 2: Temporary Permissions (Redis)**
  
        **Redis key format:**
        ```
        permission:<type>:<grantee_id>:<granter_id>[:<room_id>]
        ```
  
        **Examples:**
        ```
        permission:follow:123:456          # User 123 can follow 456 (1-hour TTL)
        permission:dress:123:456:789       # User 123 can dress 456, only in room 789
        permission:interact:123:456        # General interaction permission
        ```
  
        **Grant temporary permission:**
        ```ruby
        def grant_temporary_permission(granter, grantee, permission_type, room_id: nil, ttl: 3600)
          key = "permission:#{permission_type}:#{grantee.id}:#{granter.id}"
          key += ":#{room_id}" if room_id
  
          REDIS_POOL.with { |redis| redis.setex(key, ttl, 'granted') }
        end
        ```
  
        **Automatic cleanup:**
        - Redis TTL expires after 1 hour
        - Room-scoped permissions cleared on `clear_temporary_permissions(room_id: X)`
        - Called when character leaves room
  
        **Tier 3: One-Time Consent (Quickmenu)**
  
        **Flow:**
        1. Actor attempts action (e.g., `follow Bob`)
        2. System checks `has_permission?(actor, target, 'follow')`
        3. If no permission (tiers 1&2), show quickmenu to actor:
           - "Request permission to follow Bob?"
           - Options: Ask, Cancel
        4. If actor selects "Ask", show quickmenu to target:
           - "Alice wants to follow you. Allow?"
           - Options: Allow Once, Allow Always, Deny
        5. Handle response:
           - **Allow Once** → `grant_temporary_permission(..., room_id: current_room_id)`
           - **Allow Always** → `grant_permanent_permission(...)`
           - **Deny** → No permission granted
  
        ### Permission Check Algorithm
  
        ```ruby
        def has_permission?(actor, target, permission_type, room_scoped: false)
          # Tier 1: Permanent
          return true if has_permanent_permission?(actor, target, permission_type)
  
          # Tier 2: Temporary
          has_temporary_permission?(actor, target, permission_type,
                                     room_scoped: room_scoped,
                                     room_id: actor.current_room_id)
        end
  
        def has_temporary_permission?(actor, target, permission_type, room_scoped:, room_id:)
          key = redis_key(actor, target, permission_type, room_scoped ? room_id : nil)
  
          REDIS_POOL.with do |redis|
            redis.get(key) == 'granted'
          end
        end
        ```
  
        ### Permission Types
  
        **PERMISSION_TYPES:** `[follow, dress, undress, interact]`
  
        **Mapping to Relationship fields:**
        ```ruby
        def permission_field(permission_type)
          case permission_type
          when 'follow' then :can_follow
          when 'dress' then :can_dress
          when 'undress' then :can_undress
          when 'interact' then :can_interact
          else nil
          end
        end
        ```
  
        ---
  
        ## Content Consent System
  
        ### Models
  
        **ContentRestriction:**
        ```ruby
        content_restrictions (
          id,
          universe_id,
          name,                        # Display name
          code,                        # UPPERCASE code (VIOLENCE, MATURE, etc.)
          description,
          requires_mutual_consent,     # Boolean (default true)
          is_active
        )
        ```
  
        **ContentConsent:**
        ```ruby
        content_consents (
          id,
          character_id,
          content_restriction_id,
          consented,                   # Boolean
          consented_at
        )
        UNIQUE INDEX: (character_id, content_restriction_id)
        ```
  
        **ConsentOverride:**
        ```ruby
        consent_overrides (
          id,
          character_id,                # Who grants override
          target_character_id,         # Specific player
          content_restriction_id,
          allowed,                     # Boolean
          granted_at,
          revoked_at
        )
        UNIQUE INDEX: (character_id, target_character_id, content_restriction_id)
        ```
  
        ### Consent Checking Algorithm
  
        **Between two characters:**
        ```ruby
        def content_allowed_between?(char1, char2, restriction)
          # 1. Check base consents
          if ContentConsent.mutual_consent?(char1, char2, restriction)
            return true
          end
  
          # 2. Check mutual overrides
          if restriction.mutual?
            ConsentOverride.mutual_override?(char1, char2, restriction)
          else
            # Non-mutual: both still need to allow it
            consent1 = char_consents_to?(char1, restriction) ||
                       ConsentOverride.has_override?(char1, char2, restriction)
            consent2 = char_consents_to?(char2, restriction) ||
                       ConsentOverride.has_override?(char2, char1, restriction)
            consent1 && consent2
          end
        end
        ```
  
        **Room consent (intersection):**
        ```ruby
        def allowed_for_room(room)
          char_instances = room.characters_here.where(online: true).all
          character_ids = char_instances.map(&:character_id)
  
          ContentConsent.room_allowed_codes(character_ids)
        end
  
        # In ContentConsent model:
        def self.room_allowed_codes(character_ids)
          # Get each character's consented restriction IDs
          codes_per_char = character_ids.map do |char_id|
            where(character_id: char_id, consented: true)
              .select_map(:content_restriction_id)
          end
  
          # Intersection of all
          common_restriction_ids = codes_per_char.reduce(:&) || []
  
          ContentRestriction.where(id: common_restriction_ids, is_active: true)
                            .select_map(:code)
        end
        ```
  
        ### 10-Minute Room Stability Timer
  
        **RoomConsentCache model:**
        ```ruby
        room_consent_caches (
          id,
          room_id,
          occupancy_changed_at,        # Last enter/exit timestamp
          character_count,             # Expected count
          allowed_codes (JSONB),       # Cached intersection
          UNIQUE INDEX: room_id
        )
        ```
  
        **Display ready check:**
        ```ruby
        def display_ready?(room)
          cache = RoomConsentCache.for_room(room)
          current_count = room.characters_here.where(online: true).count
  
          # Occupancy must match cached count
          return false if cache.character_count != current_count
  
          # 10 minutes must have elapsed
          cache.display_ready?
        end
  
        # In RoomConsentCache:
        def display_ready?
          return false unless occupancy_changed_at
          Time.now - occupancy_changed_at >= DISPLAY_TIMER_SECONDS
        end
        ```
  
        **Resetting the timer:**
        ```ruby
        def reset_room_timer(room)
          cache = RoomConsentCache.for_room(room)
          char_count = room.characters_here.where(online: true).count
  
          cache.update(
            occupancy_changed_at: Time.now,
            character_count: char_count,
            allowed_codes: Sequel.pg_jsonb([])  # Clear cached codes
          )
  
          # Reset display trigger for all characters
          CharacterInstance
            .where(current_room_id: room.id, online: true)
            .update(consent_display_triggered: false)
        end
        ```
  
        **When timer resets:**
        - `ContentConsentService.on_room_entry(character_instance, room)` - Called when character enters
        - `ContentConsentService.on_room_exit(room)` - Called when character exits
        - Both trigger `reset_room_timer(room)`
  
        **Displaying consent info:**
        ```ruby
        def consent_display_for_room(room)
          return nil unless display_ready?(room)
  
          cache = RoomConsentCache.for_room(room)
          current_count = room.characters_here.where(online: true).count
  
          # Recalculate if stale
          if cache.stale?(current_count)
            allowed = allowed_for_room(room)
            cache.update(
              allowed_codes: Sequel.pg_jsonb(allowed),
              character_count: current_count
            )
          end
  
          {
            allowed_content: cache.allowed_content_codes,
            stable_since: cache.occupancy_changed_at,
            character_count: cache.character_count
          }
        end
        ```
  
        ---
  
        ## Relationship Model (Restrictions & Permanent Permissions)
  
        ### Model Structure
  
        ```ruby
        relationships (
          id,
          character_id,
          target_character_id,
          status (pending|accepted|blocked|unfriended),
  
          # Permanent interaction permissions
          can_follow,
          can_dress,
          can_undress,
          can_interact,
  
          # Granular blocking
          block_dm,
          block_ooc,
          block_channels,
          block_interaction,
          block_perception
        )
        UNIQUE INDEX: (character_id, target_character_id)
        ```
  
        ### Status Lifecycle
  
        - **pending** - Friendship request sent, awaiting acceptance
        - **accepted** - Active friendship
        - **blocked** - Legacy status (deprecated — use per-player permission overrides instead)
        - **unfriended** - Legacy status (deprecated — use per-player permission overrides instead)
  
        ### Restriction Fields (Legacy)
  
        The Relationship model still has granular block fields for backward compatibility,
        but all restriction management should go through UserPermission per-player overrides:
  
        - **block_dm** → use `ooc_messaging: 'no'` per-player override instead
        - **block_ooc** → use `ooc_messaging: 'no'` per-player override instead
        - **block_channels** → use `channel_muting: 'muted'` per-player override instead
        - **block_interaction** → use `lead_follow: 'no'` + `dress_style: 'no'` instead
        - **block_perception** → not yet in UserPermission, still uses Relationship field
  
        ### Permission Granting
  
        **Grant permanent interaction permission:**
        ```ruby
        InteractionPermissionService.grant_permanent_permission(
          granter_character,  # Who grants (target)
          grantee_character,  # Who receives (actor)
          'follow'            # Permission type
        )
  
        # Implementation:
        rel = Relationship.find_or_create_between(grantee, granter)
        field = :can_follow
        rel.update(status: 'accepted', field => true)
        ```
  
        ---
  
        ## Command Integration
  
        ### permissions.rb Command
  
        **Main entry points:**
        ```ruby
        permissions              # show_permissions_menu (quickmenu)
        permissions general      # show_generic_permissions (form)
        permissions Bob          # show_character_permissions(Bob)
        permissions blocks       # manage_blocks
        permissions consent      # manage_consent
        ```
  
        **Alias routing (deprecated aliases — use `permissions <name>` instead):**
        ```ruby
        block Bob                # manage_blocks(['Bob']) — deprecated, use permissions Bob
        unblock Bob              # manage_unblock(['Bob']) — deprecated, use permissions Bob
        unfriend Bob             # manage_unfriend('Bob') — deprecated, use permissions Bob
        consent                  # manage_consent([])
        ```
  
        **Form rendering:**
        ```ruby
        def show_permission_form(perm, title)
          is_generic = perm.generic?
  
          fields = [
            {
              name: 'visibility',
              label: 'Where Visibility',
              type: 'select',
              default: perm.visibility || 'generic',
              options: build_options(is_generic, [...]),
              description: '...'
            },
            # ... more fields
          ]
  
          create_form(character_instance, title, fields,
                      context: { command: 'permissions', ... })
        end
        ```
  
        **Option builder:**
        ```ruby
        def build_options(is_generic, base_options)
          if is_generic
            base_options  # No 'generic' option for generic row
          else
            [{ value: 'generic', label: 'Generic (use default)' }] + base_options
          end
        end
        ```
  
        ---
  
        ## Integration Points
  
        **Movement system:**
        - Calls `ContentConsentService.on_room_exit(old_room)` when leaving
        - Calls `ContentConsentService.on_room_entry(char_instance, new_room)` when entering
        - Clears room-scoped temporary permissions
  
        **Follow command:**
        - Checks `InteractionPermissionService.has_permission?(actor, target, 'follow')`
        - If false, shows quickmenu consent request
  
        **Dress command:**
        - Checks `InteractionPermissionService.has_permission?(actor, target, 'dress')`
        - If false, shows quickmenu consent request
  
        **OOC messaging (pages, tells):**
        - Checks `UserPermission.ooc_permission(sender_user, target_user)`
        - If 'no', blocks message
        - If 'ask', shows consent quickmenu
  
        **Where command:**
        - Filters list via `UserPermission.can_see_in_where?(viewer_user, target_user, target_locatability)`
        - Respects visibility settings
  
        **Channel messages:**
        - Filters via `UserPermission.channel_visible?(viewer_user, sender_user)`
        - Hides messages from muted senders
  
        ---
  
        ## Testing Considerations
  
        **UserPermission:**
        - Test generic/specific resolution
        - Test 'generic' fallback on specific rows
        - Test default values when no permission exists
  
        **InteractionPermissionService:**
        - Test three-tier priority (permanent > temporary > none)
        - Test room-scoped temporary permissions
        - Test Redis cleanup on room exit
        - Test TTL expiry (mock Time.now)
  
        **ContentConsentService:**
        - Test mutual consent requirement
        - Test per-player overrides
        - Test room intersection calculation
        - Test 10-minute timer logic
        - Test occupancy change resets
  
        **Relationship restrictions (legacy):**
        - Test granular block fields (backward compatibility)
        - Test per-player permission overrides take precedence
        - Test deprecated block/unfriend commands still work via aliases
  
        ---
  
        ## Performance Considerations
  
        **UserPermission queries:**
        - Index on `(user_id, target_user_id)` for fast lookups
        - Cache generic permissions in memory for frequent checks
        - Avoid N+1 queries when filtering where lists
  
        **Redis permissions:**
        - Use connection pooling (REDIS_POOL)
        - Batch delete on room exit (collect keys, del(*keys))
        - Monitor TTL expirations
  
        **RoomConsentCache:**
        - Cache intersection results to avoid recalculation
        - Update cache only when stale (occupancy changed)
        - Clean up caches for empty rooms (scheduler)
  
        **ContentConsent queries:**
        - Eager load content_restrictions when displaying forms
        - Cache restriction codes per-character
        - Batch check mutual consents (single query for multiple pairs)
  
        ---
  
        ## Future Enhancements
  
        **Permission templates:**
        - Save/load permission presets ("Restrictive", "Permissive", "Friends Only")
        - Apply templates to generic or specific permissions
  
        **Consent negotiation UI:**
        - Visual consent matrix (Alice vs Bob for each content type)
        - Bulk consent operations ("Allow all with RP partner")
  
        **Advanced blocking:**
        - Temporary blocks (expire after X hours)
        - Block reasons (logged for moderation)
        - Mutual blocks (both parties block each other)
  
        **Analytics:**
        - Track consent request frequency
        - Identify harassment patterns (repeated denials)
        - Monitor block escalation (DM → perception)
      NOTES
      display_order: 100
    },
    {
      name: 'character_customization',
      display_name: 'Character Customization',
      summary: 'Appearance, descriptions, names, piercings, tattoos, and profiles',
      player_guide: <<~'GUIDE',
        # Character Customization - Player Guide
  
        Firefly lets you fully customize your character's identity, appearance, and personality through multiple systems. Define your name, physical appearance, personality traits, and visual styling.
  
        ---
  
        ## Quick Commands
  
        ```
        describe                 # Open description editor (appearance, short desc, room title, color, picture)
        roomtitle <text>         # Set status/pose text (e.g., "looking tired")
        color                    # View/change your name color
        ```
  
        ---
  
        ## Character Names & Identity
  
        ### Changing Your Name
  
        ```
        change name              # Request name change
        ```
  
        **Rules:**
        - Names may have a cooldown period between changes (set by admins)
        - Some universes restrict certain name formats
        - Staff must approve name changes in some games
        - Your full name includes forename + surname
  
        **Handles/Nicknames:**
        Some settings support **IC handles** (street names, aliases, codenames). Set via admin interface or special commands.
  
        ---
  
        ## Appearance Customization
  
        ### The Describe Modal
  
        All character customization is handled through the **describe** command, which opens a modal editor:
  
        ```
        describe                 # Open the description editor
        ```
  
        **The describe modal includes:**
        - **Short description** (300 chars max) — blurb shown in room descriptions (e.g., "A weathered soldier with a scarred face")
        - **Room title** (200 chars max) — current pose/status appended to your name (e.g., "looking exhausted")
        - **Name color** — hex color code applied to your name in chat and rooms
        - **Profile picture** — URL to an externally hosted image
        - **Detailed body descriptions** — per-body-part appearance with aesthetic types
  
        ### Room Title Command
  
        You can also update your room title directly without opening the full editor:
  
        ```
        roomtitle leaning against the wall
        roomtitle clear          # Remove room title
        ```
  
        ### Name Color
  
        - Hex color code (e.g., #FF5733)
        - Applied to your name in chat, room descriptions, etc.
        - Use `color` command to preview
        - Access the gradient creator through the UI button in the webclient
  
        ---
  
        ## Detailed Physical Descriptions
  
        The describe modal lets you edit detailed descriptions for individual body parts. It supports multiple aesthetic types: **natural**, **tattoo**, **makeup**, **hairstyle**. Descriptions combine when someone looks at you.
  
        **Body positions:**
        - **Head region:** scalp, left_temple, right_temple, left_ear, right_ear, forehead, left_eyebrow, right_eyebrow, left_eye, right_eye, nose, mouth, left_cheek, right_cheek, chin, jaw
        - **Torso region:** throat, chest, navel, left_pec, right_pec, back, left_shoulder_blade, right_shoulder_blade
        - **Arms region:** left_shoulder, right_shoulder, left_upper_arm, right_upper_arm, left_elbow, right_elbow, left_forearm, right_forearm
        - **Hands region:** left_wrist, right_wrist, left_palm, right_palm, left_hand, right_hand, fingernails
        - **Legs region:** hips, left_buttock, right_buttock, groin, left_thigh, right_thigh, left_knee, right_knee, left_shin, right_shin, left_calf, right_calf, left_ankle, right_ankle
        - **Feet region:** left_foot, right_foot, toenails
  
        **Aesthetic types:**
  
        **1. Natural (default body descriptions)**
        ```
        Example: "Dark brown eyes with flecks of gold"
        ```
        - Basic physical appearance
        - Can describe any body position
        - Prefix options: "He/She has", "He/She is", "And", none
        - Suffix options: period, comma, space, newline, double_newline
  
        **2. Tattoo**
        ```
        Example: "A coiling dragon that spans from shoulder to wrist"
        ```
        - Can span multiple body positions
        - Example: Tattoo across left_shoulder + left_upper_arm + left_forearm
        - Visible description layers on top of natural
  
        **3. Makeup** (restricted to face positions)
        ```
        Example: "Dark smoky eyeshadow that accentuates the eyes"
        ```
        - Limited to: left_eye, right_eye, mouth, left_cheek, right_cheek, forehead, chin, jaw
        - Temporary aesthetic (can be removed/changed)
        - Adds to natural descriptions
  
        **4. Hairstyle** (restricted to scalp)
        ```
        Example: "Long hair pulled back in a tight braid"
        ```
        - Only applies to scalp position
        - Overrides natural scalp description when set
        - Can be changed frequently
  
        **Display formatting:**
        - **Prefix:** How description starts ("She has", "She is", "And", or none)
        - **Suffix:** How description ends (period, comma, space, newline, etc.)
        - Used to chain descriptions naturally: "She has dark hair. She is tall. And her eyes are piercing blue."
  
        ---
  
        ## Body Modifications
  
        ### Piercings
  
        ```
        pierce                   # Open piercing menu
        ```
  
        **How it works:**
        - Piercings are **items** at specific body positions
        - Example: "silver hoop" at left_ear
        - Visible when someone examines you
        - Can be removed like any item
  
        **Piercing commands:**
        - `pierce` - View/add piercings
        - Requires piercing item in inventory
        - Choose body position for placement
  
        ### Tattoos
  
        ```
        tattoo                   # Open tattoo menu
        ```
  
        **How tattoos differ from piercing:**
        - Tattoos are **descriptions**, not items
        - Created via `describe` command with aesthetic_type: tattoo
        - Permanent (can't be removed without special process)
        - Can span multiple body positions
  
        **Creating a tattoo:**
        1. `describe`
        2. Choose body positions (e.g., left_shoulder, left_upper_arm)
        3. Set aesthetic_type: **tattoo**
        4. Write description: "A coiling dragon..."
        5. Submit
  
        **Example multi-position tattoo:**
        - Positions: left_shoulder, left_upper_arm, left_forearm, left_wrist, left_hand
        - Description: "An intricate vine pattern that winds down the entire left arm"
  
        ### Makeup & Styling
  
        **Makeup command:**
        ```
        makeup                   # Open makeup menu
        ```
  
        Creates descriptions with aesthetic_type: **makeup** for face positions only.
  
        **Styling command:**
        ```
        style                    # Open styling menu
        ```
  
        Creates descriptions with aesthetic_type: **hairstyle** for scalp position.
  
        **Temporary vs permanent:**
        - **Makeup** and **hairstyle** are considered temporary aesthetics
        - Can be changed frequently without restrictions
        - **Tattoos** and **natural** descriptions are permanent
  
        ---
  
        ## Visual Enhancements
  
        ### Color Gradients
  
        Color gradients let you apply multi-color effects to text. Access the **gradient creator** through the UI button in the webclient toolbar.
  
        **How it works:**
        - Interpolates between start and end colors
        - Each letter gets a progressively different color
        - Supports RGB interpolation and CIEDE2000 (perceptually uniform, smoother transitions)
  
        ---
  
        ## Character Stats & Scores
  
        **View your stats:**
        ```
        stats                    # Show your character's stats
        score                    # Show your overall character sheet
        ```
  
        **Stat allocation:**
        Some games allow you to allocate stat points at character creation or level-up. This is handled via:
        - Character creation forms
        - Stat allocation command (if enabled)
        - Staff commands (for adjustments)
  
        **Common stats:**
        - **STR** - Strength
        - **DEX** - Dexterity
        - **CON** - Constitution
        - **INT** - Intelligence
        - **WIS** - Wisdom
        - **CHA** - Charisma
  
        *(Actual stats vary by game/universe)*
  
        ---
  
        ## Profile & Web Interface
  
        **Profile picture:** Set via the describe modal or web interface.
  
        **What shows on your profile:**
        - Full name
        - Profile picture
        - Short description
        - Detailed descriptions (when others look at you)
        - Stats and abilities (if public)
        - Character history (if you've written one)
  
        **Privacy settings:**
        Some games let you control what appears on your public profile via privacy settings.
  
        ---
  
        ## Description Display Example
  
        **When someone uses `look Alice`:**
  
        ```
        Alice, a weathered soldier with dark hair, stands here looking exhausted.
  
        She is about 5'8" tall with a lean, muscular build.
  
        Dark brown hair falls to her shoulders in messy waves. Her eyes are a piercing
        blue-green that seem to assess everything around her. A jagged scar runs from
        her left temple down to her cheekbone.
  
        A coiling dragon tattoo winds up her left arm from wrist to shoulder, rendered
        in black ink with crimson accents.
  
        Dark smoky eyeshadow accentuates her eyes.
        ```
  
        **How this was built:**
        1. **Short description:** "a weathered soldier with dark hair" (via describe modal)
        2. **Room title:** "looking exhausted" (via describe modal or `roomtitle` command)
        3. **Natural descriptions:**
           - scalp: "Dark brown hair falls to her shoulders in messy waves."
           - left_eye + right_eye: "Her eyes are a piercing blue-green..."
           - left_temple: "A jagged scar runs from her left temple down to her cheekbone."
        4. **Tattoo description:** Dragon tattoo (aesthetic_type: tattoo, spans left_wrist to left_shoulder)
        5. **Makeup description:** Eyeshadow (aesthetic_type: makeup, positions: left_eye, right_eye)
  
        ---
  
        ## Tips & Best Practices
  
        **For new players:**
        - Start with a simple short description
        - Add detailed descriptions gradually
        - Use room titles to show current mood/pose
  
        **For appearance:**
        - Keep short description under 100 chars (shown in room)
        - Use detailed descriptions for when people examine you
        - Update room title frequently for dynamic RP
  
        **For tattoos:**
        - Plan multi-position tattoos before creating
        - Describe flow/movement across positions
        - Consider how it looks from different angles
  
        **For colors:**
        - Use the gradient creator button in the webclient toolbar
        - Use hex color picker tools to find good colors
        - Avoid eye-straining colors (super bright, low contrast)
  
        **For profile:**
        - Host profile pictures externally (Imgur, personal site, etc.)
        - Keep image files under 2MB for fast loading
        - Use square aspect ratio for best display (1:1)
      GUIDE
      description: "Customize your character's identity and appearance. Change your name, set a handle/nickname, upload a profile picture, and edit descriptions. The describe modal handles short descriptions, room titles, name color, profile picture, and detailed body descriptions. Body modifications include piercings and tattoos. Color gradients are available via the webclient UI. Character stats and score tracking round out your character's mechanical identity.",
      command_names: ['change name', 'describe', 'roomtitle', 'pierce', 'tattoo', 'style', 'makeup'],
      related_systems: %w[items_economy roleplaying],
      key_files: [
        'app/models/character.rb',
        'app/models/character_instance.rb',
        'app/models/character_description.rb',
        'app/models/character_default_description.rb',
        'app/models/character_stat.rb',
        'app/services/character_display_service.rb',
        'app/services/description_copy_service.rb',
        'app/services/stat_allocation_service.rb',
        'app/services/gradient_service.rb',
        'plugins/core/customization/commands/describe.rb'
      ],
      staff_notes: <<~'NOTES',
        # Character Customization - Staff Notes
  
        ## Dual-Model Architecture
  
        **Character vs CharacterInstance:**
        - **Character** - Persistent data (name, stats, default descriptions)
        - **CharacterInstance** - Session-specific (current descriptions, room, status)
        - **DescriptionCopyService** - Syncs CharacterDefaultDescription → CharacterDescription on login
  
        ---
  
        ## CharacterDescription Model
  
        **Two description types:**
  
        1. **Profile descriptions** (`description_type_id` set)
           - Personality, background, history, etc.
           - Associated with DescriptionType (e.g., "Personality", "Background")
  
        2. **Body position descriptions** (`body_position_id` or `body_positions` set)
           - Physical appearance at specific body parts
           - Supports multiple positions via join table
           - Four aesthetic types: natural, tattoo, makeup, hairstyle
  
        **Aesthetic types:**
        ```ruby
        AESTHETIC_TYPES = %w[natural tattoo makeup hairstyle]
        ```
  
        **Validation:**
        - Must have either `description_type_id` OR body position(s)
        - Makeup restricted to MAKEUP_POSITIONS (face only)
        - Hairstyle restricted to HAIRSTYLE_POSITIONS (scalp only)
        - Tattoos can span any positions
  
        **Formatting fields:**
        - `prefix` - How description starts (pronoun_has, pronoun_is, and, none)
        - `suffix` - How description ends (period, comma, space, newline, double_newline)
  
        **Multi-position support:**
        ```ruby
        many_to_many :body_positions,
                     join_table: :character_instance_description_positions,
                     left_key: :character_description_id,
                     right_key: :body_position_id
        ```
  
        **Example query:**
        ```ruby
        CharacterDescription
          .where(character_instance_id: instance.id, aesthetic_type: 'tattoo')
          .eager(:body_positions)
          .all
        ```
  
        ---
  
        ## Character Display Service
  
        **Renders full character appearance:**
        ```ruby
        CharacterDisplayService.full_description(character_instance)
        ```
  
        **Process:**
        1. Collect all descriptions for instance
        2. Group by aesthetic type
        3. Render in order:
           - Natural descriptions (by body region)
           - Tattoo descriptions (by position)
           - Makeup descriptions (face only)
           - Hairstyle description (scalp)
        4. Apply prefixes/suffixes for natural flow
  
        **Prefix rendering:**
        ```ruby
        case prefix
        when 'pronoun_has'
          "#{pronoun.capitalize} has #{content}"
        when 'pronoun_is'
          "#{pronoun.capitalize} is #{content}"
        when 'and'
          "And #{content}"
        when 'none'
          content
        end
        ```
  
        ---
  
        ## Gradient Service
  
        **Color interpolation:**
        ```ruby
        GradientService.apply_gradient(text, start_color, end_color, mode: :rgb)
        ```
  
        **Modes:**
        - **:rgb** - Linear RGB interpolation (simple, fast)
        - **:lab** - CIEDE2000 color space (perceptually uniform, smoother)
  
        **RGB algorithm:**
        ```ruby
        def interpolate_rgb(color1, color2, ratio)
          r = color1.r + (color2.r - color1.r) * ratio
          g = color1.g + (color2.g - color1.g) * ratio
          b = color1.b + (color2.b - color1.b) * ratio
          Color.new(r, g, b)
        end
        ```
  
        **LAB algorithm:**
        ```ruby
        def interpolate_lab(color1, color2, ratio)
          lab1 = rgb_to_lab(color1)
          lab2 = rgb_to_lab(color2)
  
          l = lab1.l + (lab2.l - lab1.l) * ratio
          a = lab1.a + (lab2.a - lab1.a) * ratio
          b = lab1.b + (lab2.b - lab1.b) * ratio
  
          lab_to_rgb(LAB.new(l, a, b))
        end
        ```
  
        **Output format:**
        ```html
        <span style="color:#FF0000">H</span>
        <span style="color:#DD0033">e</span>
        <span style="color:#BB0066">l</span>
        ...
        ```
  
        ---
  
        ## Describe Modal (Unified Customization)
  
        The `describe` command opens a modal that handles all character customization:
        - Short description, room title, name color, profile picture
        - Detailed body descriptions with aesthetic types
        - `roomtitle` is also available as a standalone command
  
        **Note:** The `customize` command has been removed. Use `describe` for the full editor
        or `roomtitle` as a standalone command. The `gradient` command is deprecated;
        gradients are accessed via the webclient UI button.
  
        **Validation:**
        - Description max 300 chars
        - Roomtitle max 200 chars
        - Color must be valid hex (#RRGGBB)
        - Picture must be HTTPS URL
  
        ---
  
        ## Describe Command
  
        **Multi-position tattoo creation:**
        ```ruby
        # User selects positions: left_shoulder, left_upper_arm, left_forearm
        # Enters description: "A coiling dragon..."
        # Sets aesthetic_type: tattoo
  
        CharacterDescription.create(
          character_instance_id: instance.id,
          content: "A coiling dragon that winds down the entire left arm",
          aesthetic_type: 'tattoo',
          prefix: 'none',
          suffix: 'period'
        )
  
        # Associate with positions via join table
        desc.add_body_position(BodyPosition.find(name: 'left_shoulder'))
        desc.add_body_position(BodyPosition.find(name: 'left_upper_arm'))
        desc.add_body_position(BodyPosition.find(name: 'left_forearm'))
        ```
  
        **Makeup restrictions:**
        ```ruby
        MAKEUP_POSITIONS = %w[
          left_eye right_eye mouth
          left_cheek right_cheek
          forehead chin jaw
        ]
  
        def validate_positions_for_aesthetic_type
          if aesthetic_type == 'makeup'
            body_positions.each do |pos|
              unless MAKEUP_POSITIONS.include?(pos.name)
                errors.add(:body_positions, "Makeup can only be applied to face positions")
              end
            end
          end
        end
        ```
  
        ---
  
        ## Description Copy Service
  
        **Syncs default descriptions to instance:**
        ```ruby
        DescriptionCopyService.sync_to_instance(character, character_instance)
        ```
  
        **Process:**
        1. Find all CharacterDefaultDescription for character
        2. For each default description:
           - Check if CharacterDescription exists for instance
           - If not, create copy with same content/positions/aesthetic
        3. Called on login to ensure instance has current descriptions
  
        **Why separate models?**
        - CharacterDefaultDescription = permanent record
        - CharacterDescription = session-specific (can be modified in timelines)
        - Allows temporal RP without affecting main character
  
        ---
  
        ## Stat Allocation Service
  
        **Allocate stat points:**
        ```ruby
        StatAllocationService.allocate(character, stat_id, points)
        ```
  
        **Validation:**
        - Check available points
        - Check stat caps
        - Check dependencies (some stats require others)
  
        **CharacterStat model:**
        ```ruby
        character_stats (
          id,
          character_id,
          stat_id,
          base_value,     # Allocated points
          bonus_value,    # Equipment/buffs
          created_at, updated_at
        )
        ```
  
        **Total value calculation:**
        ```ruby
        def total_value
          base_value + (bonus_value || 0)
        end
        ```
  
        ---
  
        ## Body Position Hierarchy
  
        **Regions:**
        ```ruby
        REGIONS = {
          head: %w[scalp left_temple right_temple ...],
          torso: %w[throat chest navel ...],
          arms: %w[left_shoulder right_shoulder ...],
          hands: %w[left_wrist right_wrist ...],
          legs: %w[hips left_thigh right_thigh ...],
          feet: %w[left_foot right_foot toenails]
        }
        ```
  
        **Region determination:**
        ```ruby
        def body_region
          return nil unless body_positions.any?
  
          first_pos = body_positions.first
          REGIONS.each do |region, positions|
            return region if positions.include?(first_pos.name)
          end
          nil
        end
        ```
  
        ---
  
        ## Integration Points
  
        **Look command:**
        - Calls `CharacterDisplayService.full_description(target_instance)`
        - Renders all descriptions in order
        - Applies aesthetic layering (natural → tattoo → makeup → hairstyle)
  
        **Profile page:**
        - Shows profile_picture_url
        - Shows short_description
        - Shows speech_color preview
        - Links to detailed appearance
  
        **Timeline system:**
        - CharacterInstance descriptions independent per timeline
        - DescriptionCopyService syncs on timeline entry
        - Allows historical RP without affecting main character
  
        ---
  
        ## Testing Considerations
  
        **CharacterDescription:**
        - Test multi-position associations
        - Test aesthetic type restrictions (makeup/hairstyle)
        - Test prefix/suffix rendering
  
        **GradientService:**
        - Test RGB interpolation accuracy
        - Test LAB color space conversion
        - Test edge cases (same colors, invalid hex)
  
        **DescriptionCopyService:**
        - Test sync on login
        - Test timeline isolation
        - Test default → instance copying
  
        **Describe modal:**
        - Test validation (max lengths, hex colors, URLs)
        - Test color preview rendering
        - Test roomtitle standalone command
      NOTES
      display_order: 105
    },
    {
      name: 'staff_tools',
      display_name: 'Staff Tools',
      summary: 'NPC control, moderation, scene arrangement, and administrative commands',
      player_guide: <<~'GUIDE',
        # Staff Tools - Guide
  
        *(Staff-only commands)*
  
        Administrative tools for controlling NPCs, managing scenes, viewing world state, and moderating the game.
  
        ---
  
        ## NPC Puppeting
  
        **Take direct control of an NPC:**
        ```
        puppet <npc name>        # Start controlling an NPC
        unpuppet                 # Release control
        puppets                  # List all NPCs you're currently puppeting
        pemote <text>            # Emote as the puppeted NPC
        ```
  
        **How it works:**
        - Puppet an NPC to manually control their actions
        - While puppeting, you can make them say/emote/move
        - NPCs can be puppeted across rooms (staff privilege)
        - Multiple NPCs can be puppeted simultaneously
  
        **Example flow:**
        ```
        > puppet the merchant
        You are now puppeting Gregor the Merchant (in Market Square).
        Use 'pemote <text>' to make them emote, or 'unpuppet' to release control.
  
        > pemote grins and gestures to his wares
        Gregor the Merchant grins and gestures to his wares.
  
        > unpuppet
        You release control of Gregor the Merchant.
        ```
  
        ---
  
        ## NPC Query (AI-Powered)
  
        **Ask questions about NPCs using AI:**
        ```
        npcquery <npc name> <question>
        ```
  
        **Example:**
        ```
        npcquery Gregor What does he think about the upcoming festival?
        ```
  
        The AI analyzes:
        - NPC's personality and background
        - NPC's memories (from NpcMemory system)
        - Recent interactions
        - Faction/reputation data
  
        Returns an in-character response as if asking the NPC directly.
  
        ---
  
        ## World Memory Viewing
  
        **View saved world memories:**
        ```
        viewmemory <id>          # View a specific memory by ID
        searchmemory <query>     # Search memories by content
        ```
  
        **Example:**
        ```
        searchmemory battle
        # Shows: Memories containing "battle"
  
        viewmemory 42
        # Displays full memory record #42
        ```
  
        **What you see:**
        - Memory summary (AI-generated)
        - Involved characters
        - Location
        - Timestamp
        - Original RP log references
  
        ---
  
        ## Reputation Management
  
        **View/modify reputation:**
        ```
        reputation <character> <faction>      # View reputation
        reputation <character> <faction> +10  # Increase by 10
        reputation <character> <faction> -5   # Decrease by 5
        ```
  
        **Example:**
        ```
        reputation Alice Thieves Guild
        # Shows: Alice's reputation with Thieves Guild: 45 (Friendly)
  
        reputation Alice Thieves Guild +10
        # Increases to 55
  
        reputation Bob City Guard -20
        # Decreases by 20 (e.g., for breaking the law)
        ```
  
        **Reputation tiers (typical):**
        - **Hostile** (-100 to -50)
        - **Unfriendly** (-49 to -1)
        - **Neutral** (0 to 24)
        - **Friendly** (25 to 74)
        - **Allied** (75 to 100)
  
        *(Actual tiers vary by game)*
  
        ---
  
        ## Scene Arrangement
  
        **Arrange private meetings between animated NPCs and specific players:**
  
        ```
        arrangescene <npc> for <pc> at <room>           # Same meeting/RP room
        arrangescene <npc> for <pc> meeting <room1> rp <room2>  # Separate rooms
        cancelscene <id>         # Cancel a pending scene
        listscenes               # Show all arranged scenes
        sceneinstructions <id> = <text>  # Seed NPC with instructions
        ```
  
        **What are arranged scenes?**
        - Staff-arranged **one-on-one meetings** between a specific NPC and a specific PC
        - The NPC receives **seeded instructions** that guide their AI behavior during the meeting
        - The PC triggers the scene from a meeting room, both teleport to a private RP room
        - All dialogue is logged via world memory; an AI summary is generated when the scene ends
        - If the NPC isn't online, a temporary instance is spawned for the scene
  
        **Example flow:**
        ```
        > arrangescene Gregor for Alice meeting Reception rp Private Office
        Arranged scene created: Meeting with Gregor (#12)
        Alice has been invited.
  
        > sceneinstructions 12 = Gregor should reveal he knows about the stolen artifact
        Instructions set for scene #12.
  
        [Alice types 'scene' or 'meet' in the Reception room]
        → Both teleport to Private Office
        → Gregor's AI follows the seeded instructions
        → Alice types 'endscene' when done
        → Both return to their original locations
        → Staff receives an AI-generated summary of the meeting
        ```
  
        **Player commands:**
        - `scene` / `meet` — trigger an available arranged scene from the meeting room
        - `endscene` / `leave scene` — end an active scene and return to the meeting room
  
        ---
  
        ## Content Seeding
  
        **Trigger content generation:**
        ```
        seed                     # Trigger content seeding
        ```
  
        Seeds game content like:
        - NPC dialogue prompts
        - Random events
        - World state changes
        - Mission generation
  
        Used to populate the world with dynamic content.
  
        ---
  
        ## Monitoring & Broadcasts
  
        **Monitor game state:**
        ```
        checkall                 # Enable broadcast monitoring
        checkalloff              # Disable broadcast monitoring
        ```
  
        When enabled, you see all broadcasts happening in the game (across all rooms).
  
        **Manual broadcasts:**
        ```
        broadcast <message>      # Broadcast to all players
        ```
  
        Sends a system message to everyone online.
  
        ---
  
        ## Navigation & Utility
  
        **Staff movement:**
        ```
        goto <location>          # Teleport to a location
        staffroom                # Return to staff room
        ```
  
        **goto examples:**
        ```
        goto Town Square
        goto 145                 # Room ID
        goto Bob                 # Teleport to Bob's location
        ```
  
        ---
  
        ## NPC Management
  
        *(Via admin web interface, not commands)*
  
        **NPC features:**
        - **Archetypes** - Templates for NPC behavior (guard, merchant, scholar, etc.)
        - **Schedules** - NPCs move between locations on schedules
        - **Spawning** - Auto-spawn NPCs at specific locations
        - **Combat AI** - AI profiles for NPC combat behavior
  
        **Archetype system:**
        - Defines personality traits
        - Sets default dialogue patterns
        - Configures behavior triggers
        - Associates with faction reputation
  
        **Schedule system:**
        - Time-based movement (e.g., "8am: Go to tavern, 5pm: Go home")
        - Day-of-week patterns
        - Event-triggered schedules
  
        **Combat AI profiles:**
        - Aggression level
        - Preferred abilities
        - Target priority
        - Flee threshold
  
        ---
  
        ## Staff Responsibilities
  
        **As staff, you can:**
        - **Puppet NPCs** to drive stories
        - **Arrange scenes** for private NPC meetings with players
        - **Monitor world memories** for plot hooks
        - **Adjust reputation** for player actions
        - **Query NPCs** for in-character answers
        - **Seed content** to keep the world dynamic
        - **Broadcast** important announcements
        - **Teleport** to help players or investigate issues
  
        **Best practices:**
        - Use puppeting sparingly (let AI drive most NPC behavior)
        - Arrange scenes for important NPC conversations with specific players
        - Check world memories regularly for RP to acknowledge
        - Use reputation as reward/consequence for player actions
        - Seed content during slow periods to encourage activity
  
        ---
  
        ## Tips for Staff
  
        **For NPC puppeting:**
        - Stay in character for the NPC
        - Use NPC's known personality and background
        - Check NPC's memories before puppeting (npcquery)
        - Release control when done (don't leave NPCs puppeted)
  
        **For scene arrangement:**
        - Write clear NPC instructions that guide the conversation naturally
        - Use separate meeting/RP rooms for immersion (PC enters reception, teleports to office)
        - Check scene summaries after completion (listscenes completed)
        - Cancel pending scenes if the player hasn't triggered them
  
        **For content seeding:**
        - Seed during off-peak hours
        - Monitor results (check if NPCs generate dialogue)
        - Balance AI-generated content with staff-crafted stories
  
        **For moderation:**
        - Use checkall sparingly (high volume)
        - Investigate reports promptly
        - Document policy violations
        - Communicate clearly with players
      GUIDE
      description: "Administrative tools for game staff. Puppet NPCs to control them directly, or use pemote to emit as an NPC. Query NPCs using AI. View and search world memories. Manage NPC/faction reputation. Arrange private NPC meetings with specific players using instruction-seeded AI. Monitor broadcasts and trigger content seeding. NPC management includes archetypes, schedules, spawning, and combat AI profiles.",
      command_names: %w[puppet unpuppet puppets pemote npcquery viewmemory searchmemory reputation arrangescene cancelscene listscenes sceneinstructions seed checkall checkalloff broadcast goto staffroom],
      related_systems: %w[world_memory building auto_gm],
      key_files: [
        'plugins/core/staff/commands/puppet.rb',
        'plugins/core/staff/commands/unpuppet.rb',
        'plugins/core/staff/commands/pemote.rb',
        'plugins/core/staff/commands/npcquery.rb',
        'plugins/core/staff/commands/viewmemory.rb',
        'plugins/core/staff/commands/searchmemory.rb',
        'app/services/npc_query_service.rb',
        'app/models/arranged_scene.rb',
        'app/models/npc_archetype.rb',
        'app/models/npc_schedule.rb',
        'plugins/core/staff/commands/reputation.rb',
        'plugins/core/staff/commands/arrangescene.rb',
        'app/services/arranged_scene_service.rb',
        'app/models/npc_spawn_instance.rb',
        'app/services/npc_spawn_service.rb',
        'app/services/combat_ai_service.rb'
      ],
      staff_notes: <<~'NOTES',
        # Staff Tools - Staff Notes
  
        ## Architecture Overview
  
        Staff tools provide administrative control over NPCs, world state, and game monitoring. The system integrates with:
        - **NpcMemory** - AI-powered NPC knowledge
        - **WorldMemory** - RP session summaries
        - **Reputation** - Faction standing
        - **ArrangedScene** - Guided RP events
  
        ---
  
        ## Puppeting System
  
        **CharacterInstance model:**
        ```ruby
        character_instances (
          id,
          character_id,
          puppeting_npc_id,    # ID of NPC being puppeted
          current_room_id,
          online,
          ...
        )
        ```
  
        **Puppeting methods:**
        ```ruby
        def start_puppeting!(npc_instance)
          return { success: false, message: 'Already puppeting' } if puppeting_npc_id
  
          update(puppeting_npc_id: npc_instance.id)
          { success: true }
        end
  
        def stop_puppeting!
          update(puppeting_npc_id: nil)
        end
  
        def puppeting_npc
          return nil unless puppeting_npc_id
          CharacterInstance[puppeting_npc_id]
        end
        ```
  
        **Puppet command flow:**
        ```ruby
        1. Find NPC by name (current room first, then global)
        2. Check if staff member
        3. Call character_instance.start_puppeting!(npc_instance)
        4. Return success with NPC location info
        ```
  
        **Pemote (puppet emote):**
        ```ruby
        def perform_command(parsed_input)
          npc = character_instance.puppeting_npc
          return error unless npc
  
          emote_text = parsed_input[:text]
          # Broadcast as NPC
          broadcast_to_room("#{npc.full_name} #{emote_text}", character: npc)
        end
        ```
  
        **Multi-puppeting support:**
        - Single `puppeting_npc_id` field = one puppet at a time per staff member
        - To support multiple: change to `puppeting_npc_ids` array
        - pemote would need puppet selection (pemote as <npc> <text>)
  
        ---
  
        ## NPC Query Service
  
        **AI-powered NPC interrogation:**
        ```ruby
        NpcQueryService.query(npc, question, asker: staff_character)
        ```
  
        **Process:**
        1. Gather NPC context:
           - Personality and background
           - Recent memories (NpcMemoryService.fetch)
           - Current location and nearby characters
           - Faction relationships
        2. Build prompt:
           ```
           You are {npc.full_name}, a {npc.archetype}.
           Background: {npc.background}
  
           Recent memories:
           {memories}
  
           Question from {asker.full_name}: {question}
  
           Respond in character as {npc.full_name}.
           ```
        3. Call LLM (GPT-4 or Claude)
        4. Return response
  
        **Example:**
        ```ruby
        response = NpcQueryService.query(gregor, "What do you think of the new tax?", asker: alice)
        # Returns: "Bah! The new tax is bleeding us dry. The merchants can barely afford..."
        ```
  
        ---
  
        ## World Memory Viewing
  
        **viewmemory command:**
        ```ruby
        def perform_command(parsed_input)
          memory_id = parsed_input[:text].to_i
          memory = WorldMemory[memory_id]
  
          display_memory(memory)
        end
  
        def display_memory(memory)
          lines = []
          lines << "Memory #{memory.id}: #{memory.summary}"
          lines << "Location: #{memory.location&.name}"
          lines << "Participants: #{memory.character_names.join(', ')}"
          lines << "Timestamp: #{memory.created_at}"
          lines << ""
          lines << "Full text:"
          lines << memory.full_text
  
          success_result(lines.join("\n"))
        end
        ```
  
        **searchmemory command:**
        ```ruby
        def perform_command(parsed_input)
          query = parsed_input[:text]
          memories = WorldMemory.search(query)  # Uses semantic search
  
          display_results(memories)
        end
        ```
  
        **WorldMemory.search:**
        - Uses Voyage AI embeddings
        - Semantic similarity search
        - Returns top 10 most relevant memories
  
        ---
  
        ## Reputation Management
  
        **reputation command:**
        ```ruby
        def perform_command(parsed_input)
          args = parsed_input[:text].split
          char_name = args[0]
          faction_name = args[1]
          adjustment = args[2]&.to_i || 0
  
          character = find_character(char_name)
          faction = find_faction(faction_name)
  
          if adjustment == 0
            show_reputation(character, faction)
          else
            adjust_reputation(character, faction, adjustment)
          end
        end
  
        def adjust_reputation(character, faction, amount)
          rep = Reputation.find_or_create(character_id: character.id, faction_id: faction.id)
          new_value = rep.value + amount
          rep.update(value: new_value.clamp(-100, 100))
  
          success_result("#{character.full_name}'s reputation with #{faction.name}: #{new_value}")
        end
        ```
  
        **Reputation model:**
        ```ruby
        reputations (
          id,
          character_id,
          faction_id,
          value (-100 to 100),
          created_at, updated_at
        )
        ```
  
        **Tier calculation:**
        ```ruby
        def tier
          case value
          when -100..-50 then 'Hostile'
          when -49..-1 then 'Unfriendly'
          when 0..24 then 'Neutral'
          when 25..74 then 'Friendly'
          when 75..100 then 'Allied'
          end
        end
        ```
  
        ---
  
        ## Arranged Scene System
  
        Private one-on-one meetings between a specific animated NPC and a specific PC,
        with staff-seeded AI instructions.
  
        **ArrangedScene model:**
        ```ruby
        arranged_scenes (
          id,
          npc_character_id,       # The NPC involved
          pc_character_id,        # The specific PC invited
          meeting_room_id,        # Where PC triggers the scene (entry point)
          rp_room_id,             # Where the actual RP happens
          created_by_id,          # Staff who created it
          status (pending|active|completed|cancelled|expired),
          scene_name,
          invitation_message,
          npc_instructions (TEXT), # Seeded into NPC's AI behavior
          available_from,
          expires_at,
          started_at,
          ended_at,
          world_memory_session_id, # Link to RP log
          world_memory_id,         # Link to AI summary
          metadata (JSONB)         # pc_original_room_id, npc_original_room_id, npc_was_spawned
        )
        ```
  
        **Trigger flow (ArrangedSceneService.trigger_scene):**
        ```ruby
        1. Find or spawn NPC instance (creates temp instance if NPC offline)
        2. Store original room locations in metadata
        3. Broadcast departure from both rooms
        4. Teleport PC and NPC to rp_room
        5. Seed NPC: npc_instance.seed_instruction!(npc_instructions)
        6. Start WorldMemorySession (logs all dialogue)
        7. Update status to 'active'
        ```
  
        **End flow (ArrangedSceneService.end_scene):**
        ```ruby
        1. Finalize WorldMemorySession (generates AI summary)
        2. Clear NPC seed instructions
        3. If NPC was spawned for scene → go offline
           If NPC was already online → teleport back to original room
        4. Teleport PC back to meeting room
        5. Update status to 'completed'
        6. Send summary to staff
        ```
  
        **NPC instruction seeding:**
        Uses CharacterInstance puppet system (`puppet_instruction`, `puppet_mode='seed'`).
        NPC still makes autonomous AI decisions but incorporates the seeded instruction.
  
        ---
  
        ## Content Seeding
  
        **seed command:**
        ```ruby
        def perform_command(parsed_input)
          ContentSeedingService.seed_all
          success_result("Content seeding triggered.")
        end
        ```
  
        **ContentSeedingService:**
        ```ruby
        def self.seed_all
          seed_npc_dialogue
          seed_random_events
          seed_missions
        end
  
        def self.seed_npc_dialogue
          # Generate dialogue prompts for NPCs
          Npc.all.each do |npc|
            dialogue = generate_dialogue(npc)
            npc.update(current_dialogue: dialogue)
          end
        end
  
        def self.seed_random_events
          # Trigger random world events
          locations = Location.all.sample(5)
          locations.each do |loc|
            event = generate_event(loc)
            broadcast_to_location(loc, event)
          end
        end
        ```
  
        ---
  
        ## Broadcast Monitoring
  
        **checkall/checkalloff commands:**
        ```ruby
        def perform_command(parsed_input)
          character_instance.update(monitoring_all_broadcasts: true)
          success_result("You are now monitoring all broadcasts.")
        end
        ```
  
        **CharacterInstance model:**
        ```ruby
        character_instances (
          id,
          monitoring_all_broadcasts (boolean)
        )
        ```
  
        **BroadcastService integration:**
        ```ruby
        def self.to_room(room_id, message, ...)
          # Normal broadcast logic...
  
          # Send to monitoring staff
          monitoring_staff = CharacterInstance.where(
            monitoring_all_broadcasts: true,
            online: true
          ).all
  
          monitoring_staff.each do |staff|
            send_to_character(staff, {
              content: "[Room #{room_id}] #{message}",
              type: 'monitor'
            })
          end
        end
        ```
  
        **Performance warning:**
        - High volume for busy games
        - Consider filtering by room/zone
        - Auto-disable after inactivity
  
        ---
  
        ## Goto & Navigation
  
        **goto command:**
        ```ruby
        def perform_command(parsed_input)
          target = parsed_input[:text]
  
          destination = resolve_goto_target(target)
          return error("Destination not found") unless destination
  
          character_instance.teleport_to_room!(destination)
          success_result("You teleport to #{destination.name}.")
        end
  
        def resolve_goto_target(target)
          # Try as room ID
          return Room[target.to_i] if target.match?(/^\d+$/)
  
          # Try as room name
          room = Room.where(Sequel.ilike(:name, "%#{target}%")).first
          return room if room
  
          # Try as character location
          char = Character.where(Sequel.ilike(:full_name, "%#{target}%")).first
          return char.primary_instance.current_room if char
  
          nil
        end
        ```
  
        **staffroom command:**
        ```ruby
        def perform_command(parsed_input)
          staff_room = Room.first(is_staff_room: true) || Room.first(name: 'Staff Room')
          character_instance.teleport_to_room!(staff_room)
        end
        ```
  
        ---
  
        ## NPC Archetype System
  
        **NpcArchetype model:**
        ```ruby
        npc_archetypes (
          id,
          name,
          description,
          personality_traits (JSONB),  # { aggressive: 7, friendly: 3, ... }
          dialogue_patterns (JSONB),   # { greetings: [...], farewells: [...], ... }
          behavior_triggers (JSONB),   # { on_attacked: 'flee', on_greeted: 'respond', ... }
          faction_id,
          default_aggression_level (0-10),
          combat_ai_profile_id,
          created_at, updated_at
        )
        ```
  
        **Usage:**
        ```ruby
        npc.archetype = NpcArchetype.find(name: 'Guard')
        # NPC inherits:
        # - Personality traits (authoritative, vigilant)
        # - Dialogue patterns (law enforcement phrases)
        # - Behavior (attack criminals on sight)
        # - Combat AI (defensive tactics)
        ```
  
        **Personality traits (1-10 scale):**
        - aggressive, friendly, cautious, brave, greedy, honest, etc.
  
        **Dialogue patterns:**
        ```json
        {
          "greetings": ["What's your business here?", "Move along, citizen."],
          "farewells": ["Stay out of trouble.", "Safe travels."],
          "combat": ["You're under arrest!", "Halt in the name of the law!"]
        }
        ```
  
        **Behavior triggers:**
        ```json
        {
          "on_attacked": "fight_back",
          "on_greeted": "respond_friendly",
          "on_witness_crime": "intervene",
          "on_low_health": "flee"
        }
        ```
  
        ---
  
        ## NPC Schedule System
  
        **NpcSchedule model:**
        ```ruby
        npc_schedules (
          id,
          npc_id,
          day_of_week (0-6, or null for daily),
          start_time (TIME),
          end_time (TIME),
          location_id,
          room_id,
          action_type (move|emote|dialogue),
          action_data (JSONB),
          priority (1-10),
          created_at, updated_at
        )
        ```
  
        **Example schedules:**
        ```ruby
        # Daily morning routine
        NpcSchedule.create(
          npc_id: gregor.id,
          start_time: '08:00',
          end_time: '09:00',
          room_id: tavern.id,
          action_type: 'move'
        )
  
        # Weekly event
        NpcSchedule.create(
          npc_id: gregor.id,
          day_of_week: 0,  # Sunday
          start_time: '12:00',
          action_type: 'emote',
          action_data: { text: 'sets up a market stall' }
        )
        ```
  
        **Scheduler integration:**
        ```ruby
        # Run every minute
        NpcScheduleService.process_schedules
          1. Find schedules matching current time
          2. Execute action (move, emote, dialogue)
          3. Mark as executed (prevent repeats)
        ```
  
        ---
  
        ## Combat AI Profiles
  
        **CombatAiProfile model:**
        ```ruby
        combat_ai_profiles (
          id,
          name,
          aggression_level (1-10),
          preferred_abilities (JSONB),   # [ability_id1, ability_id2, ...]
          target_priority (JSONB),       # { lowest_hp: 8, highest_threat: 6, ... }
          flee_threshold_hp (0-100),
          use_items (boolean),
          created_at, updated_at
        )
        ```
  
        **Usage:**
        ```ruby
        npc.combat_ai_profile = CombatAiProfile.find(name: 'Defensive Guard')
        # In combat, NPC AI uses:
        # - Aggression 3/10 (defensive)
        # - Prefers shield abilities
        # - Targets highest threat first
        # - Flees at 20% HP
        # - Uses healing potions
        ```
  
        **AI decision algorithm:**
        ```ruby
        def choose_combat_action(npc, fight)
          profile = npc.combat_ai_profile
  
          # Check flee threshold
          if npc.health_percent < profile.flee_threshold_hp
            return flee_action
          end
  
          # Choose target
          target = choose_target(fight, profile.target_priority)
  
          # Choose ability
          abilities = preferred_abilities_available(npc, profile)
          ability = choose_ability(abilities, profile.aggression_level)
  
          { action: 'use_ability', ability_id: ability.id, target_id: target.id }
        end
        ```
  
        ---
  
        ## Integration Points
  
        **Puppeting:**
        - Overrides NPC AI behavior while active
        - Broadcasts show puppeted NPC as actor
        - Movement commands move the NPC
  
        **NPC Query:**
        - Integrates with NpcMemoryService for context
        - Uses archetype personality for response tone
        - Stores query in NPC memory for future reference
  
        **World Memory:**
        - Staff can view to find plot hooks
        - Search for specific events or characters
        - Export for story documentation
  
        **Reputation:**
        - Affects NPC dialogue options
        - Triggers faction-specific content
        - Used by Auto-GM for story decisions
  
        **Arranged Scenes:**
        - Creates world memories on completion
        - Rewards distributed via InventoryService
        - XP granted via CharacterProgressionService
  
        ---
  
        ## Performance Considerations
  
        **Broadcast monitoring:**
        - Disable auto-cleanup for inactive staff (1 hour timeout)
        - Filter by zone/room to reduce volume
        - Batch broadcasts instead of per-message
  
        **NPC schedules:**
        - Index on (start_time, day_of_week) for fast lookups
        - Process in batches (every minute, not realtime)
        - Cache active schedules in Redis
  
        **Content seeding:**
        - Rate limit to prevent spam (once per hour max)
        - Async processing for large batches
        - Monitor API costs (LLM generation expensive)
  
        ---
  
        ## Security & Permissions
  
        **All staff commands require:**
        ```ruby
        character.staff? == true
        ```
  
        **Permission levels:**
        - **staff** - Basic puppeting, viewing
        - **admin** - Reputation changes, scene arrangement
        - **superadmin** - Content seeding, broadcast monitoring
  
        **Audit logging:**
        All staff actions logged:
        ```ruby
        StaffAction.create(
          staff_character_id: character.id,
          action_type: 'puppet_npc',
          target_id: npc.id,
          details: { command: 'puppet gregor', timestamp: Time.now }
        )
        ```
      NOTES
      display_order: 110
    }
  ].freeze
end
