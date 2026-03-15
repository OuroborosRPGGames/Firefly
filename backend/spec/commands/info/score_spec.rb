# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Info::Score, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing',
      level: 5,
      experience: 2500,
      health: 6,
      max_health: 6,
      mana: 40,
      max_mana: 50
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'basic display' do
      it 'displays character name' do
        result = command.execute('score')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Alice')
      end

      it 'displays HP pips' do
        result = command.execute('score')
        expect(result[:success]).to be true
        expect(result[:message]).to include('HP')
        expect(result[:message]).to include('6 / 6')
      end

      it 'returns HP data' do
        result = command.execute('score')
        expect(result[:data][:current_hp]).to eq(6)
        expect(result[:data][:max_hp]).to eq(6)
      end
    end

    context 'with stats' do
      let!(:stat_block) do
        StatBlock.create(
          universe_id: (Universe.first&.id || create(:universe).id),
          name: 'Test Stats',
          block_type: 'single',
          total_points: 50,
          min_stat_value: 1,
          max_stat_value: 10,
          is_active: true
        )
      end
      let!(:strength) do
        Stat.create(
          stat_block_id: stat_block.id,
          name: 'Strength',
          abbreviation: 'STR',
          stat_category: 'primary',
          display_order: 1,
          min_value: 1,
          max_value: 10
        )
      end
      let!(:char_stat) do
        existing = CharacterStat.first(character_instance_id: character_instance.id, stat_id: strength.id)
        if existing
          existing.update(base_value: 7)
          existing
        else
          CharacterStat.create(
            character_instance_id: character_instance.id,
            stat_id: strength.id,
            base_value: 7
          )
        end
      end

      it 'displays stat abbreviation and value' do
        result = command.execute('score')
        expect(result[:message]).to include('STR')
        expect(result[:message]).to include('7')
      end

      it 'displays Attributes section' do
        result = command.execute('score')
        expect(result[:message]).to include('Attributes')
      end
    end

    context 'without stats' do
      it 'succeeds with no stats section' do
        # Clear any auto-initialized stats
        CharacterStat.where(character_instance_id: character_instance.id).delete
        result = command.execute('score')
        expect(result[:success]).to be true
        expect(result[:message]).not_to include('Attributes')
      end
    end

    context 'aliases' do
      it 'works with stats alias' do
        result = command.execute('stats')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Alice')
      end

      it 'works with status alias' do
        result = command.execute('status')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Alice')
      end
    end
  end
end
