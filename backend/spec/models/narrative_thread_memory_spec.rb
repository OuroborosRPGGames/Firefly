# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NarrativeThreadMemory, type: :model do
  describe 'validations' do
    let(:thread_memory) { create(:narrative_thread_memory) }

    it 'requires a narrative_thread_id' do
      thread_memory.narrative_thread_id = nil
      expect(thread_memory.valid?).to be false
    end

    it 'requires a world_memory_id' do
      thread_memory.world_memory_id = nil
      expect(thread_memory.valid?).to be false
    end
  end
end
