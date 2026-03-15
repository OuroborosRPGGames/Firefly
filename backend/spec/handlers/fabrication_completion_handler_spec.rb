# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FabricationCompletionHandler do
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, online: true) }
  let(:pattern) { create(:pattern) }
  let(:fabrication_room) { create(:room, room_type: 'replicator') }
  let(:delivery_room) { create(:room) }
  let(:system_messages_sent) { [] }

  before do
    # Track system messages sent
    allow_any_instance_of(CharacterInstance).to receive(:send_system_message) do |instance, **kwargs|
      system_messages_sent << { instance_id: instance.id, **kwargs }
    end
  end

  describe '.call' do
    context 'with no completed orders' do
      it 'returns success with zero processed' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(0)
        expect(result[:orders]).to eq([])
      end
    end

    context 'with completed orders for pickup' do
      let!(:order) do
        # Ensure character_instance exists first so FabricationService can find it
        character_instance
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               status: 'crafting',
               delivery_method: 'pickup',
               completes_at: Time.now - 60)
      end

      it 'processes the completed order' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(1)
        expect(result[:orders]).to include(order.id)
      end

      it 'marks order as ready' do
        described_class.call

        expect(order.reload.status).to eq('ready')
      end

      it 'notifies online character' do
        described_class.call

        expect(system_messages_sent).not_to be_empty
        expect(system_messages_sent.first[:type]).to eq('fabrication')
      end
    end

    context 'with completed orders for delivery' do
      let!(:order) do
        # Ensure character_instance exists first so FabricationService can find it
        character_instance
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               delivery_room: delivery_room,
               status: 'crafting',
               delivery_method: 'delivery',
               completes_at: Time.now - 60)
      end

      it 'processes the completed order' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(1)
      end

      it 'marks order as delivered' do
        described_class.call

        expect(order.reload.status).to eq('delivered')
      end

      it 'creates item in delivery room' do
        expect {
          described_class.call
        }.to change { Item.where(room_id: delivery_room.id).count }.by(1)
      end

      it 'notifies online character' do
        described_class.call

        expect(system_messages_sent).not_to be_empty
        expect(system_messages_sent.first[:type]).to eq('fabrication')
      end
    end

    context 'with multiple completed orders' do
      let!(:order1) do
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               status: 'crafting',
               delivery_method: 'pickup',
               completes_at: Time.now - 60)
      end

      let!(:order2) do
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               status: 'crafting',
               delivery_method: 'pickup',
               completes_at: Time.now - 30)
      end

      it 'processes all completed orders' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(2)
        expect(result[:orders]).to include(order1.id, order2.id)
      end
    end

    context 'with orders not yet completed' do
      let!(:order) do
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               status: 'crafting',
               delivery_method: 'pickup',
               completes_at: Time.now + 3600)
      end

      it 'does not process the order' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(0)
        expect(order.reload.status).to eq('crafting')
      end
    end

    context 'with already ready orders' do
      let!(:order) do
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               status: 'ready',
               delivery_method: 'pickup',
               completes_at: Time.now - 60)
      end

      it 'does not reprocess the order' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(0)
      end
    end

    context 'with offline character' do
      let(:offline_character_instance) do
        create(:character_instance, character: character, online: false)
      end

      let!(:order) do
        # Ensure offline_character_instance exists first
        offline_character_instance
        create(:fabrication_order,
               character: character,
               pattern: pattern,
               fabrication_room: fabrication_room,
               status: 'crafting',
               delivery_method: 'pickup',
               completes_at: Time.now - 60)
      end

      it 'still processes the order' do
        result = described_class.call

        expect(result[:success]).to be true
        expect(result[:processed_count]).to eq(1)
        expect(order.reload.status).to eq('ready')
      end

      it 'does not attempt to notify' do
        described_class.call

        expect(system_messages_sent).to be_empty
      end
    end

    context 'when an error occurs during processing' do
      before do
        allow(FabricationService).to receive(:process_completed_orders)
          .and_raise(StandardError, 'Database error')
      end

      it 'returns failure result' do
        result = described_class.call

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Database error')
      end
    end

    context 'with scheduled task parameter' do
      let(:task) { double('ScheduledTask', id: 1) }

      it 'accepts task parameter' do
        result = described_class.call(task)

        expect(result[:success]).to be true
      end
    end
  end

  describe '.register!' do
    before do
      allow(ScheduledTask).to receive(:register)
    end

    it 'registers as a scheduled task' do
      expect(ScheduledTask).to receive(:register).with(
        'fabrication_completion',
        'interval',
        hash_including(
          handler_class: 'FabricationCompletionHandler',
          interval_seconds: 60,
          enabled: true
        )
      )

      described_class.register!
    end
  end
end
