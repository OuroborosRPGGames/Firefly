# frozen_string_literal: true

module Commands
  module Timeline
    class TimelineCmd < Commands::Base::Command
      command_name 'timeline'
      aliases 'timelines', 'tl', 'snapshot', 'snap'
      category :info
      help_text 'Create flashback scenes at past years/locations or pause scenes with snapshots'
      usage 'timeline [snapshot-name]'
      examples 'timeline', 'timeline "Before the battle"', 'snapshot'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []

        # No args = show main menu
        if args.empty?
          return show_main_menu
        end

        # Args provided = quick-enter a timeline by name
        enter_timeline_by_name(args)
      end

      private

      # Show the main timeline menu
      def show_main_menu
        options = []

        # Build options based on current state
        options << {
          key: 'view',
          label: 'View Timelines',
          description: 'List your snapshots and accessible timelines'
        }

        options << {
          key: 'enter',
          label: 'Enter Timeline',
          description: 'Enter a snapshot or historical timeline'
        }

        options << {
          key: 'create',
          label: 'Create Snapshot',
          description: 'Save a snapshot of this moment'
        }

        # Only show leave option if in past timeline
        if character_instance.in_past_timeline?
          options << {
            key: 'leave',
            label: 'Leave Timeline',
            description: 'Return to the present'
          }

          options << {
            key: 'info',
            label: 'Timeline Info',
            description: 'View current timeline restrictions'
          }
        end

        options << {
          key: 'delete',
          label: 'Delete Snapshot',
          description: 'Remove one of your snapshots'
        }

        options << {
          key: 'q',
          label: 'Cancel',
          description: 'Close menu'
        }

        build_and_store_quickmenu(prompt: 'Timeline Management', options: options, stage: 'main_menu')
      end

      # Quick-enter a timeline by name
      def enter_timeline_by_name(args)
        # Check if already in a past timeline
        if character_instance.in_past_timeline?
          return error_result("You're already in a past timeline. Use 'timeline' and select 'Leave Timeline' first.")
        end

        name = args.join(' ')
        # Handle quoted names
        if name.start_with?('"') && name.end_with?('"')
          name = name[1...-1]
        elsif name.start_with?("'") && name.end_with?("'")
          name = name[1...-1]
        end

        # Try to parse as year first (4 digits)
        if name =~ /^\d{4}$/
          return error_result("To enter a historical timeline, use the menu: type 'timeline' and select 'Enter Timeline'.")
        end

        # Find snapshot (prefer user's own, then accessible ones)
        snapshot = CharacterSnapshot.first(character_id: character.id, name: name)
        snapshot ||= TimelineService.accessible_snapshots_for(character).find { |s| s.name.downcase == name.downcase }

        return error_result("Snapshot '#{name}' not found.") unless snapshot
        return error_result("You weren't present when this snapshot was created.") unless snapshot.can_enter?(character)

        instance = TimelineService.enter_snapshot_timeline(character, snapshot)

        lines = []
        lines << "You've entered the timeline '#{snapshot.name}'."
        lines << ""
        lines << "<h4>Timeline Restrictions</h4>"
        lines << "- Deaths are disabled"
        lines << "- Prisoner mechanics are disabled"
        lines << "- XP gain is disabled"
        lines << "- Room modifications are disabled"
        lines << ""
        lines << "Actions here won't affect your present self."
        lines << "Type 'timeline' and select 'Leave Timeline' to return to the present."
        lines << ""
        lines << "You can open this timeline in a new browser tab while continuing to play your main character."

        success_result(lines.join("\n"), data: { instance_id: instance.id, snapshot_name: snapshot.name })
      rescue TimelineService::NotAllowedError => e
        error_result(e.message)
      rescue StandardError => e
        error_result("Failed to enter timeline: #{e.message}")
      end

      # List all timelines
      def list_timelines
        # Get user's own snapshots
        snapshots = TimelineService.snapshots_for(character)

        # Get snapshots user can access (was present when created)
        accessible = TimelineService.accessible_snapshots_for(character)

        # Get active timeline instances
        active_instances = TimelineService.active_timelines_for(character)

        lines = []
        lines << "<h3>Your Timelines</h3>"

        if snapshots.any?
          lines << ""
          lines << "Your Snapshots:"
          snapshots.each do |snap|
            active = active_instances.any? { |ci| ci.source_snapshot_id == snap.id && ci.online }
            status = active ? " [ACTIVE]" : ""
            lines << "  - #{snap.name}#{status} (#{snap.snapshot_taken_at.strftime('%Y-%m-%d %H:%M')})"
            lines << "    #{snap.description}" if snap.description && !snap.description.to_s.strip.empty?
          end
        end

        other_accessible = accessible - snapshots
        if other_accessible.any?
          lines << ""
          lines << "Snapshots You Can Join:"
          other_accessible.each do |snap|
            creator = snap.character&.full_name || "Unknown"
            active = active_instances.any? { |ci| ci.source_snapshot_id == snap.id && ci.online }
            status = active ? " [ACTIVE]" : ""
            lines << "  - #{snap.name}#{status} by #{creator}"
          end
        end

        if active_instances.any?
          lines << ""
          lines << "Your Active Timeline Instances:"
          active_instances.each do |ci|
            timeline = ci.timeline
            online_status = ci.online ? "[ONLINE]" : "[OFFLINE]"
            lines << "  - #{timeline&.display_name || 'Unknown'} #{online_status}"
          end
        end

        if snapshots.empty? && other_accessible.empty? && active_instances.empty?
          lines << ""
          lines << "You have no snapshots or active timelines."
        end

        lines << ""
        lines << "Type 'timeline' to open the timeline menu."

        success_result(lines.join("\n"))
      end

      # Show enter timeline selection menu
      def show_enter_menu
        # Check if already in a past timeline
        if character_instance.in_past_timeline?
          return error_result("You're already in a past timeline. Use 'Leave Timeline' first.")
        end

        # Get accessible snapshots
        own_snapshots = TimelineService.snapshots_for(character)
        other_snapshots = TimelineService.accessible_snapshots_for(character) - own_snapshots
        all_snapshots = own_snapshots + other_snapshots

        options = []

        # Add snapshot options
        all_snapshots.each_with_index do |snap, idx|
          owner_info = snap.character_id == character.id ? '' : " (by #{snap.character&.full_name || 'Unknown'})"
          options << {
            key: (idx + 1).to_s,
            label: snap.name,
            description: "#{snap.snapshot_taken_at.strftime('%Y-%m-%d')}#{owner_info}"
          }
        end

        # Historical timeline option
        options << {
          key: 'h',
          label: 'Historical Timeline',
          description: 'Enter a specific year and zone'
        }

        options << {
          key: 'q',
          label: 'Cancel',
          description: 'Return to main menu'
        }

        snapshot_data = all_snapshots.map { |s| { id: s.id, name: s.name } }
        build_and_store_quickmenu(
          prompt: 'Select a timeline to enter:',
          options: options,
          stage: 'enter_select',
          extra_context: { snapshots: snapshot_data }
        )
      end

      # Show create snapshot form
      def show_create_form
        # Don't allow snapshots in past timelines
        if character_instance.in_past_timeline?
          return error_result("You cannot create snapshots while in a past timeline.")
        end

        build_and_store_form(
          title: 'Create Snapshot',
          description: "Capture this moment to return to later. Others present can also join this timeline.",
          fields: [
            {
              name: 'name',
              label: 'Snapshot Name',
              type: 'text',
              required: true,
              placeholder: 'e.g., "Before the battle"',
              max_length: 100
            },
            {
              name: 'description',
              label: 'Description (optional)',
              type: 'textarea',
              required: false,
              placeholder: 'A brief note about this moment',
              max_length: 500
            }
          ],
          stage: 'create_snapshot'
        )
      end

      # Show delete snapshot selection menu
      def show_delete_menu
        snapshots = TimelineService.snapshots_for(character)

        if snapshots.empty?
          return error_result("You have no snapshots to delete.")
        end

        options = snapshots.each_with_index.map do |snap, idx|
          {
            key: (idx + 1).to_s,
            label: snap.name,
            description: snap.snapshot_taken_at.strftime('%Y-%m-%d %H:%M')
          }
        end

        options << {
          key: 'q',
          label: 'Cancel',
          description: 'Return to main menu'
        }

        snapshot_data = snapshots.map { |s| { id: s.id, name: s.name } }
        build_and_store_quickmenu(
          prompt: 'Select a snapshot to delete:',
          options: options,
          stage: 'delete_select',
          extra_context: { snapshots: snapshot_data }
        )
      end

      # Leave current timeline
      def leave_timeline
        unless character_instance.in_past_timeline?
          return error_result("You're not in a past timeline.")
        end

        timeline_name = character_instance.timeline_display_name
        TimelineService.leave_timeline(character_instance)

        lines = []
        lines << "You've left the timeline '#{timeline_name}'."
        lines << ""
        lines << "You've returned to the present."

        success_result(lines.join("\n"))
      end

      # Show timeline info
      def show_timeline_info
        unless character_instance.in_past_timeline?
          return error_result("You're not in a past timeline.")
        end

        timeline = character_instance.timeline
        lines = []
        lines << "<h3>Current Timeline</h3>"
        lines << "Name: #{timeline.display_name}"
        lines << "Type: #{timeline.timeline_type.capitalize}"

        if timeline.historical?
          lines << "Year: #{timeline.year}"
          lines << "Zone: #{timeline.zone&.name}"
        elsif timeline.snapshot?
          snap = timeline.snapshot
          lines << "Snapshot by: #{snap&.character&.full_name}"
          lines << "Taken at: #{snap&.snapshot_taken_at&.strftime('%Y-%m-%d %H:%M')}"
        end

        lines << ""
        lines << "Restrictions:"
        lines << "  No Death: #{timeline.no_death? ? 'Yes' : 'No'}"
        lines << "  No Prisoner: #{timeline.no_prisoner? ? 'Yes' : 'No'}"
        lines << "  No XP: #{timeline.no_xp? ? 'Yes' : 'No'}"
        lines << "  Rooms Read-Only: #{timeline.rooms_read_only? ? 'Yes' : 'No'}"

        success_result(lines.join("\n"))
      end

      # Show historical timeline entry form
      def show_historical_form
        if character_instance.in_past_timeline?
          return error_result("You're already in a past timeline. Leave first.")
        end

        fields = [
          {
            name: 'year',
            label: 'Year',
            type: 'number',
            required: true,
            placeholder: 'e.g., 1892',
            min: 1,
            max: 9999
          },
          {
            name: 'zone',
            label: 'Zone Name',
            type: 'text',
            required: true,
            placeholder: 'e.g., Downtown'
          }
        ]

        build_and_store_form(
          title: 'Enter Historical Timeline',
          description: "Travel back in time to a specific year and location. This creates a shared timeline - others entering the same year/zone will be able to interact with you.",
          fields: fields,
          stage: 'historical_entry'
        )
      end

      def build_and_store_quickmenu(prompt:, options:, stage:, extra_context: {})
        interaction_id = SecureRandom.uuid
        context = { command: 'timeline', stage: stage }.merge(extra_context)
        menu_data = {
          type: 'quickmenu',
          interaction_id: interaction_id,
          prompt: prompt,
          options: options,
          context: context,
          created_at: Time.now.iso8601
        }
        OutputHelper.store_agent_interaction(character_instance, interaction_id, menu_data)
        { success: true, type: :quickmenu, prompt: prompt, options: options, interaction_id: interaction_id, context: context }
      end

      def build_and_store_form(title:, fields:, stage:, description: nil, extra_context: {})
        interaction_id = SecureRandom.uuid
        context = { command: 'timeline', stage: stage }.merge(extra_context)
        form_data = { type: 'form', interaction_id: interaction_id, title: title, fields: fields, context: context, created_at: Time.now.iso8601 }
        form_data[:description] = description if description
        OutputHelper.store_agent_interaction(character_instance, interaction_id, form_data)
        { success: true, type: :form, title: title, fields: fields, interaction_id: interaction_id, context: context }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Timeline::TimelineCmd)
