# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FabricationService do
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }
  let(:clothing_type) { create(:unified_object_type, category: 'Top') }
  let(:weapon_type) { create(:unified_object_type, category: 'Sword') }
  let(:pattern) { create(:pattern, unified_object_type: clothing_type) }
  let(:weapon_pattern) { create(:pattern, unified_object_type: weapon_type, is_melee: true) }
  let(:room) { create(:room, room_type: 'shop') }
  let(:tailor_room) { create(:room, room_type: 'tailor') }
  let(:forge_room) { create(:room, room_type: 'forge') }
  let(:replicator_room) { create(:room, room_type: 'replicator') }
  let(:home_room) { create(:room, room_type: 'apartment', owner_id: character.id) }

  before do
    # Default to modern era for most tests
    allow(EraService).to receive(:current_era).and_return(:modern)
  end

  describe '.can_fabricate_here?' do
    context 'when character is admin' do
      before { allow(character).to receive(:admin?).and_return(true) }

      it 'returns true regardless of room' do
        expect(described_class.can_fabricate_here?(character_instance, pattern)).to be true
      end
    end

    context 'when in a tutorial room' do
      let(:room) { create(:room, room_type: 'tutorial', tutorial_room: true) }

      it 'returns true' do
        expect(described_class.can_fabricate_here?(character_instance, pattern)).to be true
      end
    end

    context 'when in a universal facility' do
      let(:room) { replicator_room }
      let(:character_instance) { create(:character_instance, character: character, current_room: room) }

      it 'returns true for any pattern type' do
        expect(described_class.can_fabricate_here?(character_instance, pattern)).to be true
        expect(described_class.can_fabricate_here?(character_instance, weapon_pattern)).to be true
      end
    end

    context 'when in a specialized facility' do
      it 'returns true for matching pattern types' do
        ci = create(:character_instance, character: character, current_room: tailor_room)
        expect(described_class.can_fabricate_here?(ci, pattern)).to be true
      end

      it 'returns false for non-matching pattern types' do
        ci = create(:character_instance, character: character, current_room: tailor_room)
        expect(described_class.can_fabricate_here?(ci, weapon_pattern)).to be false
      end
    end

    context 'when in a shop' do
      it 'allows clothing patterns' do
        expect(described_class.can_fabricate_here?(character_instance, pattern)).to be true
      end

      it 'does not allow weapon patterns' do
        expect(described_class.can_fabricate_here?(character_instance, weapon_pattern)).to be false
      end
    end
  end

  describe '.calculate_time' do
    context 'in medieval era' do
      before { allow(EraService).to receive(:current_era).and_return(:medieval) }

      it 'returns hours for clothing' do
        time = described_class.calculate_time(pattern)
        expect(time).to eq(14_400) # 4 hours
      end

      it 'applies complexity multiplier for weapons' do
        time = described_class.calculate_time(weapon_pattern)
        expect(time).to eq(28_800) # 4 hours * 2.0 complexity
      end
    end

    context 'in modern era' do
      before { allow(EraService).to receive(:current_era).and_return(:modern) }

      it 'returns minutes for clothing' do
        time = described_class.calculate_time(pattern)
        expect(time).to eq(1800) # 30 minutes
      end
    end

    context 'in scifi era' do
      before { allow(EraService).to receive(:current_era).and_return(:scifi) }

      it 'returns seconds' do
        time = described_class.calculate_time(pattern)
        expect(time).to eq(3) # 3 seconds
      end
    end
  end

  describe '.instant?' do
    context 'in scifi era' do
      before { allow(EraService).to receive(:current_era).and_return(:scifi) }

      it 'returns true' do
        expect(described_class.instant?(pattern)).to be true
      end
    end

    context 'in medieval era' do
      before { allow(EraService).to receive(:current_era).and_return(:medieval) }

      it 'returns false' do
        expect(described_class.instant?(pattern)).to be false
      end
    end

    context 'in modern era' do
      before { allow(EraService).to receive(:current_era).and_return(:modern) }

      it 'returns false' do
        expect(described_class.instant?(pattern)).to be false
      end
    end
  end

  describe '.start_fabrication' do
    it 'creates a fabrication order' do
      order = described_class.start_fabrication(
        character_instance,
        pattern,
        delivery_method: 'pickup'
      )

      expect(order).to be_a(FabricationOrder)
      expect(order.character_id).to eq(character.id)
      expect(order.pattern_id).to eq(pattern.id)
      expect(order.status).to eq('crafting')
      expect(order.delivery_method).to eq('pickup')
      expect(order.fabrication_room_id).to eq(room.id)
      expect(order.completes_at).to be > Time.now
    end

    it 'sets delivery room for delivery orders' do
      order = described_class.start_fabrication(
        character_instance,
        pattern,
        delivery_method: 'delivery',
        delivery_room: home_room
      )

      expect(order.delivery_method).to eq('delivery')
      expect(order.delivery_room_id).to eq(home_room.id)
    end
  end

  describe '.process_completed_orders' do
    it 'processes orders that have completed' do
      # Create a completed pickup order
      pickup_order = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        fabrication_room_id: room.id,
        started_at: Time.now - 3600,
        completes_at: Time.now - 60
      )

      processed = described_class.process_completed_orders

      expect(processed).to include(pickup_order)
      expect(pickup_order.reload.status).to eq('ready')
    end

    it 'delivers items for delivery orders' do
      delivery_order = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'delivery',
        delivery_room_id: home_room.id,
        started_at: Time.now - 3600,
        completes_at: Time.now - 60
      )

      processed = described_class.process_completed_orders

      expect(processed).to include(delivery_order)
      expect(delivery_order.reload.status).to eq('delivered')
      expect(Item.where(room_id: home_room.id).count).to eq(1)
    end

    it 'does not process orders not yet complete' do
      not_ready = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        started_at: Time.now,
        completes_at: Time.now + 3600
      )

      processed = described_class.process_completed_orders

      expect(processed).not_to include(not_ready)
      expect(not_ready.reload.status).to eq('crafting')
    end
  end

  describe '.pending_orders' do
    it 'returns pending orders for a character' do
      crafting = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        completes_at: Time.now + 3600
      )

      ready = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'ready',
        delivery_method: 'pickup'
      )

      delivered = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'delivered',
        delivery_method: 'pickup'
      )

      pending = described_class.pending_orders(character)

      expect(pending).to include(crafting, ready)
      expect(pending).not_to include(delivered)
    end
  end

  describe '.pickup_order' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'ready',
        delivery_method: 'pickup',
        fabrication_room_id: room.id
      )
    end

    it 'creates item and marks order delivered' do
      result = described_class.pickup_order(character_instance, order)

      expect(result[:success]).to be true
      expect(result[:item]).to be_a(Item)
      expect(order.reload.status).to eq('delivered')
    end

    it 'fails if order is not ready' do
      order.update(status: 'crafting')

      result = described_class.pickup_order(character_instance, order)

      expect(result[:success]).to be false
      expect(result[:message]).to match(/not ready/)
    end

    it 'fails if order belongs to someone else' do
      other_character = create(:character)
      order.update(character_id: other_character.id)

      result = described_class.pickup_order(character_instance, order)

      expect(result[:success]).to be false
      expect(result[:message]).to match(/someone else/)
    end
  end

  describe '.crafting_started_message' do
    context 'in medieval era' do
      before { allow(EraService).to receive(:current_era).and_return(:medieval) }

      it 'uses craftsman language' do
        message = described_class.crafting_started_message(pattern, 14_400)
        expect(message).to include('craftsman')
      end
    end

    context 'in scifi era' do
      before { allow(EraService).to receive(:current_era).and_return(:scifi) }

      it 'uses synthesizing language' do
        message = described_class.crafting_started_message(pattern, 3)
        expect(message).to include('Synthesizing')
      end
    end
  end

  describe '.facility_name' do
    it 'returns appropriate name for replicator' do
      allow(EraService).to receive(:scifi?).and_return(true)
      expect(described_class.facility_name(replicator_room)).to eq('replicator')
    end

    it 'returns forge for forge room' do
      expect(described_class.facility_name(forge_room)).to eq('forge')
    end

    it 'returns tailor for tailor room' do
      expect(described_class.facility_name(tailor_room)).to eq('tailor')
    end
  end
end
