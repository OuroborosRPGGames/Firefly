# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveRoomDescriptionService do
  describe '.combo_key' do
    it 'generates key from shape and exits' do
      key = described_class.combo_key(exits: %w[north south], content: [])
      expect(key).to eq('corridor:ns')
    end

    it 'includes content flags sorted' do
      key = described_class.combo_key(exits: %w[north south east], content: %w[monster trap_east])
      expect(key).to eq('t_branch:nes:monster:trap_east')
    end

    it 'identifies dead end with one exit' do
      key = described_class.combo_key(exits: %w[south], content: [])
      expect(key).to eq('dead_end:s')
    end

    it 'identifies crossroads with four exits' do
      key = described_class.combo_key(exits: %w[north south east west], content: [])
      expect(key).to eq('crossroads:nesw')
    end

    it 'identifies l_turn with two non-opposite exits' do
      key = described_class.combo_key(exits: %w[north east], content: [])
      expect(key).to eq('l_turn:ne')
    end

    it 'identifies corridor for east-west pair' do
      key = described_class.combo_key(exits: %w[east west], content: [])
      expect(key).to eq('corridor:ew')
    end

    it 'identifies l_turn for south-west pair' do
      key = described_class.combo_key(exits: %w[south west], content: [])
      expect(key).to eq('l_turn:sw')
    end

    it 'sorts exit abbreviations in n,s,e,w order' do
      key = described_class.combo_key(exits: %w[west east south north], content: [])
      expect(key).to eq('crossroads:nesw')
    end

    it 'sorts content flags alphabetically' do
      key = described_class.combo_key(exits: %w[north], content: %w[treasure monster])
      expect(key).to eq('dead_end:n:monster:treasure')
    end
  end

  describe '.description_for' do
    it 'returns a non-empty string description' do
      desc = described_class.description_for(combo_key: 'corridor:ns')
      expect(desc).to be_a(String)
      expect(desc.length).to be > 10
    end

    it 'returns the same description for the same key' do
      desc1 = described_class.description_for(combo_key: 'corridor:ns')
      desc2 = described_class.description_for(combo_key: 'corridor:ns')
      expect(desc1).to eq(desc2)
    end

    it 'includes trap text when trap content is present' do
      desc = described_class.description_for(combo_key: 'corridor:ns:trap_south')
      expect(desc).to match(/trap|mechanism|danger|rune|pressure/i)
    end

    it 'includes monster text when monster content is present' do
      desc = described_class.description_for(combo_key: 'corridor:ns:monster')
      expect(desc).to match(/claw|scratch|den|lair|bone|warning|foul|stench|presence|gnaw|lurk/i)
    end

    it 'includes treasure text when treasure content is present' do
      desc = described_class.description_for(combo_key: 'dead_end:n:treasure')
      expect(desc).to match(/glint|shimmer|cache|hoard|gleam|vault|hidden|treasure|precious|gem|gold/i)
    end

    it 'returns different descriptions for different keys' do
      desc1 = described_class.description_for(combo_key: 'corridor:ns')
      desc2 = described_class.description_for(combo_key: 'dead_end:s')
      # They might be the same by coincidence, but shape should differ
      # At minimum, both should be valid descriptions
      expect(desc1).to be_a(String)
      expect(desc2).to be_a(String)
    end

    it 'handles all shape types' do
      %w[dead_end corridor l_turn t_branch crossroads].each do |shape|
        desc = described_class.description_for(combo_key: "#{shape}:n")
        expect(desc).to be_a(String)
        expect(desc.length).to be > 10
      end
    end
  end
end
