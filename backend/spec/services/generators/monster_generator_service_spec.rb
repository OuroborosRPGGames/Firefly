# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::MonsterGeneratorService do
  describe 'constants' do
    it 'defines MONSTER_MODEL' do
      expect(described_class::MONSTER_MODEL).to include(:provider, :model)
    end

    it 'defines MONSTER_KEYWORDS with dragon-related words' do
      expect(described_class::MONSTER_KEYWORDS).to include('dragon', 'wyrm', 'behemoth')
    end

    it 'defines MONSTER_KEYWORDS with size words' do
      expect(described_class::MONSTER_KEYWORDS).to include('massive', 'enormous', 'huge', 'colossal')
    end

    it 'defines MONSTER_ROLES as boss only' do
      expect(described_class::MONSTER_ROLES).to eq([:boss])
    end

    it 'defines DEFAULT_SEGMENTS for dragon' do
      dragon = described_class::DEFAULT_SEGMENTS[:dragon]
      expect(dragon).to be_an(Array)
      expect(dragon.map { |s| s[:name] }).to include('Head', 'Body', 'Tail', 'Wings')
    end

    it 'defines DEFAULT_SEGMENTS for colossus' do
      colossus = described_class::DEFAULT_SEGMENTS[:colossus]
      expect(colossus.map { |s| s[:name] }).to include('Core', 'Torso', 'Legs')
    end

    it 'defines DEFAULT_SEGMENTS for hydra with multiple heads' do
      hydra = described_class::DEFAULT_SEGMENTS[:hydra]
      heads = hydra.select { |s| s[:segment_type] == 'head' }
      expect(heads.length).to eq(3)
    end

    it 'defines DEFAULT_SEGMENTS for serpent' do
      serpent = described_class::DEFAULT_SEGMENTS[:serpent]
      expect(serpent.map { |s| s[:segment_type] }).to include('head', 'body', 'tail')
    end

    it 'defines MONSTER_TYPE_KEYWORDS for classification' do
      expect(described_class::MONSTER_TYPE_KEYWORDS.keys).to include(
        :dragon, :colossus, :hydra, :serpent, :golem, :beast
      )
    end

    it 'maps dragon keywords correctly' do
      expect(described_class::MONSTER_TYPE_KEYWORDS[:dragon]).to include('dragon', 'wyrm', 'drake')
    end
  end

  describe '.should_be_monster?' do
    context 'with boss role' do
      it 'returns true for dragon in name' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A fearsome beast' }

        result = described_class.should_be_monster?(adversary: adversary, role: :boss)

        expect(result).to be true
      end

      it 'returns true for monster keyword in description' do
        adversary = { 'name' => 'Scourge', 'description' => 'An ancient behemoth' }

        result = described_class.should_be_monster?(adversary: adversary, role: :boss)

        expect(result).to be true
      end

      it 'returns true when is_monster flag is set' do
        adversary = { 'name' => 'The Guardian', 'description' => 'A warrior', 'is_monster' => true }

        result = described_class.should_be_monster?(adversary: adversary, role: :boss)

        expect(result).to be true
      end

      it 'returns false for normal boss without keywords' do
        adversary = { 'name' => 'Dark Mage', 'description' => 'A powerful wizard' }

        result = described_class.should_be_monster?(adversary: adversary, role: :boss)

        expect(result).to be false
      end

      it 'detects size keywords' do
        adversary = { 'name' => 'Terror', 'description' => 'A massive spider' }

        result = described_class.should_be_monster?(adversary: adversary, role: :boss)

        expect(result).to be true
      end

      it 'detects construct keywords' do
        adversary = { 'name' => 'Iron Sentinel', 'description' => 'A towering golem' }

        result = described_class.should_be_monster?(adversary: adversary, role: :boss)

        expect(result).to be true
      end
    end

    context 'with non-boss roles' do
      it 'returns false for lieutenant with monster keywords' do
        adversary = { 'name' => 'Baby Dragon', 'description' => 'A small dragon' }

        result = described_class.should_be_monster?(adversary: adversary, role: :lieutenant)

        expect(result).to be false
      end

      it 'returns false for minion with monster keywords' do
        adversary = { 'name' => 'Drake Hatchling', 'description' => 'A young wyrm' }

        result = described_class.should_be_monster?(adversary: adversary, role: :minion)

        expect(result).to be false
      end

      it 'accepts string role and converts' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'Mighty' }

        result = described_class.should_be_monster?(adversary: adversary, role: 'boss')

        expect(result).to be true
      end
    end
  end

  describe '.generate_monster' do
    let(:archetype) do
      double('NpcArchetype', id: 1, combat_max_hp: 50)
    end
    let(:monster_template) do
      double('MonsterTemplate', id: 100)
    end
    let(:segment_template) do
      double('MonsterSegmentTemplate', id: 200)
    end

    before do
      allow(MonsterTemplate).to receive(:create).and_return(monster_template)
      allow(MonsterSegmentTemplate).to receive(:create).and_return(segment_template)
    end

    it 'creates monster template with correct attributes' do
      adversary = { 'name' => 'Fire Dragon', 'description' => 'Ancient fire dragon' }

      expect(MonsterTemplate).to receive(:create).with(
        hash_including(
          name: 'Fire Dragon',
          monster_type: 'dragon',
          total_hp: 150, # 50 * 3 = 150
          npc_archetype_id: 1
        )
      )

      described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
    end

    it 'uses minimum HP of 80 for weak archetypes' do
      weak_archetype = double('NpcArchetype', id: 2, combat_max_hp: 10)
      adversary = { 'name' => 'Small Golem', 'description' => 'A golem' }

      expect(MonsterTemplate).to receive(:create).with(
        hash_including(total_hp: 80) # [10*3=30, 80].max = 80
      )

      described_class.generate_monster(archetype: weak_archetype, adversary: adversary, setting: :fantasy)
    end

    it 'creates segment templates for dragon' do
      adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

      # Dragon has 6 segments
      expect(MonsterSegmentTemplate).to receive(:create).exactly(6).times

      described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
    end

    it 'returns success with monster template and segments' do
      adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

      result = described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)

      expect(result[:success]).to be true
      expect(result[:monster_template]).to eq(monster_template)
      expect(result[:segments].length).to eq(6)
    end

    context 'with different monster types' do
      it 'creates colossus segments for titan' do
        adversary = { 'name' => 'Stone Titan', 'description' => 'An ancient titan' }

        # Colossus has 5 segments
        expect(MonsterSegmentTemplate).to receive(:create).exactly(5).times

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end

      it 'creates hydra segments for multi-headed creature' do
        adversary = { 'name' => 'Swamp Hydra', 'description' => 'A hydra' }

        # Hydra has 5 segments (3 heads + body + tail)
        expect(MonsterSegmentTemplate).to receive(:create).exactly(5).times

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end

      it 'creates serpent segments for leviathan' do
        adversary = { 'name' => 'Sea Leviathan', 'description' => 'A leviathan' }

        # Serpent has 4 segments
        expect(MonsterSegmentTemplate).to receive(:create).exactly(4).times

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end

      it 'creates golem segments for construct' do
        adversary = { 'name' => 'Iron Golem', 'description' => 'A golem' }

        # Golem has 5 segments
        expect(MonsterSegmentTemplate).to receive(:create).exactly(5).times

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end

      it 'defaults to beast for unknown monster type' do
        adversary = { 'name' => 'Horrible Monster', 'description' => 'A terrible creature' }

        # Beast has 4 segments
        expect(MonsterSegmentTemplate).to receive(:create).exactly(4).times

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end
    end

    context 'segment attributes' do
      it 'sets weak point on head segment' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

        expect(MonsterSegmentTemplate).to receive(:create).with(
          hash_including(
            name: 'Head',
            is_weak_point: true
          )
        ).at_least(:once)

        allow(MonsterSegmentTemplate).to receive(:create).and_return(segment_template)

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end

      it 'marks mobility segments correctly' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

        expect(MonsterSegmentTemplate).to receive(:create).with(
          hash_including(
            name: 'Left Claw',
            required_for_mobility: true
          )
        ).at_least(:once)

        allow(MonsterSegmentTemplate).to receive(:create).and_return(segment_template)

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end

      it 'calculates segment HP from total HP percentage' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }
        # Dragon body is 30% of HP. With archetype HP 50, total is 150.
        # Body HP would be 150 * 0.30 = 45

        # We check that create is called with the monster_template_id
        expect(MonsterSegmentTemplate).to receive(:create).with(
          hash_including(
            monster_template_id: 100,
            hp_allocation_percent: 30  # Body is 30%
          )
        ).at_least(:once)

        allow(MonsterSegmentTemplate).to receive(:create).and_return(segment_template)

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end
    end

    context 'when error occurs' do
      before do
        allow(MonsterTemplate).to receive(:create).and_raise(StandardError, 'Database error')
      end

      it 'returns failure result' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

        result = described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Database error')
      end

      it 'returns empty segments array' do
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

        result = described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)

        expect(result[:segments]).to eq([])
      end
    end

    context 'with nil description' do
      it 'uses name as fallback for description' do
        adversary = { 'name' => 'Fire Dragon', 'description' => nil }

        expect(MonsterTemplate).to receive(:create).with(
          hash_including(monster_type: 'dragon')
        )

        described_class.generate_monster(archetype: archetype, adversary: adversary, setting: :fantasy)
      end
    end

    context 'with nil archetype HP' do
      it 'uses default HP of 30 when nil' do
        nil_hp_archetype = double('NpcArchetype', id: 3, combat_max_hp: nil)
        adversary = { 'name' => 'Fire Dragon', 'description' => 'A dragon' }

        # base_hp = nil || 30 = 30, total_hp = [30*3=90, 80].max = 90
        expect(MonsterTemplate).to receive(:create).with(
          hash_including(total_hp: 90)
        )

        described_class.generate_monster(archetype: nil_hp_archetype, adversary: adversary, setting: :fantasy)
      end
    end
  end

  describe 'private methods' do
    describe '#detect_monster_type' do
      it 'detects dragon type' do
        result = described_class.send(:detect_monster_type, 'An ancient fire dragon')
        expect(result).to eq(:dragon)
      end

      it 'detects wyrm as dragon' do
        result = described_class.send(:detect_monster_type, 'A frost wyrm')
        expect(result).to eq(:dragon)
      end

      it 'detects colossus type' do
        result = described_class.send(:detect_monster_type, 'A stone colossus')
        expect(result).to eq(:colossus)
      end

      it 'detects titan as colossus' do
        result = described_class.send(:detect_monster_type, 'An earth titan')
        expect(result).to eq(:colossus)
      end

      it 'detects hydra type' do
        result = described_class.send(:detect_monster_type, 'A swamp hydra')
        expect(result).to eq(:hydra)
      end

      it 'detects multi-headed as hydra' do
        result = described_class.send(:detect_monster_type, 'A multi-headed serpent')
        expect(result).to eq(:hydra)
      end

      it 'detects serpent type' do
        result = described_class.send(:detect_monster_type, 'A sea serpent')
        expect(result).to eq(:serpent)
      end

      it 'detects leviathan as serpent' do
        result = described_class.send(:detect_monster_type, 'A leviathan rises')
        expect(result).to eq(:serpent)
      end

      it 'detects golem keyword (matches colossus first due to hash order)' do
        # "golem" is in both colossus and golem keywords, colossus comes first
        result = described_class.send(:detect_monster_type, 'An iron golem')
        expect(result).to eq(:colossus)
      end

      it 'detects automaton as golem (unique to golem keywords)' do
        result = described_class.send(:detect_monster_type, 'A magical automaton')
        expect(result).to eq(:golem)
      end

      it 'detects beast type' do
        result = described_class.send(:detect_monster_type, 'A massive beast')
        expect(result).to eq(:beast)
      end

      it 'detects tarrasque as beast' do
        result = described_class.send(:detect_monster_type, 'A tarrasque')
        expect(result).to eq(:beast)
      end

      it 'defaults to beast for unknown' do
        result = described_class.send(:detect_monster_type, 'A mysterious entity')
        expect(result).to eq(:beast)
      end

      it 'handles nil description' do
        result = described_class.send(:detect_monster_type, nil)
        expect(result).to eq(:beast)
      end

      it 'is case insensitive' do
        result = described_class.send(:detect_monster_type, 'A MIGHTY DRAGON')
        expect(result).to eq(:dragon)
      end
    end
  end
end
