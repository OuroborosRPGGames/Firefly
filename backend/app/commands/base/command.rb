# frozen_string_literal: true

require_relative '../../helpers/output_helper'
require_relative '../../helpers/string_helper'
require_relative '../../helpers/naming_helper'
require_relative '../../helpers/character_lookup_helper'
require_relative '../../helpers/display_helper'
require_relative '../../helpers/item_menu_helper'
require_relative '../../helpers/item_action_helper'
require_relative '../../helpers/currency_action_helper'
require_relative '../../helpers/restraint_action_helper'
require_relative '../../helpers/place_lookup_helper'

module Commands
  module Base
    class Command
      include OutputHelper
      include StringHelper
      include NamingHelper
      include CharacterLookupHelper
      include DisplayHelper
      include ItemMenuHelper
      include ItemActionHelper
      include CurrencyActionHelper
      include RestraintActionHelper
      include PlaceLookupHelper

      attr_reader :character_instance, :character, :location, :request_env

      def initialize(character_instance, request_env: nil)
        @character_instance = character_instance
        @character = character_instance&.character
        @location = character_instance&.current_room_id ? Room[character_instance.current_room_id] : nil
        @request_env = request_env || {}
      end

      # Provide env for OutputHelper compatibility
      def env
        @request_env
      end

      def execute(input)
        # Check basic execution ability
        return error_result("Command cannot be executed in current context") unless can_execute?

        # Check mid-session suspension
        if character&.user&.suspended?
          return error_result("Your account has been suspended.")
        end

        # Check conditional requirements
        unmet = unmet_requirements
        if unmet.any?
          return error_result(unmet.first[:message] || "You can't do that right now.")
        end

        parsed_input = parse_input(input)
        result = perform_command(parsed_input)

        # Touch activity timestamp on successful commands (for auto-AFK system)
        touch_activity! if result[:success]

        result
      end

      # Update last_activity timestamp and clear AFK status
      # Called after every successful command execution
      def touch_activity!
        return unless character_instance

        # Update last_activity timestamp
        character_instance.update(last_activity: Time.now)

        # Clear AFK status if player was AFK (they're active now)
        character_instance.clear_afk! if character_instance.afk?
      end

      # Basic execution check (character exists, has location)
      def can_execute?
        !!(character_instance && character && location)
      end

      # Check all conditional requirements
      def unmet_requirements
        self.class.requirements.reject { |req| requirement_met?(req) }
      end

      def requirements_met?
        unmet_requirements.empty?
      end

      # ====== CLASS-LEVEL METADATA DSL ======

      class << self
        # Command identification
        def command_name(value = nil)
          if value
            @command_name = value.to_s
          else
            @command_name || NamingHelper.class_to_snake_case(name)
          end
        end

        # Aliases/synonyms for the command
        # Supports multiple formats:
        #   aliases 'n', 'go north'           # Simple aliases
        #   aliases 'att', context: :combat   # Context-specific alias
        def aliases(*args)
          return @aliases || [] if args.empty?

          @aliases ||= []
          args.each do |arg|
            if arg.is_a?(Hash)
              # Context-specific alias: { name: 'att', context: :combat }
              @aliases << arg
            else
              # Simple alias
              @aliases << { name: arg.to_s, context: nil }
            end
          end
          @aliases
        end

        # Get simple alias names (for backward compatibility)
        def alias_names
          (aliases || []).map { |a| a.is_a?(Hash) ? a[:name] : a.to_s }
        end

        # Category for organization (inherits from parent class)
        def category(value = nil)
          if value
            @category = value
          else
            @category || (superclass.respond_to?(:category) ? superclass.category : :general)
          end
        end

        # Output category determines how the result is displayed:
        #   :action - Player action visible to others (main window, saved)
        #   :info   - Information just for the player (temp window, not saved)
        # Default is :action for commands that broadcast to room
        def output_category(value = nil)
          if value
            @output_category = value
          else
            @output_category || :action
          end
        end

        # Help text
        def help_text(value = nil)
          value ? @help_text = value : (@help_text || "No help available for #{command_name}")
        end

        # Usage examples
        def usage(value = nil)
          value ? @usage = value : @usage
        end

        def examples(*values)
          return @examples || [] if values.empty?
          @examples = values.flatten
        end

        # Plugin association
        def plugin(value = nil)
          value ? @plugin = value : @plugin
        end

        # ====== CONDITIONAL REQUIREMENTS DSL ======

        # Define requirements for when command can be used
        # Examples:
        #   requires :in_combat
        #   requires :room_type, :water, message: "You need to be in water to swim."
        #   requires :character_state, :alive
        #   requires :has_item, 'sword'
        #   requires -> (cmd) { cmd.character.level >= 5 }, message: "Must be level 5+"
        def requires(condition, *args, **options)
          @requirements ||= []
          @requirements << build_requirement(condition, args, options)
        end

        def requirements
          own = @requirements || []
          # Include parent class requirements (for inheritance)
          parent_reqs = if superclass.respond_to?(:requirements)
                          superclass.requirements
                        else
                          []
                        end
          parent_reqs + own
        end

        # Shorthand requirement methods
        def requires_combat
          requires :character_state, :in_combat, message: "You must be in combat to do that."
        end

        def requires_room_type(*types)
          requires :room_type, *types, message: "You can't do that here."
        end

        def requires_alive
          requires :character_state, :alive, message: "You can't do that while dead."
        end

        def requires_conscious
          requires :character_state, :conscious, message: "You can't do that while unconscious."
        end

        def requires_standing
          requires :character_state, :standing, message: "You need to be standing to do that."
        end

        def requires_weapon_equipped
          requires :has_equipped, :weapon, message: "You need a weapon equipped."
        end

        def requires_mana(amount = 1)
          requires :has_resource, :mana, amount, message: "You don't have enough mana."
        end

        def requires_stamina(amount = 1)
          requires :has_resource, :stamina, amount, message: "You're too exhausted."
        end

        # Era-based requirements

        # Require the command to only be available in specific eras
        # @param eras [Array<Symbol>] the eras where this command is available
        # @option options [String] :message custom error message
        def requires_era(*eras, message: nil)
          requires :era, *eras, message: message || era_unavailable_message(eras)
        end

        # Exclude this command from specific eras
        # @param eras [Array<Symbol>] the eras where this command is NOT available
        # @option options [String] :message custom error message
        def excludes_era(*eras, message: nil)
          requires :not_era, *eras, message: message || "This command is not available in the current era."
        end

        # Require the character to have a phone/communicator
        # @option options [String] :message custom error message
        def requires_phone(message: nil)
          requires :has_phone, message: message || "You need a #{EraService.messaging_device_name} to do that."
        end

        # Require digital currency to be available
        # @option options [String] :message custom error message
        def requires_digital_currency(message: nil)
          requires :digital_currency, message: message || "Digital currency is not available in this era."
        end

        # Require character to be able to communicate IC (in-character)
        # Dead characters in death rooms cannot communicate IC
        # @option options [String] :message custom error message
        def requires_can_communicate_ic(message: nil)
          requires :can_communicate_ic, message: message || "You cannot communicate from beyond the grave."
        end

        # Require taxi service to be available
        # @option options [String] :message custom error message
        def requires_taxi(message: nil)
          requires :taxi_available, message: message || "There's no taxi service in this era."
        end

        # Require the ability to modify rooms (not in read-only timeline)
        # @option options [String] :message custom error message
        def requires_can_modify_rooms(message: nil)
          requires :can_modify_rooms, message: message || "Room modifications are disabled in past timelines."
        end

        private

        def era_unavailable_message(eras)
          era_names = eras.map { |e| e.to_s.tr('_', ' ').capitalize }.join(', ')
          "This command is only available in: #{era_names}."
        end

        def build_requirement(condition, args, options)
          {
            type: condition.is_a?(Proc) ? :custom : condition,
            condition: condition,
            args: args,
            message: options[:message]
          }
        end
      end

      # ====== REQUIREMENT CHECKING ======

      def requirement_met?(req)
        case req[:type]
        when :custom
          req[:condition].call(self)
        when :in_combat
          character_instance&.respond_to?(:in_combat?) && character_instance.in_combat?
        when :not_in_combat
          !character_instance&.respond_to?(:in_combat?) || !character_instance.in_combat?
        when :room_type
          req[:args].any? { |type| location&.room_type&.to_sym == type.to_sym }
        when :room_flag
          flag = req[:args].first
          location&.respond_to?(flag) && location.send(flag)
        when :not_room_flag
          flag = req[:args].first
          !location&.respond_to?(flag) || !location.send(flag)
        when :character_state
          check_character_state(req[:args].first)
        when :has_equipped
          check_has_equipped(req[:args].first)
        when :has_item
          check_has_item(req[:args].first)
        when :has_resource
          check_has_resource(req[:args][0], req[:args][1] || 1)
        when :has_skill
          check_has_skill(req[:args].first)
        when :has_permission
          check_has_permission(req[:args].first)
        when :time_of_day
          check_time_of_day(req[:args])
        when :weather
          check_weather(req[:args])
        # Era-based requirements
        when :era
          check_era_included(req[:args])
        when :not_era
          check_era_excluded(req[:args])
        when :has_phone
          check_has_phone
        when :digital_currency
          EraService.digital_currency?
        when :taxi_available
          EraService.taxi_available?
        when :can_communicate_ic
          check_can_communicate_ic
        when :can_modify_rooms
          check_can_modify_rooms
        else
          # Unknown requirement type - assume met (for extensibility)
          true
        end
      end

      def check_can_communicate_ic
        return false if character_instance&.status == 'dead'
        return false if location&.blocks_ic_communication?

        true
      end

      def check_can_modify_rooms
        return true unless character_instance&.respond_to?(:can_modify_rooms?)
        character_instance.can_modify_rooms?
      end

      private

      def check_character_state(state)
        case state.to_sym
        when :alive
          character_instance&.status != 'dead'
        when :dead
          character_instance&.status == 'dead'
        when :conscious
          !%w[unconscious dead].include?(character_instance&.status)
        when :unconscious
          character_instance&.status == 'unconscious'
        when :standing
          character_instance&.standing?
        when :sitting
          character_instance&.sitting?
        when :lying
          character_instance&.lying?
        when :in_combat
          character_instance&.respond_to?(:in_combat?) && character_instance.in_combat?
        else
          # Check for custom status
          character_instance&.status == state.to_s
        end
      end

      def check_has_equipped(slot_or_type)
        # Placeholder - will integrate with equipment system
        return true unless character_instance.respond_to?(:equipped_items)
        character_instance.equipped_items.any? { |item| item.slot == slot_or_type.to_s || item.item_type == slot_or_type.to_s }
      end

      def check_has_item(item_name_or_type)
        # Placeholder - will integrate with inventory system
        return true unless character_instance.respond_to?(:inventory)
        character_instance.inventory.any? { |item| item.name.downcase.include?(item_name_or_type.to_s.downcase) }
      end

      def check_has_resource(resource, amount)
        case resource.to_sym
        when :mana
          (character_instance&.mana || 0) >= amount
        when :health, :hp
          (character_instance&.health || 0) >= amount
        when :stamina, :energy
          (character_instance&.respond_to?(:stamina) ? character_instance.stamina : 100) >= amount
        else
          true
        end
      end

      def check_has_skill(skill_name)
        return true unless character_instance

        # Find the stat by name or abbreviation (case-insensitive)
        skill_name_lower = skill_name.to_s.downcase
        char_stat = character_instance.character_stats.find do |cs|
          next unless cs.stat
          cs.stat.name.downcase == skill_name_lower ||
            cs.stat.abbreviation.downcase == skill_name_lower
        end

        # Return true if character has the skill with value > 0
        char_stat && char_stat.current_value > 0
      end

      def check_has_permission(permission)
        character.user&.has_permission?(permission) != false
      end

      def check_time_of_day(times)
        return true unless location

        # Get current time of day from game time service
        current_time = GameTimeService.time_of_day(location.respond_to?(:location) ? location.location : nil)

        # Normalize input times to symbols
        allowed_times = Array(times).map do |t|
          GameTimeService::TIME_NAME_MAP[t.to_s.downcase] || t.to_s.downcase.to_sym
        end

        allowed_times.include?(current_time)
      end

      def check_weather(conditions)
        return true unless location

        # Get location (room -> location association)
        loc = location.respond_to?(:location) ? location.location : location
        return true unless loc.respond_to?(:weather)

        weather = loc.weather
        return true unless weather

        # Normalize conditions to array of strings
        allowed_conditions = Array(conditions).map { |c| c.to_s.downcase }

        # Check if current weather condition matches any allowed condition
        allowed_conditions.include?(weather.condition.downcase)
      end

      # Era requirement helpers

      def check_era_included(allowed_eras)
        allowed_eras.map(&:to_sym).include?(EraService.current_era)
      end

      def check_era_excluded(excluded_eras)
        !excluded_eras.map(&:to_sym).include?(EraService.current_era)
      end

      def check_has_phone
        # Always connected eras (implants, communicators) don't need physical device
        return true if EraService.always_connected?

        # Check if character has a phone device
        character_instance&.has_phone?
      end

      # ====== INPUT PARSING ======

      protected

      def parse_input(input)
        return { command_word: '', args: [], text: '', full_input: '' } if input.nil?

        parts = input.strip.split(/\s+/)
        return { command_word: '', args: [], text: '', full_input: input.strip } if parts.empty?

        # Determine how many words were used for the command/alias
        cmd_word_count = detect_command_word_count(parts)

        # Extract command words and remaining args
        command_word = parts[0...cmd_word_count].join(' ').downcase
        args = parts[cmd_word_count..-1] || []
        text = args.join(' ') if args.any?

        normalized = ArgumentNormalizerService.normalize(command_word, text || '')

        {
          command_word: command_word,
          args: args,
          text: text || '',
          full_input: input.strip,
          normalized: normalized
        }
      end

      # Detect how many words at the start of input match the command name or an alias
      # Important: Check longer aliases first to match "sit in" before "sit"
      def detect_command_word_count(parts)
        cmd_name = self.class.command_name
        cmd_words = cmd_name.split(/\s+/)

        # Collect all possible matches with their word counts
        all_matches = []

        # Add command name match
        if parts.length >= cmd_words.length
          input_phrase = parts[0...cmd_words.length].map(&:downcase).join(' ')
          all_matches << cmd_words.length if input_phrase == cmd_name.downcase
        end

        # Add alias matches (sorted by length, longest first)
        aliases_sorted = (self.class.aliases || []).sort_by do |alias_entry|
          alias_name = alias_entry.is_a?(Hash) ? alias_entry[:name] : alias_entry.to_s
          -alias_name.split(/\s+/).length # Negative for descending order
        end

        aliases_sorted.each do |alias_entry|
          alias_name = alias_entry.is_a?(Hash) ? alias_entry[:name] : alias_entry.to_s
          alias_words = alias_name.split(/\s+/)

          if parts.length >= alias_words.length
            input_phrase = parts[0...alias_words.length].map(&:downcase).join(' ')
            all_matches << alias_words.length if input_phrase == alias_name.downcase
          end
        end

        # Return the longest match (most specific), or fallback to 1
        all_matches.max || 1
      end

      def perform_command(parsed_input)
        raise NotImplementedError, "Subclasses must implement #perform_command"
      end

      # ====== RESULT HELPERS ======

      def success_result(message, **extra_data)
        # Infer target panel from type/display_type if not explicitly provided
        panel = extra_data[:target_panel] || infer_target_panel(
          extra_data[:type],
          extra_data.dig(:structured, :display_type) || extra_data[:display_type]
        )

        base = {
          success: true,
          message: message,
          character_id: character_instance.id,
          target_panel: panel,
          output_category: self.class.output_category,
          timestamp: Time.now,
          status_bar: build_status_bar
        }.merge(extra_data)

        # Add dual-mode output if type is specified
        if extra_data[:type] && extra_data[:data]
          result = base.merge(render_output(type: extra_data[:type], data: extra_data[:data]))
          # Use formatted_message as self-view when provided (preserves speech color spans)
          result[:message] = extra_data[:formatted_message] if extra_data[:formatted_message]
          result
        else
          base
        end
      end

      def error_result(error_message, **extra_data)
        base = {
          success: false,
          error: error_message,
          character_id: character_instance&.id,
          target_panel: extra_data[:target_panel] || Firefly::Panels::RIGHT_MAIN_FEED,
          timestamp: Time.now,
          status_bar: build_status_bar
        }.merge(extra_data)

        # Add dual-mode error output
        base.merge(render_output(type: :error, data: { message: error_message }))
      end

      # Convenience method for room output (most common case)
      def room_result(room_data, **extra_data)
        success_result(
          "You look around.",
          type: :room,
          target_panel: extra_data[:target_panel] || Firefly::Panels::RIGHT_MAIN_FEED,
          data: room_data,
          **extra_data
        )
      end

      # Convenience method for message output
      def message_result(message_type, sender, content, **extra_data)
        # Infer panel from message_type (say -> right, tell -> left, etc.)
        panel = extra_data[:target_panel] || Firefly::Panels.infer(display_type: message_type)

        data = { type: message_type, sender: sender, content: content }
        data[:verb] = extra_data.delete(:verb) if extra_data[:verb]

        success_result(
          content,
          type: :message,
          target_panel: panel,
          data: data,
          **extra_data
        )
      end

      # Convenience method for commands that require web interface
      # @param action [String] The action name (e.g., 'buy_vehicle')
      # @param message [String] The message to display explaining where to go
      def web_interface_required_result(action, message)
        success_result(
          message,
          type: :message,
          data: { action: action, requires_web: true }
        )
      end

      # Infer target panel from type and display_type
      def infer_target_panel(type, display_type)
        Firefly::Panels.infer(type: type, display_type: display_type)
      end

      # Build status bar data for API response
      # Returns nil if no character instance is available
      def build_status_bar
        return nil unless character_instance

        StatusBarService.new(character_instance).build_status_data
      rescue StandardError => e
        warn "[Command] Error building status bar: #{e.message}"
        nil
      end

      # ====== BROADCASTING ======

      # Broadcast a message to all characters in the room
      # Messages are automatically personalized per-viewer (name substitution, sensory filtering)
      #
      # @param message [String] The message to broadcast
      # @param exclude_character [CharacterInstance, nil] Character to exclude (usually self)
      # @param personalize [Boolean] Whether to personalize per viewer (default: true)
      # @param message_type [Symbol] Type for sensory filtering (:visual, :auditory, :mixed)
      # @param options [Hash] Additional options passed to BroadcastService
      def broadcast_to_room(message, exclude_character: nil, personalize: true, message_type: :mixed, **options)
        return if location.nil?

        exclude_ids = exclude_character ? [exclude_character.id] : []
        options[:sender_instance] ||= character_instance

        # Always call BroadcastService.to_room for side effects (RP logging, NPC animation, etc.)
        # This uses the original message for accurate logging
        BroadcastService.to_room(location.id, message, exclude: exclude_ids, skip_broadcast: personalize, **options)

        # Send personalized messages to each viewer
        if personalize
          # All online room characters for name lookup
          # (API agents are auto-set online when they execute commands)
          all_room_chars = location
                            .characters_here(character_instance&.reality_id, viewer: character_instance)
                            .eager(:character)
                            .all

          # Online characters only for WebSocket delivery (excluding sender)
          viewers = all_room_chars
                      .select(&:online)
                      .reject { |ci| exclude_ids.include?(ci.id) }

          # Strip IC type from per-viewer options to prevent duplicate RP logging
          # (to_room above already handles RP logging with the original message)
          notif_type = options[:type]
          viewer_options = options.except(:type)

          # Pre-compute notification body for RP types — title is per-viewer (sender's known name)
          rp_notify_types = %i[say emote whisper subtle private_emote pemit]
          notif_portrait = character_instance.character&.profile_pic_url
          notif_body = if !viewer_options[:notification] && notif_type && rp_notify_types.include?(notif_type.to_sym)
            raw = message.is_a?(Hash) ? (message[:content] || message[:message] || '').to_s : message.to_s
            stripped = raw.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ').strip.slice(0, 100)
            stripped.empty? ? nil : stripped
          end

          viewers.each do |viewer|
            personalized = MessagePersonalizationService.personalize(
              message: message,
              viewer: viewer,
              room_characters: all_room_chars,
              message_type: message_type
            )

            local_opts = viewer_options.dup
            if notif_body
              sender_name = character_instance.character&.display_name_for(viewer)
              local_opts[:notification] = { title: sender_name, body: notif_body, icon: notif_portrait, setting: 'notify_emote' }
            end

            send_to_character(viewer, personalized, **local_opts)
          end
        end
      end

      # Broadcast to all characters in room except specified ones
      # @param exclude_chars [Array<CharacterInstance>] Characters to exclude from broadcast
      # @param message [String, Hash] Message to broadcast
      # @param personalize [Boolean] Whether to personalize per viewer (default: true)
      # @param message_type [Symbol] Type for sensory filtering (:visual, :auditory, :mixed)
      def broadcast_to_room_except(exclude_chars, message, personalize: true, message_type: :mixed, **options)
        return if location.nil?

        exclude_ids = Array(exclude_chars).map(&:id)
        room_chars = location
                      .characters_here(character_instance&.reality_id, viewer: character_instance)
                      .exclude(id: exclude_ids)
                      .eager(:character)
                      .all

        room_chars.each do |viewer|
          msg = if personalize
                  MessagePersonalizationService.personalize(
                    message: message,
                    viewer: viewer,
                    room_characters: room_chars,
                    message_type: message_type
                  )
                else
                  message
                end
          BroadcastService.to_character(viewer, msg, **options)
        end
      end


      def send_to_character(char_instance, message, **options)
        BroadcastService.to_character(char_instance, message, **options)
      end

      # Store undo context in Redis for the undo command (60-second TTL)
      # @param panel [String] 'left' or 'right'
      # @param data [Hash] undo context (broadcast_id, message_id, room_id, channel_id, etc.)
      def store_undo_context(panel, **data)
        return unless defined?(REDIS_POOL) && REDIS_POOL

        REDIS_POOL.with do |redis|
          redis.setex("undo:#{panel}:#{character_instance.id}", 60, data.to_json)
        end
      rescue StandardError => e
        warn "[Command] Failed to store undo context: #{e.message}"
      end

      def log_roleplay(message, type: :emote, target: nil, recipients: nil, exclude: [], scene_id: nil, html: nil)
        return unless character_instance && location

        if target
          IcActivityService.record_targeted(
            sender: character_instance, target: target,
            content: message, type: type, scene_id: scene_id, html: html
          )
        elsif recipients
          IcActivityService.record_for(
            recipients: recipients, content: message,
            sender: character_instance, type: type,
            scene_id: scene_id, html: html
          )
        else
          IcActivityService.record(
            room_id: location.id, content: message,
            sender: character_instance, type: type,
            exclude: exclude, scene_id: scene_id, html: html
          )
        end
      end

      # ====== CHARACTER/ITEM FINDING ======

      # Find an online character in the current room using TargetResolverService
      # Used by communication commands (whisper, say to, pm, etc.)
      # Respects reality dimensions and uses consistent matching logic
      # @param target_name [String] The name to search for
      # @param exclude_self [Boolean] Whether to exclude current character (default true)
      # @param alive_only [Boolean] Whether to also filter by status: 'alive' (default false)
      # @return [CharacterInstance, nil] The matched character instance or nil
      def find_character_in_room(target_name, exclude_self: true, alive_only: false)
        return nil unless location
        return nil if blank?(target_name)

        # Use room's characters_here which respects reality dimensions
        reality_id = character_instance&.reality_id
        candidates = location.characters_here(reality_id, viewer: character_instance)
        candidates = candidates.where(status: 'alive') if alive_only
        candidates = candidates.exclude(id: character_instance.id) if exclude_self && character_instance
        candidates = candidates.all

        # Use TargetResolverService for consistent matching across all commands
        # Pass viewer for personalized name matching (short_desc for unknowns, known_name for knowns)
        TargetResolverService.resolve_character(
          query: target_name,
          candidates: candidates,
          viewer: character_instance
        )
      end

      # Find a combat target in the room (includes NPCs and matches short_desc)
      # Used by combat commands (fight, attack, etc.)
      # @param target_name [String] The name to search for
      # @param exclude_self [Boolean] Whether to exclude current character (default true)
      # @return [CharacterInstance, nil] The matched character instance or nil
      def find_combat_target(target_name, exclude_self: true)
        return nil unless location
        return nil if blank?(target_name)

        # Find online (on-grid) characters in the same visible room/event context
        reality_id = character_instance&.reality_id
        candidates = location.characters_here(reality_id, viewer: character_instance)
                             .eager(:character)
                             .all

        # Optionally exclude self
        candidates = candidates.reject { |ci| ci.id == character_instance.id } if exclude_self

        # Use TargetResolverService with viewer for personalized name matching
        # Handles short_desc for unknown characters, known_name for known characters
        TargetResolverService.resolve_character(
          query: target_name,
          candidates: candidates,
          viewer: character_instance
        )
      end

      # Get all online characters in the current room (optionally excluding some)
      # @param exclude [Array<CharacterInstance>] Characters to exclude from results
      # @return [Sequel::Dataset] Dataset of character instances
      def online_room_characters(exclude: [])
        exclude_ids = Array(exclude).map(&:id)
        reality_id = character_instance&.reality_id
        query = location ? location.characters_here(reality_id, viewer: character_instance) : CharacterInstance.where(id: nil)
        query = query.exclude(id: exclude_ids) if exclude_ids.any?
        query
      end

      # Find a character by name in the room and return the Character model
      # Note: This delegates to find_character_in_room for consistent matching
      # Does NOT exclude self by default (commands should handle self-targeting logic)
      # @param name [String] The name to search for
      # @param in_same_room [Boolean] Unused, kept for backwards compatibility
      # @return [Character, nil] The matched character or nil
      def find_character_by_name(name, in_same_room: true)
        instance = find_character_in_room(name, exclude_self: false)
        instance&.character
      end

      # Find a character globally (any character in the database)
      # Unlike find_character_by_name, this doesn't require them to be online or in room
      # @param name [String] The character name to search for
      # @param limit [Integer] Maximum candidates to search (default 200)
      # @return [Character, nil] The matched character or nil
      def find_character_globally(name, limit: 200)
        return nil if blank?(name)

        candidates = Character.limit(limit).all
        TargetResolverService.resolve_character(
          query: name,
          candidates: candidates,
          forename_field: :forename,
          full_name_method: :full_name
        )
      end

      # Find an online NPC by name.
      # Optionally prefers a match in the current room before global search.
      # @param name [String] NPC name to search for
      # @param room_first [Boolean] Search current room first if true
      # @return [CharacterInstance, nil] matched NPC instance or nil
      def find_online_npc(name, room_first: false)
        return nil if blank?(name)

        if room_first && character_instance&.current_room_id
          room_npcs = CharacterInstance
                      .where(current_room_id: character_instance.current_room_id, online: true)
                      .eager(:character)
                      .all
                      .select { |ci| ci.character&.npc? }

          room_match = TargetResolverService.resolve_character(
            query: name,
            candidates: room_npcs,
            viewer: character_instance
          )
          return room_match if room_match
        end

        global_npcs = CharacterInstance
                      .where(online: true)
                      .eager(:character)
                      .all
                      .select { |ci| ci.character&.npc? }

        TargetResolverService.resolve_character(
          query: name,
          candidates: global_npcs,
          viewer: character_instance
        )
      end

      # Check if a name input refers to the current character (self-reference)
      # Useful for preventing commands like "give item to self" or "attempt on self"
      # @param name [String] The name to check
      # @return [Boolean] True if the name matches the current character
      def is_self_reference?(name)
        return false if blank?(name) || character.nil?

        name_lower = name.downcase
        char_forename = character.forename&.downcase || ''
        char_full = character.full_name&.downcase || ''
        char_nickname = character.nickname&.downcase || ''

        name_lower == char_forename ||
          name_lower == char_full ||
          (!char_nickname.empty? && name_lower == char_nickname) ||
          (!char_forename.empty? && char_forename.start_with?(name_lower)) ||
          (!char_nickname.empty? && char_nickname.start_with?(name_lower)) ||
          (name_lower.length >= 3 && !char_forename.empty? && char_forename.include?(name_lower))
      end

      # Find an item owned by the character (worn, held, inventory, stored)
      # @param name [String] The item name to search for
      # @return [Item, nil] The matched item or nil
      def find_owned_item(name)
        return nil if blank?(name)

        all_items = character_instance.objects_dataset.all
        TargetResolverService.resolve(
          query: name,
          candidates: all_items,
          name_field: :name
        )
      end

      # Find an item in the character's inventory (not worn/held)
      # @param name [String] The item name to search for
      # @return [Item, nil] The matched item or nil
      def find_item_in_inventory(name)
        return nil if blank?(name)

        TargetResolverService.resolve(
          query: name,
          candidates: character_instance.inventory_items.all,
          name_field: :name
        )
      end

      # Find an item the character is currently wearing
      # @param name [String] The item name to search for
      # @return [Item, nil] The matched item or nil
      def find_worn_item(name)
        return nil if blank?(name)

        TargetResolverService.resolve(
          query: name,
          candidates: character_instance.worn_items.all,
          name_field: :name
        )
      end

      # Find an item the character is currently holding
      # @param name [String] The item name to search for
      # @return [Item, nil] The matched item or nil
      def find_held_item(name)
        return nil if blank?(name)

        TargetResolverService.resolve(
          query: name,
          candidates: character_instance.held_items.all,
          name_field: :name
        )
      end

      # Find a character instance in the current room by their Character record
      # Useful when you have a Character but need their CharacterInstance
      # @param target_char [Character] The character to find
      # @return [CharacterInstance, nil] The character instance or nil
      def find_character_instance_in_room(target_char)
        return nil unless target_char && location

        CharacterInstance.first(
          character_id: target_char.id,
          current_room_id: location.id,
          online: true
        )
      end

      # ====== DISAMBIGUATION HELPERS ======

      # Resolve an item with disambiguation support
      # Returns: { match: item } or { disambiguation: true, result: quickmenu_data } or { error: msg }
      def resolve_item_with_menu(query, candidates, action_context = {})
        result = TargetResolverService.resolve_with_disambiguation(
          query: query,
          candidates: candidates,
          name_field: :name,
          description_field: :description,
          display_field: :name,
          character_instance: character_instance,
          context: action_context.merge(command: self.class.command_name),
          min_prefix_length: 1
        )

        if result[:quickmenu]
          { disambiguation: true, result: result[:quickmenu] }
        elsif result[:error]
          { error: result[:error] }
        else
          { match: result[:match] }
        end
      end

      # Resolve a character with disambiguation support
      # Returns: { match: char_instance } or { disambiguation: true, result: quickmenu_data } or { error: msg }
      def resolve_character_with_menu(query, candidates = nil, action_context = {})
        # Default to online characters in the same room, excluding self
        candidates ||= CharacterInstance
                       .where(current_room_id: location&.id, online: true)
                       .exclude(id: character_instance.id)
                       .eager(:character)
                       .all

        result = TargetResolverService.resolve_character_with_disambiguation(
          query: query,
          candidates: candidates,
          character_instance: character_instance,
          context: action_context.merge(command: self.class.command_name)
        )

        if result[:quickmenu]
          { disambiguation: true, result: result[:quickmenu] }
        elsif result[:error]
          { error: result[:error] }
        else
          { match: result[:match] }
        end
      end

      # Helper to return disambiguation result from a command
      # quickmenu_data is the return value of create_quickmenu, which nests
      # prompt/options under :data. Extract them so format_quickmenu_output
      # can find them at the top level.
      def disambiguation_result(quickmenu_data, prompt = nil)
        menu_payload = quickmenu_data[:data] || quickmenu_data
        display_prompt = prompt || menu_payload[:prompt] || quickmenu_data[:prompt] || "Please select an option."

        success_result(
          display_prompt,
          type: :quickmenu,
          display_type: :quickmenu,
          data: menu_payload,
          interaction_id: quickmenu_data[:interaction_id],
          requires_response: true
        )
      end

      # ====== VALIDATION HELPERS ======

      # Check for empty input, returns error_result or nil
      # Usage: error = require_input(text, "What?"); return error if error
      def require_input(text, error_message = "Please provide input.")
        return error_result(error_message) if blank?(text)
        nil
      end

      # Require staff privileges for command execution.
      # @param via_user [Boolean] check staff status on the User record instead of Character
      # @param error_message [String] custom error message
      # @return [Hash, nil] error_result hash when unauthorized, nil when authorized
      def require_staff(via_user: false, error_message: 'This command is restricted to staff members.')
        is_staff = if via_user
                     character&.user&.staff?
                   else
                     character&.staff?
                   end

        return nil if is_staff

        error_result(error_message)
      end

      # Check admin permission, returns error_result or nil
      # Usage: error = require_admin; return error if error
      def require_admin(error_message: 'Only administrators can do that.')
        return nil if character&.admin?

        error_result(error_message)
      end

      # Check building permission (staff, admin, or creator_mode), returns error_result or nil
      # Usage: error = require_building_permission; return error if error
      def require_building_permission(error_message: 'You need building permission to do that.')
        return nil if character&.staff? || character&.admin? || character_instance&.creator_mode?

        error_result(error_message)
      end

      # Prevent self-targeting, returns error_result or nil
      # Usage: error = prevent_self_target(target, "whisper to"); return error if error
      def prevent_self_target(target_instance, action_name = "target")
        if target_instance&.id == character_instance&.id
          return error_result("You can't #{action_name} yourself.")
        end
        nil
      end

      # Check property ownership, returns error_result or nil
      # Usage: error = require_property_ownership; return error if error
      # @param room [Room] The room to check (defaults to location)
      # @param use_outer_room [Boolean] Check outer_room ownership (default: true)
      def require_property_ownership(room = nil, use_outer_room: true)
        room ||= location
        check_room = use_outer_room && room.respond_to?(:outer_room) ? room.outer_room : room
        unless check_room&.owned_by?(character)
          return error_result("You're not in a property you own.")
        end
        nil
      end

      # Check room ownership (not outer room), returns error_result or nil
      def require_room_ownership(room = nil)
        room ||= location
        unless room&.owned_by?(character)
          return error_result("You don't own this room.")
        end
        nil
      end

      # ====== CURRENCY & WALLET HELPERS ======

      # Check if an item represents money/currency
      # @param item [Item] The item to check
      # @return [Boolean] True if item is a currency item
      def is_money_item?(item)
        props = item.properties
        return false if props.nil? || !props.respond_to?(:[])
        props['is_currency'] == true || props['currency_id'].to_i > 0
      end

      # Find a money item in the current room
      # Uses JSONB queries for efficiency instead of loading all items
      # @param currency [Currency, nil] Specific currency to find, or nil for any
      # @return [Item, nil] The money item or nil
      def find_money_in_room(currency = nil)
        return nil unless location

        items = location.objects_here
        if currency
          # Query for specific currency using JSON string access
          items.where(
            Sequel.lit("(properties->>'is_currency')::boolean = true AND (properties->>'currency_id')::int = ?", currency.id)
          ).first
        else
          # Query for any currency item
          items.where(
            Sequel.lit("(properties->>'is_currency')::boolean = true OR (properties->>'currency_id')::int > 0")
          ).first
        end
      end

      # Check if text refers to money/currency (e.g., "100", "money", "cash")
      # @param text [String] The text to check
      # @param include_keywords [Boolean] Also match words like "money", "cash", "coins"
      # @return [Boolean] True if text references money
      def money_reference?(text, include_keywords: true)
        return false if blank?(text)

        text = text.to_s.strip
        return true if text.match?(/^\d+$/)

        if include_keywords
          %w[money cash coins].include?(text.downcase)
        else
          false
        end
      end

      # Get the universe from the current location (delegates to Room#universe)
      def universe
        location&.universe
      end

      # Get default currency for current location's universe
      def default_currency
        return nil unless universe
        Currency.default_for(universe)
      end

      # Get character's wallet for a currency (nil if doesn't exist)
      def wallet_for(currency = nil)
        currency ||= default_currency
        return nil unless currency
        character_instance&.wallets_dataset&.first(currency_id: currency.id)
      end

      # Get character's bank account for a currency (nil if doesn't exist)
      # @param currency [Currency, nil] currency to look up (defaults to default_currency)
      # @param target_character [Character, nil] character to look up (defaults to current character)
      def bank_account_for(currency = nil, target_character = nil)
        currency ||= default_currency
        target_character ||= character
        return nil unless currency && target_character

        target_character.bank_accounts_dataset.first(currency_id: currency.id)
      end

      # Get or create wallet for a currency
      def find_or_create_wallet(currency = nil)
        currency ||= default_currency
        return nil unless currency && character_instance

        wallet = wallet_for(currency)
        return wallet if wallet

        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 0
        )
      end

      # ====== TEXT PROCESSING ======

      # Parse input to extract target name and message
      # Common pattern: first word is target, rest is message
      # @param text [String] The input text
      # @return [Array<String, String>] [target_name, message] - either may be nil
      def parse_target_and_message(text)
        return [nil, nil] if blank?(text)

        words = text.strip.split(/\s+/)
        return [nil, nil] if words.empty?

        target_name = words.first
        message = words[1..]&.join(' ')

        [target_name, message]
      end

      # Smart target + message parsing that supports multi-word targets.
      # Tries progressively longer word prefixes against room characters.
      # E.g., "tubby dude Heya" tries "tubby dude" first, then falls back to "tubby".
      #
      # @param text [String] The input text (target + message)
      # @param exclude_self [Boolean] Whether to exclude self from matching
      # @return [Array] [target_instance, target_name, message] - target_instance may be nil
      def find_target_and_message(text, exclude_self: true)
        return [nil, nil, nil] if blank?(text)

        words = text.strip.split(/\s+/)
        return [nil, nil, nil] if words.empty?

        # Try increasingly longer prefixes as target (need at least 1 word for message)
        max_target_words = [words.length - 1, 5].min
        max_target_words.downto(1) do |n|
          target_name = words[0...n].join(' ')
          message = words[n..].join(' ')

          match = find_character_in_room(target_name, exclude_self: exclude_self)
          return [match, target_name, message] if match
        end

        # No match — return first word as target for error reporting / implicit fallback
        [nil, words.first, words[1..].join(' ')]
      end

      def process_punctuation(text)
        return text if blank?(text)

        text = text.strip
        text += '.' unless text.match?(/[.!?]["'""'']*$/)
        text
      end

      # Parse minutes from text input
      # @param text [String] The text to parse (e.g., "30", "60")
      # @param max [Integer] Maximum allowed minutes (default: 1000)
      # @return [Integer, nil] The parsed minutes, or nil if invalid/empty
      def parse_minutes(text, max: 1000)
        return nil if blank?(text)

        minutes = text.strip.to_i
        return nil if minutes <= 0
        return max if minutes > max

        minutes
      end

      # Parse count from text input, supports "all" keyword
      # @param text [String] The text to parse (e.g., "3", "all")
      # @param max [Integer] Maximum value (returned for "all" or values over max)
      # @param default [Integer] Default value if text is empty (default: 1)
      # @return [Integer] The parsed count
      def parse_count(text, max, default: 1)
        text = text.to_s.strip.downcase
        return max if text == 'all'
        return default if text.empty?

        count = text.to_i
        count = default if count < 1
        [count, max].min
      end

      def extract_adverb(text)
        words = text.split
        return [nil, text] if words.empty?

        # Only extract an adverb from the FIRST word position
        # (e.g., "quietly Hello" -> adverb: "quietly", text: "Hello")
        first = words.first
        if first.end_with?('ly') && first.length > 3
          adverb = words.shift
          remaining_text = words.join(' ')
          return [adverb, remaining_text]
        end

        [nil, text]
      end

      def name_for_character(target_character)
        knowledge = CharacterKnowledge.first(
          character_instance_id: character_instance.id,
          known_character_id: target_character.id
        )

        knowledge&.known_name || target_character.name
      end

      def has_recent_duplicate?(text, minutes: 5)
        false
      end

      def similar_text?(text1, text2, threshold: 0.8)
        return false if blank?(text1) || blank?(text2)

        normalized1 = text1.downcase.gsub(/[^a-z\s]/, '').strip
        normalized2 = text2.downcase.gsub(/[^a-z\s]/, '').strip

        return true if normalized1 == normalized2

        words1 = normalized1.split
        words2 = normalized2.split

        return false if words1.empty? || words2.empty?

        overlap = (words1 & words2).length
        similarity = overlap.to_f / [words1.length, words2.length].max

        similarity >= threshold
      end

      # ====== NAME SUBSTITUTION ======

      # Substitute character full names with display names for a specific viewer
      # Handles character knowledge, sensory state, and other personalizations
      #
      # @param message [String] The message containing character names
      # @param viewer_instance [CharacterInstance] The character viewing the message
      # @param room_characters [Array<CharacterInstance>] Optional pre-fetched characters
      # @param message_type [Symbol] Type for sensory filtering (:visual, :auditory, :mixed)
      # @return [String] Message personalized for the viewer
      def substitute_names_for_viewer(message, viewer_instance, room_characters: nil, message_type: :mixed)
        MessagePersonalizationService.personalize(
          message: message,
          viewer: viewer_instance,
          room_characters: room_characters,
          message_type: message_type
        )
      end
    end
  end
end
