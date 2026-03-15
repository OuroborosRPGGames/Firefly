# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'
require_relative '../../../../app/helpers/communication_permission_helper'

module Commands
  module Communication
    # Unified say command.
    # Handles: say, say to <target>, say through <exit>
    # Replaces: say.rb, say_to.rb, say_through.rb
    class Say < Commands::Base::Command
      include MessagePersistenceHelper
      include MessageFormattingHelper
      include CommunicationPermissionHelper

      command_name 'say'
      aliases '"', "'", 'yell', 'shout', 'mutter', 'grumble', 'scream', 'moan', 'gasp', 'sob',
              'stutter', 'murmur', 'flirt', 'lecture', 'argue', 'confess',
              'sayto', 'tell', 'order', 'instruct', 'beg', 'demand', 'tease', 'mock', 'taunt',
              'saythrough', 'yellthrough'
      category :roleplaying
      help_text 'Speak to everyone present'
      usage 'say [adverb] <message> | say to <target> <message> | say through <exit>, <message>'
      examples(
        'say Hello everyone!',
        '"How are you?',
        'say quietly I have a secret.',
        'say to John Hello there!',
        'say through north, Hello in there!'
      )

      requires_can_communicate_ic

      COMMON_ADVERBS = %w[quietly loudly nervously excitedly sadly angrily softly cheerfully].freeze
      SAY_TO_COMMAND_WORDS = %w[sayto tell order instruct beg demand tease mock taunt].freeze
      SAY_THROUGH_COMMAND_WORDS = %w[saythrough yellthrough].freeze
      YELL_COMMAND_WORDS = %w[yell shout scream].freeze

      # Maps alias command words to their display verb
      VERB_MAP = {
        'say' => 'says', 'yell' => 'yells', 'shout' => 'shouts', 'mutter' => 'mutters',
        'grumble' => 'grumbles', 'scream' => 'screams', 'moan' => 'moans', 'gasp' => 'gasps',
        'sob' => 'sobs', 'stutter' => 'stutters', 'murmur' => 'murmurs', 'flirt' => 'flirts',
        'lecture' => 'lectures', 'argue' => 'argues', 'confess' => 'confesses',
        'sayto' => 'says', 'tell' => 'tells', 'order' => 'orders', 'instruct' => 'instructs',
        'beg' => 'begs', 'demand' => 'demands', 'tease' => 'teases', 'mock' => 'mocks',
        'taunt' => 'taunts'
      }.freeze

      protected

      def perform_command(parsed_input)
        error = check_not_gagged('speak')
        return error if error

        command_word = parsed_input[:command_word]
        text = parsed_input[:text] || ''

        verb = VERB_MAP[command_word] || 'says'

        if SAY_TO_COMMAND_WORDS.include?(command_word)
          return handle_say_to(text, verb: verb)
        end

        if SAY_THROUGH_COMMAND_WORDS.include?(command_word)
          is_yell = command_word.include?('yell')
          return handle_say_through(text, is_yell: is_yell)
        end

        if text =~ /^to\s+(.+)/i
          return handle_say_to(::Regexp.last_match(1), verb: verb)
        end

        # Check for "say through <exit>" pattern — only if the next word is a valid exit
        if text =~ /^through\s+(.+)/i
          remainder = ::Regexp.last_match(1)
          exit_candidate = remainder.split(/[\s,]/, 2).first
          if exit_candidate && find_exit_by_name(exit_candidate)
            is_yell = YELL_COMMAND_WORDS.include?(command_word)
            return handle_say_through(remainder, is_yell: is_yell)
          end
          # Not a valid exit — fall through to basic say
        end

        # Check for "say <message> to <target>" pattern (reverse order)
        # Only activate when "to" is present — avoids false positives on plain say text
        normalized = parsed_input[:normalized]
        if normalized[:target] && normalized[:message] && text =~ /\bto\b/i && !text.start_with?('to ', 'through ')
          return handle_say_to("#{normalized[:target]} #{normalized[:message]}", verb: verb)
        end

        handle_basic_say(parsed_input)
      end

      private

      # ========================================
      # Basic Say
      # ========================================

      def handle_basic_say(parsed_input)
        say_text = extract_say_text(parsed_input)
        say_text = sanitize_user_html(say_text) if say_text

        if say_text.nil? || say_text.strip.empty?
          return show_adverb_help
        end

        say_text = say_text.strip
        command_word = parsed_input[:command_word]
        verb = VERB_MAP[command_word] || 'says'

        error = validate_message_content(say_text, message_type: 'say',
                                                   duplicate_error: 'You recently said something similar.')
        return error if error

        adverb, clean_text = extract_adverb(say_text)
        formatted_message = format_say_message(clean_text, adverb, verb: verb)

        message_record = persist_room_message(formatted_message, message_type: 'say')
        return error_result("You can't seem to get any words out right now.") unless message_record

        broadcast_id = SecureRandom.uuid
        broadcast_to_room(formatted_message, type: :say, broadcast_id: broadcast_id, exclude_character: character_instance)
        log_roleplay(formatted_message)

        # Automatic name learning from speech content
        room_chars = CharacterInstance.where(current_room_id: location.id, online: true).eager(:character).all
        NameLearningService.process_speech(character, clean_text, room_chars)

        # Store undo context in Redis (60-second TTL)
        store_undo_context('right', broadcast_id: broadcast_id, message_id: message_record.id, room_id: location.id)

        character_instance.update(last_channel_name: 'room')

        # Self-view uses preferred name (nickname/forename) instead of full_name
        self_formatted = format_say_self_message(clean_text, adverb, verb: verb)

        message_result(
          'say',
          character.full_name,
          clean_text,
          verb: verb,
          adverb: adverb,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at,
          formatted_message: self_formatted,
          skip_room_sync: true
        )
      end

      def extract_say_text(parsed_input)
        input = parsed_input[:full_input] || ''
        command_word = parsed_input[:command_word]
        text = parsed_input[:text]

        if input.start_with?('"') || input.start_with?("'")
          input[1..]&.strip
        else
          # For 'say' and all aliases (yell, mutter, etc.), return just the text after the command word
          text
        end
      end

      def format_say_message(text, adverb = nil, verb: 'says')
        format_narrative_message(
          character_name: character.full_name,
          text: text,
          verb: verb,
          adverb: adverb,
          speech_color: character.speech_color
        )
      end

      def format_say_self_message(text, adverb = nil, verb: 'says')
        self_name = character.display_name_for(character_instance)
        format_narrative_message(
          character_name: self_name,
          text: text,
          verb: verb,
          adverb: adverb,
          speech_color: character.speech_color
        )
      end

      def show_adverb_help
        help_text = <<~HELP
          Usage: say [adverb] <message>

          You can add an adverb to describe how you speak:
            say quietly I have a secret to tell you.
            say excitedly Did you hear the news?!

          Common adverbs: #{COMMON_ADVERBS.join(', ')}

          Quick alternatives: "message or 'message
          Verb aliases: yell, shout, mutter, scream

          Directed speech: say to <target> <message>
          Through exits: say through <exit>, <message>

          Any word ending in 'ly' will be recognized as an adverb.
        HELP

        success_result(help_text.strip, type: :message)
      end

      # ========================================
      # Say To (directed speech)
      # ========================================

      def handle_say_to(text, verb: 'says')
        return error_result('Who did you want to speak to?') if blank?(text)

        # Try multi-word target matching (e.g., "tubby dude Heya" matches "tubby dude")
        target_instance, target_name, message = find_target_and_message(text)
        implicit = false

        # If no explicit target found, try to use context
        if target_instance.nil?
          implicit_target = character_instance.last_speaker || character_instance.last_spoken_to

          if implicit_target
            # Use implicit target, entire text becomes the message
            target_instance = implicit_target
            message = text
            implicit = true
          else
            # No context available - give a helpful error
            return error_result('Say to whom? (No recent conversation to continue.)')
          end
        end

        if target_instance.id == character_instance.id
          return error_result("You can't talk to yourself.")
        end

        error = check_ic_permission(target_instance)
        return error if error

        error = validate_message_content(message, message_type: 'say_to',
                                                  duplicate_error: 'You recently said something similar.')
        return error if error

        adverb, clean_message = extract_adverb(message)
        formatted_message = format_say_to_message(target_instance.character.full_name, clean_message, adverb, verb: verb)

        message_record = persist_targeted_message(formatted_message, target_instance, message_type: 'say_to')
        return error_result("You can't seem to get any words out right now.") unless message_record

        # Update interaction context for both parties
        character_instance.set_last_spoken_to(target_instance)
        target_instance.set_last_speaker(character_instance)

        # Everyone in the room hears this
        broadcast_id = SecureRandom.uuid
        broadcast_to_observers_personalized(formatted_message, exclude_instances: [character_instance], broadcast_id: broadcast_id)
        log_roleplay(formatted_message)

        # Automatic name learning from speech content
        room_chars = CharacterInstance.where(current_room_id: location.id, online: true).eager(:character).all
        NameLearningService.process_speech(character, clean_message, room_chars)

        # Store undo context in Redis (60-second TTL)
        store_undo_context('right', broadcast_id: broadcast_id, message_id: message_record.id, room_id: location.id)

        # Self-view uses preferred name (nickname/forename)
        self_name = character.display_name_for(character_instance)
        # Target uses what the sender knows them as
        target_display = target_instance.character.display_name_for(character_instance)
        self_formatted = format_narrative_message(
          character_name: self_name,
          text: clean_message,
          verb: verb,
          target_name: target_display,
          adverb: adverb,
          speech_color: character.speech_color
        )

        message_result(
          'say_to',
          character.full_name,
          clean_message,
          target: target_instance.character.full_name,
          adverb: adverb,
          implicit_target: implicit,
          message_id: message_record&.id,
          message_created_at: message_record&.created_at,
          formatted_message: self_formatted,
          skip_room_sync: true
        )
      end

      def format_say_to_message(target_name, text, adverb = nil, verb: 'says')
        format_narrative_message(
          character_name: character.full_name,
          text: text,
          verb: verb,
          target_name: target_name,
          adverb: adverb,
          speech_color: character.speech_color
        )
      end

      # ========================================
      # Say Through (through exits)
      # ========================================

      def handle_say_through(text, is_yell: false)
        return error_result('What exit and message?') if blank?(text)

        exit_name, message = parse_say_through_input(text)
        return error_result('Which exit did you want to speak through?') if blank?(exit_name)
        return error_result('What did you want to say?') if blank?(message)

        target_exit = find_exit_by_name(exit_name)
        return error_result("You don't see an exit called '#{exit_name}' here.") unless target_exit

        target_room = target_exit.to_room
        return error_result("That exit doesn't lead anywhere.") unless target_room

        formatted_message = format_say_through_message(target_exit, message, is_yell)

        broadcast_say_through(target_exit, target_room, message, is_yell)
        log_roleplay(formatted_message, type: :say)

        success_result(
          formatted_message,
          type: :say_through,
          data: {
            exit: target_exit.display_name,
            target_room: target_room.name,
            is_yell: is_yell
          }
        )
      end

      def parse_say_through_input(text)
        if text.include?(',')
          parts = text.split(',', 2)
          exit_name = parts[0].strip
          message = parts[1]&.strip
        else
          words = text.strip.split(/\s+/)
          exit_name = words[0]
          message = words[1..]&.join(' ')
        end

        [exit_name, message]
      end

      def find_exit_by_name(exit_name)
        return nil unless location

        # Build exits from spatial adjacency
        spatial_exits = location.spatial_exits
        exits = spatial_exits.flat_map do |direction, rooms|
          rooms.map do |to_room|
            OpenStruct.new(
              direction: direction.to_s,
              to_room: to_room,
              exit_name: to_room.name
            )
          end
        end

        # Exact match on direction first
        exact = exits.find { |e| e.direction.downcase == exit_name.downcase }
        return exact if exact

        # Exact match on exit name (room name)
        named = exits.find { |e| e.exit_name&.downcase == exit_name.downcase }
        return named if named

        # Fuzzy match on direction (4+ char prefix)
        if exit_name.length >= 4
          fuzzy = exits.find { |e| e.direction.downcase.start_with?(exit_name.downcase) }
          return fuzzy if fuzzy
        end

        # Fuzzy match on exit name
        if exit_name.length >= 4
          exits.find { |e| e.exit_name&.downcase&.start_with?(exit_name.downcase) }
        end
      end

      def format_say_through_message(target_exit, message, is_yell)
        name = character.full_name
        exit_display = target_exit.display_name
        colored = apply_speech_color_to_text(message, character.speech_color)

        if is_yell
          "#{name} yells through the #{exit_display}, '#{colored}'"
        else
          "#{name} says through the #{exit_display}, '#{colored}'"
        end
      end

      def broadcast_say_through(target_exit, target_room, message, is_yell)
        sender_message = format_say_through_message(target_exit, message, is_yell)
        send_to_character(character_instance, sender_message)

        online_room_characters(exclude: [character_instance]).each do |viewer|
          send_to_character(viewer, sender_message)
        end

        # Send to target room - they hear from opposite direction
        recipient_message = format_recipient_through_message(target_exit, message, is_yell)
        find_characters_in_room(target_room.id, eager: []).each do |recipient|
          send_to_character(recipient, recipient_message)
        end
      end

      def format_recipient_through_message(target_exit, message, is_yell)
        opposite = target_exit.opposite_direction || 'somewhere'

        if is_yell
          "Someone yells from #{opposite}, '#{message}'"
        else
          "Someone says from #{opposite}, '#{message}'"
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Say)
