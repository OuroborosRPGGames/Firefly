# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Use, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end
  let(:pattern) { create(:pattern) }
  let(:item) do
    double('Item',
           id: 1,
           name: 'Steel Sword',
           quantity: 1,
           held?: false,
           worn?: false,
           clothing?: false,
           jewelry?: false,
           tattoo?: false,
           piercing?: false,
           consumable?: false,
           food?: false,
           drinkable?: false,
           smokeable?: false)
  end

  subject(:command) { described_class.new(character_instance) }

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['use']).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('use')
    end

    it 'has category inventory' do
      expect(described_class.category).to eq(:inventory)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Use')
    end

    it 'has usage' do
      expect(described_class.usage).to include('use')
    end

    it 'has examples' do
      expect(described_class.examples).to include('use sword')
    end
  end

  describe '#execute' do
    context 'with no arguments' do
      context 'with empty inventory' do
        before do
          dataset = double
          allow(character_instance).to receive(:inventory_items).and_return(dataset)
          allow(dataset).to receive(:all).and_return([])
        end

        it 'returns error about empty inventory' do
          result = command.execute('use')

          expect(result[:success]).to be false
          expect(result[:error]).to include("aren't carrying anything")
        end
      end

      context 'with items in inventory' do
        before do
          dataset = double
          allow(character_instance).to receive(:inventory_items).and_return(dataset)
          allow(dataset).to receive(:all).and_return([item])
          allow(command).to receive(:plain_name).with('Steel Sword').and_return('Steel Sword')
        end

        it 'creates quickmenu for item selection' do
          expect(command).to receive(:create_quickmenu).with(
            character_instance,
            "What would you like to use?",
            array_including(
              hash_including(key: '1', label: 'Steel Sword'),
              hash_including(key: 'q', label: 'Cancel')
            ),
            hash_including(
              context: hash_including(command: 'use', stage: 'select_item')
            )
          ).and_return({ success: true, quickmenu: true })

          command.execute('use')
        end

        it 'shows item status (held)' do
          allow(item).to receive(:held?).and_return(true)
          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            item_opt = options.find { |o| o[:key] == '1' }
            expect(item_opt[:description]).to eq('held')
          end.and_return({ success: true, quickmenu: true })

          command.execute('use')
        end

        it 'shows item status (worn)' do
          allow(item).to receive(:worn?).and_return(true)
          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            item_opt = options.find { |o| o[:key] == '1' }
            expect(item_opt[:description]).to eq('worn')
          end.and_return({ success: true, quickmenu: true })

          command.execute('use')
        end

        it 'shows item status (carried)' do
          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            item_opt = options.find { |o| o[:key] == '1' }
            expect(item_opt[:description]).to eq('carried')
          end.and_return({ success: true, quickmenu: true })

          command.execute('use')
        end

        it 'shows quantity for stacked items' do
          allow(item).to receive(:quantity).and_return(5)
          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            item_opt = options.find { |o| o[:key] == '1' }
            expect(item_opt[:label]).to include('(x5)')
          end.and_return({ success: true, quickmenu: true })

          command.execute('use')
        end
      end
    end

    context 'with item name argument' do
      before do
        dataset = double
        allow(character_instance).to receive(:inventory_items).and_return(dataset)
        allow(dataset).to receive(:all).and_return([item])
        allow(command).to receive(:plain_name).with('Steel Sword').and_return('Steel Sword')
      end

      context 'when item found' do
        it 'shows action menu for the item' do
          expect(command).to receive(:create_quickmenu).with(
            character_instance,
            match(/Steel Sword.*what do you want to do/),
            array_including(
              hash_including(key: 'h', label: 'Hold'),
              hash_including(key: 'd', label: 'Drop'),
              hash_including(key: 'e', label: 'Examine'),
              hash_including(key: 'g', label: 'Give'),
              hash_including(key: 's', label: 'Show'),
              hash_including(key: 'q', label: 'Cancel')
            ),
            hash_including(
              context: hash_including(command: 'use', stage: 'select_action', item_id: 1)
            )
          ).and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Release option when item is held' do
          allow(item).to receive(:held?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'r', label: 'Release'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Wear option for unworn wearable items' do
          allow(item).to receive(:clothing?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'w', label: 'Wear'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Remove option for worn items' do
          allow(item).to receive(:worn?).and_return(true)
          allow(item).to receive(:clothing?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'w', label: 'Remove'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Eat option for food' do
          allow(item).to receive(:consumable?).and_return(true)
          allow(item).to receive(:food?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'c', label: 'Eat'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Drink option for drinkables' do
          allow(item).to receive(:consumable?).and_return(true)
          allow(item).to receive(:drinkable?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'c', label: 'Drink'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Smoke option for smokeables' do
          allow(item).to receive(:consumable?).and_return(true)
          allow(item).to receive(:smokeable?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'c', label: 'Smoke'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows generic Consume option for other consumables' do
          allow(item).to receive(:consumable?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'c', label: 'Consume'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Wear option for jewelry' do
          allow(item).to receive(:jewelry?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'w', label: 'Wear'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Wear option for tattoos' do
          allow(item).to receive(:tattoo?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'w', label: 'Wear'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end

        it 'shows Wear option for piercings' do
          allow(item).to receive(:piercing?).and_return(true)

          expect(command).to receive(:create_quickmenu) do |_ci, _prompt, options, _ctx|
            expect(options).to include(hash_including(key: 'w', label: 'Wear'))
          end.and_return({ success: true, quickmenu: true })

          command.execute('use steel')
        end
      end

      context 'when item not found' do
        before do
          dataset = double
          allow(character_instance).to receive(:inventory_items).and_return(dataset)
          allow(dataset).to receive(:all).and_return([])
        end

        it 'returns error about missing item' do
          result = command.execute('use nonexistent')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have 'nonexistent'")
        end
      end

      context 'with stored item only' do
        let!(:stored_item) do
          create(:item,
                 character_instance: character_instance,
                 name: 'Stored Sword',
                 stored: true)
        end

        it 'does not allow using stored items' do
          result = command.execute('use stored sword')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have 'stored sword'")
        end
      end
    end
  end

  describe '#find_inventory_item' do
    before do
      dataset = double
      allow(character_instance).to receive(:inventory_items).and_return(dataset)
      allow(dataset).to receive(:all).and_return([item])
      allow(command).to receive(:plain_name).with('Steel Sword').and_return('Steel Sword')
    end

    it 'finds item by exact name match' do
      found = command.send(:find_inventory_item, 'Steel Sword')

      expect(found).to eq(item)
    end

    it 'finds item by partial name (prefix)' do
      found = command.send(:find_inventory_item, 'Steel')

      expect(found).to eq(item)
    end

    it 'is case insensitive' do
      found = command.send(:find_inventory_item, 'STEEL SWORD')

      expect(found).to eq(item)
    end

    it 'returns nil for non-matching name' do
      found = command.send(:find_inventory_item, 'Shield')

      expect(found).to be_nil
    end

    it 'returns nil for empty inventory' do
      dataset = double
      allow(character_instance).to receive(:inventory_items).and_return(dataset)
      allow(dataset).to receive(:all).and_return([])

      found = command.send(:find_inventory_item, 'Sword')

      expect(found).to be_nil
    end
  end

  # Game integration tests using real database records
  describe 'game integration' do
    # Helper method to execute commands
    def execute_command(input)
      command.execute(input)
    end

    let(:game_pattern) { GamePattern.create(name: 'Magic 8-Ball', created_by: character.id) }
    let(:branch) do
      GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'default',
        display_name: 'Ask a Question'
      )
    end
    let(:item_with_game) { create(:item, character_instance: character_instance, name: '8-ball') }
    let!(:game_instance) { GameInstance.create(game_pattern_id: game_pattern.id, item_id: item_with_game.id) }

    before do
      GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: 'Yes!', points: 0)
      GamePatternResult.create(game_pattern_branch_id: branch.id, position: 2, message: 'No.', points: 0)
    end

    it 'plays game with single branch directly' do
      result = execute_command('use 8-ball')

      expect(result[:success]).to be true
      # Should play the game, not show item menu
      expect(result[:message]).to match(/Yes!|No\./)
    end

    context 'with multiple branches' do
      let!(:branch2) do
        GamePatternBranch.create(
          game_pattern_id: game_pattern.id,
          name: 'serious',
          display_name: 'Ask Seriously',
          position: 1
        )
      end

      before do
        GamePatternResult.create(game_pattern_branch_id: branch2.id, position: 1, message: 'Perhaps.', points: 0)
      end

      it 'shows branch quickmenu when no branch specified' do
        result = execute_command('use 8-ball')

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:options].map { |o| o[:label] }).to include('Ask a Question', 'Ask Seriously')
      end

      it 'plays specific branch when specified' do
        result = execute_command('use 8-ball serious')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Perhaps.')
      end
    end
  end

  describe 'room fixture games' do
    # Helper method to execute commands
    def execute_command(input)
      command.execute(input)
    end

    let(:game_pattern) { GamePattern.create(name: 'Dart Board', created_by: character.id) }
    let(:branch) do
      GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'default',
        display_name: 'Throw Dart'
      )
    end
    let!(:game_instance) { GameInstance.create(game_pattern_id: game_pattern.id, room_id: room.id) }

    before do
      GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: 'Bullseye!', points: 0)
    end

    it 'finds and plays room fixture game' do
      result = execute_command('use dart board')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Bullseye!')
    end
  end

  describe 'game reset functionality' do
    def execute_command(input)
      command.execute(input)
    end

    let(:game_pattern) { GamePattern.create(name: 'Scoring Game', created_by: character.id, has_scoring: true) }
    let(:branch) do
      GamePatternBranch.create(
        game_pattern_id: game_pattern.id,
        name: 'default',
        display_name: 'Play'
      )
    end
    let(:item_with_game) { create(:item, character_instance: character_instance, name: 'scorer') }
    let!(:game_instance) { GameInstance.create(game_pattern_id: game_pattern.id, item_id: item_with_game.id) }

    before do
      GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: 'Scored!', points: 10)
    end

    it 'resets existing score' do
      # First create a score by playing the game
      execute_command('use scorer')

      # Verify score exists
      score = GameScore.where(
        game_instance_id: game_instance.id,
        character_instance_id: character_instance.id
      ).first
      expect(score).not_to be_nil
      expect(score.score).to eq(10)

      # Now reset
      result = execute_command('use scorer reset')

      expect(result[:success]).to be true
      expect(result[:message]).to include('has been reset')
      expect(score.reload.score).to eq(0)
    end

    it 'handles reset when no score exists' do
      result = execute_command('use scorer reset')

      expect(result[:success]).to be true
      expect(result[:message]).to include("don't have a score")
    end

    it 'returns error for reset of non-existent game' do
      result = execute_command('use nonexistent reset')

      expect(result[:success]).to be false
      expect(result[:error]).to include("No game found")
    end
  end

  describe 'game error cases' do
    def execute_command(input)
      command.execute(input)
    end

    let(:game_pattern) { GamePattern.create(name: 'Error Test Game', created_by: character.id) }
    let(:item_with_game) { create(:item, character_instance: character_instance, name: 'error-test') }
    let!(:game_instance) { GameInstance.create(game_pattern_id: game_pattern.id, item_id: item_with_game.id) }

    context 'when game has no branches' do
      it 'returns error about no playable options' do
        result = execute_command('use error-test')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no playable options')
      end
    end

    context 'when unknown branch is specified' do
      let!(:branch) do
        GamePatternBranch.create(
          game_pattern_id: game_pattern.id,
          name: 'valid',
          display_name: 'Valid Option'
        )
      end
      let!(:branch2) do
        GamePatternBranch.create(
          game_pattern_id: game_pattern.id,
          name: 'another',
          display_name: 'Another Option'
        )
      end

      before do
        GamePatternResult.create(game_pattern_branch_id: branch.id, position: 1, message: 'Result 1', points: 0)
        GamePatternResult.create(game_pattern_branch_id: branch2.id, position: 1, message: 'Result 2', points: 0)
      end

      it 'returns error listing available options' do
        result = execute_command('use error-test nonexistent')

        expect(result[:success]).to be false
        expect(result[:error]).to include("Unknown option 'nonexistent'")
        expect(result[:error]).to include('valid')
        expect(result[:error]).to include('another')
      end
    end
  end
end
