# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldBuilderOrchestratorService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }

  # Mock job tracking
  let(:mock_job) { instance_double(GenerationJob, id: 1) }
  let(:success_result) { { success: true, data: { generated: true } } }

  before do
    # Stub ProgressTrackerService to not actually create jobs, but return the block's result
    allow(ProgressTrackerService).to receive(:with_job) do |**_args, &block|
      result = block.call(mock_job) if block
      { job: mock_job, result: result || success_result }
    end
    allow(ProgressTrackerService).to receive(:create_job).and_return(mock_job)
    allow(ProgressTrackerService).to receive(:spawn_async).and_yield(mock_job)
    allow(ProgressTrackerService).to receive(:start)
    allow(ProgressTrackerService).to receive(:complete)
    allow(ProgressTrackerService).to receive(:fail)
  end

  describe '.generate_item' do
    before do
      allow(Generators::ItemGeneratorService).to receive(:generate).and_return(success_result)
    end

    it 'delegates to ItemGeneratorService' do
      expect(Generators::ItemGeneratorService).to receive(:generate).with(
        hash_including(category: :weapon, setting: :fantasy)
      )
      described_class.generate_item(category: :weapon)
    end

    it 'passes subcategory' do
      expect(Generators::ItemGeneratorService).to receive(:generate).with(
        hash_including(subcategory: 'sword')
      )
      described_class.generate_item(category: :weapon, subcategory: 'sword')
    end

    it 'tracks job with correct step count without image' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 2)
      )
      described_class.generate_item(category: :weapon)
    end

    it 'tracks job with extra step for image generation' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 3)
      )
      described_class.generate_item(category: :weapon, generate_image: true)
    end

    it 'passes setting' do
      expect(Generators::ItemGeneratorService).to receive(:generate).with(
        hash_including(setting: :scifi)
      )
      described_class.generate_item(category: :weapon, setting: :scifi)
    end

    it 'returns job and result' do
      result = described_class.generate_item(category: :clothing)
      expect(result[:job]).to eq(mock_job)
      expect(result[:result][:success]).to be true
    end
  end

  describe '.generate_npc' do
    before do
      allow(Generators::NPCGeneratorService).to receive(:generate).and_return(success_result)
    end

    it 'delegates to NPCGeneratorService' do
      expect(Generators::NPCGeneratorService).to receive(:generate).with(
        hash_including(location: location, role: 'guard')
      )
      described_class.generate_npc(location: location, role: 'guard')
    end

    it 'passes gender and culture' do
      expect(Generators::NPCGeneratorService).to receive(:generate).with(
        hash_including(gender: :female, culture: :eastern)
      )
      described_class.generate_npc(location: location, gender: :female, culture: :eastern)
    end

    it 'calculates step count with portrait' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 3)
      )
      described_class.generate_npc(location: location, generate_portrait: true)
    end

    it 'calculates step count with schedule' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 3)
      )
      described_class.generate_npc(location: location, generate_schedule: true)
    end

    it 'calculates step count with both portrait and schedule' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 4)
      )
      described_class.generate_npc(location: location, generate_portrait: true, generate_schedule: true)
    end
  end

  describe '.generate_room' do
    before do
      allow(Generators::RoomGeneratorService).to receive(:generate).and_return(success_result)
    end

    it 'delegates to RoomGeneratorService' do
      expect(Generators::RoomGeneratorService).to receive(:generate).with(
        hash_including(parent: location, room_type: 'tavern')
      )
      described_class.generate_room(parent: location, room_type: 'tavern')
    end

    it 'passes name and setting' do
      expect(Generators::RoomGeneratorService).to receive(:generate).with(
        hash_including(name: 'The Blue Dragon', setting: :fantasy)
      )
      described_class.generate_room(parent: location, room_type: 'tavern', name: 'The Blue Dragon')
    end

    it 'calculates step count without background' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 2)
      )
      described_class.generate_room(parent: location, room_type: 'tavern')
    end

    it 'calculates step count with background' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 3)
      )
      described_class.generate_room(parent: location, room_type: 'tavern', generate_background: true)
    end
  end

  describe '.generate_seasonal_descriptions' do
    before do
      allow(Generators::RoomGeneratorService).to receive(:generate_seasonal_descriptions).and_return(success_result)
    end

    it 'delegates to RoomGeneratorService' do
      expect(Generators::RoomGeneratorService).to receive(:generate_seasonal_descriptions).with(
        hash_including(room: room, setting: :fantasy)
      )
      described_class.generate_seasonal_descriptions(room: room)
    end

    it 'uses default times and seasons' do
      # Default: 4 times * 4 seasons = 16 variants
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 16)
      )
      described_class.generate_seasonal_descriptions(room: room)
    end

    it 'accepts custom times and seasons' do
      expect(Generators::RoomGeneratorService).to receive(:generate_seasonal_descriptions).with(
        hash_including(times: [:morning], seasons: [:summer])
      )
      described_class.generate_seasonal_descriptions(room: room, times: [:morning], seasons: [:summer])
    end
  end

  describe '.generate_place' do
    before do
      allow(Generators::PlaceGeneratorService).to receive(:generate).and_return(success_result)
    end

    it 'delegates to PlaceGeneratorService' do
      expect(Generators::PlaceGeneratorService).to receive(:generate).with(
        hash_including(place_type: :tavern, setting: :fantasy)
      )
      described_class.generate_place(place_type: :tavern)
    end

    it 'passes location' do
      expect(Generators::PlaceGeneratorService).to receive(:generate).with(
        hash_including(location: location)
      )
      described_class.generate_place(location: location, place_type: :shop)
    end

    it 'passes coordinates' do
      expect(Generators::PlaceGeneratorService).to receive(:generate).with(
        hash_including(longitude: -73.5, latitude: 40.7)
      )
      described_class.generate_place(longitude: -73.5, latitude: 40.7, place_type: :tavern)
    end

    it 'calculates base steps' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 5)  # 2 base + 3 for rooms
      )
      described_class.generate_place(place_type: :tavern, generate_rooms: true)
    end

    it 'adds steps for NPCs' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 8)  # 2 base + 3 rooms + 3 npcs
      )
      described_class.generate_place(place_type: :tavern, generate_rooms: true, generate_npcs: true)
    end

    it 'adds steps for inventory' do
      expect(ProgressTrackerService).to receive(:with_job).with(
        hash_including(total_steps: 7)  # 2 base + 3 rooms + 2 inventory
      )
      described_class.generate_place(place_type: :shop, generate_rooms: true, generate_inventory: true)
    end
  end

  describe '.generate_city' do
    before do
      allow(Generators::CityGeneratorService).to receive(:generate).and_return(success_result)
    end

    it 'creates a background job' do
      expect(ProgressTrackerService).to receive(:create_job).with(
        hash_including(type: :city)
      )
      described_class.generate_city(location: location)
    end

    it 'spawns async processing' do
      expect(ProgressTrackerService).to receive(:spawn_async)
      described_class.generate_city(location: location)
    end

    it 'delegates to CityGeneratorService' do
      expect(Generators::CityGeneratorService).to receive(:generate).with(
        hash_including(location: location, size: :medium)
      )
      described_class.generate_city(location: location)
    end

    it 'passes coordinates for new location' do
      expect(Generators::CityGeneratorService).to receive(:generate).with(
        hash_including(longitude: -73.5, latitude: 40.7)
      )
      described_class.generate_city(longitude: -73.5, latitude: 40.7)
    end

    it 'passes generation options' do
      expect(Generators::CityGeneratorService).to receive(:generate).with(
        hash_including(generate_places: true, generate_npcs: true)
      )
      described_class.generate_city(location: location, generate_places: true, generate_npcs: true)
    end

    it 'completes job on success' do
      expect(ProgressTrackerService).to receive(:complete)
      described_class.generate_city(location: location)
    end

    context 'when generation fails' do
      before do
        allow(Generators::CityGeneratorService).to receive(:generate).and_return({
          success: false,
          errors: ['Generation failed']
        })
      end

      it 'fails job on error' do
        expect(ProgressTrackerService).to receive(:fail).with(
          hash_including(error: 'Generation failed')
        )
        described_class.generate_city(location: location)
      end
    end

    it 'returns the job' do
      result = described_class.generate_city(location: location)
      expect(result).to eq(mock_job)
    end
  end

  describe '.populate_room' do
    let(:building_room) { create(:room, location: location, building_type: 'shop', room_type: 'building') }

    it 'returns a basic payload when optional generation is disabled' do
      result = described_class.populate_room(room: building_room, include_npcs: false, include_items: false)

      expect(result[:success]).to be true
      expect(result[:room_id]).to eq(building_room.id)
      expect(result[:npcs]).to eq([])
      expect(result[:items]).to eq([])
    end

    it 'delegates npc and inventory generation when enabled' do
      allow(Generators::PlaceGeneratorService).to receive(:generate_place_npcs).and_return({
        npcs: [{ role: 'shopkeeper', name: 'Iris Vale', character: double(id: 10), instance: double(id: 20) }],
        errors: []
      })
      allow(Generators::PlaceGeneratorService).to receive(:generate_shop_inventory).and_return({
        shop: double(id: 30, name: 'Vale General'),
        items: [{ pattern_id: 1, price: 10, stock: 3 }],
        errors: []
      })

      result = described_class.populate_room(room: building_room, include_npcs: true, include_items: true)

      expect(Generators::PlaceGeneratorService).to have_received(:generate_place_npcs)
      expect(Generators::PlaceGeneratorService).to have_received(:generate_shop_inventory)
      expect(result[:success]).to be true
      expect(result[:npcs].first[:name]).to eq('Iris Vale')
      expect(result[:items].first[:pattern_id]).to eq(1)
    end

    it 'infers :inn place_type for hotel buildings' do
      hotel_room = create(:room, location: location, building_type: 'hotel', room_type: 'building')
      allow(Generators::PlaceGeneratorService).to receive(:generate_place_npcs).and_return({
        npcs: [],
        errors: []
      })

      described_class.populate_room(room: hotel_room, include_npcs: true, include_items: false)

      expect(Generators::PlaceGeneratorService).to have_received(:generate_place_npcs).with(
        hash_including(place_type: :inn)
      )
    end

    it 'infers :guild_hall place_type for office_tower buildings' do
      office_room = create(:room, location: location, building_type: 'office_tower', room_type: 'building')
      allow(Generators::PlaceGeneratorService).to receive(:generate_place_npcs).and_return({
        npcs: [],
        errors: []
      })

      described_class.populate_room(room: office_room, include_npcs: true, include_items: false)

      expect(Generators::PlaceGeneratorService).to have_received(:generate_place_npcs).with(
        hash_including(place_type: :guild_hall)
      )
    end
  end

  describe '.generate_description' do
    context 'for Room' do
      before do
        allow(Generators::RoomGeneratorService).to receive(:generate_description).and_return(success_result)
      end

      it 'delegates to RoomGeneratorService' do
        expect(Generators::RoomGeneratorService).to receive(:generate_description).with(
          hash_including(room: room, setting: :fantasy)
        )
        described_class.generate_description(target: room)
      end
    end

    context 'for Character' do
      let(:npc) { create(:character) }

      before do
        allow(Generators::NPCGeneratorService).to receive(:generate_description).and_return(success_result)
      end

      it 'delegates to NPCGeneratorService' do
        expect(Generators::NPCGeneratorService).to receive(:generate_description).with(
          hash_including(character: npc)
        )
        described_class.generate_description(target: npc)
      end
    end

    context 'for Pattern' do
      let(:pattern) { create(:pattern) }

      before do
        allow(Generators::ItemGeneratorService).to receive(:generate_description).and_return(success_result)
      end

      it 'delegates to ItemGeneratorService' do
        expect(Generators::ItemGeneratorService).to receive(:generate_description).with(
          hash_including(pattern: pattern)
        )
        described_class.generate_description(target: pattern)
      end
    end

    context 'for unsupported type' do
      # Create a class with a proper name for the test
      let(:unsupported_class) do
        Class.new do
          def self.name
            'UnsupportedType'
          end
        end
      end

      let(:unsupported_target) do
        obj = unsupported_class.new
        allow(obj).to receive(:id).and_return(999)
        obj
      end

      it 'returns error' do
        result = described_class.generate_description(target: unsupported_target)
        expect(result[:result][:success]).to be false
        expect(result[:result][:error]).to include('Unsupported')
      end
    end
  end

  describe '.generate_image' do
    context 'for Room' do
      before do
        allow(Generators::RoomGeneratorService).to receive(:generate_background).and_return(success_result)
        allow(Generators::RoomGeneratorService).to receive(:generate_location_background).and_return({
          success: true, url: 'https://example.com/area.png'
        })
      end

      it 'calls generate_background with room: kwarg' do
        expect(Generators::RoomGeneratorService).to receive(:generate_background).with(
          hash_including(room: room)
        )
        described_class.generate_image(target: room)
      end

      it 'does not pass description: to generate_background' do
        expect(Generators::RoomGeneratorService).to receive(:generate_background) do |kwargs|
          expect(kwargs).not_to have_key(:description)
          { success: true }
        end
        described_class.generate_image(target: room)
      end

      it 'passes setting through options' do
        expect(Generators::RoomGeneratorService).to receive(:generate_background).with(
          hash_including(options: hash_including(setting: :modern))
        )
        described_class.generate_image(target: room, setting: :modern)
      end
    end

    context 'for Location' do
      before do
        allow(Generators::RoomGeneratorService).to receive(:generate_background).and_return(success_result)
        allow(Generators::RoomGeneratorService).to receive(:generate_location_background).and_return({
          success: true, url: 'https://example.com/area.png'
        })
      end

      it 'calls generate_location_background with location: kwarg' do
        expect(Generators::RoomGeneratorService).to receive(:generate_location_background).with(
          hash_including(location: location)
        )
        described_class.generate_image(target: location)
      end
    end

    context 'for Character' do
      let(:npc) { create(:character) }

      before do
        allow(Generators::NPCGeneratorService).to receive(:generate_portrait).and_return(success_result)
      end

      it 'delegates to NPCGeneratorService' do
        expect(Generators::NPCGeneratorService).to receive(:generate_portrait).with(
          hash_including(character: npc)
        )
        described_class.generate_image(target: npc)
      end
    end

    context 'for Pattern' do
      let(:pattern) { create(:pattern) }

      before do
        allow(Generators::ItemGeneratorService).to receive(:generate_image).and_return(success_result)
      end

      it 'delegates to ItemGeneratorService' do
        expect(Generators::ItemGeneratorService).to receive(:generate_image)
        described_class.generate_image(target: pattern)
      end
    end

    context 'for unsupported type' do
      # Create a class with a proper name for the test
      let(:unsupported_class) do
        Class.new do
          def self.name
            'UnsupportedType'
          end
        end
      end

      let(:unsupported_target) do
        obj = unsupported_class.new
        allow(obj).to receive(:id).and_return(999)
        obj
      end

      it 'returns error' do
        result = described_class.generate_image(target: unsupported_target)
        expect(result[:result][:success]).to be false
        expect(result[:result][:error]).to include('Unsupported')
      end
    end
  end

  describe '.available?' do
    it 'delegates to GenerationPipelineService' do
      allow(GenerationPipelineService).to receive(:available?).and_return(true)
      expect(described_class.available?).to be true
    end

    it 'returns false when unavailable' do
      allow(GenerationPipelineService).to receive(:available?).and_return(false)
      expect(described_class.available?).to be false
    end
  end

  describe '.active_jobs_for' do
    it 'delegates to ProgressTrackerService' do
      expect(ProgressTrackerService).to receive(:active_jobs_for).with(character)
      described_class.active_jobs_for(character)
    end
  end

  describe '.recent_jobs_for' do
    it 'delegates to ProgressTrackerService' do
      expect(ProgressTrackerService).to receive(:recent_jobs_for).with(character, limit: 20)
      described_class.recent_jobs_for(character)
    end

    it 'passes custom limit' do
      expect(ProgressTrackerService).to receive(:recent_jobs_for).with(character, limit: 10)
      described_class.recent_jobs_for(character, limit: 10)
    end
  end

  describe '.job_status' do
    let(:generation_job) { double('GenerationJob', id: 1) }

    before do
      allow(GenerationJob).to receive(:[]).with(1).and_return(generation_job)
      allow(GenerationJob).to receive(:[]).with(999999).and_return(nil)
      allow(ProgressTrackerService).to receive(:progress).and_return({ status: 'processing' })
    end

    it 'returns job status' do
      result = described_class.job_status(1)
      expect(result[:status]).to eq('processing')
    end

    it 'returns nil for non-existent job' do
      result = described_class.job_status(999999)
      expect(result).to be_nil
    end
  end

  describe '.job_status_for' do
    let(:owner) { create(:character) }
    let(:other) { create(:character) }
    let(:generation_job) { double('GenerationJob', id: 1, created_by_id: owner.id) }

    before do
      allow(GenerationJob).to receive(:[]).with(1).and_return(generation_job)
      allow(GenerationJob).to receive(:[]).with(999999).and_return(nil)
      allow(ProgressTrackerService).to receive(:progress).and_return({ status: 'running' })
      allow(owner).to receive(:admin?).and_return(false)
      allow(other).to receive(:admin?).and_return(false)
    end

    it 'returns status for owner' do
      result = described_class.job_status_for(1, owner)
      expect(result[:status]).to eq('running')
    end

    it 'returns nil for unauthorized character' do
      result = described_class.job_status_for(1, other)
      expect(result).to be_nil
    end

    it 'returns status for admin character' do
      admin = create(:character)
      allow(admin).to receive(:admin?).and_return(true)
      result = described_class.job_status_for(1, admin)
      expect(result[:status]).to eq('running')
    end

    it 'returns nil for missing job' do
      result = described_class.job_status_for(999999, owner)
      expect(result).to be_nil
    end
  end

  describe '.cancel_job' do
    let(:generation_job) do
      double('GenerationJob', id: 1, created_by_id: character.id)
    end

    before do
      allow(GenerationJob).to receive(:[]).with(1).and_return(generation_job)
      allow(GenerationJob).to receive(:[]).with(999999).and_return(nil)
      allow(ProgressTrackerService).to receive(:cancel)
    end

    it 'cancels job for creator' do
      expect(ProgressTrackerService).to receive(:cancel)
      result = described_class.cancel_job(1, character)
      expect(result).to be true
    end

    it 'cancels job for admin' do
      admin = create(:character)
      allow(admin).to receive(:admin?).and_return(true)
      expect(ProgressTrackerService).to receive(:cancel)
      result = described_class.cancel_job(1, admin)
      expect(result).to be true
    end

    it 'returns false for non-creator/non-admin' do
      other = create(:character)
      allow(other).to receive(:admin?).and_return(false)
      result = described_class.cancel_job(1, other)
      expect(result).to be false
    end

    it 'returns false for non-existent job' do
      result = described_class.cancel_job(999999, character)
      expect(result).to be false
    end
  end
end
