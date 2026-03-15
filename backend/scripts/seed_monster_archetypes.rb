# frozen_string_literal: true

# Idempotent seed script for delve monster archetype + template characters.
# Run with: bundle exec ruby scripts/seed_monster_archetypes.rb

require_relative '../config/room_type_config'
require_relative '../config/application'

MONSTERS = [
  {
    type: 'rat',
    archetype_name: 'Delve Rat',
    short_desc: 'a mangy rat with beady eyes',
    attacks: [
      { 'name' => 'Bite', 'attack_type' => 'melee', 'damage_dice' => '2d4',
        'damage_type' => 'physical', 'attack_speed' => 6, 'range_hexes' => 1,
        'melee_reach' => 1, 'weapon_template' => 'bite',
        'hit_message' => '%{attacker} bites %{target}!',
        'miss_message' => '%{attacker} snaps at %{target} but misses!',
        'critical_message' => '%{attacker} sinks its teeth into %{target}!' }
    ]
  },
  {
    type: 'spider',
    archetype_name: 'Delve Spider',
    short_desc: 'a large spider with glistening fangs',
    attacks: [
      { 'name' => 'Bite', 'attack_type' => 'melee', 'damage_dice' => '1d6',
        'damage_type' => 'physical', 'attack_speed' => 5, 'range_hexes' => 1,
        'melee_reach' => 1, 'weapon_template' => 'bite',
        'hit_message' => '%{attacker} bites %{target} with venomous fangs!',
        'miss_message' => '%{attacker} lunges at %{target} but misses!',
        'critical_message' => '%{attacker} sinks its fangs deep into %{target}!' },
      { 'name' => 'Spit', 'attack_type' => 'ranged', 'damage_dice' => '1d4',
        'damage_type' => 'poison', 'attack_speed' => 4, 'range_hexes' => 6,
        'weapon_template' => 'spit',
        'hit_message' => '%{attacker} spits venom at %{target}!',
        'miss_message' => '%{attacker} spits venom but it sails past %{target}!',
        'critical_message' => '%{attacker} lands a glob of caustic venom right in %{target}\'s face!' }
    ]
  },
  {
    type: 'goblin',
    archetype_name: 'Delve Goblin',
    short_desc: 'a scrawny goblin baring its claws',
    attacks: [
      { 'name' => 'Claw', 'attack_type' => 'melee', 'damage_dice' => '1d6',
        'damage_type' => 'physical', 'attack_speed' => 6, 'range_hexes' => 1,
        'melee_reach' => 1, 'weapon_template' => 'claw',
        'hit_message' => '%{attacker} rakes %{target} with sharp claws!',
        'miss_message' => '%{attacker} swipes at %{target} but misses!',
        'critical_message' => '%{attacker} tears into %{target} with a vicious claw strike!' }
    ]
  },
  {
    type: 'skeleton',
    archetype_name: 'Delve Skeleton',
    short_desc: 'a rattling skeleton held together by dark magic',
    attacks: [
      { 'name' => 'Slam', 'attack_type' => 'melee', 'damage_dice' => '2d6',
        'damage_type' => 'physical', 'attack_speed' => 4, 'range_hexes' => 1,
        'melee_reach' => 1, 'weapon_template' => 'slam',
        'hit_message' => '%{attacker} slams into %{target} with bony fists!',
        'miss_message' => '%{attacker} swings at %{target} but its bones rattle harmlessly!',
        'critical_message' => '%{attacker} delivers a bone-crushing slam to %{target}!' }
    ]
  },
  {
    type: 'orc',
    archetype_name: 'Delve Orc',
    short_desc: 'a hulking orc with tusks and scarred skin',
    attacks: [
      { 'name' => 'Slam', 'attack_type' => 'melee', 'damage_dice' => '2d8',
        'damage_type' => 'physical', 'attack_speed' => 4, 'range_hexes' => 1,
        'melee_reach' => 1, 'weapon_template' => 'slam',
        'hit_message' => '%{attacker} slams %{target} with a powerful fist!',
        'miss_message' => '%{attacker} swings wildly at %{target} but misses!',
        'critical_message' => '%{attacker} lands a devastating blow on %{target}!' }
    ]
  },
  {
    type: 'troll',
    archetype_name: 'Delve Troll',
    short_desc: 'a towering troll with long arms and mottled skin',
    attacks: [
      { 'name' => 'Claw', 'attack_type' => 'melee', 'damage_dice' => '2d6',
        'damage_type' => 'physical', 'attack_speed' => 5, 'range_hexes' => 2,
        'melee_reach' => 2, 'weapon_template' => 'claw',
        'hit_message' => '%{attacker} rakes %{target} with enormous claws!',
        'miss_message' => '%{attacker} swipes at %{target} but its claws cut only air!',
        'critical_message' => '%{attacker} tears into %{target} with both claws!' },
      { 'name' => 'Slam', 'attack_type' => 'melee', 'damage_dice' => '2d8',
        'damage_type' => 'physical', 'attack_speed' => 3, 'range_hexes' => 2,
        'melee_reach' => 2, 'weapon_template' => 'slam',
        'hit_message' => '%{attacker} slams %{target} with a massive fist!',
        'miss_message' => '%{attacker} pounds the ground near %{target} but misses!',
        'critical_message' => '%{attacker} delivers an earth-shaking slam to %{target}!' }
    ]
  },
  {
    type: 'ogre',
    archetype_name: 'Delve Ogre',
    short_desc: 'a massive ogre with a dim but brutal disposition',
    attacks: [
      { 'name' => 'Slam', 'attack_type' => 'melee', 'damage_dice' => '3d6',
        'damage_type' => 'physical', 'attack_speed' => 3, 'range_hexes' => 2,
        'melee_reach' => 2, 'weapon_template' => 'slam',
        'hit_message' => '%{attacker} slams %{target} with a colossal fist!',
        'miss_message' => '%{attacker} smashes the ground where %{target} was standing!',
        'critical_message' => '%{attacker} crushes %{target} with a tremendous blow!' }
    ]
  },
  {
    type: 'demon',
    archetype_name: 'Delve Demon',
    short_desc: 'a fiendish demon wreathed in dark flames',
    attacks: [
      { 'name' => 'Claw', 'attack_type' => 'melee', 'damage_dice' => '2d8',
        'damage_type' => 'physical', 'attack_speed' => 5, 'range_hexes' => 1,
        'melee_reach' => 1, 'weapon_template' => 'claw',
        'hit_message' => '%{attacker} rakes %{target} with burning claws!',
        'miss_message' => '%{attacker} slashes at %{target} but its claws miss!',
        'critical_message' => '%{attacker} tears into %{target} with hellish claws!' },
      { 'name' => 'Hellfire', 'attack_type' => 'ranged', 'damage_dice' => '3d6',
        'damage_type' => 'fire', 'attack_speed' => 2, 'range_hexes' => 6,
        'weapon_template' => 'breath_fire',
        'hit_message' => '%{attacker} hurls a bolt of hellfire at %{target}!',
        'miss_message' => '%{attacker} launches hellfire but %{target} dodges the flames!',
        'critical_message' => '%{attacker} engulfs %{target} in searing hellfire!' }
    ]
  },
  {
    type: 'dragon',
    archetype_name: 'Delve Dragon',
    short_desc: 'a fearsome dragon with scales like forged iron',
    attacks: [
      { 'name' => 'Bite', 'attack_type' => 'melee', 'damage_dice' => '3d8',
        'damage_type' => 'physical', 'attack_speed' => 4, 'range_hexes' => 2,
        'melee_reach' => 2, 'weapon_template' => 'bite',
        'hit_message' => '%{attacker} bites %{target} with massive jaws!',
        'miss_message' => '%{attacker} snaps at %{target} but its jaws close on empty air!',
        'critical_message' => '%{attacker} clamps down on %{target} with bone-crushing force!' },
      { 'name' => 'Fire breath', 'attack_type' => 'ranged', 'damage_dice' => '4d6',
        'damage_type' => 'fire', 'attack_speed' => 2, 'range_hexes' => 8,
        'weapon_template' => 'breath_fire',
        'hit_message' => '%{attacker} bathes %{target} in dragonfire!',
        'miss_message' => '%{attacker} unleashes a torrent of flame but %{target} evades!',
        'critical_message' => '%{attacker} engulfs %{target} in a devastating blast of dragonfire!' }
    ]
  }
].freeze

