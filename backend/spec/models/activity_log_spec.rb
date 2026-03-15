# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityLog do
  # Use activity_instance_id directly since the factory has a transient that can cause issues
  let(:activity_instance) { create(:activity_instance) }

  # Helper to create log with proper activity_instance_id
  def create_log(**attrs)
    attrs[:activity_instance_id] ||= activity_instance.id
    create(:activity_log, **attrs)
  end

  def build_log(**attrs)
    attrs[:activity_instance_id] ||= activity_instance.id
    build(:activity_log, **attrs)
  end

  describe 'constants' do
    it 'defines LOG_TYPES' do
      expect(described_class::LOG_TYPES).to include('narrative', 'round_start', 'action', 'outcome')
    end

    it 'defines all expected log types' do
      expected = %w[narrative round_start round_end action outcome combat system summary]
      expect(described_class::LOG_TYPES).to match_array(expected)
    end

    it 'defines OUTCOMES' do
      expect(described_class::OUTCOMES).to eq(%w[success partial failure])
    end

    it 'defines VISIBILITY_LEVELS' do
      expect(described_class::VISIBILITY_LEVELS).to eq(%w[participants public private])
    end
  end

  describe 'associations' do
    it 'belongs to activity_instance' do
      log = create(:activity_log, activity_instance_id: activity_instance.id)
      expect(log.activity_instance).to eq(activity_instance)
    end

    it 'belongs to character' do
      character = create(:character)
      log = create(:activity_log, activity_instance_id: activity_instance.id, character: character)
      expect(log.character).to eq(character)
    end
  end

  describe 'validations' do
    # Use model directly for validation tests to avoid factory callbacks
    it 'requires activity_instance_id' do
      log = described_class.new(text: 'Test', log_type: 'action')
      expect(log.valid?).to be false
      expect(log.errors[:activity_instance_id]).to include('is not present')
    end

    it 'requires text' do
      log = described_class.new(activity_instance_id: activity_instance.id, log_type: 'action')
      expect(log.valid?).to be false
      expect(log.errors[:text]).to include('is not present')
    end

    it 'requires log_type' do
      log = described_class.new(activity_instance_id: activity_instance.id, text: 'Test')
      expect(log.valid?).to be false
      expect(log.errors[:log_type]).to include('is not present')
    end

    it 'validates log_type is in LOG_TYPES' do
      log = described_class.new(activity_instance_id: activity_instance.id, text: 'Test', log_type: 'invalid')
      expect(log.valid?).to be false
      expect(log.errors[:log_type]).not_to be_empty
    end

    it 'accepts valid log_type values' do
      described_class::LOG_TYPES.each do |log_type|
        log = described_class.new(activity_instance_id: activity_instance.id, text: 'Test', log_type: log_type)
        expect(log.valid?).to be true
      end
    end

    it 'validates outcome when present' do
      log = described_class.new(activity_instance_id: activity_instance.id, text: 'Test', log_type: 'action', outcome: 'invalid')
      expect(log.valid?).to be false
    end

    it 'accepts valid outcome values' do
      described_class::OUTCOMES.each do |outcome|
        log = described_class.new(activity_instance_id: activity_instance.id, text: 'Test', log_type: 'action', outcome: outcome)
        expect(log.valid?).to be true
      end
    end

    it 'allows nil outcome' do
      log = described_class.new(activity_instance_id: activity_instance.id, text: 'Test', log_type: 'action', outcome: nil)
      expect(log.valid?).to be true
    end
  end

  describe '#formatted_content' do
    it 'returns html_content when present' do
      log = create(:activity_log, activity_instance_id: activity_instance.id, text: 'plain', html_content: '<b>bold</b>')
      expect(log.formatted_content).to eq('<b>bold</b>')
    end

    it 'converts text to HTML when html_content is nil' do
      log = create(:activity_log, activity_instance_id: activity_instance.id, text: "line1\nline2", html_content: nil)
      expect(log.formatted_content).to include('<br>')
    end

    it 'escapes HTML entities in plain text' do
      log = create(:activity_log, activity_instance_id: activity_instance.id, text: '<script>alert(1)</script>', html_content: nil)
      expect(log.formatted_content).to include('&lt;script&gt;')
      expect(log.formatted_content).not_to include('<script>')
    end

    it 'handles nil text gracefully' do
      log = create(:activity_log, activity_instance_id: activity_instance.id)
      # Test the text_to_html private method directly
      expect(log.send(:text_to_html, nil)).to eq('')
    end
  end

  describe '#to_api_hash' do
    let(:character) { create(:character) }
    let(:log) do
      create(:activity_log,
             activity_instance_id: activity_instance.id,
             character: character,
             log_type: 'action',
             text: 'Test action',
             title: 'Test Title',
             round_number: 2,
             action_name: 'attack',
             outcome: 'success',
             roll_result: 15,
             difficulty: 10)
    end

    it 'includes id' do
      expect(log.to_api_hash[:id]).to eq(log.id)
    end

    it 'includes type' do
      expect(log.to_api_hash[:type]).to eq('action')
    end

    it 'includes title' do
      expect(log.to_api_hash[:title]).to eq('Test Title')
    end

    it 'includes text' do
      expect(log.to_api_hash[:text]).to eq('Test action')
    end

    it 'includes html' do
      expect(log.to_api_hash[:html]).to be_a(String)
    end

    it 'includes round_number' do
      expect(log.to_api_hash[:round_number]).to eq(2)
    end

    it 'includes action_name' do
      expect(log.to_api_hash[:action_name]).to eq('attack')
    end

    it 'includes outcome' do
      expect(log.to_api_hash[:outcome]).to eq('success')
    end

    it 'includes roll_result' do
      expect(log.to_api_hash[:roll_result]).to eq(15)
    end

    it 'includes difficulty' do
      expect(log.to_api_hash[:difficulty]).to eq(10)
    end

    it 'includes character info' do
      expect(log.to_api_hash[:character][:id]).to eq(character.id)
      expect(log.to_api_hash[:character][:name]).to eq(character.full_name)
    end

    it 'includes created_at as ISO8601' do
      expect(log.to_api_hash[:created_at]).to match(/\d{4}-\d{2}-\d{2}T/)
    end

    it 'handles nil character' do
      log_no_char = create(:activity_log, activity_instance_id: activity_instance.id, character: nil)
      expect(log_no_char.to_api_hash[:character]).to be_nil
    end
  end

  describe '.for_instance' do
    it 'returns logs for the given instance' do
      log1 = create(:activity_log, activity_instance_id: activity_instance.id, sequence: 1)
      log2 = create(:activity_log, activity_instance_id: activity_instance.id, sequence: 2)
      other_instance = create(:activity_instance)
      other_log = create(:activity_log, activity_instance_id: other_instance.id)

      logs = described_class.for_instance(activity_instance.id).all
      expect(logs).to include(log1, log2)
      expect(logs).not_to include(other_log)
    end

    it 'orders by sequence then created_at' do
      log2 = create(:activity_log, activity_instance_id: activity_instance.id, sequence: 2)
      log1 = create(:activity_log, activity_instance_id: activity_instance.id, sequence: 1)
      log3 = create(:activity_log, activity_instance_id: activity_instance.id, sequence: 3)

      logs = described_class.for_instance(activity_instance.id).all
      expect(logs.map(&:sequence)).to eq([1, 2, 3])
    end
  end

  describe '.for_round' do
    it 'returns logs for the given round' do
      log_r1 = create(:activity_log, activity_instance_id: activity_instance.id, round_number: 1)
      log_r2 = create(:activity_log, activity_instance_id: activity_instance.id, round_number: 2)

      logs = described_class.for_round(activity_instance.id, 1).all
      expect(logs).to include(log_r1)
      expect(logs).not_to include(log_r2)
    end
  end

  describe '.next_sequence' do
    it 'returns 1 for empty instance' do
      expect(described_class.next_sequence(activity_instance.id)).to eq(1)
    end

    it 'returns max + 1 for instance with logs' do
      create(:activity_log, activity_instance_id: activity_instance.id, sequence: 5)
      create(:activity_log, activity_instance_id: activity_instance.id, sequence: 3)

      expect(described_class.next_sequence(activity_instance.id)).to eq(6)
    end
  end
end
