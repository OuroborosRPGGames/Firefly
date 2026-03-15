# Firefly Helpers & Services Reference

> **Before writing new code, check here for existing reusable components.**

This document catalogs all available helpers, services, and patterns to avoid code duplication.

---

## Quick Reference

| Need | Use This |
|------|----------|
| Return success/error | `success_result()` / `error_result()` |
| Broadcast to room | `broadcast_to_room()` or `BroadcastService.to_room()` |
| Send to specific character | `send_to_character()` or `BroadcastService.to_character()` |
| Find item with disambiguation | `resolve_item_with_menu()` |
| Find character with disambiguation | `resolve_character_with_menu()` |
| Find item in inventory | `find_item_in_inventory()` |
| Find worn item | `find_worn_item()` |
| Find held item | `find_held_item()` |
| Find char instance in room | `find_character_instance_in_room()` |
| Find char (room then global) | `find_character_room_then_global()` |
| Find char by name (global) | `find_character_by_name_globally()` |
| Find place/furniture in room | `find_place()` / `find_furniture()` |
| Apply restraint (gag/tie/etc.) | `apply_restraint_action()` |
| Remove restraint | `remove_restraint_action()` |
| Drag/carry character | `transport_action()` |
| Parse card draw syntax | `parse_draw_syntax()` |
| Get card display names | `card_display_names()` |
| Check IC permission | `check_ic_permission()` |
| Check OOC permission | `check_ooc_permission()` |
| Find online chars in room | `find_characters_in_room()` |
| Find others in room | `find_others_in_room()` |
| Find all online chars | `find_all_online_characters()` |
| Format time as "X ago" | `time_ago(time)` |
| Format future time | `time_until(time)` |
| Check empty input | `require_input()` |
| Prevent self-targeting | `prevent_self_target()` |
| Get character's wallet | `wallet_for()` / `find_or_create_wallet()` |
| Get current era config | `EraService.current_era` |
| Get game time | `GameTimeService.current_time(location)` |
| Check visibility | `VisibilityService.position_exposed?()` |
| Generate names | `NameGeneratorService.character()` |
| NPC animation | `NpcAnimationService.process_room_broadcast()` |
| NPC memory storage | `NpcMemoryService.store_memory()` |
| NPC memory retrieval | `NpcMemoryService.retrieve_relevant()` |
| World memory tracking | `WorldMemoryService.track_ic_message()` |
| World memory search | `WorldMemoryService.retrieve_relevant()` |
| World memory for NPCs | `WorldMemoryService.retrieve_for_npc()` |
| Nearby world memories | `WorldMemoryService.retrieve_nearby_memories()` |
| Memory distance calc | `WorldMemoryService.calculate_memory_distance()` |
| Get observer effects | `ObserverEffectService.effects_for()` |
| Persuade DC modifier | `ObserverEffectService.persuade_dc_modifier()` |
| Get character pronouns | `character.pronoun_subject` / `pronoun_possessive` / `pronoun_object` / `pronoun_reflexive` |
| Find controllable event | `Event.find_controllable_by(character, location)` |
| Event authority check | `event.controllable_by?(character)` |
| Find event attendee | `EventAttendee.for_event_and_character(event, character)` |
| Aesthete target/perms | `AestheteConcern#resolve_aesthete_target` / `has_aesthete_permission?` |

---

## 1. Base Command Helpers

**File:** `app/commands/base/command.rb`

Every command inherits these methods. Use them instead of reimplementing.

### Result Helpers

```ruby
# Success response with optional data
success_result("You pick up the sword.", data: { item_id: 123 })

# Error response
error_result("You don't see that here.")

# Room display response
room_result(room_data, target_panel: Firefly::Panels::RIGHT_MAIN_FEED)

# Message response (say, whisper, emote)
message_result(:say, sender_name, "Hello everyone!")

# Disambiguation quickmenu response
disambiguation_result(quickmenu_data, "Which sword?")
```

### Input Validation

```ruby
# Check for empty input (returns error_result or nil)
error = require_input(text, "What did you want to say?")
return error if error

# Prevent self-targeting (returns error_result or nil)
error = prevent_self_target(target_instance, "whisper to")
return error if error
```

