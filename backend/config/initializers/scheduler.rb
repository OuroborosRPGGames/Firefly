# frozen_string_literal: true

# Initialize the game scheduler and timed action processor
#
# The scheduler runs in a background thread and processes:
# - Timed actions (movement, combat, etc.)
# - Cooldown cleanup
# - Cron jobs (reports, maintenance)
# - Weather API updates
# - Auto-AFK processing
#

module Firefly
  module SchedulerInitializer
    class << self
      def start!
        return if ENV['SKIP_SCHEDULER'] == 'true'
        return if defined?(@started) && @started

        TimedActionProcessor.register!
        register_weather_updater!
        register_weather_simulator!
        register_auto_afk_processor!
        register_npc_schedule_processor!
        register_game_cleanup_processor!
        register_combat_timeout_processor!
        register_world_travel_processor!
        register_consent_notification_processor!
        register_unconsciousness_processor!
        register_activity_timeout_processor!
        register_activity_tracking_processor!
        register_activity_decay_processor!
        register_help_sync!
        register_npc_animation_processor!
        register_pet_animation_processor!
        register_world_memory_processors!
        register_atmospheric_emit_processor!
        register_moderation_cleanup_processors!
        register_draft_character_cleanup!
        register_abuse_monitoring_processors!
        register_narrative_processors!
        register_reputation_processor!
        register_weather_grid_tick!
        register_weather_grid_persistence!
        restore_weather_grid_state!
        register_battle_map_generation_watchdog!
        register_auto_gm_loop_watchdog!
        cleanup_stuck_generation_jobs!
        cleanup_stuck_mission_generation_jobs!
        register_stale_generation_job_cleanup!
        cleanup_stuck_battle_map_generation!
        cleanup_stale_online_sessions!
        register_stranded_character_rescue!
        register_observe_refresh_processor!
        register_jukebox_processor!
        register_lighting_idle_shutdown!

        # Start the scheduler
        Scheduler.start

        @started = true
        puts '[Scheduler] Game scheduler started'
      end

      def register_weather_updater!
        # Run at 0, 15, 30, 45 minutes past each hour
        Scheduler.on_cron({ minutes: [0, 15, 30, 45], hours: [], days: [], weekdays: [] }) do |_event|
          update_weather_from_api
        end
      end

      # Update all stale weather records from API
      def update_weather_from_api
        api_key = GameSetting.get('weather_api_key') rescue nil
        return unless api_key && !api_key.empty?

        updated = WeatherApiService.refresh_all_stale
        puts "[Weather] Updated #{updated} weather record(s) from API" if updated > 0
      rescue StandardError => e
        warn "[Weather] Error updating weather: #{e.message}"
      end

      def register_weather_simulator!
        # Run at 7, 22, 37, 52 minutes (every 15 minutes, offset from API updater)
        Scheduler.on_cron({ minutes: [7, 22, 37, 52], hours: [], days: [], weekdays: [] }) do |_event|
          simulate_internal_weather
        end
      end

      # Simulate weather for all internal weather sources
      def simulate_internal_weather
        return unless defined?(Weather) && defined?(WeatherSimulatorService)

        simulated = 0
        errors = []

        Weather.where(weather_source: 'internal').or(weather_source: nil).each do |weather|
          begin
            weather.simulate!
            simulated += 1
          rescue StandardError => e
            errors << { weather_id: weather.id, error: e.message }
          end
        end

        puts "[Weather] Simulated #{simulated} internal weather record(s)" if simulated > 0

        errors.each do |error|
          warn "[Weather] Simulation error for ##{error[:weather_id]}: #{error[:error]}"
        end
      rescue StandardError => e
        warn "[Weather] Error simulating internal weather: #{e.message}"
      end

      def register_auto_afk_processor!
        # Run at 0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55 minutes (every 5 minutes)
        Scheduler.on_cron({ minutes: [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55], hours: [], days: [], weekdays: [] }) do |_event|
          process_idle_characters
        end
      end

      # Process idle characters for auto-AFK
      def process_idle_characters
        results = AutoAfkService.process_idle_characters!
        if results[:afk] > 0 || results[:disconnected] > 0
          puts "[AutoAFK] #{results[:afk]} marked AFK, #{results[:disconnected]} disconnected"
        end
      rescue StandardError => e
        warn "[AutoAFK] Error processing idle characters: #{e.message}"
      end

      def register_npc_schedule_processor!
        # Run every minute (at second 30 to spread load)
        Scheduler.on_cron({ minutes: [], hours: [], days: [], weekdays: [] }) do |_event|
          process_npc_schedules
        end
      end

      # Process NPC schedules for spawning/despawning
      def process_npc_schedules
        results = NpcSpawnService.process_schedules!

        if results[:spawned].any? || results[:despawned].any?
          puts "[NPC] Spawned: #{results[:spawned].size}, Despawned: #{results[:despawned].size}"
        end

        results[:errors].each do |error|
          warn "[NPC] Error: #{error[:error]}"
        end
      rescue StandardError => e
        warn "[NPC] Error processing schedules: #{e.message}"
      end

      def register_game_cleanup_processor!
        # Run at 2, 7, 12, 17, 22, 27, 32, 37, 42, 47, 52, 57 minutes (every 5 minutes, offset from AFK)
        Scheduler.on_cron({ minutes: [2, 7, 12, 17, 22, 27, 32, 37, 42, 47, 52, 57], hours: [], days: [], weekdays: [] }) do |_event|
          sweep_game_cleanup
        end
      end

      # Unified game cleanup sweep (fights, activities, auto-GM)
      def sweep_game_cleanup
        GameCleanupService.sweep!
      rescue StandardError => e
        warn "[GameCleanup] Error during sweep: #{e.message}"
      end

      def register_combat_timeout_processor!
        # Run every 6 ticks (~6 seconds with default 1s tick) to check for timed out combat rounds
        Scheduler.on_tick(6) do |_event|
          process_combat_timeouts
        end
      end

      # Process combat round timeouts - delegates to FightService
      def process_combat_timeouts
        return unless defined?(Fight) && defined?(FightService)

        FightService.resolve_timed_out_rounds!
      end

      def register_world_travel_processor!
        # Run every minute to advance journeys
        Scheduler.on_cron({ minutes: [], hours: [], days: [], weekdays: [] }) do |_event|
          process_world_travel
        end
      end

      # Process world travel journeys
      def process_world_travel
        results = WorldTravelProcessorService.process_due_journeys!

        if results[:advanced] > 0 || results[:arrived] > 0
          puts "[WorldTravel] Advanced: #{results[:advanced]}, Arrived: #{results[:arrived]}"
        end

        results[:errors].each do |error|
          warn "[WorldTravel] Error for journey ##{error[:journey_id]}: #{error[:error]}"
        end
      rescue StandardError => e
        warn "[WorldTravel] Error processing journeys: #{e.message}"
      end

      def register_consent_notification_processor!
        # Run every minute (at second 45 to spread load)
        Scheduler.on_cron({ minutes: [], hours: [], days: [], weekdays: [] }) do |_event|
          process_consent_notifications
        end
      end

      # Process content consent notifications for rooms with stable occupancy
      def process_consent_notifications
        results = ContentConsentService.process_consent_notifications!

        if results[:notified].to_i > 0
          puts "[Consent] Sent consent notifications to #{results[:notified]} character(s)"
        end
      rescue StandardError => e
        warn "[Consent] Error processing consent notifications: #{e.message}"
      end

      def register_unconsciousness_processor!
        # Run every minute (at second 50 to spread load)
        Scheduler.on_cron({ minutes: [], hours: [], days: [], weekdays: [] }) do |_event|
          process_unconscious_characters
        end
      end

      # Process unconscious characters for auto-wake
      def process_unconscious_characters
        results = PrisonerService.process_auto_wakes!

        if results[:woken] > 0
          puts "[Prisoner] Auto-woke #{results[:woken]} character(s)"
        end

        results[:errors].each do |error|
          warn "[Prisoner] Error for character ##{error[:character_id]}: #{error[:error]}"
        end
      rescue StandardError => e
        warn "[Prisoner] Error processing unconscious characters: #{e.message}"
      end

      def register_activity_timeout_processor!
        # Run every minute (at second 20 to spread load)
        Scheduler.on_cron({ minutes: [], hours: [], days: [], weekdays: [] }) do |_event|
          process_activity_timeouts
        end
      end

      # Process activity round timeouts
      def process_activity_timeouts
        return unless defined?(ActivityInstance)

        ActivityService.resolve_timed_out_instances!
      rescue StandardError => e
        warn "[Activity] Error processing timeouts: #{e.message}"
      end

      def register_activity_tracking_processor!
        # Run at 1, 6, 11, 16, 21, 26, 31, 36, 41, 46, 51, 56 minutes (every 5 min, offset from AFK)
        Scheduler.on_cron({ minutes: [1, 6, 11, 16, 21, 26, 31, 36, 41, 46, 51, 56], hours: [], days: [], weekdays: [] }) do |_event|
          record_activity_samples
        end
      end

      # Record activity samples for online+active characters
      def record_activity_samples
        return unless defined?(ActivityTrackingService)

        results = ActivityTrackingService.record_active_characters!

        puts "[ActivityTracking] Recorded #{results[:recorded]} samples" if results[:recorded] > 0
      rescue StandardError => e
        warn "[ActivityTracking] Error recording samples: #{e.message}"
      end

      def register_activity_decay_processor!
        # Run Sunday at 4 AM
        Scheduler.on_cron({ minutes: [0], hours: [4], days: [], weekdays: [0] }) do |_event|
          apply_activity_decay
        end
      end

      # Apply decay to all activity profiles
      def apply_activity_decay
        return unless defined?(ActivityTrackingService)

        results = ActivityTrackingService.apply_decay_to_all!
        puts "[ActivityTracking] Applied decay to #{results[:decayed]} profiles"
      rescue StandardError => e
        warn "[ActivityTracking] Error applying decay: #{e.message}"
      end

      def register_help_sync!
        Thread.new do
          # Wait for database to be fully ready
          sleep 3

          sync_help_system
        end
      end

      # Sync all commands to helpfiles and seed system documentation
      def sync_help_system
        # Sync command helpfiles
        count = Firefly::HelpManager.sync_commands!
        puts "[Help] Synced #{count} command helpfiles"

        # Seed system documentation if HelpSystem exists
        if defined?(HelpSystem)
          system_count = HelpSystem.seed_defaults!
          puts "[Help] Seeded #{system_count} help systems"
        end
      rescue StandardError => e
        warn "[Help] Error syncing help: #{e.message}"
      end

      def register_npc_animation_processor!
        # Fallback only - runs every 6 ticks (30 seconds)
        # Primary processing happens immediately via async threads.
        # This catches any orphaned entries that failed to start.
        Scheduler.on_tick(6) do |_event|
          process_npc_animation_queue
        end
      end

      # Process orphaned NPC animation queue entries (fallback)
      # Primary processing is async/immediate - this is cleanup only
      def process_npc_animation_queue
        return unless defined?(NpcAnimationService)

        results = NpcAnimationService.process_queue!

        # Only log if orphaned entries were processed (shouldn't happen often)
        if results[:processed] > 0 || results[:failed] > 0
          warn "[NpcAnimation] Fallback processed: #{results[:processed]}, Failed: #{results[:failed]}"
        end
      rescue StandardError => e
        warn "[NpcAnimation] Error in fallback processor: #{e.message}"
      end

      def register_pet_animation_processor!
        # Idle animation processor - runs every 24 ticks (~2 minutes)
        # Processes pets for random idle animations
        Scheduler.on_tick(24) do |_event|
          process_pet_idle_animations
        end

        # Queue fallback processor - runs every 6 ticks (30 seconds)
        # Catches any orphaned entries that failed to start
        Scheduler.on_tick(6) do |_event|
          process_pet_animation_queue
        end
      end

      # Process idle animations for all active pets
      def process_pet_idle_animations
        return unless defined?(PetAnimationService)

        results = PetAnimationService.process_idle_animations!

        if results[:queued] > 0
          puts "[PetAnimation] Queued #{results[:queued]} idle animations"
        end
      rescue StandardError => e
        warn "[PetAnimation] Error in idle processor: #{e.message}"
      end

      # Process orphaned Pet animation queue entries (fallback)
      # Primary processing is async/immediate - this is cleanup only
      def process_pet_animation_queue
        return unless defined?(PetAnimationService)

        results = PetAnimationService.process_queue!

        # Only log if orphaned entries were processed (shouldn't happen often)
        if results[:processed] > 0 || results[:failed] > 0
          warn "[PetAnimation] Fallback processed: #{results[:processed]}, Failed: #{results[:failed]}"
        end
      rescue StandardError => e
        warn "[PetAnimation] Error in fallback processor: #{e.message}"
      end

      # ========================================
      # World Memory Processors
      # ========================================

      def register_world_memory_processors!
        # Stale session processor - runs every 5 minutes
        Scheduler.on_cron({ minutes: [3, 8, 13, 18, 23, 28, 33, 38, 43, 48, 53, 58], hours: [], days: [], weekdays: [] }) do |_event|
          finalize_stale_world_memory_sessions
        end

        # Raw log purge - runs daily at 3 AM
        Scheduler.on_cron({ minutes: [0], hours: [3], days: [], weekdays: [] }) do |_event|
          purge_world_memory_raw_logs
        end

        # Decay processor - runs Sunday at 5 AM
        Scheduler.on_cron({ minutes: [0], hours: [5], days: [], weekdays: [0] }) do |_event|
          apply_world_memory_decay
        end

        # Abstraction processor - runs every 6 hours
        Scheduler.on_cron({ minutes: [30], hours: [0, 6, 12, 18], days: [], weekdays: [] }) do |_event|
          process_world_memory_abstraction
        end
      end

      # Finalize stale world memory sessions (2+ hours inactive)
      def finalize_stale_world_memory_sessions
        return unless defined?(WorldMemoryService)

        count = WorldMemoryService.finalize_stale_sessions!
        puts "[WorldMemory] Finalized #{count} stale sessions" if count > 0
      rescue StandardError => e
        warn "[WorldMemory] Error finalizing sessions: #{e.message}"
      end

      # Purge expired raw logs (6 months old)
      def purge_world_memory_raw_logs
        return unless defined?(WorldMemoryService)

        count = WorldMemoryService.purge_expired_raw_logs!
        puts "[WorldMemory] Purged #{count} expired raw logs" if count > 0
      rescue StandardError => e
        warn "[WorldMemory] Error purging raw logs: #{e.message}"
      end

      # Apply decay to old world memories
      def apply_world_memory_decay
        return unless defined?(WorldMemoryService)

        count = WorldMemoryService.apply_decay!
        puts "[WorldMemory] Applied decay to #{count} memories" if count > 0
      rescue StandardError => e
        warn "[WorldMemory] Error applying decay: #{e.message}"
      end

      # Process world memory abstraction
      def process_world_memory_abstraction
        return unless defined?(WorldMemoryService)

        WorldMemoryService.check_and_abstract!
        puts '[WorldMemory] Abstraction check complete'
      rescue StandardError => e
        warn "[WorldMemory] Error in abstraction: #{e.message}"
      end

      # ========================================
      # Atmospheric Emit Processor
      # ========================================

      def register_atmospheric_emit_processor!
        # Run at 4, 19, 34, 49 minutes (every 15 minutes, offset from other jobs)
        Scheduler.on_cron({ minutes: [4, 19, 34, 49], hours: [], days: [], weekdays: [] }) do |_event|
          process_atmospheric_emits
        end
      end

      # Process atmospheric emits for occupied rooms
      def process_atmospheric_emits
        return unless defined?(AtmosphericEmitService)

        AtmosphericEmitService.process_pending_emits!
      end

      # ========================================
      # Moderation Cleanup Processors
      # ========================================

      def register_moderation_cleanup_processors!
        # IP ban expiry - runs hourly at minute 10
        Scheduler.on_cron({ minutes: [10], hours: [], days: [], weekdays: [] }) do |_event|
          expire_temporary_ip_bans
        end

        # Connection log cleanup - runs daily at 2 AM
        Scheduler.on_cron({ minutes: [0], hours: [2], days: [], weekdays: [] }) do |_event|
          cleanup_old_connection_logs
        end
      end

      # Expire temporary IP bans that have passed their expires_at time
      def expire_temporary_ip_bans
        return unless defined?(IpBan)

        expired = IpBan.where(active: true)
                       .exclude(expires_at: nil)
                       .where { expires_at < Time.now }
                       .update(active: false)

        puts "[Moderation] Expired #{expired} temporary IP ban(s)" if expired > 0
      rescue StandardError => e
        warn "[Moderation] Error expiring IP bans: #{e.message}"
      end

      # Cleanup connection logs older than 90 days
      def cleanup_old_connection_logs
        return unless defined?(ConnectionLog)

        deleted = ConnectionLog.cleanup_old_logs!(days: 90)
        puts "[Moderation] Cleaned up #{deleted} old connection log(s)" if deleted > 0
      rescue StandardError => e
        warn "[Moderation] Error cleaning up connection logs: #{e.message}"
      end

      # ========================================
      # Draft Character Cleanup
      # ========================================

      def register_draft_character_cleanup!
        # Run daily at 3 AM
        Scheduler.on_cron({ minutes: [0], hours: [3], days: [], weekdays: [] }) do |_event|
          cleanup_abandoned_drafts
        end
      end

      # Delete draft characters older than 24 hours
      def cleanup_abandoned_drafts
        return unless defined?(Character)

        cutoff = Time.now - (24 * 3600)
        deleted = Character.where(is_draft: true).where { created_at < cutoff }.delete

        puts "[Cleanup] Deleted #{deleted} abandoned draft character(s)" if deleted > 0
      rescue StandardError => e
        warn "[Cleanup] Error cleaning up draft characters: #{e.message}"
      end

      # ========================================
      # Abuse Monitoring Processors
      # ========================================

      def register_abuse_monitoring_processors!
        # Process pending checks - runs every 2 ticks (10 seconds)
        # Quick processing to minimize message delay
        Scheduler.on_tick(2) do |_event|
          process_pending_abuse_checks
        end

        # Expire staff overrides - runs every minute
        Scheduler.on_cron({ minutes: [], hours: [], days: [], weekdays: [] }) do |_event|
          expire_abuse_monitoring_overrides
        end

        # Cleanup old cleared checks - runs daily at 4 AM
        Scheduler.on_cron({ minutes: [0], hours: [4], days: [], weekdays: [] }) do |_event|
          cleanup_old_abuse_checks
        end
      end

      # Process pending abuse checks (Gemini screening, Claude escalation)
      def process_pending_abuse_checks
        return unless defined?(AbuseMonitoringService)

        results = AbuseMonitoringService.process_pending_checks!

        if results[:gemini].to_i > 0 || results[:escalated].to_i > 0
          puts "[AbuseMonitor] Gemini: #{results[:gemini]}, Escalated: #{results[:escalated]}"
        end

        if results[:errors].to_i > 0
          warn "[AbuseMonitor] #{results[:errors]} error(s) during processing"
        end
      rescue StandardError => e
        warn "[AbuseMonitor] Error processing checks: #{e.message}"
      end

      # Expire old staff overrides
      def expire_abuse_monitoring_overrides
        return unless defined?(AbuseMonitoringOverride)

        expired = AbuseMonitoringOverride.where(active: true)
                                          .where { active_until < Time.now }
                                          .all

        expired.each do |override|
          override.deactivate!
          puts "[AbuseMonitor] Override expired (was activated by #{override.triggered_by_user&.username || 'Unknown'})"
        end
      rescue StandardError => e
        warn "[AbuseMonitor] Error expiring overrides: #{e.message}"
      end

      # Cleanup old cleared abuse checks (older than 30 days)
      def cleanup_old_abuse_checks
        return unless defined?(AbuseCheck)

        cutoff = Time.now - (30 * 24 * 60 * 60) # 30 days

        # Delete cleared checks older than 30 days
        deleted = AbuseCheck.where(status: 'cleared')
                            .where { created_at < cutoff }
                            .delete

        puts "[AbuseMonitor] Cleaned up #{deleted} old cleared check(s)" if deleted > 0
      rescue StandardError => e
        warn "[AbuseMonitor] Error cleaning up old checks: #{e.message}"
      end

      # ========================================
      # PC Reputation Processor
      # ========================================

      def register_reputation_processor!
        # Run Sunday at 6 AM (after activity decay at 4 AM and world memory decay at 5 AM)
        Scheduler.on_cron({ minutes: [0], hours: [6], days: [], weekdays: [0] }) do |_event|
          regenerate_pc_reputations
        end
      end

      # Regenerate reputation tiers for all PCs from world memories
      def regenerate_pc_reputations
        return unless defined?(ReputationService)

        results = ReputationService.regenerate_all!
        puts "[Reputation] Regenerated reputations for #{results[:updated]} PC(s)"

        results[:errors]&.each do |error|
          warn "[Reputation] Error for character ##{error[:character_id]}: #{error[:error]}"
        end
      rescue StandardError => e
        warn "[Reputation] Error regenerating reputations: #{e.message}"
      end

      # ========================================
      # Narrative Intelligence Processors
      # ========================================

      def register_narrative_processors!
        # Batch extraction - every 12 hours (at 6am and 6pm, minute 15)
        # Most RP scenes take a few hours, so frequent extraction is unnecessary.
        # Important events still get immediate comprehensive extraction via hooks.
        Scheduler.on_cron({ minutes: [15], hours: [6, 18], days: [], weekdays: [] }) do |_event|
          process_narrative_extraction_batch
        end

        # Thread detection - hourly at minute 45
        Scheduler.on_cron({ minutes: [45], hours: [], days: [], weekdays: [] }) do |_event|
          process_narrative_thread_detection
        end
      end

      def process_narrative_extraction_batch
        return unless defined?(NarrativeExtractionService)

        results = NarrativeExtractionService.extract_batch
        if results[:processed] > 0
          puts "[Narrative] Extracted entities from #{results[:processed]} memories " \
               "(#{results[:entities]} entities, #{results[:relationships]} relationships)"
        end
        results[:errors].each do |err|
          warn "[Narrative] Extraction error for memory ##{err[:memory_id]}: #{err[:error]}"
        end
      rescue StandardError => e
        warn "[Narrative] Error in batch extraction: #{e.message}"
      end

      def process_narrative_thread_detection
        return unless defined?(NarrativeThreadService)

        results = NarrativeThreadService.detect_and_update!
        if results[:new_threads] > 0 || results[:updated_threads] > 0
          puts "[Narrative] Thread detection: #{results[:new_threads]} new, " \
               "#{results[:updated_threads]} updated, #{results[:dormant_count]} dormant"
        end
      rescue StandardError => e
        warn "[Narrative] Error in thread detection: #{e.message}"
      end

      # ========================================
      # Battle Map Generation Watchdog
      # ========================================

      # Catches fights stuck with battle_map_generating=true due to native crashes
      # (e.g., SIGBUS in libvips) that can't be caught by Ruby rescue
      def register_battle_map_generation_watchdog!
        # Run every 6 ticks (~30 seconds) - fast enough to not leave players waiting long
        Scheduler.on_tick(6) do |_event|
          recover_stuck_battle_map_generation
        end
      end

      # Detect and recover fights where battle_map_generating has been true for too long.
      # Native crashes (SIGBUS, SEGV) kill the generation thread without triggering
      # any Ruby rescue, leaving the flag stuck forever.
      def recover_stuck_battle_map_generation
        return unless defined?(Fight) && defined?(BattleMapGeneratorService)

        BattleMapGeneratorService.recover_stuck!
      end

      # ========================================
      # Auto-GM Loop Watchdog
      # ========================================

      # Detects sessions whose GM loop thread died (server restart, crash)
      # and restarts the loop in a new thread, using DB row locks for cluster safety
      def register_auto_gm_loop_watchdog!
        Scheduler.on_tick(6) do |_event|
          recover_orphaned_auto_gm_loops
        end
      end

      def recover_orphaned_auto_gm_loops
        return unless defined?(AutoGm::AutoGmSessionService)

        recovered = AutoGm::AutoGmSessionService.recover_orphaned_loops
        puts "[AutoGmWatchdog] Recovered #{recovered} orphaned GM loop(s)" if recovered > 0
      rescue StandardError => e
        warn "[AutoGmWatchdog] Error: #{e.message}"
      end

      # ========================================
      # Weather Grid Processors
      # ========================================

      def register_weather_grid_tick!
        Scheduler.on_tick(3) do |_event|
          tick_grid_weather
        end
      end

      # Tick weather simulation and storm processing for all grid-enabled worlds
      def tick_grid_weather
        return unless defined?(WeatherGrid::SimulationService)

        World.where(use_grid_weather: true).each do |world|
          WeatherGrid::SimulationService.tick(world)
          WeatherGrid::StormService.tick(world)
        rescue StandardError => e
          warn "[WeatherGrid] Tick error for world #{world.id}: #{e.message}"
        end
      rescue StandardError => e
        warn "[WeatherGrid] Error in grid tick: #{e.message}"
      end

      def register_weather_grid_persistence!
        Scheduler.on_cron({ minutes: [4, 9, 14, 19, 24, 29, 34, 39, 44, 49, 54, 59], hours: [], days: [], weekdays: [] }) do |_event|
          persist_grid_weather
        end
      end

      # Persist Redis weather state to PostgreSQL
      def persist_grid_weather
        return unless defined?(WeatherGrid::PersistenceService)

        results = WeatherGrid::PersistenceService.persist_all!
        puts "[WeatherGrid] Persisted #{results[:persisted]} world(s)" if results[:persisted]&.positive?
      rescue StandardError => e
        warn "[WeatherGrid] Persistence error: #{e.message}"
      end

      # Restore weather grid state from DB on startup (runs once in background)
      def restore_weather_grid_state!
        Thread.new do
          sleep 2
          return unless defined?(WeatherGrid::PersistenceService)

          WeatherGrid::PersistenceService.startup_load
          puts '[WeatherGrid] Restored grid state from database'
        rescue StandardError => e
          warn "[WeatherGrid] Startup restore error: #{e.message}"
        end
      end

      # Mark any "running" world generation jobs as failed on startup
      # Background threads die on server restart, leaving jobs stuck
      def cleanup_stuck_generation_jobs!
        return unless defined?(WorldGenerationJob)

        stuck = WorldGenerationJob.where(status: 'running').all
        stuck.each do |job|
          job.fail!('Server restarted during generation')
          warn "[WorldGeneration] Marked stuck job ##{job.id} as failed (was at #{job.progress_percentage}%)"
        end
      rescue StandardError => e
        warn "[WorldGeneration] Error cleaning up stuck jobs: #{e.message}"
      end

      # Mark any "running" or "pending" mission generation jobs as failed on startup
      # Background threads die on server restart, leaving jobs stuck
      def cleanup_stuck_mission_generation_jobs!
        return unless defined?(GenerationJob)

        stuck = GenerationJob.where(status: %w[running pending]).where(job_type: 'mission').all
        stuck.each do |job|
          job.fail!('Server restarted during generation')
          warn "[MissionGeneration] Marked stuck job ##{job.id} as failed (was #{job.status})"
        end
      rescue StandardError => e
        warn "[MissionGeneration] Error cleaning up stuck jobs: #{e.message}"
      end

      # Register periodic cleanup for stale generation jobs (running > 30 min)
      def register_stale_generation_job_cleanup!
        # Run at 1, 6, 11, 16, 21, 26, 31, 36, 41, 46, 51, 56 minutes (every 5 minutes)
        Scheduler.on_cron({ minutes: [1, 6, 11, 16, 21, 26, 31, 36, 41, 46, 51, 56], hours: [], days: [], weekdays: [] }) do |_event|
          cleanup_stale_generation_jobs
        end
      end

      # Find and fail generation jobs that have been running too long
      def cleanup_stale_generation_jobs
        return unless defined?(GenerationJob)

        stale = GenerationJob.stale_running
        stale.each do |job|
          job.fail!("Stale: running for over #{GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS / 60} minutes")
          warn "[MissionGeneration] Failed stale job ##{job.id} (started #{job.started_at})"
        end

        # Also clean up old completed jobs
        deleted = GenerationJob.cleanup_old!
        puts "[MissionGeneration] Cleaned up #{deleted} old generation jobs" if deleted.positive?
      rescue StandardError => e
        warn "[MissionGeneration] Error in stale job cleanup: #{e.message}"
      end

      # On server restart, any battle map generation threads are dead.
      # Clear the flag so fights aren't stuck waiting for a generation that will never complete.
      def cleanup_stuck_battle_map_generation!
        return unless defined?(Fight)

        stuck = Fight.where(battle_map_generating: true).all
        stuck.each do |fight|
          fight.complete_battle_map_generation!
          warn "[Startup] Cleared stuck battle_map_generating on fight ##{fight.id}"
        end
      rescue StandardError => e
        warn "[Startup] Error cleaning up stuck battle map generation: #{e.message}"
      end

      # On server restart, any player character instances still marked online are stale.
      # WebSocket connections don't survive restarts, but NPC "online" means "on grid"
      # and should be preserved.
      def cleanup_stale_online_sessions!
        return unless defined?(CharacterInstance) && defined?(Character)

        # Only clean up player characters - NPCs use online to track on-grid status
        player_query = CharacterInstance.where(online: true)
                                        .exclude(character_id: Character.where(is_npc: true).select(:id))
        stale = player_query.count
        return if stale.zero?

        player_query.update(
          online: false,
          session_start_at: nil,
          afk: false,
          semiafk: false
        )

        puts "[Startup] Cleaned up #{stale} stale online player session(s) from previous server run"
      rescue StandardError => e
        warn "[Startup] Error cleaning up stale sessions: #{e.message}"
      end

      # Register observe refresh processor - flushes dirty rooms to observers
      def register_observe_refresh_processor!
        Scheduler.on_tick(5) do |_event|
          ObserveRefreshService.flush_dirty_rooms
        rescue StandardError => e
          warn "[Scheduler] Observe refresh failed: #{e.message}"
        end
      end

      # Register stranded character rescue - rescues characters stuck in defunct temporary rooms
      def register_stranded_character_rescue!
        # Run every 60 ticks (~5 minutes)
        Scheduler.on_tick(60) do |_event|
          StrandedCharacterService.rescue_all_stranded!
        rescue StandardError => e
          warn "[Scheduler] Stranded character rescue failed: #{e.message}"
        end
      end

      # Register lighting service idle shutdown check
      # Runs every 10 minutes to shut down the Python lighting service if unused
      # Process jukebox track advancement for tracks without precise scheduling.
      # Primary track advancement uses thread-based precise scheduling (in JukeboxPlaybackService).
      # This fallback catches jukeboxes whose tracks ended without precise scheduling.
      def register_jukebox_processor!
        Scheduler.on_tick(6) do |_event|
          JukeboxPlaybackService.process_due_jukeboxes!
        rescue StandardError => e
          warn "[Scheduler] Jukebox processing failed: #{e.message}"
        end
      end

      def register_lighting_idle_shutdown!
        Scheduler.on_cron({ minutes: [5, 15, 25, 35, 45, 55], hours: [], days: [], weekdays: [] }) do |_event|
          LightingServiceManager.check_idle_shutdown
        rescue StandardError => e
          warn "[Scheduler] Lighting idle shutdown check failed: #{e.message}"
        end
      end

      def stop!
        Scheduler.stop
        LightingServiceManager.stop if defined?(LightingServiceManager)
        @started = false
        puts '[Scheduler] Game scheduler stopped'
      end

      def started?
        @started == true
      end
    end
  end
end

# Auto-start when loaded in server context (not in console/rake tasks)
if defined?(Puma) || ENV['START_SCHEDULER'] == 'true'
  Firefly::SchedulerInitializer.start!
end
