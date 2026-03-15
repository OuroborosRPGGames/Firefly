# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BalancedEncounter do
  let(:universe) { create(:universe) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe 'validations' do
    it 'requires name' do
      encounter = BalancedEncounter.new
      expect(encounter.valid?).to be false
      expect(encounter.errors[:name]).not_to be_empty
    end

    it 'accepts valid attributes' do
      encounter = BalancedEncounter.new(name: 'Boss Fight')
      expect(encounter.valid?).to be true
    end
  end

  describe 'associations' do
    it 'belongs to universe' do
      encounter = BalancedEncounter.create(name: 'Test', universe_id: universe.id)
      expect(encounter.universe).to eq(universe)
    end
  end

  describe 'defaults' do
    it 'has default status of pending' do
      encounter = BalancedEncounter.create(name: 'Test')
      expect(encounter.status).to eq('pending')
    end

    it 'has empty arrays for archetype IDs' do
      encounter = BalancedEncounter.create(name: 'Test')
      expect(encounter.mandatory_npc_archetype_ids).to eq([])
      expect(encounter.optional_npc_archetype_ids).to eq([])
      expect(encounter.pc_character_ids).to eq([])
    end

    it 'has empty hashes for composition data' do
      encounter = BalancedEncounter.create(name: 'Test')
      expect(encounter.balanced_composition).to eq({})
      expect(encounter.stat_modifiers).to eq({})
      expect(encounter.difficulty_variants).to eq({})
    end
  end

  describe '#configuration_for' do
    let(:encounter) do
      BalancedEncounter.create(
        name: 'Test Encounter',
        balanced_composition: { '1' => { 'count' => 2 } },
        stat_modifiers: { '1' => 0.1 },
        difficulty_variants: {
          'easy' => {
            'composition' => { '1' => { 'count' => 1 } },
            'stat_modifiers' => { '1' => -0.2 }
          },
          'hard' => {
            'composition' => { '1' => { 'count' => 3 } },
            'stat_modifiers' => { '1' => 0.3 }
          }
        }
      )
    end

    it 'returns variant config for specified difficulty' do
      config = encounter.configuration_for('easy')
      expect(config[:composition]).to eq({ '1' => { 'count' => 1 } })
      expect(config[:stat_modifiers]).to eq({ '1' => -0.2 })
    end

    it 'falls back to normal for unknown difficulty' do
      config = encounter.configuration_for('impossible')
      # Should fall back to balanced_composition since no 'normal' variant
      expect(config[:composition]).to eq({ '1' => { 'count' => 2 } })
    end

    it 'uses base composition when no variants defined' do
      simple_encounter = BalancedEncounter.create(
        name: 'Simple',
        balanced_composition: { '5' => { 'count' => 1 } }
      )
      config = simple_encounter.configuration_for('hard')
      expect(config[:composition]).to eq({ '5' => { 'count' => 1 } })
    end
  end

  describe '#summary' do
    let(:encounter) do
      BalancedEncounter.create(
        name: 'Test Fight',
        status: 'balanced',
        pc_power: 150.5,
        npc_power: 140.2,
        avg_win_margin: 1.5,
        avg_rounds: 5.2,
        simulations_run: 100,
        balanced_composition: {}
      )
    end

    it 'returns formatted string' do
      summary = encounter.summary
      expect(summary).to include('Test Fight')
      expect(summary).to include('balanced')
      expect(summary).to include('150.5')
      expect(summary).to include('140.2')
    end

    it 'handles nil values gracefully' do
      empty_encounter = BalancedEncounter.create(name: 'Empty')
      summary = empty_encounter.summary
      expect(summary).to include('Empty')
      expect(summary).to include('pending')
    end
  end

  describe '#balance_valid?' do
    it 'returns false when not balanced' do
      encounter = BalancedEncounter.create(name: 'Test', status: 'pending')
      expect(encounter.balance_valid?).to be false
    end

    it 'returns false when balanced_at is nil' do
      encounter = BalancedEncounter.create(name: 'Test', status: 'balanced')
      expect(encounter.balance_valid?).to be false
    end

    it 'returns false for failed status' do
      encounter = BalancedEncounter.create(
        name: 'Test',
        status: 'failed',
        balanced_at: Time.now
      )
      expect(encounter.balance_valid?).to be false
    end

    context 'with balanced status and timestamp' do
      let(:encounter) do
        BalancedEncounter.create(
          name: 'Balanced Test',
          status: 'balanced',
          balanced_at: Time.now,
          pc_power: 100.0,
          pc_character_ids: Sequel.pg_array([character.id])
        )
      end

      it 'returns true for recently balanced encounter' do
        # Mock PowerCalculatorService to return similar power
        allow(PowerCalculatorService).to receive(:calculate_pc_group_power)
          .and_return(95.0) # Within 20% of 100

        expect(encounter.balance_valid?).to be true
      end

      it 'returns false when PC power has drifted significantly' do
        allow(PowerCalculatorService).to receive(:calculate_pc_group_power)
          .and_return(200.0) # More than 20% drift

        expect(encounter.balance_valid?).to be false
      end
    end

    it 'returns true for approximate status' do
      encounter = BalancedEncounter.create(
        name: 'Approx Test',
        status: 'approximate',
        balanced_at: Time.now,
        pc_power: 100.0
      )

      allow(PowerCalculatorService).to receive(:calculate_pc_group_power)
        .and_return(100.0)

      expect(encounter.balance_valid?).to be true
    end
  end

  describe '#npc_participants' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Test Monster',
        combat_max_hp: 6,
        combat_damage_bonus: 2
      )
    end

    let(:encounter) do
      BalancedEncounter.create(
        name: 'NPC Test',
        balanced_composition: { archetype.id.to_s => { 'count' => 2 } }
      )
    end

    it 'returns SimParticipant array' do
      participants = encounter.npc_participants
      expect(participants).to be_an(Array)
      # PowerCalculatorService handles the conversion
    end
  end

  describe '#pc_participants' do
    it 'calls PowerCalculatorService.pcs_to_participants' do
      encounter = BalancedEncounter.create(name: 'PC Test')

      allow(PowerCalculatorService).to receive(:pcs_to_participants)
        .and_return([double('SimParticipant')])

      result = encounter.pc_participants
      expect(result).to be_an(Array)
    end

    it 'handles nil character IDs' do
      encounter = BalancedEncounter.create(name: 'Empty')

      allow(PowerCalculatorService).to receive(:pcs_to_participants)
        .with([]).and_return([])

      expect(encounter.pc_participants).to eq([])
    end
  end

  describe '#balance!' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Balance Test Monster',
        combat_max_hp: 5,
        combat_damage_bonus: 1
      )
    end

    let(:encounter) do
      BalancedEncounter.create(
        name: 'Balance Test',
        mandatory_npc_archetype_ids: Sequel.pg_array([archetype.id]),
        pc_character_ids: Sequel.pg_array([character.id])
      )
    end

    it 'calls BattleBalancingService' do
      mock_result = {
        composition: { archetype.id => { count: 1 } },
        stat_modifiers: {},
        difficulty_variants: {},
        pc_power: 50.0,
        aggregate: {
          avg_score: 0.5,
          avg_rounds: 3.0,
          avg_pc_kos: 0.2
        },
        simulation_count: 10,
        iterations_used: 5,
        status: 'balanced'
      }

      mock_service = instance_double(BattleBalancingService)
      allow(BattleBalancingService).to receive(:new).and_return(mock_service)
      allow(mock_service).to receive(:balance!).and_return(mock_result)

      result = encounter.balance!
      expect(result).to be true
      expect(encounter.status).to eq('balanced')
      expect(encounter.balanced_at).not_to be_nil
    end

    it 'treats approximate balance as successful' do
      mock_result = {
        composition: { archetype.id => { count: 1 } },
        stat_modifiers: {},
        difficulty_variants: {},
        pc_power: 50.0,
        aggregate: {
          avg_score: 0.5,
          avg_rounds: 3.0,
          avg_pc_kos: 0.2
        },
        simulation_count: 10,
        iterations_used: 5,
        status: 'approximate'
      }

      mock_service = instance_double(BattleBalancingService)
      allow(BattleBalancingService).to receive(:new).and_return(mock_service)
      allow(mock_service).to receive(:balance!).and_return(mock_result)

      result = encounter.balance!
      expect(result).to be true
      expect(encounter.status).to eq('approximate')
    end

    it 'marks status as failed when balancing raises an exception' do
      mock_service = instance_double(BattleBalancingService)
      allow(BattleBalancingService).to receive(:new).and_return(mock_service)
      allow(mock_service).to receive(:balance!).and_raise(StandardError.new('sim crash'))

      result = encounter.balance!
      expect(result).to be false
      expect(encounter.status).to eq('failed')
      expect(encounter.balanced_at).not_to be_nil
    end
  end

  describe '#verify_balance' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Verify Test Monster',
        combat_max_hp: 5
      )
    end

    let(:encounter) do
      BalancedEncounter.create(
        name: 'Verify Test',
        balanced_composition: { archetype.id.to_s => { 'count' => 1 } },
        pc_character_ids: Sequel.pg_array([character.id])
      )
    end

    it 'runs quick check via BattleBalancingService' do
      mock_service = instance_double(BattleBalancingService)
      allow(BattleBalancingService).to receive(:new).and_return(mock_service)
      allow(mock_service).to receive(:quick_check).and_return({
                                                                pc_wins: 5,
                                                                npc_wins: 5,
                                                                avg_rounds: 4.0
                                                              })

      result = encounter.verify_balance
      expect(result).to be_a(Hash)
    end

    it 'uses string-keyed variant composition and modifiers when present' do
      encounter.update(
        difficulty_variants: {
          'hard' => {
            'composition' => { archetype.id.to_s => { 'count' => 2 } },
            'stat_modifiers' => { archetype.id.to_s => 0.2 }
          }
        }
      )

      mock_service = instance_double(BattleBalancingService)
      allow(BattleBalancingService).to receive(:new).and_return(mock_service)
      expect(mock_service).to receive(:quick_check).with(
        { archetype.id.to_s => { 'count' => 2 } },
        stat_modifiers: { archetype.id.to_s => 0.2 }
      ).and_return({})

      encounter.verify_balance(difficulty: 'hard')
    end

    it 'returns an error payload when verification raises an exception' do
      mock_service = instance_double(BattleBalancingService)
      allow(BattleBalancingService).to receive(:new).and_return(mock_service)
      allow(mock_service).to receive(:quick_check).and_raise(StandardError.new('sim crash'))

      result = encounter.verify_balance
      expect(result[:is_balanced]).to be false
      expect(result[:error]).to include('sim crash')
    end
  end

  describe 'timestamps' do
    it 'sets created_at on create' do
      encounter = BalancedEncounter.create(name: 'Timestamp Test')
      expect(encounter.created_at).not_to be_nil
    end
  end
end