### Broadcasting

```ruby
# Broadcast to everyone in room except self
broadcast_to_room("John picks up a sword.", exclude_character: character_instance)

# Send to specific character
send_to_character(target_instance, "John whispers to you: Hello")
```

### Item & Character Finding

```ruby
# Find item in character's inventory (not worn/held)
item = find_item_in_inventory("sword")

# Find item character is wearing
item = find_worn_item("jacket")

# Find item character is holding
item = find_held_item("staff")

# Find any owned item (inventory + worn + held + stored)
item = find_owned_item("ring")

# Find a character instance in current room by Character record
char_instance = find_character_instance_in_room(target_character)

# Find character - search room first, then global online chars (for finger/profile/info)
target = find_character_room_then_global(
  target_name,
  room: location,
  reality_id: character_instance.reality_id,
  exclude_instance_id: character_instance.id
)

# Find character by name globally (all characters in DB, not just online)
# Returns Character, not CharacterInstance - efficient unlike Character.all.find
char = find_character_by_name_globally("Alice")
```

### Target Resolution

```ruby
# Item disambiguation
result = resolve_item_with_menu(item_name, candidates, { shop_id: shop.id })

if result[:disambiguation]
  return disambiguation_result(result[:result], "Which '#{item_name}'?")
end
return error_result(result[:error]) if result[:error]

item = result[:match]  # Proceed with item

# Character disambiguation (defaults to chars in room, excluding self)
result = resolve_character_with_menu(target_name)

if result[:disambiguation]
  return disambiguation_result(result[:result], "Who did you mean?")
end
return error_result(result[:error]) if result[:error]

target = result[:match]  # Proceed with target
```

### Currency & Wallet

```ruby
# Get the universe from the current location
universe = universe  # -> location.location.area.world.universe

# Get default currency for current location (uses Currency.default_for)
currency = default_currency

# Get character's wallet for a currency
wallet = wallet_for(currency)

# Get or create wallet (useful for transactions)
wallet = find_or_create_wallet(currency)
```

### Restraint Actions (Prisoner Commands)

**File:** `app/helpers/restraint_action_helper.rb`

Standardized helpers for prisoner/restraint commands (gag, blindfold, tie, etc.):

```ruby
# Apply a restraint (gag, blindfold, tie hands/feet)
apply_restraint_action(
  target_name: "Bob",
  restraint_type: 'gag',           # gag, blindfold, hands, feet
  action_verb: 'gag',
  target_msg_template: '%{actor} gags you. You can no longer speak.',
  check_timeline: false            # Check timeline restrictions
)

# Remove restraints from target
remove_restraint_action(
  target_name: "Bob",
  restraint_type: 'all'            # hands, feet, gag, blindfold, all
)

# Start dragging or carrying a helpless character
transport_action(
  target_name: "Bob",
  action_type: :drag,              # :drag or :carry
  check_timeline: true
)
```

### Place/Furniture Lookup

**File:** `app/helpers/place_lookup_helper.rb`

Find places and furniture in rooms:

```ruby
# Find any place in current room by name
place = find_place("couch")

# Find furniture specifically (is_furniture: true)
furniture = find_furniture("bed")

# Search in specific room
place = find_place("bar stool", room: other_room)
```

Supports exact, prefix, and contains matching with automatic article stripping ("the couch" → "couch").

### Card Actions

**File:** `app/helpers/card_action_helper.rb`

Helpers for card game commands:

```ruby
# Parse draw syntax: [number] [faceup|facedown]
parsed = parse_draw_syntax("3 faceup")
# => { count: 3, facedown: false }

# Get display names for cards
names = card_display_names([1, 2, 3])
# => ["Ace of Spades", "King of Hearts", "Queen of Diamonds"]

# Face type strings
face_type_string(true)   # => "face down"
face_type_string(false)  # => "face up"

# Card word (singular/plural)
card_word(1)  # => "card"
card_word(5)  # => "cards"

# Add cards to hand or center
add_cards_to_holder(character_instance, card_ids, facedown: true)
add_cards_to_holder(deck, card_ids, facedown: false, to_center: true)

# Build standard draw messages
draw_self_message(count: 3, facedown: true, card_names: names)
draw_others_message(actor_name: "John", count: 3, facedown: true, card_names: names)

# Validate deck has enough cards
if error = validate_deck_count(deck, 5)
  return error_result(error)
end
```

