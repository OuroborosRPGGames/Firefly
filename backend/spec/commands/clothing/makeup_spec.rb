# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Makeup, type: :command do
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

  # Create face positions (required for makeup)
  let!(:eyes_position) { create(:body_position, label: 'eyes', region: 'head') }
  let!(:mouth_position) { create(:body_position, label: 'mouth', region: 'head') }
  let!(:cheeks_position) { create(:body_position, label: 'cheeks', region: 'head') }
  let!(:forehead_position) { create(:body_position, label: 'forehead', region: 'head') }
  let!(:nose_position) { create(:body_position, label: 'nose', region: 'head') }
  let!(:chin_position) { create(:body_position, label: 'chin', region: 'head') }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  describe '#execute' do
    subject(:command) { described_class.new(alice_instance) }

    context 'with no arguments' do
      it 'returns usage error' do
        result = command.execute('makeup')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/who do you want to apply makeup to/i)
      end
    end

    context 'with "me" as target' do
      it 'opens form to apply makeup to self' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          expect(title).to eq('Apply Makeup to Yourself')
          expect(options[:context][:command]).to eq('aesthete')
          expect(options[:context][:aesthete_type]).to eq('makeup')
          expect(options[:context][:target_character_id]).to eq(alice.id)
          expect(options[:context][:performer_id]).to eq(alice.id)
          { success: true, message: 'Form opened' }
        end

        result = command.execute('makeup me')
        expect(result[:success]).to be true
      end

      it 'includes body_position_ids multi-select with face positions only' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          position_field = fields.find { |f| f[:name] == 'body_position_ids' }
          expect(position_field).not_to be_nil
          expect(position_field[:type]).to eq('select')
          expect(position_field[:multiple]).to be true

          # Should only include face positions
          option_labels = position_field[:options].map { |o| o[:label] }
          expect(option_labels).to include('Eyes')
          expect(option_labels).to include('Mouth')
          expect(option_labels).to include('Cheeks')

          { success: true, message: 'Form opened' }
        end

        command.execute('makeup me')
      end

      it 'includes content richtext field' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          content_field = fields.find { |f| f[:name] == 'content' }
          expect(content_field).not_to be_nil
          expect(content_field[:type]).to eq('richtext')
          expect(content_field[:required]).to be true
          expect(content_field[:placeholder]).to include('makeup')
          { success: true, message: 'Form opened' }
        end

        command.execute('makeup me')
      end

      it 'includes image_url field' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          image_field = fields.find { |f| f[:name] == 'image_url' }
          expect(image_field).not_to be_nil
          expect(image_field[:required]).to be false
          { success: true, message: 'Form opened' }
        end

        command.execute('makeup me')
      end
    end

    context 'with face area hint' do
      it 'preselects eyes when "eyes" specified' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          position_field = fields.find { |f| f[:name] == 'body_position_ids' }
          expect(position_field[:default]).to eq(eyes_position.id.to_s)
          { success: true, message: 'Form opened' }
        end

        command.execute('makeup me eyes')
      end

      it 'preselects mouth when "lips" specified' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          position_field = fields.find { |f| f[:name] == 'body_position_ids' }
          expect(position_field[:default]).to eq(mouth_position.id.to_s)
          { success: true, message: 'Form opened' }
        end

        command.execute('makeup me lips')
      end

      it 'preselects cheeks when "cheek" specified' do
        expect(command).to receive(:create_form) do |instance, title, fields, options|
          position_field = fields.find { |f| f[:name] == 'body_position_ids' }
          expect(position_field[:default]).to eq(cheeks_position.id.to_s)
          { success: true, message: 'Form opened' }
        end

        command.execute('makeup me cheek')
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
          result = command.execute('makeup Bob')

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

        it 'opens form to apply makeup to them' do
          expect(command).to receive(:create_form) do |instance, title, fields, options|
            expect(title).to eq('Apply Makeup to Bob')
            expect(options[:context][:target_character_id]).to eq(bob.id)
            expect(options[:context][:performer_id]).to eq(alice.id)
            { success: true, message: 'Form opened' }
          end

          result = command.execute('makeup Bob')
          expect(result[:success]).to be true
        end
      end

      context 'with generic dress_style permission' do
        before do
          # Create generic permission for Bob's user (allows everyone)
          perm = UserPermission.generic_for(bob_user)
          perm.update(dress_style: 'yes')
        end

        it 'opens form to apply makeup to them' do
          expect(command).to receive(:create_form).and_return({ success: true, message: 'Form opened' })

          result = command.execute('makeup Bob')
          expect(result[:success]).to be true
        end
      end
    end

    context 'with non-existent target' do
      it 'returns error' do
        result = command.execute('makeup Charlie')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no one named 'Charlie'/i)
      end
    end

    context 'when no face positions exist' do
      before do
        BodyPosition.where(label: CharacterDefaultDescription::MAKEUP_POSITIONS).delete
      end

      it 'returns error' do
        result = command.execute('makeup me')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/cannot find face body positions/i)
      end
    end
  end

  describe 'FACE_AREAS constant' do
    it 'maps eye aliases to eyes' do
      expect(described_class::FACE_AREAS['eye']).to eq('eyes')
      expect(described_class::FACE_AREAS['eyes']).to eq('eyes')
    end

    it 'maps lip aliases to mouth' do
      expect(described_class::FACE_AREAS['lips']).to eq('mouth')
      expect(described_class::FACE_AREAS['lip']).to eq('mouth')
      expect(described_class::FACE_AREAS['mouth']).to eq('mouth')
    end

    it 'maps cheek aliases to cheeks' do
      expect(described_class::FACE_AREAS['cheek']).to eq('cheeks')
      expect(described_class::FACE_AREAS['cheeks']).to eq('cheeks')
    end
  end

  describe 'command metadata' do
    it 'has the correct command name' do
      expect(described_class.command_name).to eq('makeup')
    end

    it 'has correct aliases' do
      aliases = described_class.alias_names
      expect(aliases).to include('cosmetics')
      expect(aliases).to include('makeover')
    end

    it 'is in the clothing category' do
      expect(described_class.category).to eq(:clothing)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('makeup')
    end
  end

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['makeup']).to eq(described_class)
    end

    it 'is registered under cosmetics alias' do
      command_class, _ = Commands::Base::Registry.find_command('cosmetics')
      expect(command_class).to eq(described_class)
    end

    it 'is registered under makeover alias' do
      command_class, _ = Commands::Base::Registry.find_command('makeover')
      expect(command_class).to eq(described_class)
    end
  end
end
