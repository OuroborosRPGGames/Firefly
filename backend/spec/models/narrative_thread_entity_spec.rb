# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NarrativeThreadEntity, type: :model do
  describe 'validations' do
    let(:thread_entity) { create(:narrative_thread_entity) }

    it 'requires a narrative_thread_id' do
      thread_entity.narrative_thread_id = nil
      expect(thread_entity.valid?).to be false
    end

    it 'requires a narrative_entity_id' do
      thread_entity.narrative_entity_id = nil
      expect(thread_entity.valid?).to be false
    end

    it 'validates role is in allowed list when provided' do
      thread_entity.role = 'invalid_role'
      expect(thread_entity.valid?).to be false
    end

    it 'allows a nil role' do
      thread_entity.role = nil
      expect(thread_entity.valid?).to be true
    end

    it 'accepts all supported role values' do
      NarrativeThreadEntity::ROLES.each do |role|
        thread_entity.role = role
        expect(thread_entity.valid?).to be true
      end
    end
  end
end
