# frozen_string_literal: true

module Commands
  module System
    class Narrate < ::Commands::Base::Command
      command_name 'narrate'
      aliases 'tts', 'voice'
      category :system
      help_text 'Toggle or configure text-to-speech narration and playback control'
      usage 'narrate [on|off|status|config|pause|resume|skip|current|clear]'
      examples 'narrate', 'narrate on', 'narrate pause', 'narrate skip +15', 'narrate config speech off'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        subcommand = args.first&.downcase

        case subcommand
        when 'on', 'enable'
          enable_tts
        when 'off', 'disable'
          disable_tts
        when 'status'
          show_status
        when nil
          toggle_tts
        when 'config', 'configure'
          configure_tts(args[1..])
        when 'pause', 'stop'
          pause_tts
        when 'resume', 'play', 'continue'
          resume_tts
        when 'skip'
          skip_tts(args[1])
        when 'current', 'latest', 'now'
          skip_to_current
        when 'clear'
          clear_queue
        when 'queue'
          show_queue_status
        else
          toggle_tts
        end
      end

      private

      def enable_tts
        unless TtsService.available?
          return error_result('Text-to-speech is not currently available. Please contact an administrator.')
        end

        character_instance.enable_tts!

        success_result(
          "Text-to-speech narration is now ON.",
          type: :system,
          data: { tts_enabled: true }
        )
      end

      def disable_tts
        character_instance.disable_tts!

        success_result(
          "Text-to-speech narration is now OFF.",
          type: :system,
          data: { tts_enabled: false }
        )
      end

      def toggle_tts
        unless TtsService.available?
          return error_result('Text-to-speech is not currently available. Please contact an administrator.')
        end

        new_state = character_instance.toggle_tts!

        success_result(
          "Text-to-speech narration is now #{new_state ? 'ON' : 'OFF'}.",
          type: :system,
          data: { tts_enabled: new_state }
        )
      end

      def show_status
        settings = character_instance.tts_settings
        user = character.user

        status_lines = []
        status_lines << "TTS Narration: #{settings[:enabled] ? 'ON' : 'OFF'}"
        status_lines << ''
        status_lines << "Content Settings:"
        status_lines << "  Speech (say, whisper): #{settings[:narrate_speech] ? 'ON' : 'OFF'}"
        status_lines << "  Actions (emotes): #{settings[:narrate_actions] ? 'ON' : 'OFF'}"
        status_lines << "  Room descriptions: #{settings[:narrate_rooms] ? 'ON' : 'OFF'}"
        status_lines << "  System messages: #{settings[:narrate_system] ? 'ON' : 'OFF'}"
        status_lines << ''

        # Character voice
        voice_settings = character.voice_settings
        status_lines << "Your Character Voice:"
        status_lines << "  Voice: #{voice_settings[:voice_type] || 'Not set'}"
        status_lines << "  Pitch: #{voice_settings[:voice_pitch]}"
        status_lines << "  Speed: #{voice_settings[:voice_speed]}x"
        status_lines << ''

        # Narrator voice
        if user
          narrator_settings = user.narrator_settings
          status_lines << "Your Narrator Voice:"
          status_lines << "  Voice: #{narrator_settings[:voice_type]}"
          status_lines << "  Pitch: #{narrator_settings[:voice_pitch]}"
          status_lines << "  Speed: #{narrator_settings[:voice_speed]}x"
        end

        # Availability
        status_lines << ''
        status_lines << "TTS Service: #{TtsService.available? ? 'Available' : 'Not Available'}"

        success_result(
          status_lines.join("\n"),
          type: :system,
          data: {
            tts_settings: settings,
            character_voice: character.voice_settings,
            narrator_voice: user&.narrator_settings,
            available: TtsService.available?
          }
        )
      end

      def configure_tts(args)
        return show_config_help if args.empty?

        setting = args[0]&.downcase
        value = args[1]&.downcase

        valid_settings = %w[speech actions rooms system]
        unless valid_settings.include?(setting)
          return error_result("Invalid setting '#{setting}'. Valid options: #{valid_settings.join(', ')}")
        end

        unless %w[on off true false 1 0].include?(value)
          return error_result("Invalid value '#{value}'. Use 'on' or 'off'.")
        end

        enabled = %w[on true 1].include?(value)

        case setting
        when 'speech'
          character_instance.configure_tts!(speech: enabled)
        when 'actions'
          character_instance.configure_tts!(actions: enabled)
        when 'rooms'
          character_instance.configure_tts!(rooms: enabled)
        when 'system'
          character_instance.configure_tts!(system: enabled)
        end

        success_result(
          "TTS #{setting} narration is now #{enabled ? 'ON' : 'OFF'}.",
          type: :system,
          data: { setting: setting, enabled: enabled }
        )
      end

      def show_config_help
        help_text = <<~HELP
          Configure what content types are narrated:

          narrate config speech on/off  - Character speech (say, whisper, yell)
          narrate config actions on/off - Emotes and actions
          narrate config rooms on/off   - Room descriptions
          narrate config system on/off  - System messages

          Current settings:
        HELP

        settings = character_instance.tts_settings
        help_text += "  Speech: #{settings[:narrate_speech] ? 'ON' : 'OFF'}\n"
        help_text += "  Actions: #{settings[:narrate_actions] ? 'ON' : 'OFF'}\n"
        help_text += "  Rooms: #{settings[:narrate_rooms] ? 'ON' : 'OFF'}\n"
        help_text += "  System: #{settings[:narrate_system] ? 'ON' : 'OFF'}"

        success_result(help_text, type: :system)
      end

      # ============================================
      # TTS Playback Control Methods
      # ============================================

      def pause_tts
        unless character_instance.tts_enabled?
          return error_result('TTS narration is not enabled. Use "narrate on" first.')
        end

        if character_instance.tts_paused?
          return success_result(
            'TTS narration is already paused. Use "tts resume" to continue.',
            type: :system,
            data: { tts_paused: true }
          )
        end

        character_instance.pause_tts!

        success_result(
          "TTS narration paused. Use 'tts resume' to continue from this point, or 'tts current' to skip to latest.",
          type: :system,
          data: {
            tts_paused: true,
            queue_position: character_instance.tts_queue_position,
            action: :pause
          }
        )
      end

      def resume_tts
        unless character_instance.tts_enabled?
          return error_result('TTS narration is not enabled. Use "narrate on" first.')
        end

        unless character_instance.tts_paused?
          return success_result(
            'TTS narration is already playing.',
            type: :system,
            data: { tts_paused: false }
          )
        end

        character_instance.resume_tts!

        pending_count = character_instance.pending_audio_items.count

        success_result(
          "TTS narration resumed.#{pending_count > 0 ? " #{pending_count} items in queue." : ''}",
          type: :system,
          data: {
            tts_paused: false,
            queue_position: character_instance.tts_queue_position,
            pending_count: pending_count,
            action: :resume
          }
        )
      end

      def skip_tts(amount)
        unless character_instance.tts_enabled?
          return error_result('TTS narration is not enabled. Use "narrate on" first.')
        end

        if amount.nil? || amount.empty?
          return error_result('Specify skip amount: "tts skip +15" (forward) or "tts skip -15" (backward)')
        end

        # Parse amount like "+15", "-15", "15", "-30"
        seconds = parse_skip_amount(amount)
        return error_result("Invalid skip amount: #{amount}. Use +15 or -15 seconds.") unless seconds

        direction = seconds >= 0 ? 'forward' : 'backward'

        success_result(
          "Skipping #{direction} #{seconds.abs} seconds.",
          type: :system,
          data: {
            skip_seconds: seconds,
            direction: direction,
            action: :skip
          }
        )
      end

      def skip_to_current
        unless character_instance.tts_enabled?
          return error_result('TTS narration is not enabled. Use "narrate on" first.')
        end

        character_instance.skip_to_latest!

        success_result(
          'Skipped to latest content. Narration will continue from current moment.',
          type: :system,
          data: {
            queue_position: character_instance.tts_queue_position,
            tts_paused: false,
            action: :skip_to_current
          }
        )
      end

      def clear_queue
        unless character_instance.tts_enabled?
          return error_result('TTS narration is not enabled.')
        end

        count = character_instance.audio_queue_items_dataset.where(played: false).delete
        character_instance.skip_to_latest!

        success_result(
          "Cleared #{count} items from TTS queue.",
          type: :system,
          data: {
            cleared_count: count,
            action: :clear_queue
          }
        )
      end

      def show_queue_status
        unless character_instance.tts_enabled?
          return error_result('TTS narration is not enabled. Use "narrate on" first.')
        end

        pending = character_instance.pending_audio_items.all
        current_position = character_instance.tts_queue_position || 0
        paused = character_instance.tts_paused?

        lines = []
        lines << "<h4>TTS Queue Status</h4>"
        lines << ""
        lines << "State: #{paused ? 'PAUSED' : 'PLAYING'}"
        lines << "Current Position: #{current_position}"
        lines << "Pending Items: #{pending.count}"

        if pending.any?
          lines << ""
          lines << "Next items:"
          pending.first(5).each do |item|
            text_preview = StringHelper.truncate(item.original_text.to_s, 40)
            text_preview = '(no text)' if text_preview.empty?
            lines << "  #{item.sequence_number}. [#{item.content_type}] #{text_preview}"
          end
          if pending.count > 5
            lines << "  ... and #{pending.count - 5} more"
          end
        end

        success_result(
          lines.join("\n"),
          type: :system,
          data: {
            paused: paused,
            position: current_position,
            pending_count: pending.count,
            pending_items: pending.first(5).map(&:to_api_hash)
          }
        )
      end

      def parse_skip_amount(amount)
        return nil unless amount

        # Handle formats: "+15", "-15", "15", "+30s", "-30s"
        clean = amount.to_s.gsub(/[s\s]/, '')

        begin
          Integer(clean)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Narrate)
