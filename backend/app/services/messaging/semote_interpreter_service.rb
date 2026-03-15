# frozen_string_literal: true

require_relative '../../lib/safe_json_helper'

# SemoteInterpreterService handles LLM-based action extraction from emotes.
#
# It sends emote text + room context to Gemini Flash Lite and receives
# a structured list of game commands to execute.
#
class SemoteInterpreterService
  extend SafeJSONHelper
  # Commands that cannot be triggered via semote
  BLOCKLIST = %w[
    pay transfer deposit withdraw
    ooc say whisper tell page
    teleport summon ban kick mute gag goto wizinvis possess
    description setdesc password email
    delete suicide quit logout disconnect
    attack fight kill challenge
    steal pickpocket rob
  ].freeze

  # Maximum LLM iterations for disambiguation
  MAX_DISAMBIGUATION_ITERATIONS = 3

  class << self
    # Check if a command is blocklisted
    # @param command [String]
    # @return [Boolean]
    def blocklisted?(command)
      BLOCKLIST.include?(command.to_s.downcase)
    end

    # Build context hash for LLM prompt
    # @param character_instance [CharacterInstance]
    # @return [Hash]
    def build_context(character_instance)
      room = character_instance.current_room
      char = character_instance.character

      {
        character_name: char.full_name,
        stance: character_instance.stance || 'standing',
        place_context: build_place_context(character_instance),
        furniture_list: build_furniture_list(room, character_instance.reality_id),
        characters_list: build_characters_list(room, character_instance),
        exits_list: build_exits_list(room),
        inventory_summary: build_inventory_summary(character_instance)
      }
    end

    # Interpret an emote and extract actions
    # @param emote_text [String]
    # @param character_instance [CharacterInstance]
    # @return [Hash] { success: Boolean, actions: Array<Hash>, error: String? }
    def interpret(emote_text, character_instance)
      context = build_context(character_instance)

      prompt = GamePrompts.get(
        'semote.action_extraction.user',
        emote_text: emote_text,
        **context
      )

      system_prompt = GamePrompts.get('semote.action_extraction.system')

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'gemini-3.1-flash-lite-preview',
        provider: 'google_gemini',
        options: { system_prompt: system_prompt, max_tokens: 500, temperature: 0.1 },
        json_mode: true
      )

      unless result[:success]
        return { success: false, actions: [], error: result[:error] }
      end

      actions = parse_llm_response(result[:text])

      # Log the interpretation
      SemoteLog.log_interpretation(
        character_instance: character_instance,
        emote_text: emote_text,
        interpreted_actions: actions
      )

      { success: true, actions: actions }
    rescue StandardError => e
      warn "[SemoteInterpreterService] Error: #{e.message}"
      { success: false, actions: [], error: e.message }
    end

    # Parse LLM response into action array
    # @param response_text [String]
    # @return [Array<Hash>]
    def parse_llm_response(response_text)
      # Extract JSON from response (may have markdown code fences)
      json_text = response_text.gsub(/```json\s*/, '').gsub(/```\s*/, '').strip

      parsed = safe_json_parse(json_text, fallback: [], context: 'SemoteInterpreterService', symbolize_names: true)
      return [] unless parsed.is_a?(Array)

      # Filter out blocklisted commands and normalize
      parsed.filter_map do |action|
        next unless action.is_a?(Hash) && action[:command]

        command = action[:command].to_s.downcase
        next if blocklisted?(command)

        { command: command, target: action[:target]&.to_s }
      end
    end

    # Handle disambiguation when a command matches multiple targets
    # @param emote_text [String]
    # @param command [String]
    # @param original_target [String]
    # @param options [Array<String>]
    # @return [String, nil] selected option or nil
    def disambiguate(emote_text, command, original_target, options)
      prompt = GamePrompts.get(
        'semote.disambiguation.user',
        emote_text: emote_text,
        command: command,
        original_target: original_target,
        options: options.map { |o| "- #{o}" }.join("\n")
      )

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'gemini-3.1-flash-lite-preview',
        provider: 'google_gemini',
        options: { max_tokens: 100, temperature: 0.1 },
        json_mode: true
      )

      return nil unless result[:success]

      parsed = JSON.parse(result[:text], symbolize_names: true)
      choice = parsed[:choice]

      # Verify choice is actually in options (case-insensitive)
      options.find { |o| o.downcase == choice.to_s.downcase }
    rescue StandardError => e
      warn "[SemoteInterpreterService] disambiguate failed: #{e.message}"
      nil
    end

    private

    def build_place_context(character_instance)
      place = character_instance.current_place
      return '' unless place

      " at #{place.name}"
    end

    def build_furniture_list(room, reality_id)
      return 'None' unless room

      places = room.places_dataset.where(invisible: false).all
      return 'None' if places.empty?

      places.map do |p|
        occupants = p.character_instances_dataset.where(reality_id: reality_id).count
        "#{p.name} (#{occupants}/#{p.capacity} occupied)"
      end.join(', ')
    end

    def build_characters_list(room, current_instance)
      return 'None' unless room

      instances = CharacterInstance
        .where(current_room_id: room.id, reality_id: current_instance.reality_id, online: true)
        .exclude(id: current_instance.id)
        .eager(:character)
        .all

      return 'None' if instances.empty?

      instances.map do |ci|
        place_info = ci.current_place ? " at #{ci.current_place.name}" : ''
        "#{ci.character.full_name} (#{ci.stance || 'standing'}#{place_info})"
      end.join(', ')
    end

    def build_exits_list(room)
      return 'None' unless room

      exits = room.passable_spatial_exits
      return 'None' if exits.empty?

      exits.map { |e| "#{e[:direction]} -> #{e[:room]&.name || 'unknown'}" }.join(', ')
    end

    def build_inventory_summary(character_instance)
      # Get consumable items only (for eat/drink/smoke context)
      # Items belong to character_instance, not character
      # Check pattern's consume_type for consumables
      items = character_instance.objects_dataset
        .eager(:pattern)
        .all
        .select { |item| item.pattern&.consumable? }
        .first(10)

      return 'None relevant' if items.empty?

      items.map(&:name).join(', ')
    end
  end
end
