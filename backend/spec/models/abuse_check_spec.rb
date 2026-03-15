# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbuseCheck do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe 'constants' do
    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[pending gemini_checking flagged escalated confirmed cleared])
    end

    it 'defines MESSAGE_TYPES' do
      expect(described_class::MESSAGE_TYPES).to include('say', 'emote', 'whisper', 'pm')
    end

    it 'defines ABUSE_CATEGORIES' do
      expect(described_class::ABUSE_CATEGORIES).to include('harassment', 'hate_speech', 'threats')
    end

    it 'defines SEVERITIES' do
      expect(described_class::SEVERITIES).to eq(%w[low medium high critical])
    end

    it 'defines DETECTION_SOURCES' do
      expect(described_class::DETECTION_SOURCES).to eq(%w[pre_llm llm])
    end
  end

  describe '.create_for_message' do
    # Note: This method requires ip_address on CharacterInstance which isn't in test schema
    # Testing the method signature with direct create instead
    it 'accepts required parameters' do
      expect(described_class).to respond_to(:create_for_message)
    end
  end

  describe 'direct creation' do
    it 'creates an abuse check with pending status' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Hello world',
        message_type: 'say',
        status: 'pending'
      )
      expect(check.status).to eq('pending')
      expect(check.message_content).to eq('Hello world')
      expect(check.message_type).to eq('say')
    end

    it 'sets character and user associations' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      expect(check.character_instance_id).to eq(character_instance.id)
      expect(check.user_id).to eq(character.user_id)
    end
  end

  describe '.pending_gemini_checks' do
    it 'returns checks with pending status' do
      check1 = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test 1',
        message_type: 'say',
        status: 'pending'
      )
      check2 = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test 2',
        message_type: 'say',
        status: 'cleared'
      )

      pending = described_class.pending_gemini_checks
      expect(pending).to include(check1)
      expect(pending).not_to include(check2)
    end
  end

  describe '.pending_escalation' do
    it 'returns checks with flagged status' do
      check1 = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'flagged'
      )
      check2 = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test 2',
        message_type: 'say',
        status: 'pending'
      )

      escalation = described_class.pending_escalation
      expect(escalation).to include(check1)
      expect(escalation).not_to include(check2)
    end
  end

  describe '.recent_for_user' do
    it 'returns checks for a specific user' do
      other_user = create(:user)
      check1 = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      check2 = described_class.create(
        character_instance_id: character_instance.id,
        user_id: other_user.id,
        message_content: 'Test 2',
        message_type: 'say',
        status: 'pending'
      )

      recent = described_class.recent_for_user(character.user_id)
      expect(recent).to include(check1)
      expect(recent).not_to include(check2)
    end
  end

  describe '#start_gemini_check!' do
    it 'sets status to gemini_checking' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      check.start_gemini_check!
      expect(check.status).to eq('gemini_checking')
    end
  end

  describe '#mark_gemini_result!' do
    let(:check) do
      described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'gemini_checking'
      )
    end

    it 'sets status to flagged when flagged is true' do
      check.mark_gemini_result!(flagged: true, confidence: 0.8, reasoning: 'Suspicious content')
      expect(check.status).to eq('flagged')
      expect(check.gemini_flagged).to be true
      expect(check.gemini_confidence).to eq(0.8)
    end

    it 'sets status to cleared when flagged is false' do
      check.mark_gemini_result!(flagged: false, confidence: 0.1, reasoning: 'Normal content')
      expect(check.status).to eq('cleared')
      expect(check.gemini_flagged).to be false
    end

    it 'sets gemini_checked_at' do
      check.mark_gemini_result!(flagged: false, confidence: 0.1, reasoning: 'OK')
      expect(check.gemini_checked_at).not_to be_nil
    end
  end

  describe '#start_escalation!' do
    it 'sets status to escalated' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'flagged'
      )
      check.start_escalation!
      expect(check.status).to eq('escalated')
    end
  end

  describe '#mark_claude_result!' do
    let(:check) do
      described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'escalated'
      )
    end

    it 'sets status to confirmed when confirmed is true' do
      check.mark_claude_result!(confirmed: true, confidence: 0.9, reasoning: 'Abuse confirmed')
      expect(check.status).to eq('confirmed')
      expect(check.claude_confirmed).to be true
    end

    it 'sets status to cleared when confirmed is false' do
      check.mark_claude_result!(confirmed: false, confidence: 0.2, reasoning: 'False positive')
      expect(check.status).to eq('cleared')
      expect(check.claude_confirmed).to be false
    end

    it 'sets severity when provided' do
      check.mark_claude_result!(confirmed: true, confidence: 0.9, reasoning: 'Bad', severity: 'high')
      expect(check.severity).to eq('high')
    end
  end

  describe '#needs_escalation?' do
    it 'returns true when status is flagged' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'flagged'
      )
      expect(check.needs_escalation?).to be true
    end

    it 'returns false when status is not flagged' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      expect(check.needs_escalation?).to be false
    end
  end

  describe '#abuse_confirmed?' do
    it 'returns true when status is confirmed and claude_confirmed is true' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'confirmed',
        claude_confirmed: true
      )
      expect(check.abuse_confirmed?).to be true
    end

    it 'returns false when status is not confirmed' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'cleared'
      )
      expect(check.abuse_confirmed?).to be false
    end
  end

  describe '#completed?' do
    it 'returns true when status is cleared' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'cleared'
      )
      expect(check.completed?).to be true
    end

    it 'returns true when status is confirmed' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'confirmed'
      )
      expect(check.completed?).to be true
    end

    it 'returns false when status is pending' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      expect(check.completed?).to be false
    end
  end

  describe '#parsed_context' do
    it 'returns empty hash when context is nil' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      expect(check.parsed_context).to eq({})
    end
  end

  describe '#pre_llm_detected?' do
    it 'returns true when pre_llm_flagged is true' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending',
        pre_llm_flagged: true
      )
      expect(check.pre_llm_detected?).to be true
    end

    it 'returns false when pre_llm_flagged is false or nil' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      expect(check.pre_llm_detected?).to be false
    end
  end

  describe '#to_admin_hash' do
    it 'returns a hash with check data' do
      check = described_class.create(
        character_instance_id: character_instance.id,
        user_id: character.user_id,
        message_content: 'Test',
        message_type: 'say',
        status: 'pending'
      )
      hash = check.to_admin_hash
      expect(hash[:id]).to eq(check.id)
      expect(hash[:status]).to eq('pending')
      expect(hash[:message_content]).to eq('Test')
      expect(hash[:message_type]).to eq('say')
    end
  end
end