puts "Seeding delve monster archetypes..."

MONSTERS.each do |monster|
  # Character model titlecases forenames on save, so we match that for lookups
  forename = "monster:#{monster[:type]}"
  stored_forename = forename.sub(/\A(.)/) { $1.upcase }

  # Find or create the archetype
  archetype = NpcArchetype.first(name: monster[:archetype_name])
  if archetype
    # Update attacks on existing archetype
    archetype.update(npc_attacks: monster[:attacks])
    puts "  Updated archetype: #{archetype.name} (ID: #{archetype.id})"
  else
    archetype = NpcArchetype.create(
      name: monster[:archetype_name],
      behavior_pattern: 'aggressive',
      is_humanoid: false,
      npc_attacks: Sequel.pg_jsonb_wrap(monster[:attacks])
    )
    puts "  Created archetype: #{archetype.name} (ID: #{archetype.id})"
  end

  # Find or create the template character
  character = Character.first(forename: stored_forename)
  if character
    puts "  Character already exists: #{character.forename} (ID: #{character.id})"
  else
    character = Character.create(
      forename: forename,
      is_npc: true,
      is_unique_npc: false,
      npc_archetype_id: archetype.id,
      short_desc: monster[:short_desc]
    )
    puts "  Created character: #{character.forename} (ID: #{character.id})"
  end
end

puts "\nDone! Seeded #{MONSTERS.size} monster archetypes."
