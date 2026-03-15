# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Embedding do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }

  describe 'constants' do
    it 'defines CONTENT_TYPES' do
      expect(described_class::CONTENT_TYPES).to include('npc_memory', 'room_description', 'item_description')
    end

    it 'includes world_memory in CONTENT_TYPES' do
      expect(described_class::CONTENT_TYPES).to include('world_memory')
    end

    it 'includes helpfile in CONTENT_TYPES' do
      expect(described_class::CONTENT_TYPES).to include('helpfile')
    end

    it 'defines INPUT_TYPES' do
      expect(described_class::INPUT_TYPES).to eq(%w[document query])
    end
  end

  describe 'validations' do
    it 'validates presence of content_type' do
      e = Embedding.new(content_id: 1)
      expect(e.valid?).to be false
    end

    it 'validates presence of content_id' do
      e = Embedding.new(content_type: 'npc_memory')
      expect(e.valid?).to be false
    end

    it 'validates content_type inclusion' do
      e = Embedding.new(content_type: 'invalid_type', content_id: 1)
      expect(e.valid?).to be false
    end

    it 'validates input_type inclusion when set' do
      e = Embedding.new(content_type: 'npc_memory', content_id: 1, input_type: 'invalid')
      expect(e.valid?).to be false
    end

    it 'accepts valid input_type' do
      e = Embedding.new(content_type: 'npc_memory', content_id: 1, input_type: 'document')
      e.valid?
      # errors[:input_type] returns nil if no errors for that field
      expect(e.errors[:input_type]).to be_nil
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      expect(described_class.new).to respond_to(:character)
    end

    it 'belongs to room' do
      expect(described_class.new).to respond_to(:room)
    end

    it 'belongs to item' do
      expect(described_class.new).to respond_to(:item)
    end
  end

  describe '.exists_for?' do
    it 'returns false when no embedding exists' do
      expect(described_class.exists_for?(content_type: 'npc_memory', content_id: 999999)).to be false
    end
  end

  describe '.find_for' do
    it 'returns nil when no embedding exists' do
      expect(described_class.find_for(content_type: 'npc_memory', content_id: 999999)).to be_nil
    end
  end

  describe '.remove' do
    it 'returns 0 when no matching embeddings' do
      result = described_class.remove(content_type: 'npc_memory', content_id: 999999)
      expect(result).to eq(0)
    end
  end

  describe '.remove_for_character' do
    it 'returns 0 when no matching embeddings' do
      result = described_class.remove_for_character(999999)
      expect(result).to eq(0)
    end
  end

  describe '.remove_for_room' do
    it 'returns 0 when no matching embeddings' do
      result = described_class.remove_for_room(999999)
      expect(result).to eq(0)
    end
  end

  describe '#stale?' do
    it 'returns true when text has changed' do
      e = Embedding.new(content_hash: Digest::SHA256.hexdigest('old text'))
      expect(e.stale?('new text')).to be true
    end

    it 'returns false when text matches' do
      text = 'test text'
      e = Embedding.new(content_hash: Digest::SHA256.hexdigest(text))
      expect(e.stale?(text)).to be false
    end
  end
end
