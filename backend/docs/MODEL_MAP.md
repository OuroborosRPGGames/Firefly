# Model Mapping Guide

This document maps game design concepts to their actual model implementations, helping developers quickly locate the correct models.

## World Structure

| Concept | Model Class | File | Table |
|-------------------|-------------|------|-------|
| Universe | `Universe` | `universe.rb` | `universes` |
| World | `World` | `world.rb` | `worlds` |
| Area | `Area` | `area.rb` | `areas` |
| Location | `Location` | `location.rb` | `locations` |
| Room | `Room` | `room.rb` | `rooms` |
| World hexes | `WorldHex` | `world_hex.rb` | `world_hexes` |
| Room hexes | `RoomHex` | `room_hex.rb` | `room_hexes` |

## Room Contents

| Concept | Model Class | File | Table | Notes |
|-------------------|-------------|------|-------|-------|
| Furniture/places | `Place` | `place.rb` | `places` | Has `is_furniture` flag |
| Decorations | `Decoration` | `decoration.rb` | `decorations` | Visual elements |
| Windows, doors | `RoomFeature` | `room_feature.rb` | `room_features` | Handles sightlines |
| Exits | `RoomExit` | `room_exit.rb` | `room_exits` | Connections between rooms |
| Sightlines | `RoomSightline` | `room_sightline.rb` | `room_sightlines` | Visibility cache |

## Characters

| Concept | Model Class | File | Table | Notes |
|-------------------|-------------|------|-------|-------|
| User | `User` | `user.rb` | `users` | Player account |
| Character | `Character` | `character.rb` | `characters` | Player/NPC definition |
| Character Instance | `CharacterInstance` | `character_instance.rb` | `character_instances` | Active incarnation |
| Shapes | `CharacterShape` | `character_shape.rb` | `character_shapes` | Shapeshifter forms |
| Body parts | `BodyPosition` | `body_position.rb` | `body_positions` | Anatomical positions |
| Character descriptions | `CharacterDescription` | `character_description.rb` | `character_descriptions` | Per-body-part text |
| Names/Knowledge | `CharacterKnowledge` | `character_knowledge.rb` | `character_knowledge` | Who knows whom |

## Objects/Items

| Concept | Model Class | File | Table | Notes |
|-------------------|-------------|------|-------|-------|
| **Object** | `Item` | `item.rb` | `objects` | Physical items in the world |
| Object type | `UnifiedObjectType` | `unified_object_type.rb` | `unified_object_types` | Base definitions |
| Patterns | `Pattern` | `pattern.rb` | `patterns` | Specific item templates |
| Item coverage | `ItemBodyPosition` | `item_body_position.rb` | `item_body_positions` | What body parts items cover |

### Object System Hierarchy

```
UnifiedObjectType (base definition: "shirt", "sword")
    └── Pattern (specific template: "silk shirt", "iron sword")
        └── Item (instance: "worn silk shirt in room 5")
```

## Character Systems

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Appearances/Disguises | `Appearance` | `appearance.rb` | Alternate looks for shapes |

## Stats & Abilities

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Stat System | `StatBlock` | `stat_block.rb` | Universe stat configuration |
| Individual Stats | `Stat` | `stat.rb` | Stat definitions (STR, DEX, etc.) |
| Character Stats | `CharacterStat` | `character_stat.rb` | Character stat values |
| Abilities/Powers | `Ability` | `ability.rb` | Combat/utility powers |
| Character Abilities | `CharacterAbility` | `character_ability.rb` | Learned abilities per character |

## Currency & Economy

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Currency Types | `Currency` | `currency.rb` | Money types per universe |
| Wallet | `Wallet` | `wallet.rb` | Money on character's person |
| Bank Account | `BankAccount` | `bank_account.rb` | Safe money storage |
| Shops | `Shop`, `ShopItem` | `shop.rb`, `shop_item.rb` | Commerce |

## Communication & Social

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Channels | `Channel` | `channel.rb` | IC/OOC chat channels |
| Channel Membership | `ChannelMember` | `channel_member.rb` | Channel subscriptions |
| Groups/Factions | `Group` | `group.rb` | Guilds, factions, orgs |
| Group Membership | `GroupMember` | `group_member.rb` | Character group membership |
| Friends | `Friend` | `friend.rb` | OOC friendships between users |
| Blocks | `Block` | `block.rb` | Privacy blocks (OOC/IC) |
| Memos | `Memo` | `memo.rb` | Longer messages/letters |
| Messages | `Message` | `message.rb` | Chat/communication |
| Relationships | `Relationship` | `relationship.rb` | Character connections |

## Vehicles & Access

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Vehicle Types | `VehicleType` | `vehicle_type.rb` | Vehicle templates |
| Vehicles | `Vehicle` | `vehicle.rb` | Vehicle instances |
| Keys | `Key` | `key.rb` | Door/container access |

