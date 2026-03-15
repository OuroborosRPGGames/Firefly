# frozen_string_literal: true

# Alternates character names with descriptive phrases to create varied prose.
# Inspired by cyberrun's alt_fight_name() function.
#
# Uses character appearance data (eye color, hair, body type, height, gender)
# to generate descriptive alternatives like "the blue-eyed woman" or
# "the tall fighter".
#
# @example
#   service = CombatNameAlternationService.new(fight)
#   service.name_for(participant)  # "Alice"
#   service.name_for(participant)  # "the blue-eyed woman"
#   service.name_for(participant)  # "Alice"
#
class CombatNameAlternationService
  # Helper: returns nil if string is nil or empty, otherwise returns the string
  # Equivalent to ActiveSupport's #presence
  def self.present_or_nil(str)
    str.nil? || str.empty? ? nil : str
  end
  # Probability of using actual name vs descriptor (from GameConfig)
  NAME_PROBABILITY = GameConfig::Combat::NAME_ALTERNATION[:name_probability]

  # Descriptor probabilities (each rolled independently if name not used)
  DESCRIPTOR_PROBABILITIES = GameConfig::Combat::NAME_ALTERNATION[:descriptor_probabilities]

  # Gender-appropriate suffix words
  GENDER_SUFFIXES = {
    'male' => %w[man fighter combatant],
    'female' => %w[woman fighter combatant],
    'other' => %w[fighter combatant person],
    'unknown' => %w[fighter combatant person]
  }.freeze

  def initialize(fight)
    @fight = fight
    @used_descriptors = Hash.new { |h, k| h[k] = [] }
    @name_use_count = Hash.new(0)
    @weapon_use_count = Hash.new(0)
    @participant_cache = {}
  end

  # Get a name or descriptor for a participant
  #
  # @param participant [FightParticipant] The participant to name
  # @param opponent [FightParticipant, nil] Optional opponent for comparison
  # @return [String] Name or descriptor
  def name_for(participant, opponent: nil)
    @name_use_count[participant.id] += 1

    # First mention always uses the actual name
    return character_name(participant) if @name_use_count[participant.id] == 1

    # 70% chance to use actual name on subsequent mentions
    return character_name(participant) if rand(100) < NAME_PROBABILITY

    # Try to generate a descriptor
    descriptor = try_descriptors(participant, opponent)

    descriptor || character_name(participant)
  end

  # Get pronoun for a participant (he/she/they)
  # Delegates to Character#pronoun_subject
  #
  # @param participant [FightParticipant] The participant
  # @return [String] Pronoun
  def pronoun_for(participant)
    char = character_for(participant)
    char&.pronoun_subject || 'they'
  end

  # Get possessive pronoun (his/her/their)
  # Delegates to Character#pronoun_possessive
  #
  # @param participant [FightParticipant] The participant
  # @return [String] Possessive pronoun
  def possessive_for(participant)
    char = character_for(participant)
    char&.pronoun_possessive || 'their'
  end

  # Get object pronoun (him/her/them)
  # Delegates to Character#pronoun_object
  #
  # @param participant [FightParticipant] The participant
  # @return [String] Object pronoun
  def object_pronoun_for(participant)
    char = character_for(participant)
    char&.pronoun_object || 'them'
  end

  # Get weapon name with alternation based on use count
  #
  # @param participant [FightParticipant] The participant
  # @param weapon_type [Symbol] :melee or :ranged
  # @return [String] Weapon description
  def weapon_name_for(participant, weapon_type: :melee)
    weapon = weapon_type == :ranged ? participant.ranged_weapon : participant.melee_weapon

    return 'fists' unless weapon&.pattern

    @weapon_use_count[[participant.id, weapon_type]] += 1
    use_count = @weapon_use_count[[participant.id, weapon_type]]

    pattern = weapon.pattern
    raw_name = pattern.description || pattern.name || 'weapon'
    # Strip HTML color spans then remove leading article
    plain_name = raw_name.gsub(/<[^>]+>/, '')
    full_name = plain_name.sub(/^(a|an|the)\s+/i, '')
    short_name = extract_weapon_short_name(plain_name)
    category = categorize_weapon(plain_name)

    case use_count
    when 1
      # Use appropriate article based on first letter
      article = full_name.match?(/^[aeiou]/i) ? 'an' : 'a'
      "#{article} #{full_name}"
    when 2
      "#{possessive_for(participant)} #{short_name}"
    when 3
      "the #{category}"
    else
      weapon_synonym(category)
    end
  end

  # Reset tracking for a new paragraph
  def reset_paragraph_tracking!
    @used_descriptors.clear
    # Don't reset name_use_count - that persists across paragraphs
  end

  private

  # Strip leading article (a/an/the) from a string, handling HTML span-wrapped characters
  # Pattern descriptions may have per-character color spans like:
  #   <span style="...">A</span><span style="..."> </span><span style="...">h</span>...
  def strip_leading_article(name)
    plain = name.gsub(/<[^>]+>/, '')
    match = plain.match(/^(a|an|the)\s+/i)
    return name unless match

    if name.include?('<')
      # Strip character-by-character from HTML, skipping tags, counting content chars
      chars_to_strip = match[0].length
      result = name.dup
      stripped = 0
      while stripped < chars_to_strip && !result.empty?
        if result.start_with?('<')
          close = result.index('>')
          result = close ? result[(close + 1)..] : ''
        else
          stripped += 1
          result = result[1..]
        end
      end
      result
    else
      plain.sub(/^(a|an|the)\s+/i, '')
    end
  end

  # Get character from participant (with caching)
  def character_for(participant)
    @participant_cache[participant.id] ||= participant.character_instance&.character
  end

  # Get character's display name
  def character_name(participant)
    name = participant.character_name
    name = participant.character_instance&.character&.full_name if name.nil? || name.empty?
    name || 'Unknown'
  end

  # Get character's gender
  def character_gender(participant)
    char = character_for(participant)
    gender = char&.gender&.downcase
    %w[male female].include?(gender) ? gender : 'unknown'
  end

  # Try each descriptor type in random order
  def try_descriptors(participant, opponent)
    descriptor_types = DESCRIPTOR_PROBABILITIES.keys.shuffle

    descriptor_types.each do |desc_type|
      next if @used_descriptors[participant.id].include?(desc_type)

      probability = DESCRIPTOR_PROBABILITIES[desc_type]
      next if rand(100) >= probability

      descriptor = generate_descriptor(participant, opponent, desc_type)
      if descriptor
        @used_descriptors[participant.id] << desc_type
        return descriptor
      end
    end

    nil
  end

  # Generate a specific type of descriptor
  def generate_descriptor(participant, opponent, desc_type)
    case desc_type
    when :name_part
      generate_name_part_descriptor(participant)
    when :eye_color
      generate_eye_color_descriptor(participant, opponent)
    when :body_type
      generate_body_type_descriptor(participant, opponent)
    when :height
      generate_height_descriptor(participant, opponent)
    when :hair
      generate_hair_descriptor(participant, opponent)
    when :weapon
      generate_weapon_descriptor(participant, opponent)
    end
  end

  # "the woman", "the man", "the fighter"
  def generate_name_part_descriptor(participant)
    suffix = gender_suffix(participant)
    "the #{suffix}"
  end

  # "the blue-eyed woman"
  def generate_eye_color_descriptor(participant, opponent)
    char = character_for(participant)
    return nil unless char

    eye_color = (char.respond_to?(:custom_eye_color) && self.class.present_or_nil(char.custom_eye_color.to_s)) ||
                (char.respond_to?(:eye_color) && self.class.present_or_nil(char.eye_color.to_s))
    return nil unless eye_color

    # Only use if different from opponent
    if opponent
      opp_char = character_for(opponent)
      if opp_char
        opp_eye = (opp_char.respond_to?(:custom_eye_color) && self.class.present_or_nil(opp_char.custom_eye_color.to_s)) ||
                  (opp_char.respond_to?(:eye_color) && self.class.present_or_nil(opp_char.eye_color.to_s))
        return nil if opp_eye&.downcase == eye_color.downcase
      end
    end

    suffix = gender_suffix(participant)
    "the #{eye_color.downcase}-eyed #{suffix}"
  end

  # "the slim fighter"
  def generate_body_type_descriptor(participant, opponent)
    char = character_for(participant)
    return nil unless char

    body_type = char.respond_to?(:body_type) ? char.body_type.to_s : nil
    body_type = nil if body_type&.empty?
    return nil unless body_type
    return nil if body_type.downcase == 'average'

    # Only use if different from opponent
    if opponent
      opp_char = character_for(opponent)
      opp_body = opp_char.respond_to?(:body_type) ? opp_char.body_type : nil
      return nil if opp_body&.downcase == body_type.downcase
    end

    suffix = gender_suffix(participant)
    "the #{body_type.downcase} #{suffix}"
  end

  # "the tall man", "the short fighter"
  def generate_height_descriptor(participant, opponent)
    char = character_for(participant)
    return nil unless char

    height = char.respond_to?(:height_cm) ? char.height_cm : nil
    return nil unless height && height > 0

    # Only use with significant height difference
    if opponent
      opp_char = character_for(opponent)
      opp_height = opp_char&.respond_to?(:height_cm) ? opp_char.height_cm : nil
      return nil unless opp_height && opp_height > 0

      diff = (height - opp_height).abs
      return nil if diff < GameConfig::Combat::HEIGHT_THRESHOLDS[:significant_diff]
    end

    height_word = if height < GameConfig::Combat::HEIGHT_THRESHOLDS[:short_max]
                    'short'
                  elsif height > GameConfig::Combat::HEIGHT_THRESHOLDS[:tall_min]
                    'tall'
                  else
                    return nil # Average height, don't describe
                  end

    suffix = gender_suffix(participant)
    "the #{height_word} #{suffix}"
  end

  # "the blonde fighter"
  def generate_hair_descriptor(participant, opponent)
    char = character_for(participant)
    return nil unless char

    hair_color = (char.respond_to?(:custom_hair_color) && self.class.present_or_nil(char.custom_hair_color.to_s)) ||
                 (char.respond_to?(:hair_color) && self.class.present_or_nil(char.hair_color.to_s))
    return nil unless hair_color

    # Only use if different from opponent
    if opponent
      opp_char = character_for(opponent)
      if opp_char
        opp_hair = (opp_char.respond_to?(:custom_hair_color) && self.class.present_or_nil(opp_char.custom_hair_color.to_s)) ||
                   (opp_char.respond_to?(:hair_color) && self.class.present_or_nil(opp_char.hair_color.to_s))
        return nil if opp_hair&.downcase == hair_color.downcase
      end
    end

    suffix = gender_suffix(participant)
    "the #{hair_color.downcase}-haired #{suffix}"
  end

  # "the sword-wielding man"
  def generate_weapon_descriptor(participant, opponent)
    weapon = participant.melee_weapon || participant.ranged_weapon
    return nil unless weapon&.pattern

    weapon_name = weapon.pattern.description || weapon.pattern.name
    return nil unless weapon_name

    # Only use if different from opponent
    if opponent
      opp_weapon = opponent.melee_weapon || opponent.ranged_weapon
      opp_name = opp_weapon&.pattern&.description || opp_weapon&.pattern&.name
      return nil if opp_name&.downcase&.include?(weapon_name.downcase.split.last)
    end

    wielding = extract_wielding_string(weapon_name)
    suffix = gender_suffix(participant)
    "the #{wielding} #{suffix}"
  end

  # Get gender-appropriate suffix word
  def gender_suffix(participant)
    gender = character_gender(participant)
    GENDER_SUFFIXES[gender].sample
  end

  # Extract wielding string from weapon name
  def extract_wielding_string(weapon_name)
    name = weapon_name.downcase

    # Map weapon types to wielding descriptions
    case name
    when /sword/ then 'sword-wielding'
    when /knife|dagger/ then 'knife-wielding'
    when /axe/ then 'axe-wielding'
    when /hammer|mace/ then 'hammer-wielding'
    when /spear|lance/ then 'spear-wielding'
    when /bow/ then 'bow-wielding'
    when /pistol|gun/ then 'pistol-wielding'
    when /rifle/ then 'rifle-wielding'
    when /staff/ then 'staff-wielding'
    when /club/ then 'club-wielding'
    else 'armed'
    end
  end

  # Extract short weapon name (last word)
  def extract_weapon_short_name(full_name)
    words = full_name.split
    words.last || 'weapon'
  end

  # Categorize weapon for generic descriptions
  def categorize_weapon(full_name)
    name = full_name.downcase

    case name
    when /sword/ then 'blade'
    when /knife|dagger/ then 'blade'
    when /axe/ then 'axe'
    when /hammer|mace/ then 'weapon'
    when /spear|lance/ then 'weapon'
    when /bow/ then 'bow'
    when /pistol/ then 'gun'
    when /rifle/ then 'rifle'
    when /staff/ then 'staff'
    else 'weapon'
    end
  end

  # Get weapon synonym for variety
  def weapon_synonym(category)
    synonyms = {
      'blade' => ['the weapon', 'the steel', 'the blade'],
      'axe' => ['the weapon', 'the heavy blade'],
      'gun' => ['the weapon', 'the firearm'],
      'rifle' => ['the weapon', 'the firearm', 'the long gun'],
      'bow' => ['the weapon', 'the bow'],
      'staff' => ['the weapon', 'the staff'],
      'weapon' => ['the weapon', 'their armament']
    }

    (synonyms[category] || ['the weapon']).sample
  end
end