### Communication Permission Checks

**File:** `app/helpers/communication_permission_helper.rb`

Check if a user has permission to send IC/OOC messages to another user:

```ruby
# Check IC (in-character) messaging permission
error = check_ic_permission(target_instance)
return error if error  # Returns error_result if blocked, nil if allowed

# Check OOC (out-of-character) messaging permission
# Handles 'yes', 'no', and 'ask' (OocRequest) cases
error = check_ooc_permission(target_instance)
return error if error  # Returns error_result if blocked, nil if allowed
```

Used by whisper, say_to, private_message and other communication commands.

### Character Lookup (Room Queries)

**File:** `app/helpers/character_lookup_helper.rb`

Standardized queries for finding online characters:

```ruby
# Find all online characters in a specific room
chars = find_characters_in_room(room_id)
chars = find_characters_in_room(room_id, eager: [:character, :user])

# Find all online characters except one (useful for broadcasts)
others = find_others_in_room(room_id, exclude_id: character_instance.id)

# Find all online characters globally
all_online = find_all_online_characters
all_online = find_all_online_characters(eager: [:character])

# Find online character by character ID
instance = find_online_character(character_id)
```

### Text Processing

```ruby
# Add punctuation if missing
text = process_punctuation(text)  # "hello" -> "hello."

# Extract adverb from text
adverb, remaining = extract_adverb("quietly say hello")
# adverb = "quietly", remaining = "say hello"

# Get display name for character (handles knowledge)
name = name_for_character(target_character)
```

### Time Formatting

```ruby
# Format past time as human-readable "X ago" (from StringHelper, included in all commands)
time_ago(Time.now - 30)        # => "just now"
time_ago(Time.now - 120)       # => "2 minutes ago"
time_ago(Time.now - 7200)      # => "2 hours ago"
time_ago(Time.now - 172800)    # => "2 days ago"
time_ago(nil)                  # => "Unknown"

# Format future time as human-readable countdown
time_until(Time.now + 1800)    # => "In 30 minutes"
time_until(Time.now + 7200)    # => "In 2 hours"
time_until(Time.now + 172800)  # => "Jan 14 at 10:30 AM"
time_until(Time.now - 100)     # => "Started 1 minute ago"
```

### Character Name Substitution

```ruby
# Substitute real names with display names for viewer
message = substitute_names_for_viewer(
  "John Smith waves at Jane Doe.",
  viewer_instance
)
# -> "John waves at tall woman." (if viewer doesn't know them)
```

---

## 2. Requirements DSL

Define when commands can be used. Set at class level.

```ruby
class Wave < Commands::Base::Command
  # Basic requirements
  requires_alive                           # Must not be dead
  requires_conscious                       # Must not be unconscious
  requires_standing                        # Must be standing

  # Era requirements
  requires_era :modern, :near_future       # Only in these eras
  excludes_era :medieval                   # Not in these eras
  requires_phone                           # Must have communication device
  requires_taxi                            # Taxi service must be available
  requires_digital_currency                # Digital payments available

  # Combat requirements
  requires_combat                          # Must be in combat
  requires_weapon_equipped                 # Must have weapon

  # Resource requirements
  requires_mana 10                         # Need 10+ mana
  requires_stamina 5                       # Need 5+ stamina

  # Custom requirements
  requires -> (cmd) { cmd.character.level >= 5 }, message: "Must be level 5+"
  requires :room_type, :water, message: "You need to be in water."
end
```

---

## 3. Services Index

### BroadcastService
**File:** `app/services/messaging/broadcast_service.rb`

Message delivery to rooms, characters, areas.

