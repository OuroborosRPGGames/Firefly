# frozen_string_literal: true

# Executes Ruby code blocks from triggers in a sandboxed context.
# Provides a safe DSL for common game actions.
module TriggerCodeExecutor
  # Timeout for code execution (prevent infinite loops)
  EXECUTION_TIMEOUT = GameConfig::LLM::TIMEOUTS[:trigger_code]

  # Sandboxed execution context with safe DSL methods
  class SandboxContext
    include CharacterLookupHelper

    attr_reader :context, :activation, :results

    def initialize(context:, activation:)
      @context = context
      @activation = activation
      @results = []
    end

    # DSL Methods available in trigger code

    # Broadcast a message to a room
    def broadcast_to_room(room_id, message, type: :system)
      BroadcastService.to_room(room_id, message, type: type)
      results << "Broadcast to room #{room_id}"
    end

    # Send a message to a specific character by ID
    def send_to_character(character_id, message)
      instance = find_online_character(character_id)
      return results << "Character #{character_id} not online" unless instance

      BroadcastService.to_character(instance, message, type: :system)
      results << "Message sent to character #{character_id}"
    end

    # Award currency to a character
    def award_currency(character_id, amount, currency_name: 'credits')
      wallet = Wallet.first(character_id: character_id)
      return results << "No wallet for character #{character_id}" unless wallet

      wallet.add_currency(currency_name, amount)
      results << "Awarded #{amount} #{currency_name} to character #{character_id}"
    end

    # Spawn an NPC at a location
    def spawn_npc(character_id, room_id)
      NpcSpawnService.spawn_at_room(character_id: character_id, room_id: room_id)
      results << "Spawned NPC #{character_id} at room #{room_id}"
    end

    # Despawn an NPC
    def despawn_npc(character_id)
      instance = find_online_character(character_id)
      return results << "NPC #{character_id} not online" unless instance

      instance.update(online: false)
      results << "Despawned NPC #{character_id}"
    end

    # Update a game setting
    def set_game_setting(key, value)
      GameSetting.set(key, value)
      results << "Set game setting #{key} = #{value}"
    end

    # Get a game setting
    def game_setting(key)
      GameSetting.get(key)
    end

    # Start an activity for a character
    def start_activity(activity_id, room_id:, initiator_id:)
      activity = Activity[activity_id]
      return results << "Activity #{activity_id} not found" unless activity

      room = Room[room_id]
      return results << "Room #{room_id} not found" unless room

      initiator = find_online_character(initiator_id)
      return results << "Initiator #{initiator_id} not online" unless initiator

      ActivityService.start_activity(activity, room: room, initiator: initiator)
      results << "Started activity #{activity_id} in room #{room_id}"
    end

    # Send a staff alert
    def alert_staff(message)
      StaffAlertService.broadcast_to_staff(message)
      results << "Alerted staff: #{message}"
    end

    # Log a message (for debugging)
    def log(message)
      warn "[TriggerCode] #{message}"
      results << "Logged: #{message}"
    end

    # Access activation context
    def trigger_context
      context
    end

    def source_character_id
      activation.source_character_id
    end

    def source_room_id
      context[:room_id]
    end

    def source_character
      activation.source_character
    end

    # Get clue recipient (for clue_share triggers)
    def clue_recipient_id
      activation.clue_recipient_id
    end

    def clue_id
      activation.clue_id
    end
  end

  class << self
    # Execute trigger code in sandboxed context
    # @param code [String] Ruby code to execute
    # @param context [Hash] Activation context
    # @param activation [TriggerActivation] The activation record
    # @return [String] Execution results
    def execute(code:, context:, activation:)
      return 'No code to execute' if code.nil? || code.strip.empty?

      sandbox = SandboxContext.new(context: context, activation: activation)

      Timeout.timeout(EXECUTION_TIMEOUT) do
        sandbox.instance_eval(code)
      end

      sandbox.results.join('; ')
    rescue Timeout::Error
      raise "Code execution timed out after #{EXECUTION_TIMEOUT} seconds"
    rescue SyntaxError => e
      raise "Syntax error in trigger code: #{e.message}"
    rescue StandardError => e
      raise "Execution error: #{e.class.name}: #{e.message}"
    end

    # Validate code syntax without executing
    # @param code [String] Ruby code to validate
    # @return [Hash] { valid: Boolean, error: String or nil }
    def validate_syntax(code)
      return { valid: true, error: nil } if code.nil? || code.strip.empty?

      RubyVM::InstructionSequence.compile(code)
      { valid: true, error: nil }
    rescue SyntaxError => e
      { valid: false, error: e.message }
    end
  end
end
