# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapTemplate do
  let(:hex_data) do
    [
      { 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'normal', 'traversable' => true },
      { 'hex_x' => 1, 'hex_y' => 0, 'hex_type' => 'wall', 'traversable' => false }
    ]
  end

  let(:template) do
    BattleMapTemplate.create(
      category: 'delve',
      shape_key: 'small_chamber',
      variant: 0,
      width_feet: 12.0,
      height_feet: 12.0,
      hex_data: Sequel.pg_jsonb_wrap(hex_data),
      image_url: 'https://example.com/map.png',
      description_hint: 'A small dungeon chamber'
    )
  end

  describe '.random_for' do
    it 'returns a template matching category and shape_key' do
      template # create it
      result = described_class.random_for('delve', 'small_chamber')
      expect(result).to eq(template)
    end

    it 'returns nil when no match' do
      expect(described_class.random_for('nonexistent', 'fake')).to be_nil
    end

    context 'with multiple variants' do
      let!(:variant0) do
        BattleMapTemplate.create(
          category: 'delve', shape_key: 'rect_vertical', variant: 0,
          width_feet: 6.0, height_feet: 18.0,
          hex_data: Sequel.pg_jsonb_wrap(hex_data),
          description_hint: 'Variant 0'
        )
      end
      let!(:variant1) do
        BattleMapTemplate.create(
          category: 'delve', shape_key: 'rect_vertical', variant: 1,
          width_feet: 6.0, height_feet: 18.0,
          hex_data: Sequel.pg_jsonb_wrap(hex_data),
          description_hint: 'Variant 1'
        )
      end

      it 'returns one of the matching templates' do
        result = described_class.random_for('delve', 'rect_vertical')
        expect([variant0, variant1]).to include(result)
      end
    end
  end

  describe '.for_shape' do
    before do
      BattleMapTemplate.create(
        category: 'delve', shape_key: 'large_chamber', variant: 0,
        width_feet: 20.0, height_feet: 20.0,
        hex_data: Sequel.pg_jsonb_wrap(hex_data),
        description_hint: 'Large 0'
      )
      BattleMapTemplate.create(
        category: 'delve', shape_key: 'large_chamber', variant: 1,
        width_feet: 20.0, height_feet: 20.0,
        hex_data: Sequel.pg_jsonb_wrap(hex_data),
        description_hint: 'Large 1'
      )
    end

    it 'returns all templates for category and shape' do
      results = described_class.for_shape('delve', 'large_chamber')
      expect(results.length).to eq(2)
    end

    it 'returns empty when no match' do
      expect(described_class.for_shape('delve', 'nonexistent')).to be_empty
    end
  end

  describe '#touch!' do
    it 'updates last_used_at' do
      template.update(last_used_at: nil)
      template.touch!
      template.reload

      expect(template.last_used_at).not_to be_nil
      expect(template.last_used_at).to be_within(2).of(Time.now)
    end
  end

  describe 'hex_data storage' do
    it 'stores and retrieves JSONB hex data' do
      data = template.hex_data.to_a
      expect(data.length).to eq(2)
      expect(data.first['hex_type']).to eq('normal')
    end
  end
end