## Events & Outfits

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Calendar Events | `Event` | `event.rb` | Scheduled IC/OOC events |
| Event Attendance | `EventAttendee` | `event_attendee.rb` | RSVPs and attendance |
| Outfits | `Outfit` | `outfit.rb` | Saved clothing combinations |
| Outfit Items | `OutfitItem` | `outfit_item.rb` | Items in an outfit |

## Content & Consent

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Content Restrictions | `ContentRestriction` | `content_restriction.rb` | Adult content types |
| Content Consent | `ContentConsent` | `content_consent.rb` | Player consent settings |

## AI & NPCs

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| NPC Archetypes | `NpcArchetype` | `npc_archetype.rb` | NPC templates |
| NPC Memories | `NpcMemory` | `npc_memory.rb` | AI memory for RAG |
| NPC Goals | `NpcGoal` | `npc_goal.rb` | Goals, secrets, triggers |
| NPC Schedules | `NpcSchedule` | `npc_schedule.rb` | Location schedules |
| Pets | `Pet` | `pet.rb` | AI-puppeted companions |

## Story & World Events

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Metaplot Events | `MetaplotEvent` | `metaplot_event.rb` | World-changing events |
| News Articles | `NewsArticle` | `news_article.rb` | IC news from events |
| Weather | `Weather` | `weather.rb` | Location weather conditions |

## Delves (Procedural Dungeons)

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Delve | `Delve` | `delve.rb` | Procedural dungeon instance |
| Delve Rooms | `DelveRoom` | `delve_room.rb` | Rooms within delves |
| Delve Participants | `DelveParticipant` | `delve_participant.rb` | Characters in a delve |

## Other Systems

| Concept | Model Class | File | Notes |
|-------------------|-------------|------|-------|
| Realities/Timelines | `Reality` | `reality.rb` | Parallel timelines |
| RP Logs | `RpLog` | `rp_log.rb` | Scene logging |
| Help system | `Helpfile` | `helpfile.rb` | In-game help |
| Timed actions | `TimedAction` | `timed_action.rb` | Movement, crafting |
| Cooldowns | `ActionCooldown` | `action_cooldown.rb` | Ability cooldowns |
| Description types | `DescriptionType` | `description_type.rb` | Face, chest, etc. |

## Not Yet Implemented

These concepts still need models:

- **Activities/Missions** - Structured gameplay objectives
- **Skills/Crafting** - Skill system and crafting
- **Quests** - Quest tracking system

## Common Lookups

```ruby
# Find an item
Item.first(name: 'sword')                    # By name
Item.where(room_id: 123)                     # In a room
Item.where(character_instance_id: 456)       # On a character

# Find characters in a room
room.characters_here(reality_id)             # Online characters
room.character_instances                     # All instances

# Find places/furniture
room.places                                  # All places
room.visible_places                          # Non-hidden places
Place.where(is_furniture: true)              # Furniture only

# Find exits
room.room_exits                              # From this room
room.exits                                   # Visible exits only
room.passable_exits                          # Can walk through

# Stats & Abilities
character_instance.character_stats           # All stats
character_instance.character_abilities       # All abilities
ability.on_cooldown_for?(character_instance) # Check cooldown

# Currency & Economy
character_instance.wallets                   # Money on person
character.bank_accounts                      # Saved money
wallet.add(100)                              # Add currency
wallet.transfer_to(other_wallet, 50)         # Transfer

# Social & Communication
channel.members                              # Channel members
character.group_memberships                  # Groups joined
user.friends                                 # OOC friends
user.blocks                                  # Blocked users

# Vehicles
character_instance.current_vehicle           # Current vehicle
vehicle.passengers                           # Characters inside
vehicle.start!                               # Start vehicle

# NPCs (AI-powered)
character.npc_memories                       # NPC's memories
NpcMemory.relevant_for(npc, about_character) # RAG lookup
npc.npc_goals.active                         # Active goals

# Story & Events
location.weather                             # Current weather
location.metaplot_events                     # Story events
NewsArticle.breaking_news                    # Latest breaking news

# Delves
delve.delve_rooms                            # All rooms in delve
delve.delve_participants.active              # Active participants
participant.move_to!(delve_room)             # Move in delve
```

## Naming Conventions

- Models match their table names (singularized)
- Associations use `class:` option when names differ
- Join tables use both model names: `item_body_positions`

## Historical Notes

- `Item` was previously named `GameObject` (renamed Dec 2025)
- `UnifiedObjectType` consolidates legacy `ctypes`, `jtypes`, `wtypes`, `ttypes` tables
- `Pattern` consolidates legacy `cpatterns`, `jpatterns`, `wpatterns`, `tpatterns` tables
- Legacy tables `channels`, `vehicles`, `outfits` had primary key constraints added (Dec 2025)
