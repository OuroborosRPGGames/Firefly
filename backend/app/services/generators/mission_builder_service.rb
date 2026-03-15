# frozen_string_literal: true

module Generators
  # MissionBuilderService builds Activity records from synthesized mission plans
  #
  # Takes a mission plan from MissionSynthesisService and creates all database records:
  # Activity, ActivityRounds, NpcArchetypes, and optionally Rooms.
  #
  # @example Build a mission from plan
  #   result = Generators::MissionBuilderService.build(
  #     mission_plan: plan,
  #     location_mode: :mission_specific,
  #     setting: :fantasy,
  #     options: { generate_images: true }
  #   )
  #
  class MissionBuilderService
    # Model for content generation
    BUILDER_MODEL = { provider: 'google_gemini', model: 'gemini-3-flash-preview' }.freeze

    # BuildContext tracks state during mission building
    class BuildContext
      attr_accessor :activity, :rooms, :archetypes, :round_map
      attr_reader :mission_plan, :setting, :difficulty, :location_mode, :options, :generation_job, :errors

      def initialize(mission_plan:, setting:, difficulty:, location_mode:, options:, generation_job:)
        @mission_plan = mission_plan
        @setting = setting
        @difficulty = difficulty
        @location_mode = location_mode
        @options = options
        @generation_job = generation_job
        @activity = nil
        @rooms = {}         # key -> Room
        @archetypes = {}    # key -> NpcArchetype
        @round_map = {}     # "branch-round_number" -> ActivityRound
        @errors = []
      end

      def log(message)
        generation_job&.log_progress!(message)
      end

      def add_error(error)
        @errors << error
      end

      def base_location
        options[:base_location]
      end

      def generate_images?
        options[:generate_images] == true
      end
    end

    class << self
      # Build mission from synthesized plan
      # @param mission_plan [Hash] Plan from MissionSynthesisService
      # @param location_mode [Symbol] :existing, :mission_specific, :reusable_asset
      # @param setting [Symbol] World setting
      # @param difficulty [Symbol] Difficulty tier
      # @param options [Hash] Additional options
      # @param generation_job [GenerationJob, nil] For progress tracking
      # @return [Hash] { success:, activity:, rooms:, archetypes:, errors: }
      def build(mission_plan:, location_mode:, setting:, difficulty: :normal, options: {}, generation_job: nil)
        context = BuildContext.new(
          mission_plan: mission_plan,
          setting: setting,
          difficulty: difficulty,
          location_mode: location_mode,
          options: options,
          generation_job: generation_job
        )

        # Step 1: Create Activity record
        context.log('Creating activity record...')
        create_activity(context)
        return failure_result(context, 'Failed to create activity') unless context.activity

        # Step 2: Build locations (if not using existing)
        if location_mode != :existing
          context.log('Generating locations...')
          build_locations(context)
        end

        # Step 3: Build adversaries
        context.log('Creating adversaries...')
        build_adversaries(context)

        # Step 4: Build rounds
        context.log('Building mission rounds...')
        build_rounds(context)

        # Step 5: Link branches
        context.log('Linking branches...')
        link_branches(context)

        # Step 6: Generate images (async)
        if context.generate_images?
          context.log('Spawning image generation...')
          spawn_image_generation(context)
        end

        {
          success: true,
          activity: context.activity,
          rooms: context.rooms,
          archetypes: context.archetypes,
          rounds_created: context.round_map.size,
          errors: context.errors
        }
      rescue StandardError => e
        context.add_error("Build failed: #{e.message}")
        failure_result(context, e.message)
      end

      private

      # Create the Activity record
      def create_activity(context)
        plan = context.mission_plan

        context.activity = Activity.create(
          name: plan['title'],
          description: plan['summary'],
          activity_type: context.options[:activity_type] || plan['atype'] || 'mission',
          share_type: 'public',
          launch_mode: 'creator',
          location: context.base_location&.id,
          universe_id: context.options[:universe_id],
          stat_block_id: context.options[:stat_block_id],
          is_public: true,  # Generated missions are public by default
          repeatable: true,
          logging_enabled: true,
          logs_visible_to: 'participants'
        )
      rescue StandardError => e
        context.add_error("Activity creation failed: #{e.message}")
        nil
      end

      # Build location rooms from plan
      def build_locations(context)
        locations = context.mission_plan['locations'] || []
        return if locations.empty?

        locations.each do |loc|
          context.log("Creating room: #{loc['name']}...")

          room = create_room_from_location(loc, context)
          context.rooms[loc['key']] = room if room
        end
      end

      # Create a single room from location definition
      def create_room_from_location(location, context)
        # Use RoomGeneratorService if available, otherwise create basic room
        seed_terms = SeedTermService.for_generation(:room, count: 5)

        # Generate description using LLM
        desc_result = generate_room_description(
          name: location['name'],
          description: location['description'],
          room_type: location['room_type'],
          setting: context.setting,
          seed_terms: seed_terms
        )

        room = Room.create(
          name: location['name'],
          description: desc_result[:content] || location['description'],
          room_type: location['room_type'] || 'indoor',
          location_id: context.base_location&.location_id,
          is_mission_specific: context.location_mode == :mission_specific,
          generated_for_activity_id: context.activity&.id
        )

        # Queue background image generation if requested
        if context.generate_images? && location['generate_background']
          queue_room_image(room, context)
        end

        room
      rescue StandardError => e
        context.add_error("Room creation failed for #{location['name']}: #{e.message}")
        nil
      end

      # Generate room description
      def generate_room_description(name:, description:, room_type:, setting:, seed_terms:)
        prompt = GamePrompts.get(
          'generators.mission_room',
          setting: setting,
          name: name,
          room_type: room_type,
          description: description,
          seed_terms: seed_terms.join(', ')
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: BUILDER_MODEL[:provider],
          model: BUILDER_MODEL[:model],
          options: { max_tokens: 300, temperature: 0.7 }
        )

        { success: result[:success], content: result[:text] }
      end

      # Build adversary archetypes from plan
      def build_adversaries(context)
        adversaries = context.mission_plan['adversaries'] || []
        return if adversaries.empty?

        result = AdversaryGeneratorService.generate(
          adversaries: adversaries,
          setting: context.setting,
          difficulty: context.difficulty,
          activity_id: context.activity&.id
        )

        context.archetypes.merge!(result[:archetypes])
        context.errors.concat(result[:errors]) if result[:errors]&.any?
      end

      # Build all mission rounds
      def build_rounds(context)
        rounds = context.mission_plan['rounds'] || []
        return if rounds.empty?

        # Sort by branch then round_number
        sorted_rounds = rounds.sort_by { |r| [r['branch'] || 0, r['round_number']] }

        sorted_rounds.each_with_index do |round_def, index|
          context.log("Creating round #{index + 1}/#{rounds.length}...")
          create_round(round_def, context)
        end
      end

      # Create a single ActivityRound
      def create_round(round_def, context)
        # Create base round
        round = ActivityRound.create(
          activity_id: context.activity.id,
          round_number: round_def['round_number'],
          branch: round_def['branch'] || 0,
          rtype: round_def['rtype'] || 'standard',
          emit: round_def['emit'],
          succ_text: round_def['succ_text'],
          fail_text: round_def['fail_text'],
          fail_con: round_def['fail_con'] || 'none',
          fail_repeat: round_def['fail_repeat'] || false,
          knockout: round_def['knockout'] || false
        )

        # Store for branch linking
        plan_id = "#{round_def['branch'] || 0}-#{round_def['round_number']}"
        context.round_map[plan_id] = round

        # Configure by round type
        configure_round_by_type(round, round_def, context)

        # Assign room
        assign_room_to_round(round, round_def, context)

        round
      rescue StandardError => e
        context.add_error("Round creation failed: #{e.message}")
        nil
      end

      # Configure round based on type
      def configure_round_by_type(round, round_def, context)
        case round_def['rtype']
        when 'combat'
          configure_combat_round(round, round_def, context)
        when 'branch'
          configure_branch_round(round, round_def, context)
        when 'persuade'
          configure_persuade_round(round, round_def, context)
        when 'standard'
          configure_standard_round(round, round_def, context)
        when 'reflex'
          configure_reflex_round(round, round_def, context)
        when 'free_roll'
          configure_free_roll_round(round, round_def, context)
        when 'group_check'
          configure_group_check_round(round, round_def, context)
        end
      end

      # Configure combat round
      def configure_combat_round(round, round_def, context)
        encounter_key = round_def['combat_encounter_name'] || round_def['combat_encounter_key']
        matching = context.archetypes[encounter_key]

        # Archetypes may be stored as an array (multiple NPCs per encounter) or single value
        archetype_ids = case matching
                        when Array then matching.map(&:id)
                        when NpcArchetype then [matching.id]
                        else []
                        end

        if archetype_ids.any?
          round.update(
            combat_npc_ids: Sequel.pg_array(archetype_ids),
            combat_difficulty: round_def['combat_difficulty'] || 'normal',
            combat_is_finale: round_def['is_finale'] || false
          )
        end
      end

      # Configure branch round with choices
      def configure_branch_round(round, round_def, context)
        # Branch choices will be linked in second pass
        # Store the choice definitions for later
        choices = round_def['branch_choices'] || []

        if choices.any?
          # Store as JSONB for now, will update with round IDs in link_branches
          round.update(
            branch_choices: Sequel.pg_jsonb(choices.map do |c|
              {
                'text' => c['text'],
                'description' => c['description'],
                'leads_to_branch' => c['leads_to_branch']
              }
            end)
          )
        end
      end

      # Configure persuade round
      def configure_persuade_round(round, round_def, context)
        attrs = {
          persuade_npc_name: round_def['persuade_npc_name'],
          persuade_goal: round_def['persuade_goal'],
          persuade_base_dc: round_def['persuade_base_dc'] || 15,
          persuade_npc_personality: round_def['persuade_npc_personality']
        }
        persuade_stat_ids = round_def['persuade_stat_ids']
        if persuade_stat_ids.is_a?(Array) && persuade_stat_ids.any?
          attrs[:stat_set_a] = Sequel.pg_array(persuade_stat_ids.map(&:to_i))
        end
        round.update(attrs)
      end

      # Configure standard round with actions
      def configure_standard_round(round, round_def, context)
        actions = round_def['actions'] || []
        return if actions.empty?

        action_ids = actions.map do |action_def|
          action = create_activity_action(action_def, context)
          action&.id
        end.compact

        round.update(actions: Sequel.pg_array(action_ids)) if action_ids.any?
      end

      # Configure reflex round
      def configure_reflex_round(round, round_def, context)
        attrs = { timeout_seconds: round_def['timeout_seconds'] || 120 }
        attrs[:reflex_stat_id] = round_def['reflex_stat_id'].to_i if round_def['reflex_stat_id']
        round.update(attrs)
      end

      # Configure free roll round
      def configure_free_roll_round(round, round_def, context)
        round.update(
          free_roll_context: round_def['free_roll_context']
        )
      end

      # Configure group check round
      def configure_group_check_round(round, round_def, context)
        stat_set = round_def['stat_set_a']
        if stat_set.is_a?(Array) && stat_set.any?
          round.update(stat_set_a: Sequel.pg_array(stat_set.map(&:to_i)))
        end
      end

      # Create an ActivityAction
      def create_activity_action(action_def, context)
        action_attrs = {
          activity_parent: context.activity.id,
          choice_string: action_def['choice_text'],
          output_string: action_def['output_string'],
          fail_string: action_def['fail_string']
        }

        # Set stat IDs if provided (skill_list is JSONB array)
        stat_ids = action_def['stat_ids']
        if stat_ids.is_a?(Array) && stat_ids.any?
          action_attrs[:skill_list] = Sequel.pg_array(stat_ids.map(&:to_i))
        end

        ActivityAction.create(action_attrs)
      rescue StandardError => e
        context.add_error("Action creation failed: #{e.message}")
        nil
      end

      # Assign room to round
      def assign_room_to_round(round, round_def, context)
        location_key = round_def['location_key']
        return if location_key.nil? || location_key == 'existing'

        room = context.rooms[location_key]
        return unless room

        round.update(
          round_room_id: room.id,
          use_activity_room: false
        )
      end

      # Link branches (second pass after all rounds created)
      def link_branches(context)
        rounds = context.mission_plan['rounds'] || []

        # Build a map of branch_id => first round_number in that branch
        branch_first_rounds = {}
        rounds.each do |r|
          branch_id = r['branch'] || 0
          round_num = r['round_number']
          next unless round_num

          if branch_first_rounds[branch_id].nil? || round_num < branch_first_rounds[branch_id]
            branch_first_rounds[branch_id] = round_num
          end
        end

        rounds.each do |round_def|
          next unless round_def['rtype'] == 'branch' && round_def['branch_choices']

          plan_id = "#{round_def['branch'] || 0}-#{round_def['round_number']}"
          round = context.round_map[plan_id]
          next unless round

          # Update branch_choices with actual round IDs
          choices = round_def['branch_choices'].map do |choice|
            target_branch = choice['leads_to_branch']
            # Find the first round in the target branch
            first_round_num = branch_first_rounds[target_branch]
            target_plan_id = "#{target_branch}-#{first_round_num}" if first_round_num
            target_round = target_plan_id ? context.round_map[target_plan_id] : nil

            {
              'text' => choice['text'],
              'description' => choice['description'],
              'branch_to_round_id' => target_round&.id
            }
          end

          round.update(branch_choices: Sequel.pg_jsonb(choices))

          # Set legacy branch_to for first choice
          if choices.first && choices.first['branch_to_round_id']
            round.update(branch_to: choices.first['branch_to_round_id'])
          end
        end
      end

      # Spawn async image generation
      def spawn_image_generation(context)
        # Queue room background generation
        context.rooms.each_value do |room|
          next unless room

          # Create child job for room image
          GenerationJob.create(
            job_type: 'image',
            parent_job_id: context.generation_job&.id,
            config: {
              target_type: 'room',
              target_id: room.id,
              image_type: 'background'
            },
            status: 'pending'
          )
        end

        # Queue NPC portrait generation
        context.archetypes.each_value do |archetype|
          next unless archetype

          GenerationJob.create(
            job_type: 'image',
            parent_job_id: context.generation_job&.id,
            config: {
              target_type: 'npc_archetype',
              target_id: archetype.id,
              image_type: 'portrait'
            },
            status: 'pending'
          )
        end
      end

      # Queue room image generation
      def queue_room_image(room, context)
        # Will be picked up by background worker
        GenerationJob.create(
          job_type: 'image',
          parent_job_id: context.generation_job&.id,
          config: {
            target_type: 'room',
            target_id: room.id,
            image_type: 'background'
          },
          status: 'pending'
        )
      end

      # Build failure result
      def failure_result(context, message)
        {
          success: false,
          activity: context.activity,
          rooms: context.rooms,
          archetypes: context.archetypes,
          rounds_created: context.round_map.size,
          errors: context.errors + [message]
        }
      end
    end
  end
end
