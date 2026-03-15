# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Argument Normalization Contract' do
  describe 'ArgumentNormalizerService coverage' do
    Commands::Base::Registry.commands.each do |command_name, _command_class|
      describe "#{command_name} command" do
        it 'produces valid normalized output' do
          result = ArgumentNormalizerService.normalize(command_name, 'test input')
          expect(result).to be_a(Hash)
          expect(result.keys).to satisfy('have :raw or structured keys') { |keys|
            keys.include?(:raw) ||
            (keys.include?(:target) && (keys.include?(:message) || keys.include?(:item)))
          }
        end
      end
    end
  end

  describe 'communication commands produce target+message' do
    %w[say tell yell shout whisper mutter].each do |cmd|
      it "#{cmd} normalizes 'to bob hello' correctly" do
        result = ArgumentNormalizerService.normalize(cmd, 'to bob hello')
        expect(result).to include(target: 'bob', message: 'hello')
      end

      it "#{cmd} normalizes 'hello to bob' correctly" do
        result = ArgumentNormalizerService.normalize(cmd, 'hello to bob')
        expect(result).to include(target: 'bob', message: 'hello')
      end
    end
  end

  describe 'transfer commands produce target+item' do
    %w[give hand show throw toss offer].each do |cmd|
      it "#{cmd} normalizes 'sword to bob' correctly" do
        result = ArgumentNormalizerService.normalize(cmd, 'sword to bob')
        expect(result).to include(target: 'bob', item: 'sword')
      end

      it "#{cmd} normalizes 'bob the sword' correctly" do
        result = ArgumentNormalizerService.normalize(cmd, 'bob the sword')
        expect(result).to include(target: 'bob', item: 'sword')
      end
    end
  end

  describe 'container commands produce item with optional container' do
    %w[get take grab drop put discard].each do |cmd|
      it "#{cmd} strips articles from 'the sword'" do
        result = ArgumentNormalizerService.normalize(cmd, 'the sword')
        expect(result).to include(item: 'sword')
      end
    end

    %w[get take grab].each do |cmd|
      it "#{cmd} extracts container from 'sword from bag'" do
        result = ArgumentNormalizerService.normalize(cmd, 'sword from bag')
        expect(result).to include(item: 'sword', container: 'bag', preposition: 'from')
      end
    end

    %w[drop put].each do |cmd|
      it "#{cmd} extracts container from 'sword in bag'" do
        result = ArgumentNormalizerService.normalize(cmd, 'sword in bag')
        expect(result).to include(item: 'sword', container: 'bag', preposition: 'in')
      end
    end
  end

  describe 'parse_input includes normalized key' do
    let(:room) { create(:room) }
    let(:character) { create(:character) }
    let(:reality) { create(:reality) }
    let(:character_instance) do
      create(:character_instance, character: character, current_room: room, reality: reality)
    end

    it 'includes :normalized in parsed_input' do
      cmd_class = Commands::Base::Registry.commands.values.first
      cmd = cmd_class.new(character_instance)
      parsed = cmd.send(:parse_input, 'test hello world')
      expect(parsed).to have_key(:normalized)
      expect(parsed[:normalized]).to be_a(Hash)
    end
  end

  # ========================================
  # Integration specs: end-to-end command execution with normalized input patterns
  # ========================================

  describe 'integration: say with reverse-order target' do
    let(:room) { create(:room) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let(:target_character) { create(:character, forename: 'Bob') }
    let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

    subject(:command) { Commands::Communication::Say.new(character_instance) }

    it '"say hello to Bob" routes to directed speech' do
      result = command.execute('say hello to Bob')

      expect(result[:success]).to be true
      expect(result[:data][:type]).to eq('say_to')
      expect(result[:target]).to eq(target_character.full_name)
    end

    it '"say greetings to Bob" includes the message' do
      result = command.execute('say greetings to Bob')

      expect(result[:success]).to be true
      expect(result[:data][:content]).to eq('greetings')
    end

    it '"say Hello everyone!" still works as basic say (no target)' do
      result = command.execute('say Hello everyone!')

      expect(result[:success]).to be true
      expect(result[:data][:type]).to eq('say')
    end

    it '"yell hey to Bob" works with verb alias' do
      result = command.execute('yell hey to Bob')

      expect(result[:success]).to be true
      expect(result[:data][:type]).to eq('say_to')
    end
  end

  describe 'integration: whisper with flexible patterns' do
    let(:room) { create(:room) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let(:target_character) { create(:character, forename: 'Bob') }
    let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

    subject(:command) { Commands::Communication::Whisper.new(character_instance) }

    it '"whisper to Bob secret" works' do
      result = command.execute('whisper to Bob secret')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(target_character.full_name)
    end

    it '"whisper secret to Bob" works (reverse order)' do
      result = command.execute('whisper secret to Bob')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(target_character.full_name)
    end

    it '"whisper Bob secret" still works (original pattern)' do
      result = command.execute('whisper Bob secret')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(target_character.full_name)
    end
  end

  describe 'integration: give with flexible patterns' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:area) { create(:area, world: world) }
    let(:location) { create(:location, zone: area) }
    let(:room) { create(:room, location: location) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let(:target_character) { create(:character, forename: 'Bob') }
    let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }
    let!(:item) { Item.create(name: 'Sword', character_instance: character_instance, quantity: 1, condition: 'good') }

    subject(:command) { Commands::Inventory::Give.new(character_instance) }

    it '"give sword to Bob" works (original pattern)' do
      result = command.execute('give sword to Bob')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Sword')
    end

    it '"give Bob the sword" works (article pattern)' do
      result = command.execute('give Bob the sword')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Sword')
    end

    it '"give Bob sword" works (target-first pattern)' do
      result = command.execute('give Bob sword')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Sword')
    end

    it '"give sword Bob" resolves via context-aware disambiguation' do
      result = command.execute('give sword Bob')

      # Normalizer detects Bob is a character, swaps ordering
      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Sword')
    end
  end

  describe 'integration: show with flexible patterns' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:area) { create(:area, world: world) }
    let(:location) { create(:location, zone: area) }
    let(:room) { create(:room, location: location) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let(:target_character) { create(:character, forename: 'Bob') }
    let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }
    let!(:item) { Item.create(name: 'Ring', character_instance: character_instance, quantity: 1, condition: 'good') }

    subject(:command) { Commands::Inventory::Show.new(character_instance) }

    it '"show ring to Bob" works (original pattern)' do
      result = command.execute('show ring to Bob')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Ring')
    end

    it '"show Bob the ring" works (article pattern)' do
      result = command.execute('show Bob the ring')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Ring')
    end

    it '"show Bob ring" works (target-first pattern)' do
      result = command.execute('show Bob ring')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Ring')
    end

    it '"show ring Bob" resolves via context-aware disambiguation' do
      result = command.execute('show ring Bob')

      expect(result[:success]).to be true
      expect(result[:data][:item_name]).to eq('Ring')
    end
  end

  describe 'integration: private with reverse-order target' do
    let(:room) { create(:room) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let(:target_character) { create(:character, forename: 'Bob') }
    let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

    subject(:command) { Commands::Social::Private.new(character_instance) }

    it '"private Bob winks" works (original pattern)' do
      result = command.execute('private Bob winks')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(target_character.full_name)
    end

    it '"private to Bob winks" works (to-prefix pattern)' do
      result = command.execute('private to Bob winks')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(target_character.full_name)
    end

    it '"private winks to Bob" works (reverse order)' do
      result = command.execute('private winks to Bob')

      expect(result[:success]).to be true
      expect(result[:target]).to eq(target_character.full_name)
    end
  end

  describe 'integration: attempt with flexible patterns' do
    let(:user) { create(:user) }
    let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
    let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
    let(:reality) { create(:reality) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, stance: 'standing') }
    let(:user2) { create(:user) }
    let(:bob_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
    let!(:bob_instance) { create(:character_instance, character: bob_character, current_room: room, reality: reality, stance: 'standing') }

    subject(:command) { Commands::Communication::Attempt.new(character_instance) }

    it '"attempt Bob hugs" works (original pattern)' do
      result = command.execute('attempt Bob hugs')

      expect(result[:success]).to be true
      expect(result[:data][:target_id]).to eq(bob_instance.id)
    end

    it '"attempt to Bob hugs" works (to-prefix pattern)' do
      result = command.execute('attempt to Bob hugs')

      expect(result[:success]).to be true
      expect(result[:data][:target_id]).to eq(bob_instance.id)
    end

    it '"attempt hugs to Bob" works (reverse order)' do
      result = command.execute('attempt hugs to Bob')

      expect(result[:success]).to be true
      expect(result[:data][:target_id]).to eq(bob_instance.id)
    end
  end

  describe 'integration: pemit without = separator' do
    let(:room) { create(:room) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let(:target_character) { create(:character, forename: 'Bob') }
    let!(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    subject(:command) { Commands::Communication::Pemit.new(character_instance) }

    it '"pemit Bob = message" works (original pattern)' do
      result = command.execute('pemit Bob = A chill runs down your spine.')

      expect(result[:success]).to be true
      expect(result[:data][:targets]).to include('Bob')
    end

    it '"pemit Bob message" works without = separator' do
      result = command.execute('pemit Bob A chill runs down your spine.')

      expect(result[:success]).to be true
      expect(result[:data][:targets]).to include('Bob')
    end
  end

  describe 'integration: get with article stripping' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:area) { create(:area, world: world) }
    let(:location) { create(:location, zone: area) }
    let(:room) { create(:room, location: location) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let!(:item) { Item.create(name: 'Sword', room: room, quantity: 1, condition: 'good') }

    subject(:command) { Commands::Inventory::Get.new(character_instance) }

    it '"get sword" works (original pattern)' do
      result = command.execute('get sword')

      expect(result[:success]).to be true
    end

    it '"get the sword" works with article stripping' do
      result = command.execute('get the sword')

      expect(result[:success]).to be true
    end

    it '"take a sword" works with article stripping' do
      result = command.execute('take a sword')

      expect(result[:success]).to be true
    end
  end

  describe 'integration: drop with article stripping' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:area) { create(:area, world: world) }
    let(:location) { create(:location, zone: area) }
    let(:room) { create(:room, location: location) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
    let!(:item) { Item.create(name: 'Sword', character_instance: character_instance, quantity: 1, condition: 'good') }

    subject(:command) { Commands::Inventory::Drop.new(character_instance) }

    it '"drop sword" works (original pattern)' do
      result = command.execute('drop sword')

      expect(result[:success]).to be true
    end

    it '"drop the sword" works with article stripping' do
      result = command.execute('drop the sword')

      expect(result[:success]).to be true
    end
  end

  describe 'integration: unrelated commands unaffected by normalized key' do
    let(:room) { create(:room) }
    let(:reality) { create(:reality) }
    let(:character) { create(:character, forename: 'Alice') }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

    it 'look command works with normalized key present' do
      cmd = Commands::Navigation::Look.new(character_instance)
      result = cmd.execute('look')

      expect(result[:success]).to be true
    end

    it 'exits command works with normalized key present' do
      cmd = Commands::Navigation::Exits.new(character_instance)
      result = cmd.execute('exits')

      expect(result[:success]).to be true
    end
  end
end
