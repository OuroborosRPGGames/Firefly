# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveTreasureService do
  let(:room) { instance_double('DelveRoom', id: 1) }
  let(:treasure) do
    instance_double('DelveTreasure',
                    id: 1,
                    gold_value: 50,
                    container_type: 'chest',
                    looted?: false,
                    description: 'A wooden chest',
                    value_hint: 'substantial',
                    loot!: true)
  end
  let(:participant) do
    instance_double('DelveParticipant',
                    add_loot!: true,
                    loot_collected: 100)
  end

  describe 'class methods' do
    it 'responds to generate!' do
      expect(described_class).to respond_to(:generate!)
    end

    it 'responds to loot!' do
      expect(described_class).to respond_to(:loot!)
    end

    it 'responds to display_text' do
      expect(described_class).to respond_to(:display_text)
    end
  end

  describe '.generate!' do
    before do
      allow(DelveTreasure).to receive(:calculate_value).and_return(75)
      allow(DelveTreasure).to receive(:container_for_era).and_return('strongbox')
      allow(DelveTreasure).to receive(:create).and_return(treasure)
    end

    it 'calculates gold value based on level' do
      expect(DelveTreasure).to receive(:calculate_value).with(3)
      described_class.generate!(room, 3, :modern)
    end

    it 'selects era-appropriate container' do
      expect(DelveTreasure).to receive(:container_for_era).with(:modern)
      described_class.generate!(room, 3, :modern)
    end

    it 'creates a treasure record' do
      expect(DelveTreasure).to receive(:create).with(
        delve_room_id: room.id,
        gold_value: 75,
        container_type: 'strongbox'
      )
      described_class.generate!(room, 3, :modern)
    end

    it 'returns the created treasure' do
      result = described_class.generate!(room, 3, :modern)
      expect(result).to eq(treasure)
    end
  end

  describe '.loot!' do
    context 'when treasure has not been looted' do
      it 'adds gold to participant' do
        expect(participant).to receive(:add_loot!).with(50)
        described_class.loot!(participant, treasure)
      end

      it 'marks treasure as looted' do
        expect(treasure).to receive(:loot!)
        described_class.loot!(participant, treasure)
      end

      it 'returns success result' do
        result = described_class.loot!(participant, treasure)
        expect(result[:success]).to be true
        expect(result[:data][:looted]).to be true
      end

      it 'includes gold amount in data' do
        result = described_class.loot!(participant, treasure)
        expect(result[:data][:gold]).to eq(50)
      end

      it 'includes total loot in data' do
        result = described_class.loot!(participant, treasure)
        expect(result[:data][:total_loot]).to eq(100)
      end

      it 'includes descriptive message' do
        result = described_class.loot!(participant, treasure)
        expect(result[:message]).to include('chest')
        expect(result[:message]).to include('gold')
      end
    end

    context 'when treasure has already been looted' do
      before do
        allow(treasure).to receive(:looted?).and_return(true)
      end

      it 'does not add gold to participant' do
        expect(participant).not_to receive(:add_loot!)
        described_class.loot!(participant, treasure)
      end

      it 'returns failure result' do
        result = described_class.loot!(participant, treasure)
        expect(result[:success]).to be false
        expect(result[:data][:looted]).to be false
      end

      it 'includes appropriate message' do
        result = described_class.loot!(participant, treasure)
        expect(result[:message]).to include('already been emptied')
      end
    end
  end

  describe '.display_text' do
    it 'returns container type' do
      result = described_class.display_text(treasure)
      expect(result[:container]).to eq('chest')
    end

    it 'returns looted status' do
      result = described_class.display_text(treasure)
      expect(result[:looted]).to be false
    end

    it 'returns description' do
      result = described_class.display_text(treasure)
      expect(result[:description]).to eq('A wooden chest')
    end

    it 'returns value hint' do
      result = described_class.display_text(treasure)
      expect(result[:value_hint]).to eq('substantial')
    end
  end

  describe 'loot messages by value' do
    before do
      allow(treasure).to receive(:container_type).and_return('chest')
    end

    it 'uses modest message for low gold (0-10)' do
      allow(treasure).to receive(:gold_value).and_return(5)
      result = described_class.loot!(participant, treasure)
      expect(result[:message]).to include('pry open')
    end

    it 'uses standard message for medium gold (11-30)' do
      allow(treasure).to receive(:gold_value).and_return(20)
      result = described_class.loot!(participant, treasure)
      expect(result[:message]).to include('open')
    end

    it 'uses respectable message for good gold (31-60)' do
      allow(treasure).to receive(:gold_value).and_return(45)
      result = described_class.loot!(participant, treasure)
      expect(result[:message]).to include('respectable')
    end

    it 'uses excellent message for great gold (61-100)' do
      allow(treasure).to receive(:gold_value).and_return(80)
      result = described_class.loot!(participant, treasure)
      expect(result[:message]).to include('Excellent')
    end

    it 'uses ransom message for huge gold (100+)' do
      allow(treasure).to receive(:gold_value).and_return(150)
      result = described_class.loot!(participant, treasure)
      expect(result[:message]).to include('ransom')
    end
  end
end
