# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcAnimationProcessJob do
  let(:room) { create(:room) }
  let(:npc_character) { create(:character, :npc) }
  let(:npc_instance) { create(:character_instance, character: npc_character, current_room: room, online: true) }
  let(:entry) { create(:npc_animation_queue, character_instance: npc_instance, room: room) }

  describe '#perform' do
    it 'processes queue entry through NpcAnimationService' do
      expect(NpcAnimationService).to receive(:send).with(:process_queue_entry, entry).and_return(true)

      described_class.new.perform(entry.id)
    end

    it 'handles missing queue entry gracefully' do
      expect {
        described_class.new.perform(999_999)
      }.not_to raise_error
    end
  end
end
