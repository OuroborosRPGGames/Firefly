# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::MissionRoundDetailService do
  describe '.detail_rounds' do
    let(:concept_plan) do
      {
        'title' => 'The Duke\'s Secret',
        'summary' => 'A daring heist into the Duke\'s manor.',
        'theme' => 'corruption',
        'tone_adjectives' => %w[tense dark],
        'rounds' => [
          {
            'round_number' => 1,
            'branch' => 0,
            'rtype' => 'standard',
            'narrative' => 'The party approaches the manor gates under cover of darkness.',
            'fail_con' => 'none',
            'is_finale' => false,
            'location_key' => 'manor_gate'
          },
          {
            'round_number' => 2,
            'branch' => 0,
            'rtype' => 'combat',
            'narrative' => 'Guards discover the intruders.',
            'fail_con' => 'injury',
            'is_finale' => false,
            'combat_encounter_key' => 'manor_guards'
          }
        ],
        'adversaries' => [
          { 'name' => 'Manor Guard', 'role' => 'minion', 'combat_encounter_key' => 'manor_guards', 'description' => 'A burly guard' }
        ],
        'locations' => [
          { 'key' => 'manor_gate', 'name' => 'Manor Gates' }
        ]
      }
    end

    let(:available_stats) do
      [
        { id: 1, name: 'Strength', abbreviation: 'STR' },
        { id: 2, name: 'Dexterity', abbreviation: 'DEX' },
        { id: 3, name: 'Intelligence', abbreviation: 'INT' }
      ]
    end

    let(:standard_detail) do
      {
        'emit' => '(Name) peers through the iron bars of the manor gate...',
        'succ_text' => '(Name) slips past unnoticed.',
        'fail_text' => 'A branch snaps underfoot.',
        'fail_repeat' => false,
        'knockout' => false,
        'actions' => [
          { 'choice_text' => 'Pick the lock', 'output_string' => '(Name) works the tumblers.', 'fail_string' => 'The pick snaps.', 'stat_ids' => [2] },
          { 'choice_text' => 'Force it open', 'output_string' => '(Name) shoves.', 'fail_string' => 'It holds firm.', 'stat_ids' => [1] }
        ]
      }
    end

    let(:combat_detail) do
      {
        'emit' => 'Steel rings out as guards rush from the shadows.',
        'succ_text' => 'The guards fall.',
        'fail_text' => 'The guards overwhelm the party.',
        'fail_repeat' => false,
        'knockout' => false,
        'combat_encounter_name' => 'manor_guards',
        'combat_difficulty' => 'normal'
      }
    end

    let(:standard_request) do
      double('LLMRequest',
             status: 'completed',
             response_text: standard_detail.to_json,
             error_message: nil,
             parsed_context: { 'round_index' => 0, 'round_number' => 1, 'rtype' => 'standard' })
    end

    let(:combat_request) do
      double('LLMRequest',
             status: 'completed',
             response_text: combat_detail.to_json,
             error_message: nil,
             parsed_context: { 'round_index' => 1, 'round_number' => 2, 'rtype' => 'combat' })
    end

    let(:batch) do
      double('LlmBatch', wait!: true, results: [standard_request, combat_request])
    end

    before do
      allow(LLM::Client).to receive(:batch_submit).and_return(batch)
    end

    it 'returns success with detailed rounds' do
      result = described_class.detail_rounds(
        concept_plan: concept_plan,
        available_stats: available_stats
      )

      expect(result[:success]).to be true
      expect(result[:errors]).to be_empty
      expect(result[:plan]['rounds'].length).to eq(2)
    end

    it 'merges sketch fields with detail fields' do
      result = described_class.detail_rounds(
        concept_plan: concept_plan,
        available_stats: available_stats
      )

      standard_round = result[:plan]['rounds'].find { |r| r['rtype'] == 'standard' }
      # Sketch fields preserved
      expect(standard_round['round_number']).to eq(1)
      expect(standard_round['branch']).to eq(0)
      expect(standard_round['rtype']).to eq('standard')
      expect(standard_round['fail_con']).to eq('none')
      expect(standard_round['is_finale']).to eq(false)
      expect(standard_round['location_key']).to eq('manor_gate')
      # Detail fields added
      expect(standard_round['emit']).to include('manor gate')
      expect(standard_round['actions']).to be_an(Array)
      expect(standard_round['actions'].length).to eq(2)
    end

    it 'preserves non-round plan fields' do
      result = described_class.detail_rounds(
        concept_plan: concept_plan,
        available_stats: available_stats
      )

      expect(result[:plan]['title']).to eq('The Duke\'s Secret')
      expect(result[:plan]['adversaries']).to be_an(Array)
      expect(result[:plan]['locations']).to be_an(Array)
    end

    it 'submits batch with correct request count' do
      expect(LLM::Client).to receive(:batch_submit).with(
        an_instance_of(Array) & have_attributes(length: 2)
      ).and_return(batch)

      described_class.detail_rounds(
        concept_plan: concept_plan,
        available_stats: available_stats
      )
    end

    it 'uses correct provider and model for each request' do
      expect(LLM::Client).to receive(:batch_submit).with(
        array_including(
          hash_including(
            provider: 'anthropic',
            model: 'claude-sonnet-4-6',
            json_mode: true
          )
        )
      ).and_return(batch)

      described_class.detail_rounds(
        concept_plan: concept_plan,
        available_stats: available_stats
      )
    end

    it 'includes round_index in context for result matching' do
      expect(LLM::Client).to receive(:batch_submit).with(
        array_including(
          hash_including(context: hash_including(round_index: 0)),
          hash_including(context: hash_including(round_index: 1))
        )
      ).and_return(batch)

      described_class.detail_rounds(
        concept_plan: concept_plan,
        available_stats: available_stats
      )
    end

    it 'returns empty plan for empty rounds' do
      empty_plan = concept_plan.merge('rounds' => [])

      result = described_class.detail_rounds(
        concept_plan: empty_plan,
        available_stats: available_stats
      )

      expect(result[:success]).to be true
      expect(result[:plan]['rounds']).to be_empty
    end

    context 'when a round detail fails' do
      let(:failed_request) do
        double('LLMRequest',
               status: 'failed',
               response_text: nil,
               error_message: 'API timeout',
               parsed_context: { 'round_index' => 0, 'round_number' => 1, 'rtype' => 'standard' })
      end

      let(:partial_batch) do
        double('LlmBatch', wait!: true, results: [failed_request, combat_request])
      end

      before do
        allow(LLM::Client).to receive(:batch_submit).and_return(partial_batch)
      end

      it 'uses fallback for failed round and reports error' do
        result = described_class.detail_rounds(
          concept_plan: concept_plan,
          available_stats: available_stats
        )

        expect(result[:success]).to be true # still succeeds because there are rounds
        expect(result[:errors]).to include(/Round 1.*API timeout/)

        fallback = result[:plan]['rounds'].find { |r| r['round_number'] == 1 }
        expect(fallback['emit']).to include('approaches the manor gates') # uses narrative as fallback
        expect(fallback['fail_repeat']).to eq(false)
      end
    end

    context 'when response has invalid JSON' do
      let(:bad_json_request) do
        double('LLMRequest',
               status: 'completed',
               response_text: 'not valid json at all',
               error_message: nil,
               parsed_context: { 'round_index' => 0, 'round_number' => 1, 'rtype' => 'standard' })
      end

      let(:bad_batch) do
        double('LlmBatch', wait!: true, results: [bad_json_request, combat_request])
      end

      before do
        allow(LLM::Client).to receive(:batch_submit).and_return(bad_batch)
      end

      it 'uses fallback for JSON parse error and reports error' do
        result = described_class.detail_rounds(
          concept_plan: concept_plan,
          available_stats: available_stats
        )

        expect(result[:success]).to be true
        expect(result[:errors]).to include(/Round 1.*JSON parse error/)
      end
    end
  end

  describe 'ROUND_SCHEMAS' do
    it 'defines schemas for all valid round types' do
      expected_types = %w[standard combat persuade reflex group_check branch free_roll rest]
      expected_types.each do |rtype|
        expect(described_class::ROUND_SCHEMAS).to have_key(rtype), "Missing schema for #{rtype}"
      end
    end

    it 'requires emit for all round types' do
      described_class::ROUND_SCHEMAS.each do |rtype, schema|
        expect(schema[:required]).to include('emit'), "#{rtype} schema missing required 'emit'"
      end
    end

    it 'requires actions for standard rounds' do
      expect(described_class::ROUND_SCHEMAS['standard'][:required]).to include('actions')
    end

    it 'requires combat_encounter_name for combat rounds' do
      expect(described_class::ROUND_SCHEMAS['combat'][:required]).to include('combat_encounter_name')
    end

    it 'requires branch_choices for branch rounds' do
      expect(described_class::ROUND_SCHEMAS['branch'][:required]).to include('branch_choices')
    end

    it 'requires persuade fields for persuade rounds' do
      schema = described_class::ROUND_SCHEMAS['persuade']
      expect(schema[:required]).to include('persuade_npc_name')
      expect(schema[:required]).to include('persuade_npc_personality')
    end
  end

  describe 'DETAIL_MODEL' do
    it 'uses Sonnet' do
      expect(described_class::DETAIL_MODEL[:provider]).to eq('anthropic')
      expect(described_class::DETAIL_MODEL[:model]).to eq('claude-sonnet-4-6')
    end
  end

  describe 'branch round handling' do
    let(:branch_plan) do
      {
        'title' => 'Branch Test',
        'summary' => 'Testing branch rounds.',
        'theme' => 'choice',
        'tone_adjectives' => ['tense'],
        'rounds' => [
          {
            'round_number' => 1,
            'branch' => 0,
            'rtype' => 'branch',
            'narrative' => 'A fork in the road.',
            'fail_con' => 'none',
            'is_finale' => false,
            'branch_targets' => [
              { 'text' => 'Go left', 'leads_to_branch' => 1 },
              { 'text' => 'Go right', 'leads_to_branch' => 2 }
            ]
          }
        ],
        'adversaries' => [],
        'locations' => []
      }
    end

    let(:branch_detail) do
      {
        'emit' => 'The path splits before you.',
        'branch_choices' => [
          { 'text' => 'Go left', 'description' => 'A dark, narrow passage.', 'leads_to_branch' => 1 },
          { 'text' => 'Go right', 'description' => 'A wide, well-lit corridor.', 'leads_to_branch' => 2 }
        ]
      }
    end

    let(:branch_request) do
      double('LLMRequest',
             status: 'completed',
             response_text: branch_detail.to_json,
             error_message: nil,
             parsed_context: { 'round_index' => 0, 'round_number' => 1, 'rtype' => 'branch' })
    end

    let(:batch) do
      double('LlmBatch', wait!: true, results: [branch_request])
    end

    before do
      allow(LLM::Client).to receive(:batch_submit).and_return(batch)
    end

    it 'expands branch_targets into branch_choices' do
      result = described_class.detail_rounds(
        concept_plan: branch_plan,
        available_stats: []
      )

      round = result[:plan]['rounds'][0]
      expect(round['branch_choices']).to be_an(Array)
      expect(round['branch_choices'].length).to eq(2)
      expect(round['branch_choices'][0]['description']).to include('dark')
    end

    it 'falls back to branch_targets if detail lacks branch_choices' do
      no_choices_detail = { 'emit' => 'The path splits.' }
      no_choices_request = double('LLMRequest',
                                  status: 'completed',
                                  response_text: no_choices_detail.to_json,
                                  error_message: nil,
                                  parsed_context: { 'round_index' => 0, 'round_number' => 1, 'rtype' => 'branch' })
      allow(LLM::Client).to receive(:batch_submit).and_return(
        double('LlmBatch', wait!: true, results: [no_choices_request])
      )

      result = described_class.detail_rounds(
        concept_plan: branch_plan,
        available_stats: []
      )

      round = result[:plan]['rounds'][0]
      expect(round['branch_choices']).to eq(branch_plan['rounds'][0]['branch_targets'])
    end
  end
end