```ruby
# Broadcast to room
BroadcastService.to_room(room_id, "Message", exclude: [char_instance_id])

# Send to character
BroadcastService.to_character(char_instance, "Message")

# Broadcast to area
BroadcastService.to_area(area_id, "Server announcement!")

# Broadcast to observers
BroadcastService.to_observers(observed_char, "They moved.")

# Staff vision (see actions in other rooms)
BroadcastService.to_staff_vision(room, "Someone whispers...")
```

### TargetResolverService
**File:** `app/services/target_resolver_service.rb`

Find items/characters by name with disambiguation.

```ruby
# Simple resolution (first match)
match = TargetResolverService.resolve(
  query: "sword",
  candidates: items,
  name_field: :name
)

# With disambiguation (returns quickmenu if multiple matches)
result = TargetResolverService.resolve_with_disambiguation(
  query: "sword",
  candidates: items,
  name_field: :name,
  character_instance: char_instance,
  context: { action: 'get' }
)

# Character-specific resolution
result = TargetResolverService.resolve_character_with_disambiguation(
  query: "john",
  candidates: chars_in_room,
  character_instance: char_instance,
  context: { action: 'follow' }
)
```

### MovementService
**File:** `app/services/navigation/movement_service.rb`

Handle character movement and following.

```ruby
# Start timed movement to room/exit
result = MovementService.start_movement(char_instance, target: room_exit, adverb: "quickly")

# Stop current movement
MovementService.stop_movement(char_instance, reason: "interrupted")

# Follow another character
result = MovementService.start_following(follower, leader)

# Grant follow permission
MovementService.grant_follow_permission(actor, target)

# Revoke follow permission
MovementService.revoke_follow_permission(actor, target)

# Check if moving
MovementService.moving?(char_instance)
```

### GameTimeService
**File:** `app/services/game_time_service.rb`

Game time calculations.

```ruby
# Current game time
time = GameTimeService.current_time(location)

# Time of day (:dawn, :day, :dusk, :night)
period = GameTimeService.time_of_day(location)

# Check time conditions
GameTimeService.night?(location)
GameTimeService.day?(location)

# Formatted output
GameTimeService.formatted_time(location, format: "%H:%M")
GameTimeService.formatted_date(location, format: "%B %d, %Y")
```

### EraService
**File:** `app/services/era_service.rb`

Era-specific configuration.

```ruby
# Current era (:medieval, :gaslight, :modern, :near_future, :scifi)
era = EraService.current_era

# Currency
EraService.currency_name       # "dollars"
EraService.currency_symbol     # "$"
EraService.digital_currency?   # true/false
EraService.format_currency(100) # "$100.00"

# Messaging
EraService.messaging_device_name  # "phone", "communicator"
EraService.messenger_required?    # true if courier needed
EraService.always_connected?      # true if implants/always-on

# Travel
EraService.taxi_available?       # true/false
EraService.taxi_type            # :hansom_cab, :rideshare, :autocab
EraService.taxi_name            # "hansom cab", "rideshare"
```

### VisibilityService
**File:** `app/services/visibility_service.rb`

Clothing and position visibility.

```ruby
# Check if body position is exposed
VisibilityService.position_exposed?(char_instance, :torso, viewer: viewer_instance)

# Get visible clothing
items = VisibilityService.visible_clothing(char_instance, viewer: viewer_instance)

# Check description visibility
VisibilityService.description_visible?(desc, char_instance, viewer: viewer_instance)

# Check private mode content
VisibilityService.show_private_content?(viewer_instance, target_instance)
```

### CharacterDisplayService
**File:** `app/services/character/character_display_service.rb`

Build rich character display for look command.

```ruby
service = CharacterDisplayService.new(target_instance, viewer_instance: viewer, xray: false)
display = service.build_display

# Returns hash with:
# - profile_pic_url, name, short_desc, status, roomtitle
# - intro (body type paragraph)
# - descriptions, clothing, held_items, thumbnails
```

### RoomDisplayService
**File:** `app/services/room/room_display_service.rb`

Build room display for look command.

```ruby
service = RoomDisplayService.new(room, viewer_instance)
display = service.build_display

# Returns hash with:
# - room (id, name, description, type)
# - places, decorations, objects, exits
# - characters_ungrouped, nearby_rooms
```

### NameGeneratorService
**File:** `app/services/name_generator_service.rb`

