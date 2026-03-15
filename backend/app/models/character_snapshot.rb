# frozen_string_literal: true

class CharacterSnapshot < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :room
  one_to_many :timelines, key: :snapshot_id

  def validate
    super
    validates_presence [:character_id, :name, :frozen_state, :snapshot_taken_at]
    validates_unique [:character_id, :name]
    validates_max_length 100, :name
  end

  # Take a snapshot of a character instance's current state
  # Captures who's in the room - only they can join this timeline later
  def self.capture(character_instance, name:, description: nil)
    char = character_instance.character
    room = character_instance.current_room

    # Capture who's in the room right now (these characters can join later)
    # Always include the creator even if their online status is false
    present_character_ids = room.characters_here(character_instance.reality_id, viewer: character_instance)
                                .select_map(:character_id)
    present_character_ids = (present_character_ids + [char.id]).uniq

    create(
      character_id: char.id,
      room_id: room.id,
      name: name,
      description: description,
      frozen_state: Sequel.pg_jsonb_wrap(capture_state(character_instance)),
      frozen_inventory: Sequel.pg_jsonb_wrap(capture_inventory(character_instance)),
      frozen_descriptions: Sequel.pg_jsonb_wrap(capture_descriptions(character_instance)),
      allowed_character_ids: Sequel.pg_jsonb_wrap(present_character_ids),
      snapshot_taken_at: Time.now
    )
  end

  # Check if a character is allowed to enter this snapshot's timeline
  def can_enter?(character)
    parsed_allowed_ids.include?(character.id)
  end

  def parsed_allowed_ids
    return [] if allowed_character_ids.nil?

    if allowed_character_ids.is_a?(String)
      begin
        JSON.parse(allowed_character_ids)
      rescue JSON::ParserError => e
        warn "[CharacterSnapshot] Invalid JSON in allowed_character_ids for snapshot #{id}: #{e.message}"
        []
      end
    else
      allowed_character_ids.to_a
    end
  end

  def parsed_frozen_state
    return {} if frozen_state.nil?

    if frozen_state.is_a?(String)
      begin
        JSON.parse(frozen_state)
      rescue JSON::ParserError => e
        warn "[CharacterSnapshot] Invalid JSON in frozen_state for snapshot #{id}: #{e.message}"
        {}
      end
    else
      frozen_state
    end
  end

  def parsed_frozen_inventory
    return [] if frozen_inventory.nil?

    if frozen_inventory.is_a?(String)
      begin
        JSON.parse(frozen_inventory)
      rescue JSON::ParserError => e
        warn "[CharacterSnapshot] Invalid JSON in frozen_inventory for snapshot #{id}: #{e.message}"
        []
      end
    else
      frozen_inventory.to_a
    end
  end

  def parsed_frozen_descriptions
    return [] if frozen_descriptions.nil?

    if frozen_descriptions.is_a?(String)
      begin
        JSON.parse(frozen_descriptions)
      rescue JSON::ParserError => e
        warn "[CharacterSnapshot] Invalid JSON in frozen_descriptions for snapshot #{id}: #{e.message}"
        []
      end
    else
      frozen_descriptions.to_a
    end
  end

  # Restore snapshot state to a character instance
  def restore_to_instance(character_instance)
    state = parsed_frozen_state

    character_instance.update(
      level: state['level'] || 1,
      health: state['health'] || state['max_health'] || 100,
      max_health: state['max_health'] || 100,
      mana: state['mana'] || state['max_mana'] || 50,
      max_mana: state['max_mana'] || 50,
      experience: state['experience'] || 0,
      status: 'alive',  # Always restore as alive
      stance: state['stance'] || 'standing'
    )

    restore_stats(character_instance, state['stats'])
    restore_abilities(character_instance, state['abilities'])
  end

  # Get the allowed characters as Character objects
  def allowed_characters
    Character.where(id: parsed_allowed_ids).all
  end

  private

  def self.capture_state(ci)
    {
      level: ci.level,
      experience: ci.experience,
      health: ci.health,
      max_health: ci.max_health,
      mana: ci.mana,
      max_mana: ci.max_mana,
      status: ci.status,
      stance: ci.stance,
      stats: capture_stats(ci),
      abilities: capture_abilities(ci)
    }
  end

  def self.capture_stats(ci)
    ci.character_stats.map do |cs|
      {
        stat_id: cs.stat_id,
        base_value: cs.base_value,
        current_value: cs.respond_to?(:current_value) ? cs.current_value : cs.base_value
      }
    end
  end

  def self.capture_abilities(ci)
    ci.character_abilities.map do |ca|
      {
        ability_id: ca.ability_id,
        proficiency_level: ca.respond_to?(:proficiency_level) ? ca.proficiency_level : 1
      }
    end
  end

  def self.capture_inventory(ci)
    ci.objects.map do |item|
      {
        pattern_id: item.pattern_id,
        name: item.name,
        description: item.description,
        worn: item.worn || false,
        held: item.held || false,
        equipped: item.equipped || false,
        equipment_slot: item.equipment_slot,
        worn_layer: item.worn_layer,
        concealed: item.concealed || false,
        zipped: item.zipped || false,
        quantity: item.quantity || 1,
        condition: item.condition || 'good'
      }
    end
  end

  def self.capture_descriptions(ci)
    ci.character_descriptions.map do |desc|
      {
        body_position_id: desc.respond_to?(:body_position_id) ? desc.body_position_id : nil,
        description_type_id: desc.description_type_id,
        content: desc.content,
        image_url: desc.respond_to?(:image_url) ? desc.image_url : nil,
        active: desc.active != false
      }
    end
  end

  def restore_stats(ci, stats_data)
    return if stats_data.nil? || stats_data.empty?

    stats_data.each do |stat|
      existing = ci.character_stats_dataset.first(stat_id: stat['stat_id'])
      if existing
        existing.update(base_value: stat['base_value'])
      else
        ci.add_character_stat(stat_id: stat['stat_id'], base_value: stat['base_value'])
      end
    end
  end

  def restore_abilities(ci, abilities_data)
    return if abilities_data.nil? || abilities_data.empty?

    abilities_data.each do |ability|
      existing = ci.character_abilities_dataset.first(ability_id: ability['ability_id'])
      if existing
        existing.update(proficiency_level: ability['proficiency_level']) if existing.respond_to?(:proficiency_level=)
      else
        ci.add_character_ability(ability_id: ability['ability_id'])
      end
    end
  end
end
