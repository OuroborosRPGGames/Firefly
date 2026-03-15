# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CommunicationPermissionHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    it 'defines check_ic_permission' do
      expect(described_class.instance_methods).to include(:check_ic_permission)
    end

    it 'defines check_ooc_permission' do
      expect(described_class.instance_methods).to include(:check_ooc_permission)
    end
  end

  # Create a test class that includes the helper with required dependencies
  let(:test_class) do
    Class.new do
      include CommunicationPermissionHelper

      attr_accessor :character, :character_instance

      def error_result(msg)
        { success: false, error: msg }
      end
    end
  end

  let(:sender_user) { double(id: 1) }
  let(:target_user) { double(id: 2) }
  let(:sender_instance) { double(id: 10) }
  let(:character) { double(user: sender_user, full_name: 'Sender') }
  let(:target_character) { double(user: target_user, full_name: 'Target') }
  let(:target_instance) { double(character: target_character) }

  let(:instance) do
    obj = test_class.new
    obj.character = character
    obj.character_instance = sender_instance
    # display_name_for returns the target's full_name by default in tests
    allow(target_character).to receive(:display_name_for).with(sender_instance).and_return('Target')
    obj
  end

  describe '#check_ic_permission' do
    before do
      allow(Relationship).to receive(:blocked_for_between?).and_return(false)
    end

    it 'returns nil for NPC targets (no user)' do
      npc_instance = double(character: double(user: nil))
      expect(instance.check_ic_permission(npc_instance)).to be_nil
    end

    it 'returns nil when IC messaging is allowed' do
      allow(UserPermission).to receive(:ic_allowed?).with(sender_user, target_user).and_return(true)
      expect(instance.check_ic_permission(target_instance)).to be_nil
    end

    it 'returns error when IC messaging is blocked' do
      allow(UserPermission).to receive(:ic_allowed?).with(sender_user, target_user).and_return(false)
      result = instance.check_ic_permission(target_instance)
      expect(result[:success]).to be false
      expect(result[:error]).to include('blocked IC messages')
    end

    it 'returns error when relationship dm block exists' do
      allow(Relationship).to receive(:blocked_for_between?).with(character, target_character, 'dm').and_return(true)
      result = instance.check_ic_permission(target_instance)
      expect(result[:success]).to be false
      expect(result[:error]).to include('blocked IC messages')
    end
  end

  describe '#check_ooc_permission' do
    before do
      allow(Relationship).to receive(:blocked_for_between?).and_return(false)
    end

    it 'returns nil for NPC targets (no user)' do
      npc_instance = double(character: double(user: nil))
      expect(instance.check_ooc_permission(npc_instance)).to be_nil
    end

    context 'when permission is yes' do
      it 'returns nil' do
        allow(UserPermission).to receive(:ooc_permission).with(sender_user, target_user).and_return('yes')
        expect(instance.check_ooc_permission(target_instance)).to be_nil
      end
    end

    context 'when permission is no' do
      it 'returns error' do
        allow(UserPermission).to receive(:ooc_permission).with(sender_user, target_user).and_return('no')
        result = instance.check_ooc_permission(target_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('blocked OOC messages')
      end
    end

    context 'when permission is ask' do
      before do
        allow(UserPermission).to receive(:ooc_permission).with(sender_user, target_user).and_return('ask')
      end

      it 'returns nil when request has been accepted' do
        allow(OocRequest).to receive(:has_accepted_request?).with(sender_user, target_user).and_return(true)
        expect(instance.check_ooc_permission(target_instance)).to be_nil
      end

      it 'returns error with instructions when no accepted request' do
        allow(OocRequest).to receive(:has_accepted_request?).with(sender_user, target_user).and_return(false)
        result = instance.check_ooc_permission(target_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('requires an OOC request')
        expect(result[:error]).to include('oocrequest')
      end
    end

    context 'when permission is generic (defaults to yes)' do
      it 'returns nil' do
        allow(UserPermission).to receive(:ooc_permission).with(sender_user, target_user).and_return('generic')
        expect(instance.check_ooc_permission(target_instance)).to be_nil
      end
    end

    context 'when relationship ooc block exists' do
      it 'returns error' do
        allow(Relationship).to receive(:blocked_for_between?).with(character, target_character, 'ooc').and_return(true)
        result = instance.check_ooc_permission(target_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('blocked OOC messages')
      end
    end
  end
end