Generate names for characters, places, etc.

```ruby
# Single character name
name = NameGeneratorService.character(gender: :female, culture: :english)

# Multiple options
names = NameGeneratorService.character_options(count: 5, gender: :any)

# Other generators
NameGeneratorService.city(setting: :fantasy)
NameGeneratorService.street()
NameGeneratorService.shop()
```

### InteractionPermissionService
**File:** `app/services/interaction_permission_service.rb`

Three-tier permission system (permanent, temporary, one-time).

```ruby
# Check permission
InteractionPermissionService.has_permission?(actor, target, 'follow')

# Grant/revoke temporary (Redis, expires)
InteractionPermissionService.grant_temporary_permission(granter, grantee, 'dress', ttl: 3600)
InteractionPermissionService.revoke_temporary_permission(granter, grantee, 'dress')

# Request consent (one-time)
InteractionPermissionService.request_consent(actor, target, 'interact', context: { action: 'hug' })
```

### TaxiService
**File:** `app/services/vehicle/taxi_service.rb`

Era-appropriate transportation.

```ruby
TaxiService.available?                      # Check if taxi works here
TaxiService.taxi_name                       # "hansom cab", "rideshare"
TaxiService.call_taxi(char_instance, dest)  # Call taxi
TaxiService.board_taxi(char_instance, dest) # Board waiting taxi
```

### DistanceService
**File:** `app/services/distance_service.rb`

3D distance and travel time calculations.

```ruby
# Distance between coordinates
dist = DistanceService.calculate_distance(x1, y1, z1, x2, y2, z2)

# Travel time in milliseconds
time_ms = DistanceService.time_for_distance(dist, speed_multiplier)

# Time to reach exit
time_ms = DistanceService.time_to_exit(char_instance, room_exit, 1.0)
```

### PathfindingService
**File:** `app/services/navigation/pathfinding_service.rb`

Calculate routes between rooms.

```ruby
path = PathfindingService.find_path(from_room, to_room, max_depth: 50)
# Returns array of room IDs or nil if no path
```

### NpcAnimationService
**File:** `app/services/npc/npc_animation_service.rb`

LLM-powered NPC responses to room activity.

```ruby
# Called automatically from BroadcastService.to_room for IC content
NpcAnimationService.process_room_broadcast(
  room_id: 123,
  content: "Hello merchant!",
  sender_instance: player_instance,
  type: :say
)

# Process orphaned queue entries (scheduler fallback)
NpcAnimationService.process_queue!

# Generate spawn outfit/status for NPC
outfit = NpcAnimationService.generate_spawn_outfit(npc_instance)
status = NpcAnimationService.generate_spawn_status(npc_instance)

# Check if NPC is mentioned in content
NpcAnimationService.mentioned_in_content?(npc_instance: npc, content: "Hey merchant")
```

### NpcMemoryService
**File:** `app/services/npc/npc_memory_service.rb`

NPC memory storage with semantic search and abstraction hierarchy.

```ruby
# Store a memory (auto-embeds with Voyage AI)
NpcMemoryService.store_memory(
  npc: character,
  content: "Player asked about the weather",
  about_character: player_character,  # Optional
  importance: 5,                       # 1-10 scale
  memory_type: 'interaction'
)

# Retrieve semantically relevant memories
memories = NpcMemoryService.retrieve_relevant(
  npc: character,
  query: "weather conversation",
  limit: 3,
  include_abstractions: true,
  min_age_hours: 3  # Prevents echo of recent memories
)

# Format memories for LLM context
context = NpcMemoryService.format_for_context(memories)

# Manually trigger abstraction (normally automatic)
NpcMemoryService.abstract_memories!(npc: character, level: 1)

# Process all pending abstractions
NpcMemoryService.process_abstractions!(npc: character)
```

**Memory Hierarchy:** 8 memories at level N → 1 summary at level N+1 (max 4 levels)

### WorldMemoryService
**File:** `app/services/world/world_memory_service.rb`

Automatic RP session capture with LLM summarization and semantic search.

