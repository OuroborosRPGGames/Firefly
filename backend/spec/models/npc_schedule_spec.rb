# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcSchedule, type: :model do
  let(:reality) { create(:reality) }
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:npc_archetype) { create(:npc_archetype, name: 'Barmaid') }
  let(:npc_character) { create(:character, :npc, forename: 'Jane', npc_archetype: npc_archetype) }

  describe 'validations' do
    it 'requires character_id' do
      schedule = NpcSchedule.new(room: room)
      expect(schedule.valid?).to be false
    end

    it 'requires room_id' do
      schedule = NpcSchedule.new(character: npc_character)
      expect(schedule.valid?).to be false
    end

    it 'validates probability range' do
      schedule = NpcSchedule.new(
        character: npc_character,
        room: room,
        probability: 150
      )
      expect(schedule.valid?).to be false
    end

    it 'accepts legacy integer day_of_week values 0-6' do
      schedule = NpcSchedule.new(
        character: npc_character,
        room: room,
        day_of_week: 1
      )
      expect(schedule.valid?).to be true
    end

    it 'rejects legacy integer day_of_week values outside 0-6' do
      schedule = NpcSchedule.new(
        character: npc_character,
        room: room,
        day_of_week: 9
      )
      expect(schedule.valid?).to be false
      expect(schedule.errors[:day_of_week]).not_to be_empty
    end

    it 'rejects schedules where start_hour equals end_hour' do
      schedule = NpcSchedule.new(
        character: npc_character,
        room: room,
        start_hour: 9,
        end_hour: 9
      )

      expect(schedule.valid?).to be false
      expect(schedule.errors[:end_hour]).to include('must be different from start_hour')
    end
  end

  describe 'defaults' do
    let(:schedule) { NpcSchedule.create(character: npc_character, room: room) }

    it 'sets default probability to 100' do
      expect(schedule.probability).to eq(100)
    end

    it 'sets default weekdays to all' do
      expect(schedule.weekdays).to eq('all')
    end

    it 'sets default max_npcs to 1' do
      expect(schedule.max_npcs).to eq(1)
    end

    it 'sets default start_hour to 0' do
      expect(schedule.start_hour).to eq(0)
    end

    it 'sets default end_hour to 24' do
      expect(schedule.end_hour).to eq(24)
    end
  end

  describe '#day_matches?' do
    let(:schedule) { NpcSchedule.create(character: npc_character, room: room, is_active: true) }

    context 'with weekdays pattern' do
      it 'returns true for all days with pattern "all"' do
        schedule.update(weekdays: 'all')
        monday = Time.new(2024, 1, 1, 12, 0, 0) # Monday
        saturday = Time.new(2024, 1, 6, 12, 0, 0) # Saturday
        expect(schedule.day_matches?(monday)).to be true
        expect(schedule.day_matches?(saturday)).to be true
      end

      it 'returns true for weekdays only with pattern "weekdays"' do
        schedule.update(weekdays: 'weekdays')
        monday = Time.new(2024, 1, 1, 12, 0, 0) # Monday
        saturday = Time.new(2024, 1, 6, 12, 0, 0) # Saturday
        expect(schedule.day_matches?(monday)).to be true
        expect(schedule.day_matches?(saturday)).to be false
      end

      it 'returns true for weekends only with pattern "weekends"' do
        schedule.update(weekdays: 'weekends')
        monday = Time.new(2024, 1, 1, 12, 0, 0) # Monday
        saturday = Time.new(2024, 1, 6, 12, 0, 0) # Saturday
        expect(schedule.day_matches?(monday)).to be false
        expect(schedule.day_matches?(saturday)).to be true
      end

      it 'returns true for specific day' do
        schedule.update(weekdays: 'monday')
        monday = Time.new(2024, 1, 1, 12, 0, 0) # Monday
        tuesday = Time.new(2024, 1, 2, 12, 0, 0) # Tuesday
        expect(schedule.day_matches?(monday)).to be true
        expect(schedule.day_matches?(tuesday)).to be false
      end
    end

    context 'with legacy day_of_week integer fallback' do
      it 'matches monday when day_of_week is 1 and weekdays is blank' do
        schedule.update(weekdays: nil, day_of_week: 1)
        monday = Time.new(2024, 1, 1, 12, 0, 0) # Monday
        tuesday = Time.new(2024, 1, 2, 12, 0, 0) # Tuesday

        expect(schedule.day_matches?(monday)).to be true
        expect(schedule.day_matches?(tuesday)).to be false
      end
    end
  end

  describe '#time_matches?' do
    let(:schedule) { NpcSchedule.create(character: npc_character, room: room, is_active: true) }

    context 'with normal time range' do
      it 'returns true when current hour is within range' do
        schedule.update(start_hour: 9, end_hour: 17)
        noon = Time.new(2024, 1, 1, 12, 0, 0)
        expect(schedule.time_matches?(noon)).to be true
      end

      it 'returns false when current hour is before range' do
        schedule.update(start_hour: 9, end_hour: 17)
        early_morning = Time.new(2024, 1, 1, 6, 0, 0)
        expect(schedule.time_matches?(early_morning)).to be false
      end

      it 'returns false when current hour is after range' do
        schedule.update(start_hour: 9, end_hour: 17)
        evening = Time.new(2024, 1, 1, 20, 0, 0)
        expect(schedule.time_matches?(evening)).to be false
      end
    end

    context 'with overnight time range' do
      it 'returns true for late night hours' do
        schedule.update(start_hour: 22, end_hour: 6)
        midnight = Time.new(2024, 1, 1, 0, 0, 0)
        expect(schedule.time_matches?(midnight)).to be true
      end

      it 'returns true for early morning hours' do
        schedule.update(start_hour: 22, end_hour: 6)
        early_morning = Time.new(2024, 1, 1, 3, 0, 0)
        expect(schedule.time_matches?(early_morning)).to be true
      end

      it 'returns false for afternoon hours' do
        schedule.update(start_hour: 22, end_hour: 6)
        afternoon = Time.new(2024, 1, 1, 15, 0, 0)
        expect(schedule.time_matches?(afternoon)).to be false
      end
    end

    context 'with equal start and end hours' do
      it 'returns false for all times' do
        schedule.start_hour = 9
        schedule.end_hour = 9
        noon = Time.new(2024, 1, 1, 12, 0, 0)
        expect(schedule.time_matches?(noon)).to be false
      end
    end
  end

  describe '#applies_now?' do
    let(:schedule) { NpcSchedule.create(character: npc_character, room: room, is_active: true, start_hour: 9, end_hour: 17, weekdays: 'weekdays') }

    it 'returns false if schedule is inactive' do
      schedule.update(is_active: false)
      monday_noon = Time.new(2024, 1, 1, 12, 0, 0)
      expect(schedule.applies_now?(monday_noon)).to be false
    end

    it 'returns true when day and time both match' do
      monday_noon = Time.new(2024, 1, 1, 12, 0, 0) # Monday at noon
      expect(schedule.applies_now?(monday_noon)).to be true
    end

    it 'returns false when day matches but time does not' do
      monday_evening = Time.new(2024, 1, 1, 20, 0, 0) # Monday at 8pm
      expect(schedule.applies_now?(monday_evening)).to be false
    end

    it 'returns false when time matches but day does not' do
      saturday_noon = Time.new(2024, 1, 6, 12, 0, 0) # Saturday at noon
      expect(schedule.applies_now?(saturday_noon)).to be false
    end
  end

  describe '#should_spawn?' do
    let(:schedule) { NpcSchedule.create(character: npc_character, room: room, is_active: true, start_hour: 9, end_hour: 17, weekdays: 'all', probability: 100) }

    it 'returns true when applies_now? and probability check pass' do
      noon = Time.new(2024, 1, 1, 12, 0, 0)
      allow(schedule).to receive(:applies_now?).and_return(true)
      # With 100% probability, should always return true
      expect(schedule.should_spawn?).to be true
    end

    it 'returns false when applies_now? fails' do
      schedule.update(is_active: false)
      expect(schedule.should_spawn?).to be false
    end
  end

  describe '#can_spawn_more?' do
    let(:schedule) { NpcSchedule.create(character: npc_character, room: room, is_active: true, max_npcs: 2) }
    let(:character_instance) { create(:character_instance, character: npc_character, reality: reality, current_room: room) }

    it 'returns true when no spawns exist' do
      expect(schedule.can_spawn_more?).to be true
    end

    it 'returns true when spawns are below max_npcs' do
      NpcSpawnInstance.create(
        character: npc_character,
        character_instance: character_instance,
        npc_schedule: schedule,
        room: room,
        spawned_at: Time.now,
        active: true
      )
      expect(schedule.can_spawn_more?).to be true
    end

    it 'returns false when spawns equal max_npcs' do
      2.times do |i|
        # Each spawn needs a unique character/reality combination
        npc = create(:character, :npc, forename: "Guard #{i}", npc_archetype: npc_archetype)
        instance_reality = create(:reality)
        instance = create(:character_instance, character: npc, reality: instance_reality, current_room: room)
        NpcSpawnInstance.create(
          character: npc,
          character_instance: instance,
          npc_schedule: schedule,
          room: room,
          spawned_at: Time.now,
          active: true
        )
      end
      expect(schedule.can_spawn_more?).to be false
    end
  end
end
