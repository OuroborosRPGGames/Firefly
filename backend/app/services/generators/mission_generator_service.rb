# frozen_string_literal: true

require 'timeout'

module Generators
  # MissionGeneratorService orchestrates multi-model mission generation
  #
  # Uses a four-phase pipeline:
  # 1. Brainstorming: Kimi-k2 + GPT-5.2 generate creative ideas in parallel
  # 2. Synthesis: Opus combines and structures ideas into a concept-level plan
  # 3. Round Detail: Sonnet expands round sketches into full detail in parallel
  # 4. Building: Flash creates all database records iteratively
  #
  # @example Generate a mission synchronously
  #   result = Generators::MissionGeneratorService.generate(
  #     description: "A heist to steal the Duke's ledger",
  #     location_mode: :mission_specific,
  #     setting: :fantasy,
  #     difficulty: :normal,
  #     options: { generate_images: true }
  #   )
  #
  # @example Generate a mission asynchronously
  #   job = Generators::MissionGeneratorService.generate_async(
  #     description: "Investigate the haunted manor",
  #     location_mode: :reusable_asset,
  #     setting: :fantasy,
  #     difficulty: :hard,
  #     created_by: character
  #   )
  #
  class MissionGeneratorService
    # Location mode options
    LOCATION_MODES = %i[existing mission_specific reusable_asset].freeze

    # Difficulty tiers
    DIFFICULTY_TIERS = %i[easy normal hard].freeze

    # Settings available
    SETTINGS = %i[fantasy scifi modern horror steampunk].freeze

    class << self
      # Generate a mission synchronously (blocking)
      # @param description [String] Mission concept/description
      # @param location_mode [Symbol] :existing, :mission_specific, :reusable_asset
      # @param setting [Symbol] World setting
      # @param difficulty [Symbol] Difficulty tier
      # @param options [Hash] Additional options
      # @return [Hash] { success:, activity:, job:, errors: }
      def generate(description:, location_mode:, setting:, difficulty: :normal, options: {})
        # Validate inputs
        validation = validate_inputs(description, location_mode, setting, difficulty)
        return validation unless validation[:valid]

        # Create generation job for tracking
        job = create_generation_job(
          description: description,
          location_mode: location_mode,
          setting: setting,
          difficulty: difficulty,
          options: options,
          created_by: options[:created_by]
        )

        # Execute the pipeline
        execute_pipeline(job, description, location_mode, setting, difficulty, options)
      end

      # Generate a mission asynchronously (returns job immediately)
      # @param description [String] Mission concept/description
      # @param location_mode [Symbol] :existing, :mission_specific, :reusable_asset
      # @param setting [Symbol] World setting
      # @param difficulty [Symbol] Difficulty tier
      # @param options [Hash] Additional options
      # @param created_by [Character, nil] Creator for tracking
      # @return [GenerationJob] Job to track progress
      def generate_async(description:, location_mode:, setting:, difficulty: :normal, options: {}, created_by: nil)
        # Validate inputs
        validation = validate_inputs(description, location_mode, setting, difficulty)
        unless validation[:valid]
          # Create failed job to return
          return GenerationJob.create(
            job_type: 'mission',
            status: 'failed',
            error_message: validation[:errors].join(', '),
            config: { description: description }
          )
        end

        # Create generation job
        job = create_generation_job(
          description: description,
          location_mode: location_mode,
          setting: setting,
          difficulty: difficulty,
          options: options,
          created_by: created_by
        )

        # Spawn background thread for generation with overall timeout
        Thread.new do
          Timeout.timeout(GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS) do
            execute_pipeline(job, description, location_mode, setting, difficulty, options)
          end
        rescue Timeout::Error
          warn "[MissionGenerator] Pipeline timed out for job #{job.id} after #{GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS}s"
          job.fail!("Pipeline timed out after #{GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS}s")
        rescue StandardError => e
          warn "[MissionGenerator] Pipeline thread error for job #{job.id}: #{e.message}"
          job.fail!("Thread error: #{e.message}") if job.running? || job.pending?
        end

        job
      end

      # Cancel a running generation job
      # @param job [GenerationJob] Job to cancel
      # @return [Boolean] Whether cancellation succeeded
      def cancel(job)
        return false unless job.running? || job.pending?

        job.cancel!
        true
      end

      # Check if all required models are available
      # @return [Hash] { available:, models: }
      def models_available?
        brainstorm_status = MissionBrainstormService.models_available?
        synthesis_available = MissionSynthesisService.available?

        {
          available: brainstorm_status.values.any? && synthesis_available,
          models: {
            brainstorm_a: brainstorm_status[:creative_a],
            brainstorm_b: brainstorm_status[:creative_b],
            synthesis: synthesis_available,
            builder: AIProviderService.provider_available?('google_gemini')
          }
        }
      end

      private

      # Validate generation inputs
      def validate_inputs(description, location_mode, setting, difficulty)
        errors = []

        errors << 'Description is required' if StringHelper.blank?(description)
        errors << 'Description must be at least 10 characters' if description.to_s.strip.length < 10
        errors << "Invalid location_mode: #{location_mode}" unless LOCATION_MODES.include?(location_mode.to_sym)
        errors << "Invalid setting: #{setting}" unless SETTINGS.include?(setting.to_sym)
        errors << "Invalid difficulty: #{difficulty}" unless DIFFICULTY_TIERS.include?(difficulty.to_sym)

        { valid: errors.empty?, errors: errors }
      end

      # Create generation job for tracking
      def create_generation_job(description:, location_mode:, setting:, difficulty:, options:, created_by:)
        config = {
          description: description,
          location_mode: location_mode.to_s,
          setting: setting.to_s,
          difficulty: difficulty.to_s,
          options: options.except(:created_by, :base_location)
        }
        # Store base room ID for display (Room object itself isn't serializable)
        config[:base_room_id] = options[:base_location].id if options[:base_location]

        GenerationJob.create(
          job_type: 'mission',
          status: 'pending',
          config: Sequel.pg_jsonb(config),
          created_by_id: created_by&.id
        )
      end

      # Execute the four-phase pipeline
      def execute_pipeline(job, description, location_mode, setting, difficulty, options)
        job.start!

        begin
          # Phase 1: Brainstorming
          brainstorm_result = execute_brainstorm_phase(job, description, setting, options)
          return pipeline_failure(job, brainstorm_result[:error]) unless brainstorm_result[:success]

          # Phase 2: Synthesis (concept-level)
          synthesis_result = execute_synthesis_phase(job, brainstorm_result, description, setting, difficulty, location_mode, options)
          return pipeline_failure(job, synthesis_result[:error]) unless synthesis_result[:success]

          # Phase 3: Round Detail (parallel)
          detail_result = execute_round_detail_phase(job, synthesis_result[:plan], options)
          return pipeline_failure(job, 'Round detail phase failed') unless detail_result

          # Phase 4: Building
          build_result = execute_build_phase(job, detail_result, setting, difficulty, location_mode, options)
          return pipeline_failure(job, build_result[:errors]&.join(', ')) unless build_result[:success]

          # Success!
          complete_pipeline(job, build_result)
        rescue StandardError => e
          pipeline_failure(job, "Pipeline error: #{e.message}")
        end
      end

      # Phase 1: Brainstorming with parallel models
      def execute_brainstorm_phase(job, description, setting, options)
        job.update_phase!('brainstorm')
        job.update_progress!(step: 1, total: 4, message: 'Brainstorming with AI models...')

        # Get seed terms for inspiration
        seed_terms = SeedTermService.for_generation(:lore, count: 8)

        result = MissionBrainstormService.brainstorm(
          description: description,
          setting: setting,
          seed_terms: seed_terms,
          options: options.slice(:max_tokens, :temperature)
        )

        if result[:success]
          job.store_brainstorm!(result[:outputs])
          job.log_progress!("Brainstorm complete: #{result[:outputs].keys.length} models responded")
        else
          job.log_progress!("Brainstorm failed: #{result[:errors]&.join(', ')}")
        end

        {
          success: result[:success],
          outputs: result[:outputs],
          seed_terms: result[:seed_terms],
          error: result[:errors]&.first
        }
      end

      # Phase 2: Synthesis with Opus (concept-level plan)
      def execute_synthesis_phase(job, brainstorm_result, description, setting, difficulty, location_mode, options)
        job.update_phase!('synthesis')
        job.update_progress!(step: 2, total: 4, message: 'Synthesizing mission structure...')

        result = MissionSynthesisService.synthesize(
          brainstorm_outputs: brainstorm_result[:outputs],
          description: description,
          setting: setting,
          difficulty: difficulty,
          location_mode: location_mode,
          activity_type: options[:activity_type] || 'mission',
          options: options.slice(:max_tokens, :temperature)
        )

        if result[:success]
          job.store_synthesis!(result[:plan])
          job.log_progress!("Synthesis complete: #{result[:plan]['title']}")
          job.log_progress!("Rounds: #{result[:plan]['rounds']&.length || 0}, Adversaries: #{result[:plan]['adversaries']&.length || 0}")
        else
          job.log_progress!("Synthesis failed: #{result[:error]}")
        end

        {
          success: result[:success],
          plan: result[:plan],
          error: result[:error]
        }
      end

      # Phase 3: Round Detail with Sonnet (parallel)
      def execute_round_detail_phase(job, concept_plan, options)
        job.update_phase!('round_detail')
        job.update_progress!(step: 3, total: 4, message: 'Expanding round details in parallel...')

        available_stats = load_available_stats(options)

        result = Generators::MissionRoundDetailService.detail_rounds(
          concept_plan: concept_plan,
          available_stats: available_stats,
          options: { timeout: 120 }
        )

        if result[:errors]&.any?
          result[:errors].each { |e| job.log_progress!("Round detail warning: #{e}") }
        end

        unless result[:success]
          job.fail!("Round detail phase failed: #{result[:errors]&.join(', ')}")
          return nil
        end

        # Store the enriched plan
        job.update(synthesized_plan: Sequel.pg_jsonb(result[:plan]))
        job.log_progress!("Round details complete: #{result[:plan]['rounds']&.length} rounds expanded")

        result[:plan]
      end

      # Phase 4: Building with Flash
      def execute_build_phase(job, plan, setting, difficulty, location_mode, options)
        job.update_phase!('building')
        job.update_progress!(step: 4, total: 4, message: 'Building mission components...')

        result = MissionBuilderService.build(
          mission_plan: plan,
          location_mode: location_mode,
          setting: setting,
          difficulty: difficulty,
          options: options,
          generation_job: job
        )

        if result[:success]
          job.log_progress!("Build complete: Activity ##{result[:activity]&.id}")
          job.log_progress!("Created #{result[:rounds_created]} rounds, #{result[:archetypes].size} archetypes, #{result[:rooms].size} rooms")
        else
          job.log_progress!("Build failed: #{result[:errors]&.join(', ')}")
        end

        result
      end

      # Complete the pipeline successfully
      def complete_pipeline(job, build_result)
        job.complete!(
          activity_id: build_result[:activity]&.id,
          rounds_created: build_result[:rounds_created],
          archetypes_created: build_result[:archetypes]&.size || 0,
          rooms_created: build_result[:rooms]&.size || 0
        )

        {
          success: true,
          activity: build_result[:activity],
          job: job,
          rounds_created: build_result[:rounds_created],
          archetypes: build_result[:archetypes],
          rooms: build_result[:rooms],
          errors: build_result[:errors]
        }
      end

      # Handle pipeline failure
      def pipeline_failure(job, error_message)
        job.fail!(error_message || 'Unknown error')

        # Rollback any created resources
        rollback_resources(job)

        {
          success: false,
          activity: nil,
          job: job,
          errors: [error_message]
        }
      end

      # Load available stats from options
      # @param options [Hash] Options with :stat_block_id or :universe_id
      # @return [Array<Hash>] Stats with :id, :name, :abbreviation
      def load_available_stats(options)
        stat_block_id = options[:stat_block_id] || options['stat_block_id']
        universe_id = options[:universe_id] || options['universe_id']

        stat_block = if stat_block_id && stat_block_id.to_i > 0
                       StatBlock[stat_block_id.to_i]
                     elsif universe_id && universe_id.to_i > 0
                       Universe[universe_id.to_i]&.default_stat_block
                     end

        return [] unless stat_block

        stat_block.stats.map { |s| { id: s.id, name: s.name, abbreviation: s.abbreviation } }
      rescue StandardError => e
        warn "[MissionGenerator] Failed to load stats: #{e.message}"
        []
      end

      # Rollback resources created during failed generation
      def rollback_resources(job)
        # Get activity ID from results if it was created
        activity_id = job.result_value(:activity_id)
        return unless activity_id

        begin
          # Delete the activity (cascades to rounds, actions)
          activity = Activity[activity_id]
          if activity
            # Delete mission-specific rooms
            Room.where(generated_for_activity_id: activity_id, is_mission_specific: true).delete

            # Delete generated archetypes
            NpcArchetype.where(generated_for_activity_id: activity_id, is_generated: true).delete

            # Delete child image generation jobs
            GenerationJob.where(parent_job_id: job.id).delete

            # Delete the activity
            activity.destroy
          end

          job.log_progress!('Rolled back created resources')
        rescue StandardError => e
          job.log_progress!("Rollback error: #{e.message}")
        end
      end
    end
  end
end
