# frozen_string_literal: true

module Commands
  module Building
    # Unified generation command.
    # Replaces: generate.rb, genjobs.rb, genjob.rb
    class Generate < Commands::Base::Command
      command_name 'gen'
      aliases 'generate', 'genjob', 'genjobs'
      category :building
      help_text 'Generate content using LLM world building'
      usage 'gen <type> [options] | gen jobs | gen job <id> [cancel]'
      examples(
        'gen description',
        'gen description seasonal',
        'gen background',
        'gen npc shopkeeper',
        'gen item clothing',
        'gen place tavern',
        'gen city medium',
        'gen jobs',
        'gen job 42',
        'gen job 42 cancel'
      )

      # Generation types and their requirements
      GENERATION_TYPES = {
        'description' => { requires: :room, help: 'Generate description for current room' },
        'seasonal' => { requires: :room, help: 'Generate seasonal description variants' },
        'background' => { requires: :room, help: 'Generate background image for room' },
        'npc' => { requires: :location, help: 'Generate NPC (optionally specify role)' },
        'item' => { requires: :none, help: 'Generate item (specify category)' },
        'place' => { requires: :location, help: 'Generate place (specify type)' },
        'city' => { requires: :location, help: 'Generate full city (specify size)' }
      }.freeze

      protected

      def perform_command(parsed_input)
        # Check build permission
        unless character_instance.character.can_build?
          return error_result('You must have building permissions to use generation commands.')
        end

        # Parse arguments
        args = (parsed_input[:text] || '').strip.split(/\s+/)
        subcommand = args.shift&.downcase

        if subcommand.nil? || subcommand.empty?
          return show_help
        end

        # Handle job-related subcommands
        case subcommand
        when 'jobs', 'list'
          return show_jobs(args)
        when 'job'
          return handle_job(args)
        end

        # Handle generation types
        gen_type = subcommand

        unless GENERATION_TYPES.key?(gen_type)
          # Check if they meant "job <id>"
          if gen_type =~ /^\d+$/
            return handle_job([gen_type] + args)
          end
          return error_result("Unknown generation type: #{gen_type}. Valid types: #{GENERATION_TYPES.keys.join(', ')}")
        end

        # Check if generation is available
        unless WorldBuilderOrchestratorService.available?
          return error_result('Generation services are currently unavailable. Check LLM configuration.')
        end

        # Route to appropriate handler
        case gen_type
        when 'description'
          generate_description(args)
        when 'seasonal'
          generate_seasonal(args)
        when 'background'
          generate_background(args)
        when 'npc'
          generate_npc(args)
        when 'item'
          generate_item(args)
        when 'place'
          generate_place(args)
        when 'city'
          generate_city(args)
        else
          show_help
        end
      end

      private

      # Helper to truncate strings without Rails
      def truncate_string(str, length, omission = '...')
        return nil if str.nil?
        return str if str.length <= length
        str[0, length - omission.length] + omission
      end

      # ========================================
      # Help
      # ========================================

      def show_help
        lines = ['<bold>Generation Commands</bold>']
        lines << ''
        GENERATION_TYPES.each do |type, info|
          lines << "  <cmd>gen #{type}</cmd> - #{info[:help]}"
        end
        lines << ''
        lines << 'Job Management:'
        lines << '  <cmd>gen jobs</cmd> - View active generation jobs'
        lines << '  <cmd>gen job <id></cmd> - Check job status'
        lines << '  <cmd>gen job <id> cancel</cmd> - Cancel a job'

        success_result(lines.join("\n"), type: :info)
      end

      # ========================================
      # Job Management (from genjobs.rb and genjob.rb)
      # ========================================

      def show_jobs(args)
        filter = args.first || 'active'
        char = character_instance.character

        case filter.downcase
        when 'active'
          show_active_jobs(char)
        when 'recent'
          show_recent_jobs(char, limit: 10)
        when 'all'
          show_recent_jobs(char, limit: 50)
        else
          show_active_jobs(char)
        end
      end

      def show_active_jobs(char)
        jobs = WorldBuilderOrchestratorService.active_jobs_for(char)

        if jobs.empty?
          return success_result(
            'No active generation jobs. Use <cmd>gen</cmd> to start one.',
            type: :info
          )
        end

        lines = ["<bold>Active Generation Jobs</bold> (#{jobs.length})"]
        lines << ''

        jobs.each do |job|
          status_icon = status_icon_for(job[:status])
          progress = job[:percent] ? "(#{job[:percent].round(0)}%)" : ''

          lines << "  #{status_icon} <bold>##{job[:id]}</bold> #{job[:type]} #{progress}"
          lines << "     #{job[:message]}" if job[:message]
          lines << "     Duration: #{job[:duration]}" if job[:duration]
        end

        lines << ''
        lines << 'Use <cmd>gen job <id></cmd> for details or <cmd>gen job <id> cancel</cmd> to cancel.'

        success_result(lines.join("\n"), type: :info)
      end

      def show_recent_jobs(char, limit: 10)
        jobs = WorldBuilderOrchestratorService.recent_jobs_for(char, limit: limit)

        if jobs.empty?
          return success_result(
            'No generation jobs found. Use <cmd>gen</cmd> to start one.',
            type: :info
          )
        end

        lines = ["<bold>Recent Generation Jobs</bold> (showing #{[jobs.length, limit].min})"]
        lines << ''

        jobs.each do |job|
          status_icon = status_icon_for(job[:status])
          type_display = job[:type] || job[:status_display]

          lines << "  #{status_icon} <bold>##{job[:id]}</bold> #{type_display}"

          case job[:status]
          when 'completed'
            lines << "     Completed in #{job[:duration]}"
          when 'failed'
            lines << "     <red>#{truncate_string(job[:error], 60)}</red>"
          when 'running'
            lines << "     #{job[:message]} (#{job[:percent]&.round(0) || 0}%)"
          when 'pending'
            lines << '     Waiting to start...'
          when 'cancelled'
            lines << '     Cancelled'
          end
        end

        lines << ''
        lines << 'Use <cmd>gen job <id></cmd> for full details.'

        success_result(lines.join("\n"), type: :info)
      end

      def handle_job(args)
        if args.empty?
          return error_result('Usage: gen job <id> or gen job <id> cancel')
        end

        # Parse arguments - handle both "gen job cancel 42" and "gen job 42 cancel"
        cancel = args.include?('cancel')
        args = args.reject { |a| a == 'cancel' }

        job_id = args.first&.to_i
        if job_id.nil? || job_id <= 0
          return error_result('Please provide a valid job ID number.')
        end

        # Get job status
        job_info = WorldBuilderOrchestratorService.job_status_for(job_id, character_instance.character)

        unless job_info
          return error_result("Job ##{job_id} not found.")
        end

        if cancel
          cancel_job(job_id, job_info)
        else
          show_job_status(job_id, job_info)
        end
      end

      def show_job_status(job_id, info)
        lines = ["<bold>Generation Job ##{job_id}</bold>"]
        lines << ''

        lines << "Type: #{info[:type]}"
        lines << "Status: #{status_display(info[:status])}"

        if info[:status] == 'running'
          lines << "Progress: #{info[:percent]&.round(1) || 0}%"
          lines << "Message: #{info[:message]}" if info[:message]
        end

        lines << "Started: #{format_iso_timestamp(info[:started_at])}" if info[:started_at]
        lines << "Duration: #{info[:duration]}" if info[:duration]

        case info[:status]
        when 'completed'
          lines << ''
          lines << '<bold>Results:</bold>'
          format_results(info[:results]).each { |line| lines << "  #{line}" }
        when 'failed'
          lines << ''
          lines << "<red>Error: #{info[:error]}</red>"
        end

        if info[:has_children] && info[:child_progress]&.any?
          lines << ''
          lines << '<bold>Sub-tasks:</bold>'
          info[:child_progress].each do |child|
            icon = status_icon_for(child[:status])
            lines << "  #{icon} #{child[:type]} - #{child[:status_display]}"
          end
        end

        lines << ''
        if %w[pending running].include?(info[:status])
          lines << "Use <cmd>gen job #{job_id} cancel</cmd> to cancel this job."
        end

        success_result(lines.join("\n"), type: :info)
      end

      def cancel_job(job_id, info)
        unless %w[pending running].include?(info[:status])
          return error_result("Job ##{job_id} is already #{info[:status]} and cannot be cancelled.")
        end

        char = character_instance.character

        if WorldBuilderOrchestratorService.cancel_job(job_id, char)
          success_result(
            "Job ##{job_id} (#{info[:type]}) has been cancelled.",
            type: :message,
            data: { action: 'cancel_job', job_id: job_id }
          )
        else
          error_result("Could not cancel job ##{job_id}. You may only cancel your own jobs.")
        end
      end

      def status_display(status)
        case status
        when 'pending' then 'Pending'
        when 'running' then 'Running'
        when 'completed' then 'Completed'
        when 'failed' then 'Failed'
        when 'cancelled' then 'Cancelled'
        else status.to_s.capitalize
        end
      end

      def status_icon_for(status)
        case status
        when 'pending' then '...'
        when 'running' then '>>>'
        when 'completed' then '[+]'
        when 'failed' then '[X]'
        when 'cancelled' then '[-]'
        else '[?]'
        end
      end

      def format_iso_timestamp(iso_time)
        return 'N/A' unless iso_time

        Time.parse(iso_time).strftime('%Y-%m-%d %H:%M:%S')
      rescue StandardError => e
        warn "[Generate] Error parsing time '#{iso_time}': #{e.message}"
        iso_time
      end

      def format_results(results)
        return ['No results'] unless results&.any?

        lines = []

        results.each do |key, value|
          next if value.nil?

          case value
          when String
            lines << "#{key}: #{truncate_string(value, 100)}"
          when Array
            lines << "#{key}: #{value.length} items"
          when Hash
            lines << "#{key}: #{value.keys.join(', ')}"
          else
            lines << "#{key}: #{value}"
          end
        end

        lines.empty? ? ['Generation complete'] : lines
      end

      # ========================================
      # Generation Methods
      # ========================================

      def generate_description(args)
        room = location
        seasonal = args.include?('seasonal')

        job = if seasonal
                WorldBuilderOrchestratorService.generate_seasonal_descriptions(
                  room: room,
                  setting: current_setting,
                  created_by: character_instance.character
                )
              else
                WorldBuilderOrchestratorService.generate_description(
                  target: room,
                  setting: current_setting,
                  created_by: character_instance.character
                )
              end

        if job.completed?
          description = job.result_value('content') || job.result_value('description')
          if description
            room.update(long_description: description)
            success_result(
              "Room description generated:\n\n#{description}",
              type: :message,
              data: { action: 'generate_description', job_id: job.id }
            )
          else
            error_result("Generation completed but no description returned. Check job #{job.id}.")
          end
        else
          success_result(
            "Description generation started. Job ID: #{job.id}\nUse <cmd>gen job #{job.id}</cmd> to check status.",
            type: :info,
            data: { action: 'generate', job_id: job.id }
          )
        end
      end

      def generate_seasonal(args)
        room = location

        job = WorldBuilderOrchestratorService.generate_seasonal_descriptions(
          room: room,
          setting: current_setting,
          created_by: character_instance.character
        )

        success_result(
          "Seasonal descriptions generation started (16 variants). Job ID: #{job.id}\nUse <cmd>gen job #{job.id}</cmd> to check status.",
          type: :info,
          data: { action: 'generate_seasonal', job_id: job.id }
        )
      end

      def generate_background(args)
        room = location

        job = WorldBuilderOrchestratorService.generate_image(
          target: room,
          image_type: :room_background,
          setting: current_setting,
          created_by: character_instance.character
        )

        if job.completed?
          url = job.result_value('local_url') || job.result_value('url')
          if url
            room.update(default_background_url: url)
            success_result(
              "Background generated and saved: #{url}",
              type: :message,
              data: { action: 'generate_background', job_id: job.id, url: url }
            )
          else
            error_result("Generation completed but no image URL returned. Check job #{job.id}.")
          end
        else
          success_result(
            "Background generation started. Job ID: #{job.id}\nUse <cmd>gen job #{job.id}</cmd> to check status.",
            type: :info,
            data: { action: 'generate_background', job_id: job.id }
          )
        end
      end

      def generate_npc(args)
        role = args.first
        loc = location.location

        job = WorldBuilderOrchestratorService.generate_npc(
          location: loc,
          role: role,
          setting: current_setting,
          generate_portrait: false,
          generate_schedule: true,
          created_by: character_instance.character
        )

        if job.completed?
          name = job.result_value('name')&.dig('full_name')
          success_result(
            "NPC generated: #{name || 'Unknown'}\nAppearance: #{truncate_string(job.result_value('appearance'), 200)}",
            type: :message,
            data: { action: 'generate_npc', job_id: job.id }
          )
        else
          success_result(
            "NPC generation started#{role ? " (#{role})" : ''}. Job ID: #{job.id}",
            type: :info,
            data: { action: 'generate_npc', job_id: job.id }
          )
        end
      end

      def generate_item(args)
        category = args.first&.to_sym || :misc
        valid_categories = %i[clothing jewelry weapon consumable furniture misc]

        unless valid_categories.include?(category)
          return error_result("Invalid item category: #{category}. Valid: #{valid_categories.join(', ')}")
        end

        job = WorldBuilderOrchestratorService.generate_item(
          category: category,
          setting: current_setting,
          generate_image: false,
          created_by: character_instance.character
        )

        if job.completed?
          name = job.result_value('name')
          desc = job.result_value('description')
          success_result(
            "Item generated: #{name}\n#{desc}",
            type: :message,
            data: { action: 'generate_item', job_id: job.id }
          )
        else
          success_result(
            "Item generation started (#{category}). Job ID: #{job.id}",
            type: :info,
            data: { action: 'generate_item', job_id: job.id }
          )
        end
      end

      def generate_place(args)
        place_type = args.first&.to_sym || :tavern
        valid_types = Generators::PlaceGeneratorService::PLACE_TYPES.keys

        unless valid_types.include?(place_type)
          return error_result("Invalid place type: #{place_type}. Valid: #{valid_types.first(10).join(', ')}...")
        end

        loc = location.location

        job = WorldBuilderOrchestratorService.generate_place(
          location: loc,
          place_type: place_type,
          setting: current_setting,
          generate_rooms: true,
          generate_npcs: false,
          created_by: character_instance.character
        )

        if job.completed?
          name = job.result_value('name')
          success_result(
            "Place generated: #{name}\nRooms: #{job.result_value('layout')&.length || 0}",
            type: :message,
            data: { action: 'generate_place', job_id: job.id }
          )
        else
          success_result(
            "Place generation started (#{place_type}). Job ID: #{job.id}",
            type: :info,
            data: { action: 'generate_place', job_id: job.id }
          )
        end
      end

      def generate_city(args)
        size = args.first&.to_sym || :medium
        valid_sizes = Generators::CityGeneratorService::CITY_SIZES.keys

        unless valid_sizes.include?(size)
          return error_result("Invalid city size: #{size}. Valid: #{valid_sizes.join(', ')}")
        end

        loc = location.location

        job = WorldBuilderOrchestratorService.generate_city(
          location: loc,
          setting: current_setting,
          size: size,
          generate_places: true,
          generate_place_rooms: false,
          generate_npcs: false,
          created_by: character_instance.character
        )

        success_result(
          "City generation started (#{size}). This may take several minutes.\nJob ID: #{job.id}\nUse <cmd>gen job #{job.id}</cmd> to track progress.",
          type: :info,
          data: { action: 'generate_city', job_id: job.id }
        )
      end

      def current_setting
        loc = location.respond_to?(:location) ? location.location : nil
        return :fantasy unless loc

        setting_value = loc.respond_to?(:setting) ? loc.setting : nil
        return :fantasy unless setting_value

        case setting_value
        when /modern|contemporary/i then :modern
        when /scifi|sci-fi|futur/i then :scifi
        when /steampunk/i then :steampunk
        else :fantasy
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Generate)
