# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FabricationOrder do
  let(:character) { create(:character) }
  let(:pattern) { create(:pattern) }
  let(:fabrication_room) { create(:room, room_type: 'tailor') }
  let(:delivery_room) { create(:room, room_type: 'apartment') }

  describe 'validations' do
    it 'requires character_id' do
      order = FabricationOrder.new(pattern_id: pattern.id, status: 'crafting', delivery_method: 'pickup')
      expect(order.valid?).to be false
      expect(order.errors[:character_id]).to include('is not present')
    end

    it 'requires pattern_id' do
      order = FabricationOrder.new(character_id: character.id, status: 'crafting', delivery_method: 'pickup')
      expect(order.valid?).to be false
      expect(order.errors[:pattern_id]).to include('is not present')
    end

    it 'validates status is one of allowed values' do
      order = FabricationOrder.new(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'invalid',
        delivery_method: 'pickup'
      )
      expect(order.valid?).to be false
    end

    it 'validates delivery_method is one of allowed values' do
      order = FabricationOrder.new(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'invalid'
      )
      expect(order.valid?).to be false
    end

    it 'creates a valid order' do
      order = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        started_at: Time.now,
        completes_at: Time.now + 3600
      )
      expect(order.valid?).to be true
      expect(order.id).not_to be_nil
    end
  end

  describe '#complete?' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        started_at: Time.now,
        completes_at: completes_at
      )
    end

    context 'when completes_at is in the future' do
      let(:completes_at) { Time.now + 3600 }

      it 'returns false' do
        expect(order.complete?).to be false
      end
    end

    context 'when completes_at is in the past' do
      let(:completes_at) { Time.now - 60 }

      it 'returns true' do
        expect(order.complete?).to be true
      end
    end

    context 'when completes_at is nil' do
      let(:completes_at) { nil }

      it 'returns false' do
        expect(order.complete?).to be false
      end
    end
  end

  describe '#time_remaining' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        started_at: Time.now,
        completes_at: Time.now + 3600
      )
    end

    it 'returns the seconds remaining' do
      # Allow for small timing variations
      expect(order.time_remaining).to be_within(2).of(3600)
    end

    it 'returns 0 when order is complete' do
      order.update(completes_at: Time.now - 60)
      expect(order.time_remaining).to eq(0)
    end
  end

  describe '#time_remaining_display' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        started_at: Time.now,
        completes_at: completes_at
      )
    end

    context 'when hours remaining' do
      let(:completes_at) { Time.now + 7200 } # 2 hours

      it 'displays hours' do
        expect(order.time_remaining_display).to match(/2 hours/)
      end
    end

    context 'when minutes remaining' do
      let(:completes_at) { Time.now + 1800 } # 30 minutes

      it 'displays minutes' do
        expect(order.time_remaining_display).to match(/30 minutes/)
      end
    end

    context 'when seconds remaining' do
      let(:completes_at) { Time.now + 45 }

      it 'displays seconds' do
        expect(order.time_remaining_display).to match(/\d+ seconds?/)
      end
    end

    context 'when complete' do
      let(:completes_at) { Time.now - 60 }

      it 'displays ready' do
        expect(order.time_remaining_display).to eq('ready')
      end
    end
  end

  describe 'status methods' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup'
      )
    end

    it '#crafting? returns true when status is crafting' do
      expect(order.crafting?).to be true
    end

    it '#ready? returns true when status is ready' do
      order.update(status: 'ready')
      expect(order.ready?).to be true
    end

    it '#delivered? returns true when status is delivered' do
      order.update(status: 'delivered')
      expect(order.delivered?).to be true
    end

    it '#cancelled? returns true when status is cancelled' do
      order.update(status: 'cancelled')
      expect(order.cancelled?).to be true
    end
  end

  describe '#mark_ready!' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup'
      )
    end

    it 'changes status to ready' do
      order.mark_ready!
      expect(order.reload.status).to eq('ready')
    end
  end

  describe '#mark_delivered!' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'ready',
        delivery_method: 'pickup'
      )
    end

    it 'changes status to delivered and sets delivered_at' do
      order.mark_delivered!
      order.reload
      expect(order.status).to eq('delivered')
      expect(order.delivered_at).not_to be_nil
    end
  end

  describe '#cancel!' do
    let(:order) do
      FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup'
      )
    end

    it 'changes status to cancelled' do
      order.cancel!
      expect(order.reload.status).to eq('cancelled')
    end
  end

  describe '.ready_to_complete' do
    it 'returns orders that have completed fabrication' do
      crafting_order = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        completes_at: Time.now - 60
      )

      not_ready_order = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'crafting',
        delivery_method: 'pickup',
        completes_at: Time.now + 3600
      )

      already_ready = FabricationOrder.create(
        character_id: character.id,
        pattern_id: pattern.id,
        status: 'ready',
        delivery_method: 'pickup',
        completes_at: Time.now - 60
      )

      ready = FabricationOrder.ready_to_complete.all
      expect(ready).to include(crafting_order)
      expect(ready).not_to include(not_ready_order)
      expect(ready).not_to include(already_ready)
    end
  end

  describe '.pending_for_character' do
    it 'returns crafting and ready orders for a character' do
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

      pending = FabricationOrder.pending_for_character(character).all
      expect(pending).to include(crafting, ready)
      expect(pending).not_to include(delivered)
    end
  end
end
