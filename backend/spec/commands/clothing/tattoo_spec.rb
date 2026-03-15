# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Tattoo, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:alice_user) { create(:user) }
  let(:alice) { create(:character, user: alice_user, forename: 'Alice') }
  let(:alice_instance) { create(:character_instance, character: alice, current_room: room, reality: reality, online: true) }

  let(:bob_user) { create(:user) }
  let(:bob) { create(:character, user: bob_user, forename: 'Bob') }
  let(:bob_instance) { create(:character_instance, character: bob, current_room: room, reality: reality, online: true) }

  # Create body positions for the form
  let!(:torso_position) { create(:body_position, label: 'chest', region: 'torso') }
  let!(:back_position) { create(:body_position, label: 'back', region: 'torso') }
  let!(:arm_position) { create(:body_position, label: 'upper_arm', region: 'arms') }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  describe '#execute' do
    subject(:command) { described_class.new(alice_instance) }

    context 'with no arguments' do
      it 'returns usage error' do
        result = command.execute('tattoo')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/who do you want to tattoo/i)
      end
    end

    context 'with "me" as target' do
      it 'opens form to tattoo self' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          expect(title).to eq('Tattoo Yourself')
          expect(options[:context][:command]).to eq('aesthete')
          expect(options[:context][:aesthete_type]).to eq('tattoo')
          expect(options[:context][:target_character_id]).to eq(alice.id)
          expect(options[:context][:performer_id]).to eq(alice.id)
          { success: true, message: 'Form opened' }
        end

        result = command.execute('tattoo me')
        expect(result[:success]).to be true
      end

      it 'includes body position field' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          position_field = fields.find { |f| f[:name] == 'body_position_ids' }
          expect(position_field).not_to be_nil
          expect(position_field[:type]).to eq('select')
          expect(position_field[:multiple]).to be true
          { success: true, message: 'Form opened' }
        end

        command.execute('tattoo me')
      end

      it 'includes content richtext field' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          content_field = fields.find { |f| f[:name] == 'content' }
          expect(content_field).not_to be_nil
          expect(content_field[:type]).to eq('richtext')
          expect(content_field[:required]).to be true
          { success: true, message: 'Form opened' }
        end

        command.execute('tattoo me')
      end

      it 'includes image_url field' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          image_field = fields.find { |f| f[:name] == 'image_url' }
          expect(image_field).not_to be_nil
          expect(image_field[:required]).to be false
          { success: true, message: 'Form opened' }
        end

        command.execute('tattoo me')
      end

      it 'includes concealed_by_clothing checkbox' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          concealed_field = fields.find { |f| f[:name] == 'concealed_by_clothing' }
          expect(concealed_field).not_to be_nil
          expect(concealed_field[:type]).to eq('checkbox')
          { success: true, message: 'Form opened' }
        end

        command.execute('tattoo me')
      end
    end

    context 'with "self" as target' do
      it 'opens form to tattoo self' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          expect(title).to eq('Tattoo Yourself')
          { success: true, message: 'Form opened' }
        end

        command.execute('tattoo self')
      end
    end

    context 'with region hint' do
      it 'preselects the hinted region' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          position_field = fields.find { |f| f[:name] == 'body_position_ids' }
          # When 'torso' is hinted, positions in torso region should come first
          expect(position_field[:options].first[:group]).to eq('Torso')
          { success: true, message: 'Form opened' }
        end

        command.execute('tattoo me torso')
      end
    end

    context 'with another character as target' do
      before do
        bob_instance # ensure bob is in the room
      end

      context 'without permission (explicit denial)' do
        before do
          # Create generic permission for Bob's user that denies dress_style
          perm = UserPermission.generic_for(bob_user)
          perm.update(dress_style: 'no')
        end

        it 'returns permission error' do
          result = command.execute('tattoo Bob')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/don't have permission/i)
        end
      end

      context 'with dress_style permission' do
        before do
          # Create specific permission from Bob's user to Alice's user
          perm = UserPermission.specific_for(bob_user, alice_user)
          perm.update(dress_style: 'yes')
        end

        it 'opens form to tattoo Bob' do
          expect(command).to receive(:create_form) do |instance, title, fields, options|
            expect(title).to eq('Tattoo Bob')
            expect(options[:context][:target_character_id]).to eq(bob.id)
            expect(options[:context][:performer_id]).to eq(alice.id)
            { success: true, message: 'Form opened' }
          end

          result = command.execute('tattoo Bob')
          expect(result[:success]).to be true
        end
      end

      context 'with generic dress_style permission' do
        before do
          # Create generic permission for Bob's user (allows everyone)
          perm = UserPermission.generic_for(bob_user)
          perm.update(dress_style: 'yes')
        end

        it 'opens form to tattoo Bob' do
          expect(command).to receive(:create_form).and_return({ success: true, message: 'Form opened' })

          result = command.execute('tattoo Bob')
          expect(result[:success]).to be true
        end
      end
    end

    context 'with non-existent target' do
      it 'returns error' do
        result = command.execute('tattoo Charlie')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one named 'Charlie'/i)
      end
    end
  end

  describe 'command metadata' do
    it 'has the correct command name' do
      expect(described_class.command_name).to eq('tattoo')
    end

    it 'is in the clothing category' do
      expect(described_class.category).to eq(:clothing)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('tattoo')
    end
  end

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['tattoo']).to eq(described_class)
    end
  end
end
