# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::MissionSynthesisService do
  describe '.synthesize' do
    let(:brainstorm_outputs) do
      {
        creative_a: 'First model ideas about narrative arc...',
        creative_b: 'Second model ideas about encounters...'
      }
    end
    let(:description) { 'A heist to steal the Duke\'s ledger' }
    let(:setting) { :fantasy }
    let(:difficulty) { :normal }
    let(:location_mode) { :mission_specific }

    let(:valid_plan) do
      {
        'title' => 'The Duke\'s Secret',
        'summary' => 'A daring heist into the Duke\'s manor.',
        'atype' => 'mission',
        'theme' => 'suspense',
        'tone_adjectives' => %w[tense dark],
        'chekhov_details' => ['A loose brick in the wall'],
        'rounds' => [
          {
            'round_number' => 1,
            'branch' => 0,
            'rtype' => 'standard',
            'narrative' => 'The party approaches the manor gates under cover of darkness.',
            'fail_con' => 'none',
            'is_finale' => false
          },
          {
            'round_number' => 2,
            'branch' => 0,
            'rtype' => 'combat',
            'narrative' => 'Guards discover the intruders and attack.',
            'fail_con' => 'injury',
            'is_finale' => false,
            'combat_encounter_key' => 'manor_guards'
          }
        ],
        'locations' => [
          { 'key' => 'manor_gate', 'name' => 'Manor Gates', 'description' => 'Ornate iron gates', 'room_type' => 'outdoor' }
        ],
        'adversaries' => [
          { 'name' => 'Manor Guard', 'role' => 'minion', 'behavior' => 'aggressive', 'combat_encounter_key' => 'manor_guards' }
        ]
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: valid_plan.to_json
      })
    end

    it 'returns success with valid concept plan' do
      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs,
        description: description,
        setting: setting,
        difficulty: difficulty,
        location_mode: location_mode
      )

      expect(result[:success]).to be true
      expect(result[:plan]).to be_a(Hash)
      expect(result[:plan]['title']).to eq('The Duke\'s Secret')
    end

    it 'produces rounds with narrative field instead of emit' do
      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs,
        description: description,
        setting: setting,
        difficulty: difficulty,
        location_mode: location_mode
      )

      expect(result[:success]).to be true
      round = result[:plan]['rounds'][0]
      expect(round['narrative']).to include('manor gates')
      expect(round).not_to have_key('emit')
      expect(round).not_to have_key('actions')
    end

    it 'validates plan structure' do
      invalid_plan = { 'title' => '' } # Missing required fields
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: invalid_plan.to_json
      })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs,
        description: description,
        setting: setting,
        difficulty: difficulty,
        location_mode: location_mode
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('validation failed')
    end

    it 'handles JSON parse errors' do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: 'Not valid JSON'
      })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs,
        description: description,
        setting: setting,
        difficulty: difficulty,
        location_mode: location_mode
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('JSON')
    end

    it 'handles LLM failures' do
      allow(LLM::Client).to receive(:generate).and_return({
        success: false,
        error: 'API timeout'
      })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs,
        description: description,
        setting: setting,
        difficulty: difficulty,
        location_mode: location_mode
      )

      expect(result[:success]).to be false
      expect(result[:error]).to eq('API timeout')
    end

    it 'passes json_schema option to LLM::Client' do
      expect(LLM::Client).to receive(:generate).with(
        hash_including(
          options: hash_including(json_schema: described_class::CONCEPT_SCHEMA)
        )
      ).and_return({ success: true, text: valid_plan.to_json })

      described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs,
        description: description,
        setting: setting,
        difficulty: difficulty,
        location_mode: location_mode
      )
    end
  end

  describe 'VALID_ROUND_TYPES' do
    it 'includes expected round types' do
      expect(described_class::VALID_ROUND_TYPES).to include('standard')
      expect(described_class::VALID_ROUND_TYPES).to include('combat')
      expect(described_class::VALID_ROUND_TYPES).to include('branch')
      expect(described_class::VALID_ROUND_TYPES).to include('persuade')
      expect(described_class::VALID_ROUND_TYPES).to include('group_check')
    end
  end

  describe 'VALID_ACTIVITY_TYPES' do
    it 'includes mission type' do
      expect(described_class::VALID_ACTIVITY_TYPES).to include('mission')
    end
  end

  describe 'CONCEPT_SCHEMA' do
    it 'defines concept-level round fields without detail fields' do
      round_props = described_class::CONCEPT_SCHEMA[:properties][:rounds][:items][:properties]
      expect(round_props).to have_key(:narrative)
      expect(round_props).to have_key(:branch_targets)
      expect(round_props).to have_key(:combat_encounter_key)
      expect(round_props).not_to have_key(:emit)
      expect(round_props).not_to have_key(:actions)
      expect(round_props).not_to have_key(:succ_text)
      expect(round_props).not_to have_key(:fail_text)
      expect(round_props).not_to have_key(:stat_ids)
    end
  end

  describe '.available?' do
    it 'checks Anthropic provider availability' do
      allow(AIProviderService).to receive(:provider_available?).with('anthropic').and_return(true)

      expect(described_class.available?).to be true
    end
  end

  describe 'concept-level round validation' do
    let(:brainstorm_outputs) { { creative_a: 'Ideas A', creative_b: 'Ideas B' } }
    let(:description) { 'Test mission' }
    let(:setting) { :fantasy }
    let(:difficulty) { :normal }
    let(:location_mode) { :mission_specific }

    it 'requires narrative on rounds' do
      plan = {
        'title' => 'Test', 'summary' => 'Testing.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'standard', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('missing narrative')
    end

    it 'requires combat_encounter_key on combat rounds' do
      plan = {
        'title' => 'Test', 'summary' => 'Testing.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'combat', 'narrative' => 'Fight!', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('combat_encounter_key')
    end

    it 'requires branch_targets on branch rounds' do
      plan = {
        'title' => 'Test', 'summary' => 'Testing.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'branch', 'narrative' => 'Choose!', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('branch_targets')
    end

    it 'accepts valid branch round with branch_targets' do
      plan = {
        'title' => 'Branch Test', 'summary' => 'Testing branches.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          {
            'round_number' => 1, 'branch' => 0, 'rtype' => 'branch',
            'narrative' => 'A fork in the road.',
            'fail_con' => 'none', 'is_finale' => false,
            'branch_targets' => [
              { 'text' => 'Go left', 'leads_to_branch' => 1 },
              { 'text' => 'Go right', 'leads_to_branch' => 2 }
            ]
          },
          { 'round_number' => 2, 'branch' => 1, 'rtype' => 'standard', 'narrative' => 'Left path.', 'fail_con' => 'none', 'is_finale' => false },
          { 'round_number' => 3, 'branch' => 2, 'rtype' => 'standard', 'narrative' => 'Right path.', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be true
      branch_round = result[:plan]['rounds'].find { |r| r['rtype'] == 'branch' }
      expect(branch_round['branch_targets']).to be_an(Array)
      expect(branch_round['branch_targets'].length).to eq(2)
    end
  end

  describe 'pacing validation (soft warnings)' do
    let(:brainstorm_outputs) { { creative_a: 'Ideas A', creative_b: 'Ideas B' } }
    let(:description) { 'Test mission' }
    let(:setting) { :fantasy }
    let(:difficulty) { :normal }
    let(:location_mode) { :mission_specific }

    it 'warns on adjacent combat rounds' do
      plan = {
        'title' => 'Pacing Test', 'summary' => 'Testing pacing.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'combat', 'narrative' => 'Fight!', 'combat_encounter_key' => 'a', 'fail_con' => 'none', 'is_finale' => false },
          { 'round_number' => 2, 'branch' => 0, 'rtype' => 'combat', 'narrative' => 'Fight again!', 'combat_encounter_key' => 'b', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be true
      expect(result[:plan]['pacing_warnings']).to include(/adjacent combat/)
    end

    it 'warns on adjacent persuade rounds' do
      plan = {
        'title' => 'Social Test', 'summary' => 'Testing pacing.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'persuade', 'narrative' => 'Talk.', 'fail_con' => 'none', 'is_finale' => false },
          { 'round_number' => 2, 'branch' => 0, 'rtype' => 'persuade', 'narrative' => 'Talk again.', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be true
      expect(result[:plan]['pacing_warnings']).to include(/adjacent persuade/)
    end

    it 'warns when climax fail_con is branch' do
      plan = {
        'title' => 'Climax Test', 'summary' => 'Testing climax.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'standard', 'narrative' => 'Start.', 'fail_con' => 'none', 'is_finale' => false },
          { 'round_number' => 2, 'branch' => 0, 'rtype' => 'combat', 'narrative' => 'Boss!', 'combat_encounter_key' => 'boss', 'is_finale' => true, 'fail_con' => 'branch' }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be true
      expect(result[:plan]['pacing_warnings']).to include(/climax.*fail_con/)
    end

    it 'produces no warnings for well-paced plan' do
      plan = {
        'title' => 'Good Plan', 'summary' => 'Well paced.', 'atype' => 'mission',
        'theme' => 'test', 'tone_adjectives' => [], 'chekhov_details' => [],
        'rounds' => [
          { 'round_number' => 1, 'branch' => 0, 'rtype' => 'standard', 'narrative' => 'Enter.', 'fail_con' => 'none', 'is_finale' => false },
          { 'round_number' => 2, 'branch' => 0, 'rtype' => 'persuade', 'narrative' => 'Talk.', 'fail_con' => 'none', 'is_finale' => false },
          { 'round_number' => 3, 'branch' => 0, 'rtype' => 'combat', 'narrative' => 'Fight!', 'combat_encounter_key' => 'a', 'fail_con' => 'none', 'is_finale' => false }
        ],
        'locations' => [], 'adversaries' => []
      }
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan.to_json })

      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: description,
        setting: setting, difficulty: difficulty, location_mode: location_mode
      )

      expect(result[:success]).to be true
      expect(result[:plan]['pacing_warnings']).to be_empty
    end
  end

  describe 'theme and tone fields' do
    let(:brainstorm_outputs) { { creative_a: 'Ideas A', creative_b: 'Ideas B' } }
    let(:plan_with_theme) do
      {
        'title' => 'Themed Mission', 'summary' => 'A thematic test.', 'atype' => 'mission',
        'theme' => 'corruption',
        'tone_adjectives' => ['desperate', 'ancient', 'treacherous'],
        'chekhov_details' => ['The strange symbol on the wall', 'The merchant flinches at the name'],
        'rounds' => [{ 'round_number' => 1, 'branch' => 0, 'rtype' => 'standard', 'narrative' => 'Start.', 'fail_con' => 'none', 'is_finale' => false }],
        'locations' => [], 'adversaries' => []
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: plan_with_theme.to_json })
    end

    it 'passes through theme and tone_adjectives' do
      result = described_class.synthesize(
        brainstorm_outputs: brainstorm_outputs, description: 'Test',
        setting: :fantasy, difficulty: :normal, location_mode: :mission_specific
      )

      expect(result[:success]).to be true
      expect(result[:plan]['theme']).to eq('corruption')
      expect(result[:plan]['tone_adjectives']).to eq(['desperate', 'ancient', 'treacherous'])
      expect(result[:plan]['chekhov_details']).to be_an(Array)
    end
  end
end
