# frozen_string_literal: true

require 'spec_helper'
require 'sidekiq/testing'

RSpec.describe 'Battle Map Async Generation', type: :integration do
  let(:room) { create(:room, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
  let(:initiator) { create(:character_instance, :not_in_combat, current_room: room) }
  let(:target) { create(:character_instance, :not_in_combat, current_room: room) }
  let(:redis) { double('Redis') }

  before do
    Sidekiq::Testing.inline!
    # Mock Redis pool
    allow(REDIS_POOL).to receive(:with).and_yield(redis)
    allow(redis).to receive(:publish)
    allow(redis).to receive(:del)
    allow(redis).to receive(:get).and_return(nil)
    allow(redis).to receive(:set)
    allow(redis).to receive(:setex)
  end

  after do
    Sidekiq::Testing.fake!
  end

  it 'starts fight with async generation when room needs battle map' do
    # Enable AI battle maps
    GameSetting.set('ai_battle_maps_enabled', 'true')

    # Track Redis messages
    messages = []
    allow(redis).to receive(:publish) do |channel, message|
      messages << { channel: channel, data: JSON.parse(message) }
    end

    allow(FightService).to receive(:push_quickmenus_to_participants)
    allow(FightService).to receive(:revalidate_participant_positions)

    # Mock AI generation to complete successfully
    allow_any_instance_of(AIBattleMapGeneratorService).to receive(:generate_async) do |service, fight|
      service.send(:publish_progress, fight.id, 50, "Generating...")
      service.send(:publish_completion, fight.id, success: true)
    end

    # Start fight
    service = FightService.start_fight(room: room, initiator: initiator, target: target)
    fight = service.fight

    # Should have published progress messages
    progress_messages = messages.select { |m| m[:channel] == "fight:#{fight.id}:generation" }
    expect(progress_messages.count).to be >= 2

    # Should have completion message
    completion = progress_messages.find { |m| m[:data]['type'] == 'complete' }
    expect(completion).not_to be_nil
    expect(completion[:data]['success']).to be true
    expect(completion[:data]['fallback']).to be_falsey

    # Generation flag should be cleared
    expect(fight.reload.battle_map_generating).to be false
  end

  it 'falls back to procedural generation on AI failure' do
    # Enable AI battle maps
    GameSetting.set('ai_battle_maps_enabled', 'true')

    messages = []
    allow(redis).to receive(:publish) do |channel, message|
      messages << { channel: channel, data: JSON.parse(message) }
    end

    allow(FightService).to receive(:push_quickmenus_to_participants)
    allow(FightService).to receive(:revalidate_participant_positions)

    # Make AI generation fail
    allow_any_instance_of(AIBattleMapGeneratorService).to receive(:generate_async) do |_service, _fight|
      raise StandardError.new('API error')
    end

    service = FightService.start_fight(room: room, initiator: initiator, target: target)
    fight = service.fight

    # Error should be caught by FightService rescue block and flag cleared
    expect(fight.reload.battle_map_generating).to be false
  end

  it 'does not generate duplicate maps for same room' do
    # Don't execute the job (keep generation "in progress")
    allow(BattleMapGenerationJob).to receive(:perform_async)

    # First fight triggers generation
    first_service = FightService.start_fight(room: room, initiator: initiator, target: target)
    first_fight = first_service.fight

    expect(first_fight.battle_map_generating).to be true

    # Complete the first fight so second one can be created
    first_fight.update(status: 'complete')

    # Second fight in same room should not trigger generation
    # (generation already in progress)
    second_initiator = create(:character_instance, :not_in_combat, current_room: room)
    second_target = create(:character_instance, :not_in_combat, current_room: room)
    second_service = FightService.start_fight(room: room, initiator: second_initiator, target: second_target)
    second_fight = second_service.fight

    expect(second_fight.battle_map_generating).to be false
  end

  it 'reuses existing battle map without generation' do
    # Don't execute the job
    allow(BattleMapGenerationJob).to receive(:perform_async)

    # Set up room with existing battle map by directly inserting room hexes
    room.update(has_battle_map: true)
    DB[:room_hexes].insert(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal')
    DB[:room_hexes].insert(room_id: room.id, hex_x: 2, hex_y: 0, hex_type: 'normal')
    DB[:room_hexes].insert(room_id: room.id, hex_x: 4, hex_y: 0, hex_type: 'normal')

    # Start fight - should not trigger generation
    service = FightService.start_fight(room: room, initiator: initiator, target: target)
    fight = service.fight

    expect(fight.battle_map_generating).to be false
  end
end
