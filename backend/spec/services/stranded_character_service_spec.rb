# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StrandedCharacterService do
  let(:location) { create(:location) }
  let(:permanent_room) { create(:room, location: location, name: 'Town Square') }
  let(:temp_room) do
    create(:room, location: location, is_temporary: true, pool_status: 'in_use', name: 'Temp Room')
  end
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: temp_room, online: true,
                                last_nontemporary_room_id: permanent_room.id)
  end

  describe '.check_and_rescue!' do
    context 'when character is in a permanent room' do
      it 'returns nil' do
        character_instance.update(current_room_id: permanent_room.id)
        expect(described_class.check_and_rescue!(character_instance)).to be_nil
      end
    end

    context 'when character is in an active temporary room' do
      it 'returns nil' do
        expect(described_class.check_and_rescue!(character_instance)).to be_nil
      end
    end

    context 'when room pool_status is available (released)' do
      it 'rescues the character' do
        temp_room.update(pool_status: 'available')
        result = described_class.check_and_rescue!(character_instance)
        expect(result).to eq(permanent_room)
        character_instance.reload
        expect(character_instance.current_room_id).to eq(permanent_room.id)
      end
    end

    context 'when delve is completed' do
      it 'rescues the character' do
        delve = create(:delve, status: 'completed')
        temp_room.update(temp_delve_id: delve.id)
        result = described_class.check_and_rescue!(character_instance)
        expect(result).to eq(permanent_room)
      end
    end

    context 'when delve is abandoned' do
      it 'rescues the character' do
        delve = create(:delve, status: 'abandoned')
        temp_room.update(temp_delve_id: delve.id)
        result = described_class.check_and_rescue!(character_instance)
        expect(result).to eq(permanent_room)
      end
    end

    context 'when delve is active' do
      it 'does not rescue the character' do
        delve = create(:delve, status: 'active')
        temp_room.update(temp_delve_id: delve.id)
        expect(described_class.check_and_rescue!(character_instance)).to be_nil
      end
    end

    context 'when journey is arrived' do
      it 'rescues the character' do
        journey = create(:world_journey, status: 'arrived')
        temp_room.update(temp_journey_id: journey.id)
        result = described_class.check_and_rescue!(character_instance)
        expect(result).to eq(permanent_room)
      end
    end

    context 'when journey is traveling' do
      it 'does not rescue the character' do
        journey = create(:world_journey, status: 'traveling')
        temp_room.update(temp_journey_id: journey.id)
        expect(described_class.check_and_rescue!(character_instance)).to be_nil
      end
    end

    context 'when temp room has no entity and is not in_use' do
      it 'rescues the character' do
        temp_room.update(pool_status: 'permanent', temp_delve_id: nil, temp_journey_id: nil, temp_vehicle_id: nil)
        result = described_class.check_and_rescue!(character_instance)
        expect(result).to eq(permanent_room)
      end
    end

    context 'when no last_nontemporary_room_id is set' do
      it 'falls back to tutorial spawn room' do
        temp_room.update(pool_status: 'available')
        character_instance.update(last_nontemporary_room_id: nil)
        result = described_class.check_and_rescue!(character_instance)
        expect(result).to eq(Room.tutorial_spawn_room)
      end
    end
  end

  describe '.rescue_all_stranded!' do
    it 'rescues online characters in defunct temporary rooms' do
      temp_room.update(pool_status: 'available')
      # Ensure the character_instance is created
      character_instance

      count = described_class.rescue_all_stranded!
      expect(count).to eq(1)

      character_instance.reload
      expect(character_instance.current_room_id).to eq(permanent_room.id)
    end

    it 'skips offline characters' do
      temp_room.update(pool_status: 'available')
      character_instance.update(online: false)

      count = described_class.rescue_all_stranded!
      expect(count).to eq(0)
    end
  end
end
