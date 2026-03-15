# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DescriptionTypeBodyPosition, type: :model do
  describe 'associations' do
    it 'belongs to description_type' do
      expect(described_class.association_reflections[:description_type]).not_to be_nil
    end

    it 'belongs to body_position' do
      expect(described_class.association_reflections[:body_position]).not_to be_nil
    end

    it 'can connect a description type and body position' do
      desc_type = create(:description_type)
      body_position = create(:body_position)
      join = described_class.create(description_type_id: desc_type.id, body_position_id: body_position.id)

      expect(join.description_type).to eq(desc_type)
      expect(join.body_position).to eq(body_position)
      expect(desc_type.description_type_body_positions).to include(join)
      expect(body_position.description_type_body_positions).to include(join)
    end
  end
end
