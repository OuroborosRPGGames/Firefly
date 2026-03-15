# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StaffBroadcastDelivery do
  describe 'associations' do
    it 'belongs to staff_broadcast' do
      expect(described_class.association_reflections[:staff_broadcast]).not_to be_nil
    end

    it 'belongs to character_instance' do
      expect(described_class.association_reflections[:character_instance]).not_to be_nil
    end
  end
end
