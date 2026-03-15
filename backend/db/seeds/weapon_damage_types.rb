# frozen_string_literal: true

# Seed weapon patterns with damage types
# Maps weapon categories to appropriate damage types

puts 'Updating weapon patterns with damage types...'

# Damage type mappings based on weapon name patterns
DAMAGE_TYPE_MAPPINGS = {
  # Slashing weapons
  /sword|saber|sabre|blade|katana|machete|axe|scimitar|cutlass|falchion|glaive/ => 'slashing',

  # Piercing weapons
  /dagger|knife|rapier|spear|lance|pike|javelin|arrow|bolt|trident|stiletto|epee|foil/ => 'piercing',

  # Bludgeoning weapons
  /hammer|mace|club|staff|flail|morningstar|quarterstaff|maul|warhammer|baton|cudgel/ => 'bludgeoning',

  # Firearms (piercing)
  /pistol|rifle|gun|musket|carbine|revolver|shotgun/ => 'piercing',

  # Energy weapons
  /laser|blaster|plasma/ => 'fire',

  # Electric weapons
  /shock|taser|stun|lightning/ => 'lightning',

  # Ice weapons
  /frost|ice|cold|cryo/ => 'cold'
}.freeze

def determine_damage_type(pattern)
  name = (pattern.description || pattern.name || '').downcase

  DAMAGE_TYPE_MAPPINGS.each do |regex, damage_type|
    return damage_type if name.match?(regex)
  end

  # Default based on source table or category
  return 'bludgeoning' if pattern.source_table == 'wpatterns'

  nil
end

# Update all weapon patterns
Pattern.weapons.each do |pattern|
  next if pattern.damage_type && !pattern.damage_type.to_s.empty?

  damage_type = determine_damage_type(pattern)
  if damage_type
    pattern.update(damage_type: damage_type)
    puts "  Updated #{pattern.description || pattern.name}: #{damage_type}"
  end
end

puts 'Done updating weapon damage types!'
