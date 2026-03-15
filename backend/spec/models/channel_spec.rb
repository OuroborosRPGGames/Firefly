# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Channel do
  let(:universe) { create(:universe) }

  describe 'validations' do
    it 'requires name' do
      channel = Channel.new(channel_type: 'ooc', universe: universe)
      expect(channel.valid?).to be false
      expect(channel.errors[:name]).to include('is not present')
    end

    it 'requires channel_type' do
      channel = Channel.new(name: 'Test Channel', universe: universe)
      expect(channel.valid?).to be false
      expect(channel.errors[:channel_type]).to include('is not present')
    end

    it 'validates name length' do
      channel = Channel.new(name: 'a' * 51, channel_type: 'ooc', universe: universe)
      expect(channel.valid?).to be false
      expect(channel.errors[:name]).to include('is longer than 50 characters')
    end

    it 'validates unique name within universe' do
      create(:channel, name: 'Unique', universe: universe)
      duplicate = Channel.new(name: 'Unique', channel_type: 'ooc', universe: universe)
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[[:universe_id, :name]]).not_to be_empty
    end

    it 'allows same name in different universes' do
      other_universe = create(:universe)
      create(:channel, name: 'Same Name', universe: universe)
      channel = Channel.new(name: 'Same Name', channel_type: 'ooc', universe: other_universe)
      expect(channel.valid?).to be true
    end

    it 'validates channel_type is one of allowed values' do
      channel = Channel.new(name: 'Test', channel_type: 'invalid', universe: universe)
      expect(channel.valid?).to be false
    end

    it 'accepts all valid channel types' do
      Channel::CHANNEL_TYPES.each do |type|
        channel = Channel.new(name: "Test #{type}", channel_type: type, universe: universe)
        expect(channel.valid?).to be(true), "Expected #{type} to be valid but got errors: #{channel.errors.full_messages}"
      end
    end
  end

  describe 'defaults' do
    it 'sets channel_type to ooc via before_save hook' do
      # Note: channel_type is required by validation, so we can't test
      # the default in isolation. The factory sets it, and the before_save
      # hook only applies when nil.
      channel = Channel.new(name: 'Test', universe: universe)
      channel.channel_type = nil
      # before_save sets it to 'ooc' if nil
      channel.before_save
      expect(channel.channel_type).to eq('ooc')
    end

    it 'sets is_default to false by default' do
      channel = create(:channel, universe: universe)
      expect(channel.is_default).to be false
    end
  end

  describe 'type predicates' do
    it '#ooc? returns true when channel_type is ooc' do
      channel = create(:channel, channel_type: 'ooc', universe: universe)
      expect(channel.ooc?).to be true
      expect(channel.ic?).to be false
    end

    it '#ic? returns true when channel_type is ic' do
      channel = create(:channel, channel_type: 'ic', universe: universe)
      expect(channel.ic?).to be true
      expect(channel.ooc?).to be false
    end

    it '#global? returns true when channel_type is global' do
      channel = create(:channel, channel_type: 'global', universe: universe)
      expect(channel.global?).to be true
    end

    it '#private? returns true when channel_type is private' do
      channel = create(:channel, channel_type: 'private', universe: universe)
      expect(channel.private?).to be true
    end
  end

  describe 'member management' do
    let(:channel) { create(:channel, universe: universe) }
    let(:character) { create(:character) }

    describe '#add_member' do
      it 'adds a character as a member' do
        channel.add_member(character)
        expect(channel.member?(character)).to be true
      end

      it 'does not duplicate members' do
        channel.add_member(character)
        channel.add_member(character)
        expect(ChannelMember.where(channel_id: channel.id, character_id: character.id).count).to eq(1)
      end

      it 'accepts role option' do
        channel.add_member(character, role: 'moderator')
        member = ChannelMember.first(channel_id: channel.id, character_id: character.id)
        expect(member.role).to eq('moderator')
      end
    end

    describe '#remove_member' do
      before { channel.add_member(character) }

      it 'removes a character from the channel' do
        channel.remove_member(character)
        expect(channel.member?(character)).to be false
      end
    end

    describe '#member?' do
      it 'returns true when character is a member' do
        channel.add_member(character)
        expect(channel.member?(character)).to be true
      end

      it 'returns false when character is not a member' do
        expect(channel.member?(character)).to be false
      end
    end

    describe '#members' do
      it 'returns dataset with character eager loading' do
        channel.add_member(character)
        result = channel.members
        expect(result).to respond_to(:eager)
      end
    end
  end

  describe 'class methods' do
    describe '.default_channel' do
      context 'when a channel is marked as default' do
        let!(:default_channel) { create(:channel, universe: universe, is_default: true) }
        let!(:other_channel) { create(:channel, universe: universe) }

        it 'returns the channel marked as default' do
          expect(Channel.default_channel).to eq(default_channel)
        end

        it 'respects universe_id filter' do
          expect(Channel.default_channel(universe_id: universe.id)).to eq(default_channel)
        end

        it 'returns nil for different universe' do
          other_universe = create(:universe)
          expect(Channel.default_channel(universe_id: other_universe.id)).to be_nil
        end
      end

      context 'when no default is marked but Newbie channel exists' do
        let!(:newbie_channel) { create(:channel, name: 'Newbie', universe: universe) }
        let!(:other_channel) { create(:channel, universe: universe) }

        it 'returns the Newbie channel' do
          expect(Channel.default_channel).to eq(newbie_channel)
        end

        it 'is case-insensitive for Newbie' do
          newbie_channel.update(name: 'NEWBIE')
          result = Channel.default_channel
          expect(result.id).to eq(newbie_channel.id)
        end
      end

      context 'when no default or Newbie channel exists' do
        let!(:ooc_channel) { create(:channel, channel_type: 'ooc', is_public: true, universe: universe) }

        it 'returns first public OOC channel' do
          expect(Channel.default_channel).to eq(ooc_channel)
        end
      end

      context 'when no channels exist' do
        it 'returns nil' do
          expect(Channel.default_channel).to be_nil
        end
      end
    end

    describe '.ensure_default_membership' do
      let(:character) { create(:character) }

      context 'when character has no channel memberships' do
        let!(:default_channel) { create(:channel, universe: universe, is_default: true) }

        it 'adds character to default channel' do
          Channel.ensure_default_membership(character)
          expect(default_channel.member?(character)).to be true
        end

        it 'returns the default channel' do
          result = Channel.ensure_default_membership(character)
          expect(result).to eq(default_channel)
        end
      end

      context 'when character already has channel memberships' do
        let!(:default_channel) { create(:channel, universe: universe, is_default: true) }
        let!(:other_channel) { create(:channel, universe: universe) }

        before { other_channel.add_member(character) }

        it 'does not add to default channel' do
          Channel.ensure_default_membership(character)
          expect(default_channel.member?(character)).to be false
        end

        it 'still returns the default channel' do
          result = Channel.ensure_default_membership(character)
          expect(result).to eq(default_channel)
        end
      end

      context 'when no default channel exists' do
        it 'returns nil' do
          result = Channel.ensure_default_membership(character)
          expect(result).to be_nil
        end
      end

      context 'when character is nil' do
        it 'returns nil' do
          result = Channel.ensure_default_membership(nil)
          expect(result).to be_nil
        end
      end
    end

    describe '.find_or_create_newbie_channel' do
      context 'when Newbie channel does not exist' do
        it 'creates a new Newbie channel' do
          expect { Channel.find_or_create_newbie_channel }.to change { Channel.count }.by(1)
        end

        it 'sets correct attributes' do
          channel = Channel.find_or_create_newbie_channel
          expect(channel.name).to eq('Newbie')
          expect(channel.channel_type).to eq('ooc')
          expect(channel.is_public).to be true
          expect(channel.is_default).to be true
        end

        it 'sets description' do
          channel = Channel.find_or_create_newbie_channel
          expect(channel.description).to include('new players')
        end

        it 'respects universe_id parameter' do
          channel = Channel.find_or_create_newbie_channel(universe_id: universe.id)
          expect(channel.universe_id).to eq(universe.id)
        end
      end

      context 'when Newbie channel already exists' do
        let!(:existing) { create(:channel, name: 'Newbie', universe: universe) }

        it 'returns existing channel' do
          channel = Channel.find_or_create_newbie_channel(universe_id: universe.id)
          expect(channel.id).to eq(existing.id)
        end

        it 'does not create a new channel' do
          expect { Channel.find_or_create_newbie_channel(universe_id: universe.id) }.not_to change { Channel.count }
        end
      end
    end
  end
end
