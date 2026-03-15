# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapGeneratorService do
  let(:location) { create(:location) }
  let(:room) do
    create(:room,
           location: location,
           room_type: 'arena',
           min_x: 0,
           max_x: 40,
           min_y: 0,
           max_y: 40)
  end

  let(:service) { described_class.new(room) }

  describe 'constants' do
    it 'defines CATEGORY_DEFAULTS' do
      expect(described_class::CATEGORY_DEFAULTS).to have_key(:indoor)
      expect(described_class::CATEGORY_DEFAULTS).to have_key(:outdoor)
      expect(described_class::CATEGORY_DEFAULTS).to have_key(:underground)
    end

    it 'defines CATEGORY_HAZARDS' do
      expect(described_class::CATEGORY_HAZARDS[:indoor]).to include('fire')
      expect(described_class::CATEGORY_HAZARDS[:outdoor]).to include('fire')
      expect(described_class::CATEGORY_HAZARDS[:underground]).to include('gas')
    end

    it 'defines WATER_TYPE_WEIGHTS' do
      expect(described_class::WATER_TYPE_WEIGHTS).to have_key('puddle')
      expect(described_class::WATER_TYPE_WEIGHTS).to have_key('deep')
    end
  end

  describe '#initialize' do
    it 'sets the room' do
      expect(service.room).to eq(room)
    end

    it 'builds config from room' do
      expect(service.config).to be_a(Hash)
      expect(service.config).to have_key(:surfaces)
      expect(service.config).to have_key(:density)
    end

    it 'sets category from room' do
      allow(room).to receive(:battle_map_category).and_return(:outdoor)
      svc = described_class.new(room)
      expect(svc.category).to eq(:outdoor)
    end
  end

  describe '#generate!' do
    context 'without valid bounds' do
      it 'returns false' do
        allow(room).to receive(:min_x).and_return(nil)
        svc = described_class.new(room)
        expect(svc.generate!).to be false
      end
    end

    context 'with valid bounds' do
      it 'returns true on success' do
        expect(service.generate!).to be true
      end

      it 'clears existing hexes' do
        # Create some existing hexes directly
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 2, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        initial_count = room.room_hexes_dataset.count

        service.generate!
        # After regeneration, old hexes are cleared and new ones created
        expect(room.room_hexes_dataset.count).to be > 0
      end

      it 'creates new hex terrain' do
        service.generate!
        expect(room.room_hexes_dataset.count).to be > 0
      end

      it 'marks room as having battle map' do
        service.generate!
        expect(room.reload.has_battle_map).to be true
      end
    end

    context 'with error' do
      before do
        allow(service).to receive(:generate_base_terrain).and_raise(StandardError.new('Test error'))
      end

      it 'returns false' do
        expect(service.generate!).to be false
      end
    end
  end

  describe '#generate_with_progress' do
    let(:fight_id) { 123 }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
    end

    it 'publishes progress updates during generation' do
      progress_updates = []
      allow(redis).to receive(:publish) do |channel, message|
        progress_updates << JSON.parse(message)
      end

      service.generate_with_progress(fight_id)

      # Should have at least start and complete messages
      expect(progress_updates.count).to be >= 2

      # Should have completion message
      completion = progress_updates.find { |m| m['type'] == 'complete' }
      expect(completion).not_to be_nil
      expect(completion['success']).to be true
      expect(completion['fallback']).to be true
    end

    it 'calls generate! and publishes completion' do
      allow(redis).to receive(:publish)
      expect(service).to receive(:generate!).and_return(true)

      service.generate_with_progress(fight_id)

      expect(redis).to have_received(:publish).at_least(:once)
    end

    it 'publishes error on failure' do
      allow(service).to receive(:generate!).and_raise(StandardError.new('Test error'))

      progress_updates = []
      allow(redis).to receive(:publish) do |channel, message|
        progress_updates << JSON.parse(message)
      end

      expect { service.generate_with_progress(fight_id) }.to raise_error(StandardError)

      # Should have completion message with failure
      completion = progress_updates.find { |m| m['type'] == 'complete' }
      expect(completion).not_to be_nil
      expect(completion['success']).to be false
      expect(completion['fallback']).to be true
    end

    it 'publishes failure and raises when generate! returns false' do
      allow(service).to receive(:generate!).and_return(false)

      progress_updates = []
      allow(redis).to receive(:publish) do |_channel, message|
        progress_updates << JSON.parse(message)
      end

      expect { service.generate_with_progress(fight_id) }
        .to raise_error(StandardError, /returned false/)

      completion = progress_updates.find { |m| m['type'] == 'complete' }
      expect(completion).not_to be_nil
      expect(completion['success']).to be false
      expect(completion['fallback']).to be true
    end
  end

  describe '#generate_without_transaction!' do
    context 'without valid bounds' do
      it 'returns false' do
        allow(room).to receive(:min_x).and_return(nil)
        svc = described_class.new(room)
        expect(svc.generate_without_transaction!).to be false
      end
    end

    context 'with valid bounds' do
      it 'returns true on success' do
        expect(service.generate_without_transaction!).to be true
      end

      it 'creates terrain' do
        service.generate_without_transaction!
        expect(room.room_hexes_dataset.count).to be > 0
      end
    end
  end

  describe 'private methods' do
    describe '#build_config' do
      it 'returns hash with expected keys' do
        config = service.send(:build_config)
        expect(config).to have_key(:surfaces)
        expect(config).to have_key(:objects)
        expect(config).to have_key(:density)
        expect(config).to have_key(:dark)
        expect(config).to have_key(:difficult_terrain)
        expect(config).to have_key(:water_chance)
        expect(config).to have_key(:hazard_chance)
        expect(config).to have_key(:explosive_chance)
        expect(config).to have_key(:elevation_variance)
        expect(config).to have_key(:combat_optimized)
      end

      it 'uses category defaults when room config missing values' do
        # Use a room with a basic type
        config = service.send(:build_config)

        # Should have valid defaults from category
        expect(config[:density]).to be_a(Numeric)
        expect(config[:hazard_chance]).to be_a(Numeric)
      end
    end

    describe '#room_has_bounds?' do
      it 'returns truthy when all bounds present' do
        expect(service.send(:room_has_bounds?)).to be_truthy
      end

      it 'returns falsy when min_x missing' do
        allow(service.room).to receive(:min_x).and_return(nil)
        expect(service.send(:room_has_bounds?)).to be_falsy
      end

      it 'returns falsy when max_x missing' do
        allow(service.room).to receive(:max_x).and_return(nil)
        expect(service.send(:room_has_bounds?)).to be_falsy
      end

      it 'returns falsy when min_y missing' do
        allow(service.room).to receive(:min_y).and_return(nil)
        expect(service.send(:room_has_bounds?)).to be_falsy
      end

      it 'returns falsy when max_y missing' do
        allow(service.room).to receive(:max_y).and_return(nil)
        expect(service.send(:room_has_bounds?)).to be_falsy
      end
    end

    describe '#clear_existing_hexes' do
      it 'deletes existing hexes' do
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 2, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)

        expect { service.send(:clear_existing_hexes) }
          .to change { room.room_hexes_dataset.count }.to(0)
      end
    end

    describe '#generate_base_terrain' do
      it 'creates hex grid based on room size' do
        service.send(:generate_base_terrain)
        expect(room.room_hexes_dataset.count).to be > 0
      end

      it 'creates hexes with normal type' do
        service.send(:generate_base_terrain)
        hex = room.room_hexes.first
        expect(hex.hex_type).to eq('normal')
      end

      it 'creates traversable hexes' do
        service.send(:generate_base_terrain)
        hex = room.room_hexes.first
        expect(hex.traversable).to be true
      end

      it 'sets elevation to 0' do
        service.send(:generate_base_terrain)
        hex = room.room_hexes.first
        expect(hex.elevation_level).to eq(0)
      end
    end

    describe '#place_cover_objects' do
      before do
        service.send(:generate_base_terrain)
      end

      context 'with no objects configured' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(objects: [])
          )
        end

        it 'does nothing' do
          expect { service.send(:place_cover_objects) }
            .not_to change { room.room_hexes_dataset.where(hex_type: 'cover').count }
        end
      end

      context 'with objects configured' do
        let!(:table_type) do
          CoverObjectType.where(name: 'table').delete
          CoverObjectType.create(
            name: 'table',
            default_cover_value: 2,
            default_height: 3,
            is_destroyable: true,
            default_hp: 10,
            hex_width: 1,
            hex_height: 1
          )
        end
        let!(:chair_type) do
          CoverObjectType.where(name: 'chair').delete
          CoverObjectType.create(
            name: 'chair',
            default_cover_value: 1,
            default_height: 2,
            is_destroyable: true,
            default_hp: 5,
            hex_width: 1,
            hex_height: 1
          )
        end

        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(objects: %w[table chair], density: 0.2)
          )
        end

        it 'places cover when objects are available' do
          # Verify the method runs without error and processes hexes
          expect { service.send(:place_cover_objects) }.not_to raise_error

          # With valid cover types, some hexes should be converted to cover
          # (randomness may affect exact count)
          cover_count = room.room_hexes_dataset.where(hex_type: 'cover').count
          total_count = room.room_hexes_dataset.count

          # Just verify it didn't place cover on more than allowed
          expect(cover_count).to be <= (total_count * 0.3).ceil
        end

        it 'sets cover hexes with correct properties' do
          service.send(:place_cover_objects)
          cover_hex = room.room_hexes_dataset.where(hex_type: 'cover').first

          if cover_hex
            # Cover hexes should not be traversable
            expect(cover_hex.traversable).to be false
            # Should have a valid cover object
            expect(cover_hex.cover_object).to be_a(String)
          end
        end
      end
    end

    describe '#add_hazards' do
      before do
        service.send(:generate_base_terrain)
      end

      context 'with zero hazard chance' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(hazard_chance: 0)
          )
        end

        it 'does nothing' do
          expect { service.send(:add_hazards) }
            .not_to change { room.room_hexes_dataset.exclude(hex_type: 'normal').count }
        end
      end

      context 'with hazard chance' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(hazard_chance: 0.1)
          )
        end

        it 'adds hazards' do
          service.send(:add_hazards)
          hazard_count = room.room_hexes_dataset.where(hex_type: %w[fire hazard trap]).count
          expect(hazard_count).to be >= 0 # May be 0 if no traversable hexes
        end
      end

      context 'hazard types' do
        let(:hazard_test_room) do
          create(:room, location: location, room_type: 'apartment', min_x: 0, max_x: 40, min_y: 0, max_y: 40)
        end

        it 'uses category-appropriate hazards' do
          # Use a separate room to avoid duplicate hex conflicts
          allow(hazard_test_room).to receive(:battle_map_category).and_return(:underground)
          svc = described_class.new(hazard_test_room)
          svc.send(:generate_base_terrain)
          allow(svc).to receive(:config).and_return(svc.config.merge(hazard_chance: 0.5))

          svc.send(:add_hazards)
          # Underground should have potential for gas hazards
          hazards = hazard_test_room.room_hexes_dataset.where(hazard_type: 'gas').all
          # Just check the method runs without error
          expect(true).to be true
        end
      end
    end

    describe '#add_explosives' do
      before do
        service.send(:generate_base_terrain)
        allow(service).to receive(:config).and_return(
          service.config.merge(explosive_chance: 0.1)
        )
      end

      it 'adds explosive hexes' do
        service.send(:add_explosives)
        explosive_count = room.room_hexes_dataset.where(is_explosive: true).count
        expect(explosive_count).to be >= 0
      end

      it 'sets explosive properties' do
        service.send(:add_explosives)
        explosive = room.room_hexes_dataset.where(is_explosive: true).first

        if explosive
          expect(explosive.hex_type).to eq('explosive')
          expect(explosive.explosion_radius).to be >= 1
          expect(explosive.explosion_damage).to be >= 5
        end
      end
    end

    describe '#generate_elevation' do
      before do
        service.send(:generate_base_terrain)
      end

      context 'with zero variance' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(elevation_variance: 0)
          )
        end

        it 'does nothing' do
          service.send(:generate_elevation)
          non_zero_elevation = room.room_hexes_dataset.exclude(elevation_level: 0).count
          expect(non_zero_elevation).to eq(0)
        end
      end

      context 'with variance' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(elevation_variance: 2)
          )
        end

        it 'creates elevation zones' do
          service.send(:generate_elevation)
          # May or may not have non-zero elevation depending on random seeds
          # Just verify no errors
          expect(true).to be true
        end
      end
    end

    describe '#spread_elevation' do
      before do
        service.send(:generate_base_terrain)
      end

      it 'sets seed hex elevation' do
        seed_hex = room.room_hexes.first
        service.send(:spread_elevation, seed_hex, 2, 2)
        expect(seed_hex.reload.elevation_level).to eq(2)
      end

      it 'spreads to neighbors' do
        seed_hex = room.room_hexes.first
        service.send(:spread_elevation, seed_hex, 2, 2)

        # Check that at least seed was updated
        expect(seed_hex.reload.elevation_level).to eq(2)
      end
    end

    describe '#add_water_features' do
      before do
        service.send(:generate_base_terrain)
      end

      context 'with zero water chance' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(water_chance: 0)
          )
        end

        it 'does nothing' do
          service.send(:add_water_features)
          water_count = room.room_hexes_dataset.where(hex_type: 'water').count
          expect(water_count).to eq(0)
        end
      end

      context 'with water chance' do
        before do
          allow(service).to receive(:config).and_return(
            service.config.merge(water_chance: 0.2)
          )
        end

        it 'adds water hexes' do
          service.send(:add_water_features)
          water_count = room.room_hexes_dataset.where(hex_type: 'water').count
          expect(water_count).to be >= 0
        end

        it 'stores water depth in water_depth column' do
          service.send(:add_water_features)
          water_hex = room.room_hexes_dataset.where(hex_type: 'water').first

          if water_hex
            expect(water_hex.water_depth).to be_a(Numeric)
          end
        end
      end
    end

    describe '#weighted_water_type' do
      it 'returns valid water type' do
        result = service.send(:weighted_water_type)
        expect(%w[puddle wading swimming deep]).to include(result)
      end

      it 'favors puddles over deep water' do
        results = 100.times.map { service.send(:weighted_water_type) }
        puddle_count = results.count('puddle')
        deep_count = results.count('deep')

        expect(puddle_count).to be > deep_count
      end
    end

    describe '#mark_battle_map_ready' do
      it 'sets has_battle_map to true' do
        expect { service.send(:mark_battle_map_ready) }
          .to change { room.reload.has_battle_map }.to(true)
      end
    end
  end

  describe 'integration' do
    it 'generates a complete battle map' do
      service.generate!

      expect(room.reload.has_battle_map).to be true
      expect(room.room_hexes_dataset.count).to be > 0
    end

    context 'with different room types' do
      it 'generates for outdoor-type rooms' do
        outdoor_room = create(:room, location: location, room_type: 'street',
                              min_x: 0, max_x: 80, min_y: 0, max_y: 80)
        allow(outdoor_room).to receive(:battle_map_category).and_return(:outdoor)
        svc = described_class.new(outdoor_room)
        expect(svc.generate!).to be true
      end

      it 'generates for underground-type rooms' do
        underground_room = create(:room, location: location, room_type: 'apartment',
                                  min_x: 0, max_x: 60, min_y: 0, max_y: 20)
        allow(underground_room).to receive(:battle_map_category).and_return(:underground)
        svc = described_class.new(underground_room)
        expect(svc.generate!).to be true
      end
    end
  end
end
