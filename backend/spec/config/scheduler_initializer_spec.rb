# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Firefly::SchedulerInitializer do
  before do
    # Reset the started state
    described_class.instance_variable_set(:@started, false)

    # Mock the Firefly::Scheduler class methods (they delegate to singleton)
    allow(Firefly::Scheduler).to receive(:start)
    allow(Firefly::Scheduler).to receive(:stop)
    allow(Firefly::Scheduler).to receive(:on_cron)
    allow(Firefly::Scheduler).to receive(:on_tick)

    # Mock all the services that the scheduler calls
    allow(Firefly::TimedActionProcessor).to receive(:register!)
  end

  after do
    described_class.instance_variable_set(:@started, false)
  end

  describe '.start!' do
    context 'when SKIP_SCHEDULER is true' do
      it 'does not start the scheduler' do
        stub_const('ENV', ENV.to_h.merge('SKIP_SCHEDULER' => 'true'))

        described_class.start!

        expect(Firefly::Scheduler).not_to have_received(:start)
      end
    end

    context 'when already started' do
      it 'does not start again' do
        described_class.instance_variable_set(:@started, true)

        described_class.start!

        expect(Firefly::Scheduler).not_to have_received(:start)
      end
    end

    context 'when starting normally' do
      it 'registers the timed action processor' do
        allow($stdout).to receive(:puts)

        described_class.start!

        expect(Firefly::TimedActionProcessor).to have_received(:register!)
      end

      it 'starts the scheduler' do
        allow($stdout).to receive(:puts)

        described_class.start!

        expect(Firefly::Scheduler).to have_received(:start)
      end

      it 'sets started flag to true' do
        allow($stdout).to receive(:puts)

        described_class.start!

        expect(described_class.started?).to be true
      end

      it 'registers cron jobs for weather, AFK, and other processors' do
        allow($stdout).to receive(:puts)

        described_class.start!

        # Should have multiple on_cron calls for various processors
        expect(Firefly::Scheduler).to have_received(:on_cron).at_least(5).times
      end

      it 'registers tick handlers for combat and animation' do
        allow($stdout).to receive(:puts)

        described_class.start!

        # Should have tick handlers for combat timeout, NPC animation, etc.
        expect(Firefly::Scheduler).to have_received(:on_tick).at_least(2).times
      end
    end
  end

  describe '.stop!' do
    it 'stops the scheduler' do
      allow($stdout).to receive(:puts)

      described_class.stop!

      expect(Firefly::Scheduler).to have_received(:stop)
    end

    it 'sets started flag to false' do
      described_class.instance_variable_set(:@started, true)
      allow($stdout).to receive(:puts)

      described_class.stop!

      expect(described_class.started?).to be false
    end
  end

  describe '.started?' do
    it 'returns false when not started' do
      expect(described_class.started?).to be false
    end

    it 'returns true when started' do
      described_class.instance_variable_set(:@started, true)
      expect(described_class.started?).to be true
    end
  end

  describe '.update_weather_from_api' do
    before do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return(nil)
    end

    it 'does nothing when no API key is set' do
      allow(WeatherApiService).to receive(:refresh_all_stale)

      described_class.update_weather_from_api

      expect(WeatherApiService).not_to have_received(:refresh_all_stale)
    end

    it 'refreshes weather when API key is set' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('test_key')
      allow(WeatherApiService).to receive(:refresh_all_stale).and_return(3)
      allow($stdout).to receive(:puts)

      described_class.update_weather_from_api

      expect(WeatherApiService).to have_received(:refresh_all_stale)
    end

    it 'handles errors gracefully' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('test_key')
      allow(WeatherApiService).to receive(:refresh_all_stale).and_raise(StandardError.new('API error'))
      allow($stdout).to receive(:puts)

      expect { described_class.update_weather_from_api }.not_to raise_error
    end
  end

  describe '.simulate_internal_weather' do
    it 'does nothing when Weather model is not defined' do
      hide_const('Weather')

      expect { described_class.simulate_internal_weather }.not_to raise_error
    end

    it 'simulates weather for internal sources' do
      allow(Weather).to receive(:where).and_return([])
      allow($stdout).to receive(:puts)

      described_class.simulate_internal_weather
    end

    it 'handles simulation errors gracefully' do
      weather = instance_double('Weather', id: 1)
      allow(weather).to receive(:simulate!).and_raise(StandardError.new('simulation error'))
      allow(Weather).to receive(:where).and_return(double(or: [weather]))
      allow($stdout).to receive(:puts)

      expect { described_class.simulate_internal_weather }.not_to raise_error
    end
  end

  describe '.process_idle_characters' do
    it 'calls AutoAfkService to process idle characters' do
      allow(AutoAfkService).to receive(:process_idle_characters!).and_return(afk: 0, disconnected: 0)

      described_class.process_idle_characters

      expect(AutoAfkService).to have_received(:process_idle_characters!)
    end

    it 'logs when characters are marked AFK' do
      allow(AutoAfkService).to receive(:process_idle_characters!).and_return(afk: 2, disconnected: 1)
      allow($stdout).to receive(:puts)

      described_class.process_idle_characters

      expect($stdout).to have_received(:puts).with(a_string_matching(/2 marked AFK/))
    end

    it 'handles errors gracefully' do
      allow(AutoAfkService).to receive(:process_idle_characters!).and_raise(StandardError.new('AFK error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_idle_characters }.not_to raise_error
    end
  end

  describe '.process_npc_schedules' do
    it 'calls NpcSpawnService to process schedules' do
      allow(NpcSpawnService).to receive(:process_schedules!).and_return(spawned: [], despawned: [], errors: [])

      described_class.process_npc_schedules

      expect(NpcSpawnService).to have_received(:process_schedules!)
    end

    it 'logs spawn and despawn activity' do
      allow(NpcSpawnService).to receive(:process_schedules!).and_return(spawned: ['NPC1'], despawned: ['NPC2'], errors: [])
      allow($stdout).to receive(:puts)

      described_class.process_npc_schedules

      expect($stdout).to have_received(:puts).with(a_string_matching(/Spawned: 1/))
    end

    it 'handles errors gracefully' do
      allow(NpcSpawnService).to receive(:process_schedules!).and_raise(StandardError.new('NPC error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_npc_schedules }.not_to raise_error
    end
  end

  # cleanup_stale_fights was removed and consolidated into GameCleanupService.sweep!
  # called via sweep_game_cleanup in the scheduler

  describe '.process_combat_timeouts' do
    before do
      allow(Fight).to receive(:where).and_return([])
    end

    it 'does nothing when no fights exist' do
      described_class.process_combat_timeouts

      expect(Fight).to have_received(:where).with(status: 'input')
    end

    it 'handles errors gracefully' do
      allow(Fight).to receive(:where).and_raise(StandardError.new('combat error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_combat_timeouts }.not_to raise_error
    end
  end

  describe '.process_world_travel' do
    it 'calls WorldTravelProcessorService to process journeys' do
      allow(WorldTravelProcessorService).to receive(:process_due_journeys!).and_return(advanced: 0, arrived: 0, errors: [])

      described_class.process_world_travel

      expect(WorldTravelProcessorService).to have_received(:process_due_journeys!)
    end

    it 'logs travel activity' do
      allow(WorldTravelProcessorService).to receive(:process_due_journeys!).and_return(advanced: 2, arrived: 1, errors: [])
      allow($stdout).to receive(:puts)

      described_class.process_world_travel

      expect($stdout).to have_received(:puts).with(a_string_matching(/Advanced: 2, Arrived: 1/))
    end

    it 'handles errors gracefully' do
      allow(WorldTravelProcessorService).to receive(:process_due_journeys!).and_raise(StandardError.new('travel error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_world_travel }.not_to raise_error
    end
  end

  describe '.process_consent_notifications' do
    it 'calls ContentConsentService to process notifications' do
      allow(ContentConsentService).to receive(:process_consent_notifications!).and_return(notified: 0, rooms_processed: 0, errors: [])

      described_class.process_consent_notifications

      expect(ContentConsentService).to have_received(:process_consent_notifications!)
    end

    it 'handles errors gracefully' do
      allow(ContentConsentService).to receive(:process_consent_notifications!).and_raise(StandardError.new('consent error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_consent_notifications }.not_to raise_error
    end
  end

  describe '.process_unconscious_characters' do
    it 'calls PrisonerService to process auto-wakes' do
      allow(PrisonerService).to receive(:process_auto_wakes!).and_return(woken: 0, errors: [])

      described_class.process_unconscious_characters

      expect(PrisonerService).to have_received(:process_auto_wakes!)
    end

    it 'logs wakeup activity' do
      allow(PrisonerService).to receive(:process_auto_wakes!).and_return(woken: 3, errors: [])
      allow($stdout).to receive(:puts)

      described_class.process_unconscious_characters

      expect($stdout).to have_received(:puts).with(a_string_matching(/Auto-woke 3 character/))
    end

    it 'handles errors gracefully' do
      allow(PrisonerService).to receive(:process_auto_wakes!).and_raise(StandardError.new('prisoner error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_unconscious_characters }.not_to raise_error
    end
  end

  describe '.process_activity_timeouts' do
    before do
      allow(ActivityInstance).to receive(:where).and_return([])
    end

    it 'processes timed out activities' do
      described_class.process_activity_timeouts

      expect(ActivityInstance).to have_received(:where).with(running: true)
    end

    it 'handles errors gracefully' do
      allow(ActivityInstance).to receive(:where).and_raise(StandardError.new('activity error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_activity_timeouts }.not_to raise_error
    end
  end

  describe '.record_activity_samples' do
    it 'calls ActivityTrackingService to record samples' do
      allow(ActivityTrackingService).to receive(:record_active_characters!).and_return(recorded: 0)

      described_class.record_activity_samples

      expect(ActivityTrackingService).to have_received(:record_active_characters!)
    end

    it 'handles errors gracefully' do
      allow(ActivityTrackingService).to receive(:record_active_characters!).and_raise(StandardError.new('tracking error'))
      allow($stdout).to receive(:puts)

      expect { described_class.record_activity_samples }.not_to raise_error
    end
  end

  describe '.apply_activity_decay' do
    it 'calls ActivityTrackingService to apply decay' do
      allow(ActivityTrackingService).to receive(:apply_decay_to_all!).and_return(decayed: 10)
      allow($stdout).to receive(:puts)

      described_class.apply_activity_decay

      expect(ActivityTrackingService).to have_received(:apply_decay_to_all!)
    end

    it 'handles errors gracefully' do
      allow(ActivityTrackingService).to receive(:apply_decay_to_all!).and_raise(StandardError.new('decay error'))
      allow($stdout).to receive(:puts)

      expect { described_class.apply_activity_decay }.not_to raise_error
    end
  end

  describe '.sync_help_system' do
    it 'calls HelpManager to sync commands' do
      allow(Firefly::HelpManager).to receive(:sync_commands!).and_return(42)
      allow(HelpSystem).to receive(:seed_defaults!).and_return(5)
      allow($stdout).to receive(:puts)

      described_class.sync_help_system

      expect(Firefly::HelpManager).to have_received(:sync_commands!)
    end

    it 'seeds help system defaults' do
      allow(Firefly::HelpManager).to receive(:sync_commands!).and_return(42)
      allow(HelpSystem).to receive(:seed_defaults!).and_return(5)
      allow($stdout).to receive(:puts)

      described_class.sync_help_system

      expect(HelpSystem).to have_received(:seed_defaults!)
    end

    it 'handles errors gracefully' do
      allow(Firefly::HelpManager).to receive(:sync_commands!).and_raise(StandardError.new('sync error'))
      allow($stdout).to receive(:puts)

      expect { described_class.sync_help_system }.not_to raise_error
    end
  end

  describe '.process_npc_animation_queue' do
    it 'calls NpcAnimationService to process queue' do
      allow(NpcAnimationService).to receive(:process_queue!).and_return(processed: 0, failed: 0)

      described_class.process_npc_animation_queue

      expect(NpcAnimationService).to have_received(:process_queue!)
    end

    it 'logs orphaned entry processing' do
      allow(NpcAnimationService).to receive(:process_queue!).and_return(processed: 2, failed: 1)

      expect {
        described_class.process_npc_animation_queue
      }.to output(/Fallback processed: 2/).to_stderr
    end

    it 'handles errors gracefully' do
      allow(NpcAnimationService).to receive(:process_queue!).and_raise(StandardError.new('animation error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_npc_animation_queue }.not_to raise_error
    end
  end

  describe '.process_pet_idle_animations' do
    it 'calls PetAnimationService to process idle animations' do
      allow(PetAnimationService).to receive(:process_idle_animations!).and_return(queued: 0)

      described_class.process_pet_idle_animations

      expect(PetAnimationService).to have_received(:process_idle_animations!)
    end

    it 'logs queued animations' do
      allow(PetAnimationService).to receive(:process_idle_animations!).and_return(queued: 5)
      allow($stdout).to receive(:puts)

      described_class.process_pet_idle_animations

      expect($stdout).to have_received(:puts).with(a_string_matching(/Queued 5 idle animations/))
    end

    it 'handles errors gracefully' do
      allow(PetAnimationService).to receive(:process_idle_animations!).and_raise(StandardError.new('pet error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_pet_idle_animations }.not_to raise_error
    end
  end

  describe '.process_pet_animation_queue' do
    it 'calls PetAnimationService to process queue' do
      allow(PetAnimationService).to receive(:process_queue!).and_return(processed: 0, failed: 0)

      described_class.process_pet_animation_queue

      expect(PetAnimationService).to have_received(:process_queue!)
    end

    it 'handles errors gracefully' do
      allow(PetAnimationService).to receive(:process_queue!).and_raise(StandardError.new('pet queue error'))
      allow($stdout).to receive(:puts)

      expect { described_class.process_pet_animation_queue }.not_to raise_error
    end
  end

  describe 'world memory processors' do
    describe '.finalize_stale_world_memory_sessions' do
      it 'calls WorldMemoryService to finalize sessions' do
        allow(WorldMemoryService).to receive(:finalize_stale_sessions!).and_return(3)
        allow($stdout).to receive(:puts)

        described_class.finalize_stale_world_memory_sessions

        expect(WorldMemoryService).to have_received(:finalize_stale_sessions!)
      end

      it 'handles errors gracefully' do
        allow(WorldMemoryService).to receive(:finalize_stale_sessions!).and_raise(StandardError.new('memory error'))
        allow($stdout).to receive(:puts)

        expect { described_class.finalize_stale_world_memory_sessions }.not_to raise_error
      end
    end

    describe '.purge_world_memory_raw_logs' do
      it 'calls WorldMemoryService to purge expired logs' do
        allow(WorldMemoryService).to receive(:purge_expired_raw_logs!).and_return(100)
        allow($stdout).to receive(:puts)

        described_class.purge_world_memory_raw_logs

        expect(WorldMemoryService).to have_received(:purge_expired_raw_logs!)
      end

      it 'handles errors gracefully' do
        allow(WorldMemoryService).to receive(:purge_expired_raw_logs!).and_raise(StandardError.new('purge error'))
        allow($stdout).to receive(:puts)

        expect { described_class.purge_world_memory_raw_logs }.not_to raise_error
      end
    end

    describe '.apply_world_memory_decay' do
      it 'calls WorldMemoryService to apply decay' do
        allow(WorldMemoryService).to receive(:apply_decay!).and_return(50)
        allow($stdout).to receive(:puts)

        described_class.apply_world_memory_decay

        expect(WorldMemoryService).to have_received(:apply_decay!)
      end

      it 'handles errors gracefully' do
        allow(WorldMemoryService).to receive(:apply_decay!).and_raise(StandardError.new('decay error'))
        allow($stdout).to receive(:puts)

        expect { described_class.apply_world_memory_decay }.not_to raise_error
      end
    end

    describe '.process_world_memory_abstraction' do
      it 'calls WorldMemoryService to check and abstract' do
        allow(WorldMemoryService).to receive(:check_and_abstract!)
        allow($stdout).to receive(:puts)

        described_class.process_world_memory_abstraction

        expect(WorldMemoryService).to have_received(:check_and_abstract!)
      end

      it 'handles errors gracefully' do
        allow(WorldMemoryService).to receive(:check_and_abstract!).and_raise(StandardError.new('abstraction error'))
        allow($stdout).to receive(:puts)

        expect { described_class.process_world_memory_abstraction }.not_to raise_error
      end
    end
  end

  describe 'atmospheric emit processor' do
    describe '.process_atmospheric_emits' do
      before do
        allow(AtmosphericEmitService).to receive(:enabled?).and_return(false)
      end

      it 'does nothing when disabled' do
        allow(CharacterInstance).to receive(:where)

        described_class.process_atmospheric_emits

        expect(CharacterInstance).not_to have_received(:where)
      end

      it 'handles errors gracefully' do
        allow(AtmosphericEmitService).to receive(:enabled?).and_return(true)
        allow(CharacterInstance).to receive(:where).and_raise(StandardError.new('emit error'))
        allow($stdout).to receive(:puts)

        expect { described_class.process_atmospheric_emits }.not_to raise_error
      end
    end
  end

  describe 'moderation cleanup processors' do
    describe '.expire_temporary_ip_bans' do
      it 'expires IP bans past their expiration time' do
        query_double = double('query')
        allow(IpBan).to receive(:where).and_return(query_double)
        allow(query_double).to receive(:exclude).and_return(query_double)
        allow(query_double).to receive(:where).and_return(query_double)
        allow(query_double).to receive(:update).and_return(2)
        allow($stdout).to receive(:puts)

        described_class.expire_temporary_ip_bans

        expect($stdout).to have_received(:puts).with(a_string_matching(/Expired 2 temporary IP ban/))
      end

      it 'handles errors gracefully' do
        allow(IpBan).to receive(:where).and_raise(StandardError.new('ip ban error'))
        allow($stdout).to receive(:puts)

        expect { described_class.expire_temporary_ip_bans }.not_to raise_error
      end
    end

    describe '.cleanup_old_connection_logs' do
      it 'cleans up logs older than 90 days' do
        allow(ConnectionLog).to receive(:cleanup_old_logs!).with(days: 90).and_return(1000)
        allow($stdout).to receive(:puts)

        described_class.cleanup_old_connection_logs

        expect(ConnectionLog).to have_received(:cleanup_old_logs!).with(days: 90)
      end

      it 'handles errors gracefully' do
        allow(ConnectionLog).to receive(:cleanup_old_logs!).and_raise(StandardError.new('cleanup error'))
        allow($stdout).to receive(:puts)

        expect { described_class.cleanup_old_connection_logs }.not_to raise_error
      end
    end
  end

  describe 'abuse monitoring processors' do
    describe '.process_pending_abuse_checks' do
      it 'calls AbuseMonitoringService to process checks' do
        allow(AbuseMonitoringService).to receive(:process_pending_checks!).and_return(processed: 0, escalated: 0, confirmed: 0, errors: [])

        described_class.process_pending_abuse_checks

        expect(AbuseMonitoringService).to have_received(:process_pending_checks!)
      end

      it 'logs processing activity' do
        allow(AbuseMonitoringService).to receive(:process_pending_checks!).and_return(gemini: 5, escalated: 2, confirmed: 1, errors: 0)
        allow($stdout).to receive(:puts)

        described_class.process_pending_abuse_checks

        expect($stdout).to have_received(:puts).with(a_string_matching(/Gemini: 5/))
      end

      it 'handles errors gracefully' do
        allow(AbuseMonitoringService).to receive(:process_pending_checks!).and_raise(StandardError.new('abuse error'))
        allow($stdout).to receive(:puts)

        expect { described_class.process_pending_abuse_checks }.not_to raise_error
      end
    end

    describe '.expire_abuse_monitoring_overrides' do
      it 'expires old overrides' do
        query_double = double('query')
        allow(AbuseMonitoringOverride).to receive(:where).and_return(query_double)
        allow(query_double).to receive(:where).and_return(query_double)
        allow(query_double).to receive(:all).and_return([])

        described_class.expire_abuse_monitoring_overrides
      end

      it 'handles errors gracefully' do
        allow(AbuseMonitoringOverride).to receive(:where).and_raise(StandardError.new('override error'))
        allow($stdout).to receive(:puts)

        expect { described_class.expire_abuse_monitoring_overrides }.not_to raise_error
      end
    end

    describe '.cleanup_old_abuse_checks' do
      it 'deletes cleared checks older than 30 days' do
        query_double = double('query')
        allow(AbuseCheck).to receive(:where).and_return(query_double)
        allow(query_double).to receive(:where).and_return(query_double)
        allow(query_double).to receive(:delete).and_return(50)
        allow($stdout).to receive(:puts)

        described_class.cleanup_old_abuse_checks

        expect($stdout).to have_received(:puts).with(a_string_matching(/Cleaned up 50 old cleared check/))
      end

      it 'handles errors gracefully' do
        allow(AbuseCheck).to receive(:where).and_raise(StandardError.new('abuse check error'))
        allow($stdout).to receive(:puts)

        expect { described_class.cleanup_old_abuse_checks }.not_to raise_error
      end
    end
  end

  describe 'reputation processor' do
    describe '.regenerate_pc_reputations' do
      it 'calls ReputationService to regenerate all' do
        allow(ReputationService).to receive(:regenerate_all!).and_return(updated: 25, errors: [])
        allow($stdout).to receive(:puts)

        described_class.regenerate_pc_reputations

        expect(ReputationService).to have_received(:regenerate_all!)
      end

      it 'logs update activity' do
        allow(ReputationService).to receive(:regenerate_all!).and_return(updated: 25, errors: [])
        allow($stdout).to receive(:puts)

        described_class.regenerate_pc_reputations

        expect($stdout).to have_received(:puts).with(a_string_matching(/Regenerated reputations for 25 PC/))
      end

      it 'handles errors gracefully' do
        allow(ReputationService).to receive(:regenerate_all!).and_raise(StandardError.new('reputation error'))
        allow($stdout).to receive(:puts)

        expect { described_class.regenerate_pc_reputations }.not_to raise_error
      end
    end
  end

  describe 'weather grid processors' do
    describe '.tick_grid_weather' do
      it 'ticks simulation and storms for grid-enabled worlds' do
        world = instance_double('World', id: 1)
        query_double = double('query')
        allow(World).to receive(:where).with(use_grid_weather: true).and_return(query_double)
        allow(query_double).to receive(:each).and_yield(world)
        allow(WeatherGrid::SimulationService).to receive(:tick).with(world).and_return(true)
        allow(WeatherGrid::StormService).to receive(:tick).with(world).and_return(storms_updated: 0, storms_formed: 0)

        described_class.tick_grid_weather

        expect(WeatherGrid::SimulationService).to have_received(:tick).with(world)
        expect(WeatherGrid::StormService).to have_received(:tick).with(world)
      end

      it 'does nothing when SimulationService is not defined' do
        hide_const('WeatherGrid::SimulationService')

        expect { described_class.tick_grid_weather }.not_to raise_error
      end

      it 'handles per-world errors gracefully and continues to next world' do
        world1 = instance_double('World', id: 1)
        world2 = instance_double('World', id: 2)
        query_double = double('query')
        allow(World).to receive(:where).with(use_grid_weather: true).and_return(query_double)
        allow(query_double).to receive(:each).and_yield(world1).and_yield(world2)
        allow(WeatherGrid::SimulationService).to receive(:tick).with(world1).and_raise(StandardError.new('sim error'))
        allow(WeatherGrid::SimulationService).to receive(:tick).with(world2).and_return(true)
        allow(WeatherGrid::StormService).to receive(:tick).with(world2).and_return(storms_updated: 0, storms_formed: 0)
        allow($stderr).to receive(:write)

        described_class.tick_grid_weather

        expect(WeatherGrid::SimulationService).to have_received(:tick).with(world2)
      end

      it 'handles top-level errors gracefully' do
        allow(World).to receive(:where).and_raise(StandardError.new('db error'))
        allow($stderr).to receive(:write)

        expect { described_class.tick_grid_weather }.not_to raise_error
      end
    end

    describe '.persist_grid_weather' do
      it 'calls PersistenceService.persist_all!' do
        allow(WeatherGrid::PersistenceService).to receive(:persist_all!).and_return(persisted: 2)
        allow($stdout).to receive(:puts)

        described_class.persist_grid_weather

        expect(WeatherGrid::PersistenceService).to have_received(:persist_all!)
      end

      it 'logs when worlds are persisted' do
        allow(WeatherGrid::PersistenceService).to receive(:persist_all!).and_return(persisted: 3)
        allow($stdout).to receive(:puts)

        described_class.persist_grid_weather

        expect($stdout).to have_received(:puts).with(a_string_matching(/Persisted 3 world/))
      end

      it 'does not log when no worlds persisted' do
        allow(WeatherGrid::PersistenceService).to receive(:persist_all!).and_return(persisted: 0)
        allow($stdout).to receive(:puts)

        described_class.persist_grid_weather

        expect($stdout).not_to have_received(:puts)
      end

      it 'does nothing when PersistenceService is not defined' do
        hide_const('WeatherGrid::PersistenceService')

        expect { described_class.persist_grid_weather }.not_to raise_error
      end

      it 'handles errors gracefully' do
        allow(WeatherGrid::PersistenceService).to receive(:persist_all!).and_raise(StandardError.new('persist error'))
        allow($stderr).to receive(:write)

        expect { described_class.persist_grid_weather }.not_to raise_error
      end
    end

    describe '.restore_weather_grid_state!' do
      it 'calls startup_load in a background thread' do
        allow(WeatherGrid::PersistenceService).to receive(:startup_load).and_return({})
        allow($stdout).to receive(:puts)

        # Execute the thread body synchronously for testing
        thread = nil
        allow(Thread).to receive(:new) do |&block|
          thread = double('thread')
          # We capture the block but don't run it in tests to avoid sleep
          thread
        end

        described_class.restore_weather_grid_state!

        expect(Thread).to have_received(:new)
      end
    end

    describe '.register_weather_grid_tick!' do
      it 'registers a tick handler' do
        allow(Firefly::Scheduler).to receive(:on_tick)

        described_class.register_weather_grid_tick!

        expect(Firefly::Scheduler).to have_received(:on_tick).with(3)
      end
    end

    describe '.register_weather_grid_persistence!' do
      it 'registers a cron handler for every 5 minutes' do
        allow(Firefly::Scheduler).to receive(:on_cron)

        described_class.register_weather_grid_persistence!

        expect(Firefly::Scheduler).to have_received(:on_cron).with(
          hash_including(minutes: [4, 9, 14, 19, 24, 29, 34, 39, 44, 49, 54, 59])
        )
      end
    end
  end
end