```ruby
# Track IC message (called automatically from BroadcastService)
WorldMemoryService.track_ic_message(
  room_id: room.id,
  content: "Hello everyone!",
  sender: character_instance,
  type: :say,
  is_private: false
)

# Retrieve semantically relevant world memories
memories = WorldMemoryService.retrieve_relevant(
  query: "the merchant's silk trade",
  limit: 10,
  include_private: false  # Exclude private/secluded memories
)

# Get memories for a specific location
memories = WorldMemoryService.memories_at_location(room: room, limit: 10)

# Get memories involving a character
memories = WorldMemoryService.memories_for_character(character: char, limit: 10)

# Manual finalization (normally automatic via scheduler)
WorldMemoryService.finalize_stale_sessions!

# Trigger abstraction check
WorldMemoryService.check_and_abstract!

# Retrieve world memories for NPC context (used by NpcAnimationHandler)
# Uses distance-based scoring for location relevance
memories = WorldMemoryService.retrieve_for_npc(
  npc: character,                # The NPC character
  query: "trigger content",      # For semantic relevance
  room: current_room,            # For location-based distance calculations
  limit: 3
)

# Format world memories for NPC context
WorldMemoryService.format_for_npc_context(memories, npc: character)
# => "[You witnessed] (at Town Square) The merchant discussed silk prices..."
# => "[Recent gossip] (at Market) A traveler arrived with rare goods..."

# Get nearby memories with distance-based weighting
nearby = WorldMemoryService.retrieve_nearby_memories(room, limit: 20)
# => [{ memory: <WorldMemory>, weight: 0.8, distance: 3 }, ...]

# Calculate distance between room and memory location
distance = WorldMemoryService.calculate_memory_distance(room, memory)
# Same room = 0, same location = 1, same area nearby = 2-5, farther = 5+
```

**Session Detection:** 2+ online characters + IC message → starts session
**Minimum Threshold:** 5 IC messages before creating a memory
**Summarization:** Uses flash-2.5-lite (Gemini) for 2-3 sentence summaries
**Decay:** Linear relevance decay over 365 days (like NPC memories)
**NPC Integration:** NPCs receive world memories as context with markers: `[You witnessed]`, `[Recent gossip]`, `[You heard]`
**Distance Scoring:** Same room (1.5× bonus) > Same building (1.2×) > Same area (hex distance) > Different area (geo distance)

### SmartNavigationService
**File:** `app/services/navigation/smart_navigation_service.rb`

Handle complex navigation with ambiguity resolution.

```ruby
result = SmartNavigationService.navigate(char_instance, "coffee shop", adverb: "quickly")
# Handles: exit building -> taxi -> enter destination
```

### ObserverEffectService
**File:** `app/services/observer_effect_service.rb`

Manages remote observer effects for activities. Remote observers can support or oppose ongoing missions from afar.

```ruby
# Get effects for a participant during standard resolution
effects = ObserverEffectService.effects_for(participant, round_type: :standard)
# => { reroll_ones: true, block_explosions: true, stat_swap: :charisma }

# Get effects for persuade rounds
effects = ObserverEffectService.effects_for_persuade(instance)
# => { distraction: true, draw_attention: true }

# Get DC modifier for persuade rounds
dc_mod = ObserverEffectService.persuade_dc_modifier(instance)
# => -2 (distraction gives -2, draw_attention gives +3)

# Emit observer effect messages to participants
ObserverEffectService.emit_observer_messages(instance)
# Broadcasts effect notifications to all field participants

# Clear all observer actions at round end
ObserverEffectService.clear_actions!(instance)
```

**Support Actions:**
- `stat_swap` - Use observer's chosen stat instead of action's stat
- `reroll_ones` - Reroll any dice showing 1
- `block_damage` - Reduce damage taken (combat rounds)
- `distraction` - Lower DC by 2 (persuade rounds)
- `halve_damage` - Halve incoming damage (combat rounds)
- `expose_targets` - Provide tactical advantage (combat rounds)

**Opposition Actions:**
- `block_explosions` - Dice cap at 8 (no exploding)
- `damage_on_ones` - Take 1 damage if any die shows 1
- `block_willpower` - Cannot add willpower dice
- `draw_attention` - Raise DC by 3 (persuade rounds)
- `redirect_npc` - Redirect NPC attention (persuade rounds)
- `aggro_boost` - Increase enemy aggression (combat rounds)

