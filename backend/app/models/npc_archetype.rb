# frozen_string_literal: true

class NpcArchetype < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  one_to_many :characters
  many_to_one :created_by, class: :User
  many_to_one :monster_template

  BEHAVIOR_PATTERNS = %w[friendly hostile neutral merchant guard aggressive passive].freeze
  ANIMATION_LEVELS = %w[off low medium high].freeze

  def validate
    super
    validates_presence [:name]
    validates_unique :name
    validates_max_length 100, :name
    validates_includes BEHAVIOR_PATTERNS, :behavior_pattern if behavior_pattern
    validates_includes ANIMATION_LEVELS, :animation_level if animation_level
  end

  def before_save
    super
    self.is_humanoid = true if is_humanoid.nil?
    self.name_pattern ||= '{archetype}'
    self.name_counter ||= 0
    self.spawn_health_range ||= '100-100'
    self.spawn_level_range ||= '1-1'
  end

  # Create a unique NPC from this archetype
  def create_unique_npc(forename, options = {})
    Character.create(
      forename: forename,
      surname: options[:surname],
      race: options[:race] || race,
      character_class: options[:character_class] || character_class,
      gender: options[:gender],
      age: options[:age],
      short_desc: options[:short_desc],
      is_npc: true,
      is_unique_npc: true,
      npc_archetype: self,
      npc_hair_desc: options[:hair_desc] || default_hair_desc,
      npc_eyes_desc: options[:eyes_desc] || default_eyes_desc,
      npc_skin_tone: options[:skin_tone] || default_skin_tone,
      npc_body_desc: options[:body_desc] || default_body_desc,
      npc_clothes_desc: options[:clothes_desc] || default_clothes_desc,
      npc_creature_desc: options[:creature_desc] || default_creature_desc,
      picture_url: options[:picture_url] || profile_image_url
    )
  end

  # Create a template NPC (non-unique) from this archetype
  def create_template_npc(options = {})
    template_name = options[:name] || name
    Character.create(
      forename: template_name,
      surname: nil,
      race: options[:race] || race,
      character_class: options[:character_class] || character_class,
      gender: options[:gender],
      age: options[:age],
      short_desc: options[:short_desc],
      is_npc: true,
      is_unique_npc: false, # Template!
      npc_archetype: self,
      npc_hair_desc: options[:hair_desc] || default_hair_desc,
      npc_eyes_desc: options[:eyes_desc] || default_eyes_desc,
      npc_skin_tone: options[:skin_tone] || default_skin_tone,
      npc_body_desc: options[:body_desc] || default_body_desc,
      npc_clothes_desc: options[:clothes_desc] || default_clothes_desc,
      npc_creature_desc: options[:creature_desc] || default_creature_desc,
      picture_url: options[:picture_url] || profile_image_url
    )
  end

  # Spawn a CharacterInstance from a template Character
  def spawn_instance_from_template(template_character, room, options = {})
    raise ArgumentError, 'Template character required' unless template_character

    # Calculate stats from ranges
    health = parse_range(spawn_health_range)
    level = parse_range(spawn_level_range)

    # Get or create reality
    reality = options[:reality] || Reality.first(reality_type: 'primary')
    raise ArgumentError, 'No reality available for spawning' unless reality

    # Create character instance
    instance = CharacterInstance.create(
      character_id: template_character.id,
      reality_id: reality.id,
      current_room_id: room.id,
      level: level,
      health: health,
      max_health: health,
      mana: 50,
      max_mana: 50,
      online: true,
      status: 'alive',
      roomtitle: options[:activity]
    )

    instance
  end

  # Generate a name for a spawned NPC
  def generate_spawn_name
    update(name_counter: (name_counter || 0) + 1)

    (name_pattern || '{archetype}')
      .gsub('{archetype}', name)
      .gsub('{n}', name_counter.to_s)
      .gsub('{N}', name_counter.to_s.rjust(GameConfig::Character::NAME_COUNTER_PADDING, '0'))
  end

  # Legacy compatibility - use create_unique_npc instead
  alias_method :create_npc_character, :create_unique_npc

  # ============================================
  # Access Control
  # ============================================

  # Check if a user can view/edit this archetype
  # @param user [User] the user to check
  # @return [Boolean]
  def accessible_by?(user)
    return true if user.admin?
    return true if user.can_manage_npcs?
    return true if created_by_id == user.id

    false
  end

  # Get all archetypes accessible by a user
  # @param user [User] the user
  # @return [Sequel::Dataset]
  def self.accessible_by(user)
    return order(:name) if user.admin? || user.can_manage_npcs?

    where(created_by_id: user.id).order(:name)
  end

  # ============================================
  # Combat AI Configuration
  # ============================================

  # AI profile names for combat decision-making
  AI_PROFILES = %w[aggressive defensive balanced berserker coward guardian].freeze

  # Map behavior_pattern to default AI profile
  BEHAVIOR_TO_AI_PROFILE = {
    'aggressive' => 'aggressive',
    'hostile' => 'aggressive',
    'passive' => 'defensive',
    'friendly' => 'coward',
    'guard' => 'guardian',
    'neutral' => 'balanced',
    'merchant' => 'coward'
  }.freeze

  # Get abilities this archetype can use in combat
  # @return [Array<Ability>] available combat abilities
  def combat_abilities
    return [] unless combat_ability_ids&.any?

    # Convert Postgres array to Ruby array for Sequel query
    ids = combat_ability_ids.to_a
    Ability.where(id: ids).all
  end

  # Get the use chance for a specific ability
  # Falls back to legacy combat_ability_chance or 30% default
  # @param ability_id [Integer] the ability ID
  # @return [Integer] percentage chance (0-100)
  def ability_chance_for(ability_id)
    chances = combat_ability_chances || {}
    chances[ability_id.to_s]&.to_i || combat_ability_chance || 30
  end

  # Get ordered list of combat abilities with their individual chances
  # @return [Array<Hash>] array of { ability: Ability, chance: Integer }
  def combat_abilities_with_chances
    return [] unless combat_ability_ids&.any?

    # Convert Postgres array to Ruby array for Sequel query
    ids = combat_ability_ids.to_a
    abilities = Ability.where(id: ids).all
    abilities.map do |ability|
      { ability: ability, chance: ability_chance_for(ability.id) }
    end
  end

  # Get the AI profile name for combat decisions
  # Uses explicit combat_ai_profile if set, otherwise maps from behavior_pattern
  # @return [String] AI profile name
  def ai_profile
    return combat_ai_profile if combat_ai_profile && AI_PROFILES.include?(combat_ai_profile)

    BEHAVIOR_TO_AI_PROFILE[behavior_pattern] || 'balanced'
  end

  # Get combat stats as a hash for FightParticipant creation
  # @return [Hash] combat stat modifiers
  def combat_stats
    {
      damage_bonus: combat_damage_bonus || 0,
      defense_bonus: combat_defense_bonus || 0,
      speed_modifier: combat_speed_modifier || 0,
      max_hp: combat_max_hp || 5,
      ability_chance: combat_ability_chance || 30,
      flee_threshold: flee_health_percent || 20,
      defensive_threshold: defensive_health_percent || 50,
      damage_dice_count: damage_dice_count || 2,
      damage_dice_sides: damage_dice_sides || 8
    }
  end

  # Check if this archetype has combat abilities configured
  # @return [Boolean]
  def has_combat_abilities?
    combat_ability_ids&.any?
  end
  alias combat_abilities? has_combat_abilities?

  # ============================================
  # NPC Natural Attacks
  # ============================================

  # Parse npc_attacks JSONB into NpcAttack value objects
  # @return [Array<NpcAttack>]
  def parsed_npc_attacks
    attacks = npc_attacks
    return [] if attacks.nil? || attacks.empty?

    # Handle both Sequel::Postgres::JSONBHash and Array
    attack_array = case attacks
                   when Array then attacks
                   when Hash then [attacks]
                   else
                     attacks.respond_to?(:to_a) ? attacks.to_a : []
                   end

    attack_array.map { |data| NpcAttack.new(data) }
  end

  # Get only melee attacks
  # @return [Array<NpcAttack>]
  def melee_attacks
    parsed_npc_attacks.select(&:melee?)
  end

  # Get only ranged attacks
  # @return [Array<NpcAttack>]
  def ranged_attacks
    parsed_npc_attacks.select(&:ranged?)
  end

  # Check if this archetype has natural attacks defined
  # @return [Boolean]
  def has_natural_attacks?
    !npc_attacks.nil? && !npc_attacks.empty?
  end
  alias natural_attacks? has_natural_attacks?

  # Get the best attack for a given range
  # Prefers attacks that can actually reach the target
  # @param distance [Integer] Distance in hexes to target
  # @return [NpcAttack, nil]
  def best_attack_for_range(distance)
    attacks = parsed_npc_attacks
    return nil if attacks.empty?

    # First try to find an attack that's in range
    in_range_attacks = attacks.select { |a| a.in_range?(distance) }
    return in_range_attacks.max_by(&:expected_damage) if in_range_attacks.any?

    # Fall back to the attack with the longest range (need to close distance)
    attacks.max_by(&:range_hexes)
  end

  # Get the primary melee attack (highest damage)
  # @return [NpcAttack, nil]
  def primary_melee_attack
    melee_attacks.max_by(&:expected_damage)
  end

  # Get the primary ranged attack (highest damage)
  # @return [NpcAttack, nil]
  def primary_ranged_attack
    ranged_attacks.max_by(&:expected_damage)
  end

  # Add a new attack to this archetype
  # @param attack [NpcAttack, Hash] The attack to add
  def add_attack(attack)
    attack_data = attack.is_a?(NpcAttack) ? attack.to_h : attack
    current = npc_attacks || []
    self.npc_attacks = current + [attack_data]
  end

  # Remove an attack by name
  # @param name [String] Name of the attack to remove
  def remove_attack(name)
    current = npc_attacks || []
    self.npc_attacks = current.reject { |a| a['name'] == name }
  end

  # Set attacks from an array of attack data
  # @param attacks [Array<Hash>] Array of attack data hashes
  def set_attacks(attacks)
    self.npc_attacks = attacks.map do |a|
      a.is_a?(NpcAttack) ? a.to_h : a
    end
  end

  # ============================================
  # Animation Configuration
  # ============================================

  # Supported animation models
  ANIMATION_MODELS = {
    'claude-opus-4-6' => 'anthropic',
    'claude-sonnet-4-6' => 'anthropic',
    'claude-haiku-4-5' => 'anthropic',
    'deepseek/deepseek-v3.2' => 'openrouter',
    'moonshotai/kimi-k2-0905' => 'openrouter',
    'gemini-3.1-flash-lite-preview' => 'google_gemini'
  }.freeze

  # Claude models support partial response prefix
  CLAUDE_MODELS = %w[claude-opus-4-6 claude-sonnet-4-6 claude-haiku-4-5].freeze

  # Check if animation is enabled for this archetype
  # @return [Boolean]
  def animated?
    !animation_level.nil? && animation_level != 'off'
  end

  # Get the animation level, defaulting to 'off'
  # @return [String]
  def effective_animation_level
    ANIMATION_LEVELS.include?(animation_level) ? animation_level : 'off'
  end

  # Get the primary model for animation
  # @return [String]
  def effective_primary_model
    animation_primary_model || 'claude-sonnet-4-6'
  end

  # Get the first emote model (typically Opus for establishing character)
  # @return [String]
  def effective_first_emote_model
    animation_first_emote_model || 'claude-opus-4-6'
  end

  # Get the memory/summarization model
  # @return [String]
  def effective_memory_model
    animation_memory_model || 'gemini-3.1-flash-lite-preview'
  end

  # Get fallback models as an array
  # @return [Array<String>]
  def fallback_models
    return [] if animation_fallback_models.nil?

    case animation_fallback_models
    when Array
      animation_fallback_models
    when String
      begin
        JSON.parse(animation_fallback_models)
      rescue JSON::ParserError => e
        warn "[NpcArchetype] Invalid JSON in animation_fallback_models for archetype #{id}: #{e.message}"
        []
      end
    else
      []
    end
  end

  # Get the provider for a given model
  # @param model [String] model identifier
  # @return [String] provider name
  def self.provider_for_model(model)
    ANIMATION_MODELS[model] || 'anthropic'
  end

  # Check if a model is a Claude model (supports partial response)
  # @param model [String] model identifier
  # @return [Boolean]
  def self.claude_model?(model)
    CLAUDE_MODELS.include?(model)
  end

  # Get cooldown seconds, defaulting to 5 minutes
  # @return [Integer]
  def effective_cooldown_seconds
    animation_cooldown_seconds || 300
  end

  # Check if outfit should be generated on spawn
  # @return [Boolean]
  def should_generate_outfit?
    animated? && generate_outfit_on_spawn == true
  end

  # Check if status should be generated on spawn
  # @return [Boolean]
  def should_generate_status?
    animated? && generate_status_on_spawn == true
  end

  # Get the personality prompt, falling back to behavior pattern
  # @return [String]
  def effective_personality_prompt
    if StringHelper.present?(animation_personality_prompt)
      animation_personality_prompt
    else
      "A #{behavior_pattern || 'neutral'} #{name}"
    end
  end

  # Get example dialogue lines, or nil if not set
  # @return [String, nil]
  def effective_example_dialogue
    StringHelper.present?(example_dialogue) ? example_dialogue : nil
  end

  # Get speech quirks, or nil if not set
  # @return [String, nil]
  def effective_speech_quirks
    StringHelper.present?(speech_quirks) ? speech_quirks : nil
  end

  # Get vocabulary notes, or nil if not set
  # @return [String, nil]
  def effective_vocabulary_notes
    StringHelper.present?(vocabulary_notes) ? vocabulary_notes : nil
  end

  # Get character flaws, or nil if not set
  # @return [String, nil]
  def effective_character_flaws
    StringHelper.present?(character_flaws) ? character_flaws : nil
  end

  private

  def parse_range(range_str)
    return 100 unless range_str

    parts = range_str.split('-').map(&:to_i)
    if parts.length == 2 && parts[1] > parts[0]
      rand(parts[0]..parts[1])
    else
      parts[0] || 100
    end
  end
end