# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Dice::Roll, type: :command do
  let(:reality) { Reality.first || create(:reality) }
  let(:universe) { Universe.first || create(:universe) }
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

  let!(:stat_block) do
    StatBlock.create(
      universe_id: universe.id,
      name: 'Test Stats',
      block_type: 'single',
      total_points: 50,
      min_stat_value: 1,
      max_stat_value: 10,
      cost_formula: 'doubling_every_other',
      is_active: true
    )
  end

  let!(:strength) do
    Stat.create(
      stat_block_id: stat_block.id,
      name: 'Strength',
      abbreviation: 'STR',
      stat_category: 'primary',
      display_order: 1
    )
  end

  let!(:dexterity) do
    Stat.create(
      stat_block_id: stat_block.id,
      name: 'Dexterity',
      abbreviation: 'DEX',
      stat_category: 'primary',
      display_order: 2
    )
  end

  before do
    # Update or create character stats (after_create may have already initialized defaults)
    str_stat = CharacterStat.find_or_create(character_instance_id: character_instance.id, stat_id: strength.id)
    str_stat.update(base_value: 6)
    dex_stat = CharacterStat.find_or_create(character_instance_id: character_instance.id, stat_id: dexterity.id)
    dex_stat.update(base_value: 4)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with a single stat' do
      it 'rolls using the stat value as modifier' do
        result = command.execute('roll STR')

        expect(result[:success]).to be true
        expect(result[:message]).to include('STR')  # Shows abbreviation with value like "STR (6)"
        expect(result[:message]).to match(/= \d+/)
      end

      it 'shows exploded die values, not explosion indices' do
        allow(DiceRollService).to receive(:roll_2d8_exploding).and_return(
          DiceRollService::RollResult.new(
            dice: [8, 5, 6],
            base_dice: [8, 5],
            explosions: [0],
            modifier: 0,
            total: 19,
            count: 2,
            sides: 8,
            explode_on: 8
          )
        )

        result = command.execute('roll STR')

        expect(result[:success]).to be true
        expect(result[:message]).to include('EXPLODE!+6')
        expect(result[:message]).not_to include('EXPLODE!+0')
      end
    end

    context 'with multiple stats' do
      it 'averages stats and adds bonus' do
        result = command.execute('roll STR+DEX')

        expect(result[:success]).to be true
        expect(result[:message]).to include('STR')
        expect(result[:message]).to include('DEX')
        expect(result[:message]).to match(/= \d+/)
      end
    end

    context 'with no stat provided' do
      it 'shows stat picker when stats available' do
        # Character has stats from before block - shows quickmenu
        result = command.execute('roll')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end

      context 'when character has no stats' do
        before do
          # Remove stats created in outer before block
          CharacterStat.where(character_instance_id: character_instance.id).delete
        end

        it 'returns an error' do
          result = command.execute('roll')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/don't have any stats|stat block/i)
        end
      end
    end

    context 'with unknown stat' do
      it 'returns an error' do
        result = command.execute('roll UNKNOWN')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown stats')
      end
    end

    context 'with case-insensitive stat names' do
      it 'accepts lowercase stat abbreviations' do
        result = command.execute('roll str')

        expect(result[:success]).to be true
      end

      it 'accepts mixed case stat abbreviations' do
        result = command.execute('roll Str')

        expect(result[:success]).to be true
      end
    end

    # Dice notation tests (merged from diceroll)
    context 'with dice notation' do
      it 'rolls 2d6' do
        result = command.execute('roll 2d6')

        expect(result[:success]).to be true
        expect(result[:message]).to include('2d6')
        expect(result[:message]).to match(/= \d+/)
      end

      it 'rolls 1d20' do
        result = command.execute('roll 1d20')

        expect(result[:success]).to be true
        expect(result[:message]).to include('1d20')
      end

      it 'handles modifier addition' do
        result = command.execute('roll 2d6+5')

        expect(result[:success]).to be true
        expect(result[:message]).to include('2d6+5')
        expect(result[:message]).to include('+5')
      end

      it 'handles modifier subtraction' do
        result = command.execute('roll 2d6-3')

        expect(result[:success]).to be true
        expect(result[:message]).to include('2d6-3')
        expect(result[:message]).to include('-3')
      end
    end

    context 'with invalid dice notation' do
      it 'rejects too many dice' do
        result = command.execute('roll 100d6')

        expect(result[:success]).to be false
        expect(result[:error]).to include('1 and 20')
      end

      it 'rejects too many sides' do
        result = command.execute('roll 2d200')

        expect(result[:success]).to be false
        expect(result[:error]).to include('2 and 100')
      end

      it 'rejects too few sides' do
        result = command.execute('roll 2d1')

        expect(result[:success]).to be false
        expect(result[:error]).to include('2 and 100')
      end
    end

    context 'with dice aliases' do
      it 'works with dr alias' do
        result = command.execute('dr 2d6')

        expect(result[:success]).to be true
      end

      it 'works with dice alias' do
        result = command.execute('dice 2d6')

        expect(result[:success]).to be true
      end

      it 'works with diceroll alias' do
        result = command.execute('diceroll 2d6')

        expect(result[:success]).to be true
      end
    end
  end

  it_behaves_like 'command metadata', 'roll', :entertainment, ['rl', 'dr', 'dice', 'diceroll']
end