---

## 4. Handlers Index

Handlers process async/timed action completions.

### CommandDisambiguationHandler
**File:** `app/handlers/command_disambiguation_handler.rb`

Process quickmenu selections for disambiguation.

**Supported actions:** get, drop, wear, buy, preview, eat, drink, smoke, hold, pocket, show, give, remove, follow, lead, whisper

```ruby
# Called automatically via app.rb when user selects from quickmenu
CommandDisambiguationHandler.process_response(char_instance, interaction, selected_key)
```

### MovementHandler
**File:** `app/handlers/movement_handler.rb`

Complete room transitions after movement timer.

### ApproachHandler
**File:** `app/handlers/approach_handler.rb`

Complete furniture approach after timer.

### DisambiguationHandler
**File:** `app/handlers/disambiguation_handler.rb`

Process walk/navigation disambiguation selections.

### NpcAnimationHandler
**File:** `app/handlers/npc_animation_handler.rb`

Process NPC animation queue entries, generating contextual emotes.

```ruby
# Called by NpcAnimationService.process_queue_entry
result = NpcAnimationHandler.call(queue_entry)
# Returns { success: true, emote: "Gregor smiles warmly..." }

# Builds context from:
# - Room description and people present
# - Lore from helpfiles (Helpfile.lore_context_for)
# - NPC memories (NpcMemoryService)
# - Relationships with PCs (NpcRelationship)

# After generating, stores memory and updates relationship
```

---

## 5. OutputHelper

**File:** `app/helpers/output_helper.rb`

Included in base command. Handles dual-mode output (agent vs webclient).

```ruby
# Create quickmenu for user selection
create_quickmenu(char_instance, "Select an option:", options, context: { action: 'choose' })

# Create form for user input
create_form(char_instance, "Character Creation", fields, context: { step: 'name' })

# Render output based on mode
render_output(type: :message, data: { content: "Hello" })

# Store/retrieve interactions (Redis-backed)
store_agent_interaction(char_instance, interaction_id, data)
OutputHelper.get_agent_interaction(char_instance_id, interaction_id)
OutputHelper.get_pending_interactions(char_instance_id)
```

---

## 6. Common Patterns

### Disambiguation Flow

All item/character targeting commands should follow this pattern:

```ruby
def perform_command(parsed_input)
  item_name = parsed_input[:text]

  # 1. Validate input
  error = require_input(item_name, "Get what?")
  return error if error

  # 2. Get candidates
  items = location.objects_here.all

  # 3. Resolve with disambiguation
  result = resolve_item_with_menu(item_name, items)

  # Case 1: Multiple matches - return quickmenu
  if result[:disambiguation]
    return disambiguation_result(result[:result], "Which '#{item_name}'?")
  end

  # Case 2: No match - return error
  return error_result(result[:error] || "You don't see that.") if result[:error]

  # Case 3: Single match - proceed
  item = result[:match]
  # ... complete action
end
```

### Item Manipulation + Broadcast

```ruby
def drop_item(item)
  # 1. Move item
  item.move_to_room(location)

  # 2. Broadcast to others
  broadcast_to_room(
    "#{character.full_name} drops #{item.name}.",
    exclude_character: character_instance
  )

  # 3. Return success
  success_result("You drop #{item.name}.", data: { action: 'drop', item_id: item.id })
end
```

### Economy Transaction

```ruby
def buy_item(stock_item, shop)
  currency = shop.currency || default_currency
  wallet = find_or_create_wallet(currency)

  if wallet.balance < stock_item.price
    return error_result("You can't afford that. (#{currency.format_amount(stock_item.price)})")
  end

  wallet.subtract(stock_item.price)
  new_item = stock_item.create_item_for(character_instance)

  success_result(
    "You buy #{new_item.name} for #{currency.format_amount(stock_item.price)}.",
    data: { action: 'buy', item_id: new_item.id }
  )
end
```

---

## 7. Test Helpers

