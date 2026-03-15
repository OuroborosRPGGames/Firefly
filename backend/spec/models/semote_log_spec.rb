# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SemoteLog do
  let(:character) { create(:character) }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe 'validations' do
    it 'requires character_instance_id' do
      log = SemoteLog.new(emote_text: 'test')
      expect(log.valid?).to be false
    end

    it 'requires emote_text' do
      log = SemoteLog.new(character_instance_id: character_instance.id)
      expect(log.valid?).to be false
    end

    it 'is valid with required fields' do
      log = SemoteLog.new(
        character_instance_id: character_instance.id,
        emote_text: 'sits on the couch'
      )
      expect(log.valid?).to be true
    end
  end

  describe '.log_interpretation' do
    it 'creates a log entry with interpreted actions' do
      actions = [{ command: 'sit', target: 'couch' }]

      log = SemoteLog.log_interpretation(
        character_instance: character_instance,
        emote_text: 'sits on the couch',
        interpreted_actions: actions
      )

      expect(log.emote_text).to eq('sits on the couch')
      expect(log.parsed_interpreted_actions).to eq(actions)
    end
  end

  describe '#record_execution' do
    it 'records executed action results' do
      log = SemoteLog.create(
        character_instance_id: character_instance.id,
        emote_text: 'sits on the couch',
        interpreted_actions: [{ command: 'sit', target: 'couch' }]
      )

      log.record_execution(command: 'sit', target: 'couch', success: true)

      expect(log.parsed_executed_actions.first[:success]).to be true
    end
  end
end
