# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterDefaultDescription do
  let(:character) { create(:character) }
  let(:body_position) { create(:body_position, label: 'left_eye', region: 'head') }

  describe 'validations' do
    it 'is valid with valid attributes' do
      description = described_class.create(
        character: character,
        body_position: body_position,
        content: 'A bright blue eye'
      )
      expect(description).to be_valid
    end

    it 'requires character_id' do
      description = described_class.new(body_position: body_position, content: 'Test')
      expect(description).not_to be_valid
    end

    it 'does not require body_position_id (positions can be in join table)' do
      description = described_class.new(character: character, content: 'Test')
      expect(description).to be_valid
    end

    it 'requires content' do
      description = described_class.new(character: character, body_position: body_position)
      expect(description).not_to be_valid
    end

    it 'validates description_type is one of the allowed values' do
      description = described_class.new(
        character: character,
        content: 'Test',
        description_type: 'invalid'
      )
      expect(description).not_to be_valid
      expect(description.errors[:description_type]).not_to be_empty
    end

    it 'allows valid description types' do
      %w[natural tattoo makeup hairstyle].each do |type|
        description = described_class.new(
          character: character,
          content: 'Test',
          description_type: type
        )
        expect(description).to be_valid
      end
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      description = create(:character_default_description, character: character, body_position: body_position)
      expect(description.character).to eq(character)
    end

    it 'belongs to body_position' do
      description = create(:character_default_description, character: character, body_position: body_position)
      expect(description.body_position).to eq(body_position)
    end

    it 'has many body_positions through join table' do
      description = create(:character_default_description, character: character, content: 'Test')
      pos1 = create(:body_position, label: 'upper_back', region: 'torso')
      pos2 = create(:body_position, label: 'mid_back', region: 'torso')

      description.add_body_position(pos1)
      description.add_body_position(pos2)

      expect(description.body_positions).to include(pos1, pos2)
    end
  end

  describe '#region' do
    it 'returns the body_position region' do
      description = create(:character_default_description, character: character, body_position: body_position)
      expect(description.region).to eq('head')
    end

    it 'returns nil when body_position is nil and no positions in join table' do
      description = described_class.new(character: character, content: 'Test')
      expect(description.region).to be_nil
    end
  end

  describe '#all_positions' do
    it 'returns positions from join table' do
      description = create(:character_default_description, character: character, content: 'Test')
      pos1 = create(:body_position, label: 'upper_back', region: 'torso')
      description.add_body_position(pos1)

      expect(description.all_positions).to eq([pos1])
    end

    it 'falls back to legacy body_position if join table is empty' do
      description = create(:character_default_description, character: character, body_position: body_position)
      expect(description.all_positions).to eq([body_position])
    end
  end

  describe '#position_labels' do
    it 'returns humanized labels for all positions' do
      description = create(:character_default_description, character: character, content: 'Test')
      pos1 = create(:body_position, label: 'upper_back', region: 'torso')
      pos2 = create(:body_position, label: 'mid_back', region: 'torso')

      description.add_body_position(pos1)
      description.add_body_position(pos2)

      expect(description.position_labels).to include('Upper Back', 'Mid Back')
    end
  end

  describe '#position_label' do
    it 'returns humanized label' do
      body_position.update(label: 'left_eye')
      description = create(:character_default_description, character: character, body_position: body_position)
      expect(description.position_label).to eq('Left Eye')
    end

    it 'returns nil when no positions' do
      description = described_class.new(character: character, content: 'Test')
      expect(description.position_label).to be_nil
    end
  end

  describe '#hidden_by_clothing?' do
    it 'returns true when concealed_by_clothing and active' do
      description = create(:character_default_description,
                           character: character,
                           body_position: body_position,
                           concealed_by_clothing: true,
                           active: true)
      expect(description.hidden_by_clothing?).to be true
    end

    it 'returns false when not concealed_by_clothing' do
      description = create(:character_default_description,
                           character: character,
                           body_position: body_position,
                           concealed_by_clothing: false,
                           active: true)
      expect(description.hidden_by_clothing?).to be false
    end

    it 'returns false when not active' do
      description = create(:character_default_description,
                           character: character,
                           body_position: body_position,
                           concealed_by_clothing: true,
                           active: false)
      expect(description.hidden_by_clothing?).to be false
    end
  end

  describe 'type helpers' do
    it '#natural? returns true for natural type' do
      description = described_class.new(description_type: 'natural')
      expect(description.natural?).to be true
      expect(description.tattoo?).to be false
    end

    it '#tattoo? returns true for tattoo type' do
      description = described_class.new(description_type: 'tattoo')
      expect(description.tattoo?).to be true
      expect(description.natural?).to be false
    end

    it '#makeup? returns true for makeup type' do
      description = described_class.new(description_type: 'makeup')
      expect(description.makeup?).to be true
    end

    it '#hairstyle? returns true for hairstyle type' do
      description = described_class.new(description_type: 'hairstyle')
      expect(description.hairstyle?).to be true
    end
  end

  describe '.valid_positions_for_type' do
    it 'returns all positions for tattoo type' do
      positions = described_class.valid_positions_for_type('tattoo')
      expect(positions.count).to eq(BodyPosition.count)
    end

    it 'returns only face positions for makeup type' do
      positions = described_class.valid_positions_for_type('makeup')
      expect(positions.map(&:label)).to all(be_in(described_class::MAKEUP_POSITIONS))
    end

    it 'returns only scalp for hairstyle type' do
      # Create the scalp position if it doesn't exist
      create(:body_position, label: 'scalp', region: 'head') unless BodyPosition.first(label: 'scalp')

      positions = described_class.valid_positions_for_type('hairstyle')
      expect(positions.map(&:label)).to eq(['scalp'])
    end
  end

  describe 'dataset methods' do
    let(:other_body_position) { create(:body_position, label: 'right_eye', region: 'head') }
    let(:torso_position) { create(:body_position, label: 'chest', region: 'torso') }

    before do
      @desc1 = described_class.create(
        character: character,
        body_position: body_position,
        content: 'First',
        display_order: 2,
        active: true,
        description_type: 'natural'
      )
      @desc2 = described_class.create(
        character: character,
        body_position: other_body_position,
        content: 'Second',
        display_order: 1,
        active: true,
        description_type: 'tattoo'
      )
      @desc3 = described_class.create(
        character: character,
        body_position: torso_position,
        content: 'Third',
        display_order: 3,
        active: false,
        description_type: 'natural'
      )
    end

    describe '.ordered' do
      it 'returns descriptions ordered by display_order' do
        result = described_class.where(character_id: character.id).ordered.all
        expect(result.map(&:display_order)).to eq([1, 2, 3])
      end
    end

    describe '.active_only' do
      it 'returns only active descriptions' do
        result = described_class.where(character_id: character.id).active_only.all
        expect(result).to include(@desc1, @desc2)
        expect(result).not_to include(@desc3)
      end
    end

    describe '.by_type' do
      it 'returns descriptions of the specified type' do
        result = described_class.where(character_id: character.id).by_type('tattoo').all
        expect(result).to eq([@desc2])
      end
    end

    describe '.tattoos' do
      it 'returns only tattoo descriptions' do
        result = described_class.where(character_id: character.id).tattoos.all
        expect(result).to eq([@desc2])
      end
    end

    describe '.by_region' do
      it 'returns descriptions for the specified region' do
        result = described_class.where(character_id: character.id).by_region('head')
        expect(result).to include(@desc1, @desc2)
        expect(result).not_to include(@desc3)
      end
    end
  end
end
