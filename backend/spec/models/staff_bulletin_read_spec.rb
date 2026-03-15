# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StaffBulletinRead do
  describe 'associations' do
    it 'belongs to staff_bulletin' do
      expect(described_class.association_reflections[:staff_bulletin]).not_to be_nil
    end

    it 'belongs to user' do
      expect(described_class.association_reflections[:user]).not_to be_nil
    end
  end

  describe 'basic functionality' do
    it 'has staff_bulletin_id accessor' do
      expect(described_class.instance_methods).to include(:staff_bulletin_id)
    end

    it 'has user_id accessor' do
      expect(described_class.instance_methods).to include(:user_id)
    end
  end
end