**File:** `spec/support/test_helpers.rb`

### World Hierarchy

```ruby
# Creates: universe -> world -> area -> location -> room
hierarchy = create_test_world_hierarchy
room = hierarchy[:room]
location = hierarchy[:location]
```

### Character Instance

```ruby
char_instance = create_test_character_instance(
  room: room,
  reality: reality,
  forename: 'Test'
)
```

### Shared Examples

**File:** `spec/support/shared_examples.rb`

```ruby
# In spec file:
it_behaves_like "command metadata", 'look', :navigation, ['l', 'examine']
```

---

## 8. Anti-Patterns to Avoid

### DON'T: Inline nil/empty checks

```ruby
# Bad
return error_result("What?") if text.nil? || text.strip.empty?

# Good
error = require_input(text, "What?")
return error if error
```

### DON'T: Reimplement wallet lookup

```ruby
# Bad
wallet = char_instance.wallets_dataset.first(currency_id: currency.id)
wallet ||= Wallet.create(character_instance: char_instance, currency: currency, balance: 0)

# Good
wallet = find_or_create_wallet(currency)
```

### DON'T: Pass IDs to Sequel associations

```ruby
# Bad - causes 'pk' error
item.move_to_room(char_instance.current_room_id)

# Good
room = Room[char_instance.current_room_id]
item.move_to_room(room)
```

### DON'T: Inline HTML stripping

```ruby
# Bad - duplicated regex patterns
plain_name = item.name.gsub(/<[^>]+>/, '').strip
text = value.gsub(/<[^>]+>/, '').gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&amp;/, '&')

# Good - use StringHelper methods (included in all commands)
plain_name = plain_name(item.name)        # strip HTML + trim
text = strip_and_decode(value)            # strip HTML + decode entities
clean = strip_html(value)                 # just strip HTML
canvas_safe = sanitize_for_canvas(text)   # strip HTML + special chars
```

### DON'T: Skip disambiguation

```ruby
# Bad - silently picks first match
item = items.find { |i| i.name.downcase.include?(query.downcase) }

# Good - lets user choose
result = resolve_item_with_menu(query, items)
```

### DON'T: Load all records into memory for search

```ruby
# Bad - loads ALL characters into memory
Character.all.find { |c| c.full_name.downcase == name.downcase }

# Good - use the CharacterLookupHelper method (uses TargetResolverService)
char = find_character_by_name_globally(name)

# Or for room-first-then-global search:
target = find_character_room_then_global(name, room: location, reality_id: reality.id)
```

### DON'T: Duplicate time formatting logic

```ruby
# Bad - reimplementing time formatting in each command
seconds = (Time.now - time).to_i
return "just now" if seconds < 60
# ... etc

# Good - use StringHelper methods (included in all commands)
time_ago(time)        # => "5 minutes ago"
time_until(time)      # => "In 30 minutes"
```

---

## 9. Plugin Concerns

### VehicleCommandsConcern
**File:** `plugins/core/vehicles/commands/concerns/vehicle_commands_concern.rb`

Include in vehicle commands for shared functionality:

```ruby
class OpenRoof < Commands::Base::Command
  include Concerns::VehicleCommandsConcern

  def perform_command(_parsed_input)
    vehicle = find_current_vehicle
    return error_result("You're not in a vehicle.") unless vehicle

    vehicle.open_roof!
    broadcast_to_vehicle(vehicle, "#{character.full_name} opens the roof.")
    success_result("You open the roof.")
  end
end
```

Available methods:
- `find_current_vehicle` - Get the vehicle character is in
- `broadcast_to_vehicle(vehicle, message)` - Send personalized message to all occupants
- `in_vehicle?` - Check if character is in a vehicle
- `is_driver?` - Check if character is the driver
- `vehicle_occupants` - Get all occupants of current vehicle

---

## Related Documentation

- [Plugin Development](plugins/PLUGIN_DEVELOPMENT.md) - Command structure
- [API Reference](docs/API.md) - REST endpoints
- [Model Map](docs/MODEL_MAP.md) - Database models
- [API Reference](docs/API.md) - REST API endpoints

---

*Last updated: 2026-01-22*
