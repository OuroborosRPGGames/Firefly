# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'NPC Catchup type constants' do
  describe 'NpcMemory::MEMORY_TYPES' do
    it 'includes reflection type' do
      expect(NpcMemory::MEMORY_TYPES).to include('reflection')
    end
  end

  describe 'WorldMemory::SOURCE_TYPES' do
    it 'includes location_recap type' do
      expect(WorldMemory::SOURCE_TYPES).to include('location_recap')
    end
  end

  describe 'NpcMemory validation' do
    let(:npc) { create(:character, :npc) }

    it 'accepts reflection memory_type' do
      memory = NpcMemory.new(
        character_id: npc.id,
        content: 'Spent the week tending the garden',
        memory_type: 'reflection'
      )
      expect(memory.valid?).to be true
    end
  end

  describe 'WorldMemory validation' do
    it 'accepts location_recap source_type' do
      memory = WorldMemory.new(
        summary: 'A quiet week at the tavern',
        started_at: Time.now - 7 * 86400,
        ended_at: Time.now,
        source_type: 'location_recap'
      )
      expect(memory.valid?).to be true
    end
  end
end
