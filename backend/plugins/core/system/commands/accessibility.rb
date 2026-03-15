# frozen_string_literal: true

module Commands
  module System
    class Accessibility < ::Commands::Base::Command
      command_name 'accessibility'
      aliases 'a11y', 'access'
      category :system
      help_text 'Configure accessibility settings for screen readers and visual aids'
      usage 'accessibility [setting] [value]'
      examples 'accessibility', 'accessibility mode on', 'accessibility contrast on', 'accessibility speed 1.5'

      VALID_SETTINGS = %w[mode reader contrast effects typing resume speed keys].freeze

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        subcommand = args.first&.downcase

        case subcommand
        when 'mode'
          toggle_mode(args[1])
        when 'reader'
          toggle_reader(args[1])
        when 'contrast'
          toggle_contrast(args[1])
        when 'effects'
          toggle_effects(args[1])
        when 'typing'
          toggle_typing_pause(args[1])
        when 'resume'
          toggle_auto_resume(args[1])
        when 'speed'
          set_tts_speed(args[1])
        when 'keys'
          show_key_bindings
        when 'help'
          show_help
        when 'status'
          show_status
        when nil
          # No args = show settings form
          show_accessibility_form
        else
          error_result("Unknown setting '#{subcommand}'. Type 'accessibility help' for options.")
        end
      end

      # Handle form submission
      def handle_form_response(form_data, _context)
        return error_result('You must be logged in to change accessibility settings.') unless user

        # Apply all settings from the form
        user.configure_accessibility!(
          mode: form_data['accessibility_mode'] == 'true',
          screen_reader: form_data['screen_reader'] == 'true',
          high_contrast: form_data['high_contrast'] == 'true',
          reduced_effects: form_data['reduced_effects'] == 'true',
          pause_on_typing: form_data['pause_on_typing'] == 'true',
          auto_resume: form_data['auto_resume'] == 'true'
        )

        # Handle TTS speed separately
        speed = form_data['tts_speed']&.to_f
        if speed && speed >= 0.25 && speed <= 4.0
          user.set_narrator_voice!(
            type: user.narrator_settings[:voice_type],
            pitch: user.narrator_settings[:voice_pitch],
            speed: speed
          )
        end

        success_result(
          "Accessibility settings updated.",
          type: :system,
          data: { settings_updated: true }
        )
      end

      private

      def show_accessibility_form
        return error_result('You must be logged in to change accessibility settings.') unless user

        settings = user.accessibility_settings
        narrator = user.narrator_settings

        fields = [
          {
            name: 'accessibility_mode',
            label: 'Accessibility Mode',
            type: 'checkbox',
            default: settings[:accessibility_mode] ? 'true' : 'false',
            description: 'Optimize output for screen readers with TTS auto-queue'
          },
          {
            name: 'screen_reader',
            label: 'Screen Reader Optimization',
            type: 'checkbox',
            default: settings[:screen_reader_optimized] ? 'true' : 'false',
            description: 'Simplify output formatting for screen readers'
          },
          {
            name: 'high_contrast',
            label: 'High Contrast Mode',
            type: 'checkbox',
            default: settings[:high_contrast_mode] ? 'true' : 'false',
            description: 'Increase visual contrast for better readability'
          },
          {
            name: 'reduced_effects',
            label: 'Reduced Visual Effects',
            type: 'checkbox',
            default: settings[:reduced_visual_effects] ? 'true' : 'false',
            description: 'Minimize animations and visual effects'
          },
          {
            name: 'pause_on_typing',
            label: 'Pause TTS on Typing',
            type: 'checkbox',
            default: settings[:tts_pause_on_typing] ? 'true' : 'false',
            description: 'Pause narration when you start typing'
          },
          {
            name: 'auto_resume',
            label: 'Auto-Resume TTS',
            type: 'checkbox',
            default: settings[:tts_auto_resume] ? 'true' : 'false',
            description: 'Automatically resume narration after typing stops'
          },
          {
            name: 'tts_speed',
            label: 'TTS Speed',
            type: 'select',
            default: narrator[:voice_speed].to_s,
            options: [
              { value: '0.5', label: '0.5x (Slow)' },
              { value: '0.75', label: '0.75x' },
              { value: '1.0', label: '1.0x (Normal)' },
              { value: '1.25', label: '1.25x' },
              { value: '1.5', label: '1.5x' },
              { value: '1.75', label: '1.75x' },
              { value: '2.0', label: '2.0x (Fast)' }
            ],
            description: 'Narration playback speed'
          }
        ]

        create_form(
          character_instance,
          'Accessibility Settings',
          fields,
          context: {
            command: 'accessibility'
          }
        )
      end

      def user
        @user ||= character&.user
      end

      def toggle_mode(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        enabled = parse_toggle(value)
        return show_mode_status if enabled.nil?

        user.configure_accessibility!(mode: enabled)

        # Also enable screen reader optimization when accessibility mode is turned on
        user.configure_accessibility!(screen_reader: true) if enabled

        success_result(
          "Accessibility mode is now #{enabled ? 'ON' : 'OFF'}.#{enabled ? "\n\nOutput will be optimized for screen readers. TTS will auto-queue when narration is enabled." : ''}",
          type: :system,
          data: { accessibility_mode: enabled }
        )
      end

      def show_mode_status
        enabled = user&.accessibility_mode?
        success_result(
          "Accessibility mode is currently #{enabled ? 'ON' : 'OFF'}.\nUse 'accessibility mode on' or 'accessibility mode off' to change.",
          type: :system,
          data: { accessibility_mode: enabled }
        )
      end

      def toggle_reader(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        enabled = parse_toggle(value)
        return show_reader_status if enabled.nil?

        user.configure_accessibility!(screen_reader: enabled)

        success_result(
          "Screen reader optimization is now #{enabled ? 'ON' : 'OFF'}.",
          type: :system,
          data: { screen_reader_optimized: enabled }
        )
      end

      def show_reader_status
        enabled = user&.screen_reader_mode?
        success_result(
          "Screen reader optimization is currently #{enabled ? 'ON' : 'OFF'}.\nUse 'accessibility reader on' or 'accessibility reader off' to change.",
          type: :system,
          data: { screen_reader_optimized: enabled }
        )
      end

      def toggle_contrast(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        enabled = parse_toggle(value)
        return show_contrast_status if enabled.nil?

        user.configure_accessibility!(high_contrast: enabled)

        success_result(
          "High contrast mode is now #{enabled ? 'ON' : 'OFF'}.",
          type: :system,
          data: { high_contrast_mode: enabled }
        )
      end

      def show_contrast_status
        enabled = user&.high_contrast_mode == true
        success_result(
          "High contrast mode is currently #{enabled ? 'ON' : 'OFF'}.\nUse 'accessibility contrast on' or 'accessibility contrast off' to change.",
          type: :system,
          data: { high_contrast_mode: enabled }
        )
      end

      def toggle_effects(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        enabled = parse_toggle(value)
        return show_effects_status if enabled.nil?

        # Note: "effects off" means reduced_visual_effects is ON
        user.configure_accessibility!(reduced_effects: !enabled)

        success_result(
          "Visual effects are now #{enabled ? 'ON (full)' : 'OFF (reduced)'}.",
          type: :system,
          data: { reduced_visual_effects: !enabled }
        )
      end

      def show_effects_status
        reduced = user&.reduced_visual_effects == true
        success_result(
          "Visual effects are currently #{reduced ? 'REDUCED' : 'FULL'}.\nUse 'accessibility effects on' (full) or 'accessibility effects off' (reduced) to change.",
          type: :system,
          data: { reduced_visual_effects: reduced }
        )
      end

      def toggle_typing_pause(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        enabled = parse_toggle(value)
        return show_typing_pause_status if enabled.nil?

        user.configure_accessibility!(pause_on_typing: enabled)

        success_result(
          "TTS pause on typing is now #{enabled ? 'ON' : 'OFF'}.#{enabled ? "\n\nNarration will pause when you start typing." : ''}",
          type: :system,
          data: { tts_pause_on_typing: enabled }
        )
      end

      def show_typing_pause_status
        enabled = user&.tts_pause_on_typing?
        success_result(
          "TTS pause on typing is currently #{enabled ? 'ON' : 'OFF'}.\nUse 'accessibility typing on' or 'accessibility typing off' to change.",
          type: :system,
          data: { tts_pause_on_typing: enabled }
        )
      end

      def toggle_auto_resume(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        enabled = parse_toggle(value)
        return show_auto_resume_status if enabled.nil?

        user.configure_accessibility!(auto_resume: enabled)

        success_result(
          "TTS auto-resume is now #{enabled ? 'ON' : 'OFF'}.#{enabled ? "\n\nNarration will automatically resume when you stop typing." : ''}",
          type: :system,
          data: { tts_auto_resume: enabled }
        )
      end

      def show_auto_resume_status
        enabled = user&.tts_auto_resume?
        success_result(
          "TTS auto-resume is currently #{enabled ? 'ON' : 'OFF'}.\nUse 'accessibility resume on' or 'accessibility resume off' to change.",
          type: :system,
          data: { tts_auto_resume: enabled }
        )
      end

      def set_tts_speed(value)
        return error_result('You must be logged in to change accessibility settings.') unless user

        if value.nil? || value.empty?
          current_speed = user.narrator_settings[:voice_speed]
          return success_result(
            "Current TTS speed: #{current_speed}x\nUse 'accessibility speed 0.5' to '2.0' to change.",
            type: :system,
            data: { voice_speed: current_speed }
          )
        end

        speed = value.to_f
        unless speed >= 0.25 && speed <= 4.0
          return error_result("Speed must be between 0.25 and 4.0. Got: #{value}")
        end

        user.set_narrator_voice!(
          type: user.narrator_settings[:voice_type],
          pitch: user.narrator_settings[:voice_pitch],
          speed: speed
        )

        success_result(
          "TTS speed set to #{speed}x.",
          type: :system,
          data: { voice_speed: speed }
        )
      end

      def show_status
        unless user
          return error_result('You must be logged in to view accessibility settings.')
        end

        settings = user.accessibility_settings
        narrator = user.narrator_settings

        lines = []
        lines << "Accessibility Settings"
        lines << "=" * 40
        lines << ""
        lines << "Mode Settings:"
        lines << "  Accessibility Mode: #{settings[:accessibility_mode] ? 'ON' : 'OFF'}"
        lines << "  Screen Reader Opt:  #{settings[:screen_reader_optimized] ? 'ON' : 'OFF'}"
        lines << ""
        lines << "Visual Settings:"
        lines << "  High Contrast:      #{settings[:high_contrast_mode] ? 'ON' : 'OFF'}"
        lines << "  Reduced Effects:    #{settings[:reduced_visual_effects] ? 'ON' : 'OFF'}"
        lines << ""
        lines << "TTS Behavior:"
        lines << "  Pause on Typing:    #{settings[:tts_pause_on_typing] ? 'ON' : 'OFF'}"
        lines << "  Auto-Resume:        #{settings[:tts_auto_resume] ? 'ON' : 'OFF'}"
        lines << "  Narrator Speed:     #{narrator[:voice_speed]}x"
        lines << ""

        if character_instance
          lines << "Session TTS State:"
          lines << "  TTS Enabled:        #{character_instance.tts_enabled? ? 'ON' : 'OFF'}"
          lines << "  TTS Paused:         #{character_instance.tts_paused? ? 'YES' : 'NO'}"
          lines << "  Queue Position:     #{character_instance.tts_queue_position || 0}"
        end

        success_result(
          lines.join("\n"),
          type: :system,
          data: {
            accessibility: settings,
            narrator: narrator,
            session_tts: character_instance ? {
              enabled: character_instance.tts_enabled?,
              paused: character_instance.tts_paused?,
              queue_position: character_instance.tts_queue_position
            } : nil
          }
        )
      end

      def show_help
        lines = []
        lines << "Accessibility Commands"
        lines << "=" * 40
        lines << ""
        lines << "Mode Settings:"
        lines << "  accessibility mode on/off     - Toggle accessibility mode (screen reader output)"
        lines << "  accessibility reader on/off   - Toggle screen reader optimization"
        lines << ""
        lines << "Visual Settings:"
        lines << "  accessibility contrast on/off - Toggle high contrast mode"
        lines << "  accessibility effects on/off  - Toggle visual effects (on=full, off=reduced)"
        lines << ""
        lines << "TTS Behavior:"
        lines << "  accessibility typing on/off   - Pause TTS when you start typing"
        lines << "  accessibility resume on/off   - Auto-resume TTS when you stop typing"
        lines << "  accessibility speed 0.5-2.0   - Set TTS narration speed"
        lines << ""
        lines << "Other Commands:"
        lines << "  accessibility keys              - Show replay buffer key bindings"
        lines << "  accessibility status            - Show all current settings"
        lines << "  accessibility help              - Show this help"
        lines << ""
        lines << "TTS Playback (use 'tts' command):"
        lines << "  tts pause   - Pause narration"
        lines << "  tts resume  - Resume from pause point"
        lines << "  tts current - Skip to latest content"
        lines << "  tts skip +15/-15 - Skip forward/backward"
        lines << ""
        lines << "Keyboard Shortcuts (when focused on game):"
        lines << "  Arrow Left  - Skip back 15 seconds"
        lines << "  Arrow Right - Skip forward 15 seconds"

        success_result(lines.join("\n"), type: :system)
      end

      def show_key_bindings
        lines = []
        lines << "Replay Buffer Key Bindings"
        lines << "=" * 40
        lines << ""
        lines << "These keys let you step through recent messages"
        lines << "while staying in the input field."
        lines << ""
        lines << "  Previous Message: Alt+ArrowUp (default)"
        lines << "  Next Message:     Alt+ArrowDown (default)"
        lines << "  Stop Replaying:   Escape"
        lines << ""
        lines << "To change these bindings, open the webclient settings panel"
        lines << "(gear icon) and look under the Accessibility section."

        success_result(lines.join("\n"), type: :system)
      end

      def parse_toggle(value)
        return nil if value.nil? || value.empty?

        case value.downcase
        when 'on', 'true', 'yes', '1', 'enable', 'enabled'
          true
        when 'off', 'false', 'no', '0', 'disable', 'disabled'
          false
        else
          nil
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Accessibility)
