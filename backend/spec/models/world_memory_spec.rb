# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemory do
  describe 'constants' do
    it 'defines PUBLICITY_LEVELS' do
      expect(described_class::PUBLICITY_LEVELS).to eq(%w[private secluded semi_public public private_event public_event])
    end

    it 'defines SOURCE_TYPES' do
      expect(described_class::SOURCE_TYPES).to eq(%w[session event activity location_recap])
    end
  end

  describe 'GameConfig constants used by WorldMemory' do
    it 'MAX_ABSTRACTION_LEVEL is defined in GameConfig::NpcMemory' do
      expect(GameConfig::NpcMemory::MAX_ABSTRACTION_LEVEL).to eq(4)
    end

    it 'ABSTRACTION_THRESHOLD is defined in GameConfig::NpcMemory' do
      expect(GameConfig::NpcMemory::ABSTRACTION_THRESHOLD).to eq(8)
    end

    it 'RAW_LOG_RETENTION_MONTHS is defined in GameConfig::NpcMemory' do
      expect(GameConfig::NpcMemory::RAW_LOG_RETENTION_MONTHS).to eq(6)
    end
  end

  describe 'associations' do
    it 'has many world_memory_characters' do
      expect(described_class.association_reflections[:world_memory_characters]).not_to be_nil
    end

    it 'has many world_memory_locations' do
      expect(described_class.association_reflections[:world_memory_locations]).not_to be_nil
    end

    it 'belongs to abstracted_into' do
      expect(described_class.association_reflections[:abstracted_into]).not_to be_nil
    end

    it 'belongs to parent_memory' do
      expect(described_class.association_reflections[:parent_memory]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines relevance_score' do
      expect(described_class.instance_methods).to include(:relevance_score)
    end

    it 'defines recent?' do
      expect(described_class.instance_methods).to include(:recent?)
    end

    it 'defines important?' do
      expect(described_class.instance_methods).to include(:important?)
    end

    it 'defines private?' do
      expect(described_class.instance_methods).to include(:private?)
    end

    it 'defines public?' do
      expect(described_class.instance_methods).to include(:public?)
    end

    it 'defines searchable?' do
      expect(described_class.instance_methods).to include(:searchable?)
    end

    it 'defines abstracted?' do
      expect(described_class.instance_methods).to include(:abstracted?)
    end

    it 'defines can_abstract?' do
      expect(described_class.instance_methods).to include(:can_abstract?)
    end

    it 'defines add_character!' do
      expect(described_class.instance_methods).to include(:add_character!)
    end

    it 'defines add_location!' do
      expect(described_class.instance_methods).to include(:add_location!)
    end

    it 'defines primary_room' do
      expect(described_class.instance_methods).to include(:primary_room)
    end
  end

  describe 'class methods' do
    it 'defines unabstracted_at_level' do
      expect(described_class).to respond_to(:unabstracted_at_level)
    end

    it 'defines needs_abstraction?' do
      expect(described_class).to respond_to(:needs_abstraction?)
    end

    it 'defines expired_raw_logs' do
      expect(described_class).to respond_to(:expired_raw_logs)
    end

    it 'defines for_character' do
      expect(described_class).to respond_to(:for_character)
    end

    it 'defines for_room' do
      expect(described_class).to respond_to(:for_room)
    end

    it 'defines searchable' do
      expect(described_class).to respond_to(:searchable)
    end

    it 'defines recent' do
      expect(described_class).to respond_to(:recent)
    end

    it 'defines for_location' do
      expect(described_class).to respond_to(:for_location)
    end
  end

  describe '#private? behavior' do
    it 'returns true for private level' do
      memory = described_class.new
      memory.values[:publicity_level] = 'private'
      expect(memory.private?).to be true
    end

    it 'returns true for private_event level' do
      memory = described_class.new
      memory.values[:publicity_level] = 'private_event'
      expect(memory.private?).to be true
    end

    it 'returns false for public level' do
      memory = described_class.new
      memory.values[:publicity_level] = 'public'
      expect(memory.private?).to be false
    end
  end

  describe '#public? behavior' do
    it 'returns true for public level' do
      memory = described_class.new
      memory.values[:publicity_level] = 'public'
      expect(memory.public?).to be true
    end

    it 'returns true for public_event level' do
      memory = described_class.new
      memory.values[:publicity_level] = 'public_event'
      expect(memory.public?).to be true
    end

    it 'returns false for private level' do
      memory = described_class.new
      memory.values[:publicity_level] = 'private'
      expect(memory.public?).to be false
    end
  end

  describe '#important? behavior' do
    it 'returns true when importance >= 7' do
      memory = described_class.new
      memory.values[:importance] = 8
      expect(memory.important?).to be true
    end

    it 'returns false when importance < 7' do
      memory = described_class.new
      memory.values[:importance] = 5
      expect(memory.important?).to be false
    end

    it 'defaults to false when importance is nil (default 5)' do
      memory = described_class.new
      memory.values[:importance] = nil
      expect(memory.important?).to be false
    end
  end

  describe '#abstracted? behavior' do
    it 'returns true when abstracted_into_id is set' do
      memory = described_class.new
      memory.values[:abstracted_into_id] = 123
      expect(memory.abstracted?).to be true
    end

    it 'returns false when abstracted_into_id is nil' do
      memory = described_class.new
      memory.values[:abstracted_into_id] = nil
      expect(memory.abstracted?).to be false
    end
  end

  describe 'validations' do
    it 'requires summary' do
      memory = described_class.new(started_at: Time.now, ended_at: Time.now)
      expect(memory.valid?).to be false
      expect(memory.errors[:summary]).not_to be_empty
    end

    it 'requires started_at' do
      memory = described_class.new(summary: 'Test', ended_at: Time.now)
      expect(memory.valid?).to be false
      expect(memory.errors[:started_at]).not_to be_empty
    end

    it 'requires ended_at' do
      memory = described_class.new(summary: 'Test', started_at: Time.now)
      expect(memory.valid?).to be false
      expect(memory.errors[:ended_at]).not_to be_empty
    end

    it 'validates publicity_level is in allowed list' do
      memory = described_class.new(
        summary: 'Test',
        started_at: Time.now,
        ended_at: Time.now,
        publicity_level: 'invalid'
      )
      expect(memory.valid?).to be false
    end

    it 'validates source_type is in allowed list' do
      memory = described_class.new(
        summary: 'Test',
        started_at: Time.now,
        ended_at: Time.now,
        source_type: 'invalid'
      )
      expect(memory.valid?).to be false
    end

    it 'is valid with required attributes' do
      memory = described_class.new(
        summary: 'Test memory',
        started_at: Time.now - 3600,
        ended_at: Time.now
      )
      expect(memory.valid?).to be true
    end
  end

  describe 'before_save callbacks' do
    it 'sets memory_at to ended_at if not provided' do
      ended = Time.now
      memory = create(:world_memory, ended_at: ended, memory_at: nil)
      expect(memory.memory_at).to be_within(1).of(ended)
    end

    it 'sets raw_log_expires_at if not provided' do
      memory = create(:world_memory, raw_log_expires_at: nil)
      expect(memory.raw_log_expires_at).to be > Time.now
    end
  end

  describe '#relevance_score' do
    let(:memory) { create(:world_memory, importance: 8, memory_at: Time.now) }

    it 'returns a score between 0 and 1' do
      score = memory.relevance_score
      expect(score).to be >= 0.1
      expect(score).to be <= 1.0
    end

    it 'scores higher importance memories higher' do
      high_importance = create(:world_memory, importance: 10, memory_at: Time.now)
      low_importance = create(:world_memory, importance: 1, memory_at: Time.now)
      expect(high_importance.relevance_score).to be > low_importance.relevance_score
    end

    it 'scores more recent memories higher' do
      recent = create(:world_memory, importance: 5, memory_at: Time.now)
      old = create(:world_memory, importance: 5, memory_at: Time.now - (180 * 24 * 3600)) # 180 days ago
      expect(recent.relevance_score).to be > old.relevance_score
    end

    it 'accepts a custom query_time parameter' do
      future_time = Time.now + (30 * 24 * 3600)
      score_now = memory.relevance_score
      score_future = memory.relevance_score(query_time: future_time)
      expect(score_future).to be < score_now # Memory is older from future perspective
    end
  end

  describe '#recent?' do
    it 'returns true for memories within the specified days' do
      memory = create(:world_memory, memory_at: Time.now - (3 * 24 * 3600)) # 3 days ago
      expect(memory.recent?(days: 7)).to be true
    end

    it 'returns false for memories older than specified days' do
      memory = create(:world_memory, memory_at: Time.now - (10 * 24 * 3600)) # 10 days ago
      expect(memory.recent?(days: 7)).to be false
    end

    it 'uses default of 7 days' do
      recent_memory = create(:world_memory, memory_at: Time.now - (5 * 24 * 3600))
      old_memory = create(:world_memory, memory_at: Time.now - (10 * 24 * 3600))
      expect(recent_memory.recent?).to be true
      expect(old_memory.recent?).to be false
    end
  end

  describe '#searchable?' do
    it 'returns true for public non-excluded memories' do
      memory = create(:world_memory, publicity_level: 'public', excluded_from_public: false)
      expect(memory.searchable?).to be true
    end

    it 'returns false for private memories' do
      memory = create(:world_memory, publicity_level: 'private', excluded_from_public: false)
      expect(memory.searchable?).to be false
    end

    it 'returns false for excluded memories' do
      memory = create(:world_memory, publicity_level: 'public', excluded_from_public: true)
      expect(memory.searchable?).to be false
    end
  end

  describe '#can_abstract?' do
    it 'returns true when below max level and not already abstracted' do
      memory = create(:world_memory, abstraction_level: 1, abstracted_into_id: nil)
      expect(memory.can_abstract?).to be true
    end

    it 'returns false when at max abstraction level' do
      memory = create(:world_memory, abstraction_level: GameConfig::NpcMemory::MAX_ABSTRACTION_LEVEL)
      expect(memory.can_abstract?).to be false
    end

    it 'returns false when already abstracted' do
      parent = create(:world_memory)
      memory = create(:world_memory, abstraction_level: 1, abstracted_into_id: parent.id)
      expect(memory.can_abstract?).to be false
    end
  end

  describe '#raw_log_expired?' do
    it 'returns false when raw_log_expires_at is nil' do
      memory = create(:world_memory)
      memory.update(raw_log_expires_at: nil)
      expect(memory.raw_log_expired?).to be false
    end

    it 'returns false when expiry is in the future' do
      memory = create(:world_memory, raw_log_expires_at: Time.now + 3600)
      expect(memory.raw_log_expired?).to be false
    end

    it 'returns true when expiry has passed' do
      memory = create(:world_memory)
      memory.update(raw_log_expires_at: Time.now - 3600)
      expect(memory.raw_log_expired?).to be true
    end
  end

  describe '#purge_raw_log!' do
    it 'clears raw_log when expired' do
      memory = create(:world_memory, raw_log: 'Some log content')
      memory.update(raw_log_expires_at: Time.now - 3600)
      memory.purge_raw_log!
      memory.refresh
      expect(memory.raw_log).to be_nil
    end

    it 'does nothing when not expired' do
      memory = create(:world_memory, raw_log: 'Some log content', raw_log_expires_at: Time.now + 3600)
      memory.purge_raw_log!
      memory.refresh
      expect(memory.raw_log).to eq('Some log content')
    end

    it 'does nothing when raw_log is already nil' do
      memory = create(:world_memory, raw_log: nil)
      memory.update(raw_log_expires_at: Time.now - 3600)
      expect { memory.purge_raw_log! }.not_to raise_error
    end
  end

  describe 'character and location helpers' do
    let(:memory) { create(:world_memory) }
    let(:character) { create(:character) }
    let(:room) { create(:room) }

    describe '#add_character!' do
      it 'creates a new WorldMemoryCharacter link' do
        expect {
          memory.add_character!(character, role: 'participant', message_count: 5)
        }.to change(WorldMemoryCharacter, :count).by(1)
      end

      it 'updates existing link if character already linked' do
        memory.add_character!(character, message_count: 5)
        memory.add_character!(character, message_count: 10)
        links = WorldMemoryCharacter.where(world_memory_id: memory.id, character_id: character.id).all
        expect(links.length).to eq(1)
        expect(links.first.message_count).to eq(10)
      end
    end

    describe '#add_location!' do
      it 'creates a new WorldMemoryLocation link' do
        expect {
          memory.add_location!(room, is_primary: true, message_count: 10)
        }.to change(WorldMemoryLocation, :count).by(1)
      end

      it 'updates existing link if room already linked' do
        memory.add_location!(room, message_count: 5)
        memory.add_location!(room, message_count: 15)
        links = WorldMemoryLocation.where(world_memory_id: memory.id, room_id: room.id).all
        expect(links.length).to eq(1)
        expect(links.first.message_count).to eq(15)
      end
    end

    describe '#primary_room' do
      it 'returns nil when no primary room is set' do
        expect(memory.primary_room).to be_nil
      end

      it 'returns the primary room when set' do
        memory.add_location!(room, is_primary: true)
        expect(memory.primary_room).to eq(room)
      end
    end

    describe '#characters' do
      it 'returns empty array when no characters linked' do
        expect(memory.characters).to eq([])
      end

      it 'returns linked characters' do
        memory.add_character!(character)
        expect(memory.characters).to include(character)
      end
    end

    describe '#rooms' do
      it 'returns empty array when no rooms linked' do
        expect(memory.rooms).to eq([])
      end

      it 'returns linked rooms' do
        memory.add_location!(room)
        expect(memory.rooms).to include(room)
      end
    end
  end

  describe 'class query methods' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:location) { room.location }

    before do
      @public_memory = create(:world_memory, publicity_level: 'public', excluded_from_public: false, importance: 8)
      @private_memory = create(:world_memory, publicity_level: 'private', excluded_from_public: false)
      @private_event_memory = create(:world_memory, publicity_level: 'private_event', excluded_from_public: false)
      @excluded_memory = create(:world_memory, publicity_level: 'public', excluded_from_public: true)
      @old_memory = create(:world_memory, memory_at: Time.now - (60 * 24 * 3600)) # 60 days ago
    end

    describe '.searchable' do
      it 'returns only public non-excluded memories' do
        results = described_class.searchable.all
        expect(results.map(&:id)).to include(@public_memory.id)
        expect(results.map(&:id)).not_to include(@private_memory.id)
        expect(results.map(&:id)).not_to include(@private_event_memory.id)
        expect(results.map(&:id)).not_to include(@excluded_memory.id)
      end
    end

    describe '.recent' do
      it 'returns memories within specified days' do
        results = described_class.recent(days: 30).all
        expect(results.map(&:id)).to include(@public_memory.id)
        expect(results.map(&:id)).not_to include(@old_memory.id)
      end
    end

    describe '.for_character' do
      it 'returns memories involving the character' do
        @public_memory.add_character!(character)
        results = described_class.for_character(character).all
        expect(results.map(&:id)).to include(@public_memory.id)
      end

      it 'excludes excluded_from_public memories' do
        @excluded_memory.add_character!(character)
        results = described_class.for_character(character).all
        expect(results.map(&:id)).not_to include(@excluded_memory.id)
      end

      it 'excludes private_event memories' do
        @private_event_memory.add_character!(character)
        results = described_class.for_character(character).all
        expect(results.map(&:id)).not_to include(@private_event_memory.id)
      end

      it 'respects the limit parameter' do
        5.times do
          mem = create(:world_memory, excluded_from_public: false)
          mem.add_character!(character)
        end
        results = described_class.for_character(character, limit: 3).all
        expect(results.length).to eq(3)
      end
    end

    describe '.for_room' do
      it 'returns memories at the specified room' do
        @public_memory.add_location!(room)
        results = described_class.for_room(room).all
        expect(results.map(&:id)).to include(@public_memory.id)
      end

      it 'excludes private_event memories' do
        @private_event_memory.add_location!(room)
        results = described_class.for_room(room).all
        expect(results.map(&:id)).not_to include(@private_event_memory.id)
      end
    end

    describe '.for_location' do
      it 'returns public memories from rooms in the location' do
        @public_memory.add_location!(room)
        results = described_class.for_location(location).all
        expect(results.map(&:id)).to include(@public_memory.id)
      end

      it 'excludes private_event memories' do
        @private_event_memory.add_location!(room)
        results = described_class.for_location(location).all
        expect(results.map(&:id)).not_to include(@private_event_memory.id)
      end
    end

    describe '.unabstracted_at_level' do
      it 'returns unabstracted memories at the specified level' do
        level_1 = create(:world_memory, abstraction_level: 1, abstracted_into_id: nil)
        level_2 = create(:world_memory, abstraction_level: 2, abstracted_into_id: nil)
        abstracted = create(:world_memory, abstraction_level: 1)
        parent = create(:world_memory)
        abstracted.update(abstracted_into_id: parent.id)

        results = described_class.unabstracted_at_level(1).all
        expect(results.map(&:id)).to include(level_1.id)
        expect(results.map(&:id)).not_to include(level_2.id)
        expect(results.map(&:id)).not_to include(abstracted.id)
      end
    end

    describe '.needs_abstraction?' do
      it 'returns true when count exceeds threshold' do
        # Create enough memories to exceed threshold
        (GameConfig::NpcMemory::ABSTRACTION_THRESHOLD + 1).times do
          create(:world_memory, abstraction_level: 1, abstracted_into_id: nil)
        end
        expect(described_class.needs_abstraction?(1)).to be true
      end

      it 'returns false when count is below threshold' do
        # Ensure we're below threshold
        expect(described_class.needs_abstraction?(99)).to be false
      end
    end

    describe '.expired_raw_logs' do
      it 'returns memories with expired raw logs' do
        expired = create(:world_memory, raw_log: 'content')
        expired.update(raw_log_expires_at: Time.now - 3600)

        not_expired = create(:world_memory, raw_log: 'content', raw_log_expires_at: Time.now + 3600)
        no_log = create(:world_memory, raw_log: nil)

        results = described_class.expired_raw_logs.all
        expect(results.map(&:id)).to include(expired.id)
        expect(results.map(&:id)).not_to include(not_expired.id)
        expect(results.map(&:id)).not_to include(no_log.id)
      end
    end

    describe '.for_rooms' do
      it 'returns empty dataset for empty room_ids array' do
        results = described_class.for_rooms([]).all
        expect(results).to eq([])
      end

      it 'returns memories from multiple rooms' do
        room2 = create(:room)
        @public_memory.add_location!(room)
        mem2 = create(:world_memory, excluded_from_public: false)
        mem2.add_location!(room2)

        results = described_class.for_rooms([room.id, room2.id]).all
        expect(results.map(&:id)).to include(@public_memory.id, mem2.id)
      end

      it 'excludes private_event memories' do
        room2 = create(:room)
        @private_event_memory.add_location!(room)
        public_room2 = create(:world_memory, publicity_level: 'public', excluded_from_public: false)
        public_room2.add_location!(room2)

        results = described_class.for_rooms([room.id, room2.id]).all
        expect(results.map(&:id)).to include(public_room2.id)
        expect(results.map(&:id)).not_to include(@private_event_memory.id)
      end
    end

    describe '.for_characters' do
      it 'returns empty dataset for empty characters array' do
        results = described_class.for_characters([]).all
        expect(results).to eq([])
      end

      it 'returns memories involving any of the characters' do
        char2 = create(:character)
        @public_memory.add_character!(character)
        mem2 = create(:world_memory, excluded_from_public: false)
        mem2.add_character!(char2)

        results = described_class.for_characters([character, char2]).all
        expect(results.map(&:id)).to include(@public_memory.id, mem2.id)
      end

      it 'excludes private_event memories' do
        @private_event_memory.add_character!(character)

        results = described_class.for_characters([character]).all
        expect(results.map(&:id)).not_to include(@private_event_memory.id)
      end
    end
  end
end
