# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BodyPosition do
  describe 'validations' do
    it 'is valid with valid attributes' do
      position = described_class.create(label: 'left_eye', region: 'head')
      expect(position).to be_valid
    end

    it 'requires label' do
      position = described_class.new(region: 'head')
      expect(position).not_to be_valid
    end

    it 'validates uniqueness of label' do
      described_class.create(label: 'unique_part')
      duplicate = described_class.new(label: 'unique_part')
      expect(duplicate).not_to be_valid
    end

    it 'validates max length of label (50 chars)' do
      position = described_class.new(label: 'x' * 51)
      expect(position).not_to be_valid
    end
  end

  describe 'associations' do
    it 'has many item_body_positions' do
      position = create(:body_position)
      expect(position).to respond_to(:item_body_positions)
    end

    it 'has many description_type_body_positions' do
      position = create(:body_position)
      expect(position).to respond_to(:description_type_body_positions)
    end
  end

  describe '#is_private?' do
    it 'returns true when is_private is true' do
      position = create(:body_position, :private)
      expect(position.is_private?).to be true
    end

    it 'returns false when is_private is false' do
      position = create(:body_position, is_private: false)
      expect(position.is_private?).to be false
    end
  end

  describe '#to_s' do
    it 'returns the label' do
      position = create(:body_position, label: 'left_arm')
      expect(position.to_s).to eq('left_arm')
    end
  end

  describe '.by_label' do
    it 'finds position by label' do
      position = described_class.create(label: 'right_hand')
      expect(described_class.by_label('right_hand')).to eq(position)
    end

    it 'returns nil when not found' do
      expect(described_class.by_label('nonexistent')).to be_nil
    end
  end

  describe '.private_positions' do
    it 'returns only private positions' do
      public_pos = described_class.create(label: 'public_part', is_private: false)
      private_pos = described_class.create(label: 'private_part', is_private: true)

      result = described_class.private_positions.all
      expect(result).to include(private_pos)
      expect(result).not_to include(public_pos)
    end
  end

  describe '.public_positions' do
    it 'returns only public positions' do
      public_pos = described_class.create(label: 'visible_part', is_private: false)
      private_pos = described_class.create(label: 'hidden_part', is_private: true)

      result = described_class.public_positions.all
      expect(result).to include(public_pos)
      expect(result).not_to include(private_pos)
    end
  end

  describe '.by_region' do
    it 'returns positions for specified region' do
      head_pos = described_class.create(label: 'forehead', region: 'head')
      torso_pos = described_class.create(label: 'chest', region: 'torso')

      result = described_class.by_region('head').all
      expect(result).to include(head_pos)
      expect(result).not_to include(torso_pos)
    end
  end

  describe '.ordered' do
    it 'returns positions ordered by display_order' do
      pos3 = described_class.create(label: 'third', display_order: 3)
      pos1 = described_class.create(label: 'first', display_order: 1)
      pos2 = described_class.create(label: 'second', display_order: 2)

      result = described_class.ordered.all
      display_orders = result.map(&:display_order)
      expect(display_orders).to eq(display_orders.sort)
    end
  end

  describe 'region helper methods' do
    before do
      described_class.create(label: 'forehead', region: 'head')
      described_class.create(label: 'chest', region: 'torso')
      described_class.create(label: 'bicep', region: 'arms')
      described_class.create(label: 'palm', region: 'hands')
      described_class.create(label: 'thigh', region: 'legs')
      described_class.create(label: 'ankle', region: 'feet')
    end

    it '.head_positions returns head region positions' do
      result = described_class.head_positions.all
      expect(result.all? { |p| p.region == 'head' }).to be true
    end

    it '.torso_positions returns torso region positions' do
      result = described_class.torso_positions.all
      expect(result.all? { |p| p.region == 'torso' }).to be true
    end

    it '.arm_positions returns arms region positions' do
      result = described_class.arm_positions.all
      expect(result.all? { |p| p.region == 'arms' }).to be true
    end

    it '.hand_positions returns hands region positions' do
      result = described_class.hand_positions.all
      expect(result.all? { |p| p.region == 'hands' }).to be true
    end

    it '.leg_positions returns legs region positions' do
      result = described_class.leg_positions.all
      expect(result.all? { |p| p.region == 'legs' }).to be true
    end

    it '.foot_positions returns feet region positions' do
      result = described_class.foot_positions.all
      expect(result.all? { |p| p.region == 'feet' }).to be true
    end
  end
end
