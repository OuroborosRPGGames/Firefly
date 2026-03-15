# frozen_string_literal: true

require 'spec_helper'

RSpec.describe InteractionPermissionService do
  describe 'constants' do
    it 'defines PERMISSION_TYPES' do
      expect(described_class::PERMISSION_TYPES).to eq(%w[follow dress undress interact])
    end

    it 'defines DEFAULT_TTL' do
      expect(described_class::DEFAULT_TTL).to eq(3600)
    end
  end

  describe '.has_permission?' do
    let(:actor) { double('CharacterInstance', id: 1, current_room_id: 123, character: double('Character')) }
    let(:target) { double('CharacterInstance', id: 2, character: double('Character')) }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
      allow(redis).to receive(:get).and_return(nil)
      allow(Relationship).to receive(:between).and_return(nil)
    end

    context 'with invalid permission type' do
      it 'returns false for unknown type' do
        result = described_class.has_permission?(actor, target, 'invalid_type')

        expect(result).to be false
      end
    end

    context 'when actor is target' do
      let(:same_actor) { double('CharacterInstance', id: 1) }

      it 'returns false' do
        result = described_class.has_permission?(same_actor, same_actor, 'dress')

        expect(result).to be false
      end
    end

    context 'with permanent permission' do
      let(:relationship) { double('Relationship', accepted?: true, can_dress: true) }

      before do
        allow(Relationship).to receive(:between).with(actor.character, target.character).and_return(relationship)
      end

      it 'returns true' do
        result = described_class.has_permission?(actor, target, 'dress')

        expect(result).to be true
      end
    end

    context 'with temporary permission' do
      before do
        allow(redis).to receive(:get).and_return('granted')
      end

      it 'returns true' do
        result = described_class.has_permission?(actor, target, 'follow')

        expect(result).to be true
      end
    end

    context 'with room-scoped permission' do
      it 'checks room-scoped key' do
        expect(redis).to receive(:get).with('permission:follow:1:2:123').and_return('granted')

        described_class.has_permission?(actor, target, 'follow', room_scoped: true)
      end
    end

    context 'with no permission' do
      it 'returns false' do
        result = described_class.has_permission?(actor, target, 'dress')

        expect(result).to be false
      end
    end
  end

  describe '.grant_temporary_permission' do
    let(:granter) { double('CharacterInstance', id: 2) }
    let(:grantee) { double('CharacterInstance', id: 1) }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
    end

    context 'with valid permission type' do
      it 'sets key in Redis with TTL' do
        expect(redis).to receive(:setex).with('permission:dress:1:2', 3600, 'granted')

        described_class.grant_temporary_permission(granter, grantee, 'dress')
      end

      it 'returns true on success' do
        allow(redis).to receive(:setex)

        result = described_class.grant_temporary_permission(granter, grantee, 'follow')

        expect(result).to be true
      end

      it 'accepts custom TTL' do
        expect(redis).to receive(:setex).with('permission:dress:1:2', 7200, 'granted')

        described_class.grant_temporary_permission(granter, grantee, 'dress', ttl: 7200)
      end

      it 'includes room_id in key when provided' do
        expect(redis).to receive(:setex).with('permission:dress:1:2:123', 3600, 'granted')

        described_class.grant_temporary_permission(granter, grantee, 'dress', room_id: 123)
      end
    end

    context 'with invalid permission type' do
      it 'returns false' do
        result = described_class.grant_temporary_permission(granter, grantee, 'invalid')

        expect(result).to be false
      end
    end

    context 'when Redis fails' do
      before do
        allow(redis).to receive(:setex).and_raise(StandardError, 'Connection failed')
      end

      it 'returns false' do
        result = described_class.grant_temporary_permission(granter, grantee, 'dress')

        expect(result).to be false
      end
    end
  end

  describe '.revoke_temporary_permission' do
    let(:granter) { double('CharacterInstance', id: 2) }
    let(:grantee) { double('CharacterInstance', id: 1) }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
    end

    context 'with valid permission type' do
      it 'deletes key from Redis' do
        expect(redis).to receive(:del).with('permission:follow:1:2')

        described_class.revoke_temporary_permission(granter, grantee, 'follow')
      end

      it 'returns true on success' do
        allow(redis).to receive(:del)

        result = described_class.revoke_temporary_permission(granter, grantee, 'follow')

        expect(result).to be true
      end

      it 'includes room_id in key when provided' do
        expect(redis).to receive(:del).with('permission:dress:1:2:456')

        described_class.revoke_temporary_permission(granter, grantee, 'dress', room_id: 456)
      end
    end

    context 'with invalid permission type' do
      it 'returns false' do
        result = described_class.revoke_temporary_permission(granter, grantee, 'invalid')

        expect(result).to be false
      end
    end

    context 'when Redis fails' do
      before do
        allow(redis).to receive(:del).and_raise(StandardError, 'Connection failed')
      end

      it 'returns false' do
        result = described_class.revoke_temporary_permission(granter, grantee, 'follow')

        expect(result).to be false
      end
    end
  end

  describe '.clear_temporary_permissions' do
    let(:character_instance) { double('CharacterInstance', id: 42) }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
    end

    context 'clearing all permissions' do
      it 'scans all permission types' do
        described_class::PERMISSION_TYPES.each do |type|
          expect(redis).to receive(:scan).with("0", match: "permission:#{type}:42:*", count: 100).and_return(["0", []])
        end

        described_class.clear_temporary_permissions(character_instance)
      end

      it 'deletes found keys' do
        described_class::PERMISSION_TYPES.each do |type|
          if type == 'follow'
            allow(redis).to receive(:scan).with("0", match: "permission:follow:42:*", count: 100).and_return(["0", ['permission:follow:42:5']])
          else
            allow(redis).to receive(:scan).with("0", match: "permission:#{type}:42:*", count: 100).and_return(["0", []])
          end
        end
        expect(redis).to receive(:del).with('permission:follow:42:5')

        described_class.clear_temporary_permissions(character_instance)
      end

      it 'returns true' do
        allow(redis).to receive(:scan).and_return(["0", []])

        result = described_class.clear_temporary_permissions(character_instance)

        expect(result).to be true
      end
    end

    context 'clearing specific permission type' do
      it 'only clears specified type' do
        expect(redis).to receive(:scan).with("0", match: 'permission:dress:42:*', count: 100).and_return(["0", []])

        described_class.clear_temporary_permissions(character_instance, permission_type: 'dress')
      end
    end

    context 'clearing room-scoped permissions' do
      it 'appends room_id to pattern' do
        expect(redis).to receive(:scan).with("0", match: 'permission:follow:42:*:123', count: 100).and_return(["0", []])

        described_class.clear_temporary_permissions(character_instance, permission_type: 'follow', room_id: 123)
      end
    end

    context 'when Redis fails' do
      before do
        allow(redis).to receive(:scan).and_raise(StandardError, 'Connection failed')
      end

      it 'returns false' do
        result = described_class.clear_temporary_permissions(character_instance)

        expect(result).to be false
      end
    end
  end

  describe '.grant_permanent_permission' do
    let(:granter_character) { double('Character', id: 10) }
    let(:grantee_character) { double('Character', id: 20) }
    let(:relationship) { double('Relationship') }

    before do
      allow(Relationship).to receive(:find_or_create_between).and_return(relationship)
      allow(relationship).to receive(:update)
    end

    context 'with valid permission type' do
      it 'creates or finds relationship' do
        expect(Relationship).to receive(:find_or_create_between).with(grantee_character, granter_character)

        described_class.grant_permanent_permission(granter_character, grantee_character, 'dress')
      end

      it 'updates relationship with permission' do
        expect(relationship).to receive(:update).with(status: 'accepted', can_dress: true)

        described_class.grant_permanent_permission(granter_character, grantee_character, 'dress')
      end

      it 'returns true on success' do
        result = described_class.grant_permanent_permission(granter_character, grantee_character, 'dress')

        expect(result).to be true
      end

      described_class::PERMISSION_TYPES.each do |perm_type|
        it "grants #{perm_type} permission" do
          field = :"can_#{perm_type}"
          expect(relationship).to receive(:update).with(status: 'accepted', field => true)

          described_class.grant_permanent_permission(granter_character, grantee_character, perm_type)
        end
      end
    end

    context 'with invalid permission type' do
      it 'returns false' do
        result = described_class.grant_permanent_permission(granter_character, grantee_character, 'invalid')

        expect(result).to be false
      end
    end

    context 'when database fails' do
      before do
        allow(Relationship).to receive(:find_or_create_between).and_raise(StandardError, 'DB error')
      end

      it 'returns false' do
        result = described_class.grant_permanent_permission(granter_character, grantee_character, 'dress')

        expect(result).to be false
      end
    end
  end

  describe '.revoke_permanent_permission' do
    let(:granter_character) { double('Character', id: 10) }
    let(:grantee_character) { double('Character', id: 20) }
    let(:relationship) { double('Relationship') }

    before do
      allow(Relationship).to receive(:between).and_return(relationship)
      allow(relationship).to receive(:update)
    end

    context 'with valid permission and existing relationship' do
      it 'updates relationship to revoke permission' do
        expect(relationship).to receive(:update).with(can_follow: false)

        described_class.revoke_permanent_permission(granter_character, grantee_character, 'follow')
      end

      it 'returns true on success' do
        result = described_class.revoke_permanent_permission(granter_character, grantee_character, 'follow')

        expect(result).to be true
      end
    end

    context 'with no relationship' do
      before do
        allow(Relationship).to receive(:between).and_return(nil)
      end

      it 'returns false' do
        result = described_class.revoke_permanent_permission(granter_character, grantee_character, 'follow')

        expect(result).to be false
      end
    end

    context 'with invalid permission type' do
      it 'returns false' do
        result = described_class.revoke_permanent_permission(granter_character, grantee_character, 'invalid')

        expect(result).to be false
      end
    end

    context 'when database fails' do
      before do
        allow(relationship).to receive(:update).and_raise(StandardError, 'DB error')
      end

      it 'returns false' do
        result = described_class.revoke_permanent_permission(granter_character, grantee_character, 'follow')

        expect(result).to be false
      end
    end
  end

  describe '.permission_status' do
    let(:actor) { double('CharacterInstance', id: 1, current_room_id: 123, character: double('Character')) }
    let(:target) { double('CharacterInstance', id: 2, character: double('Character')) }
    let(:redis) { double('Redis') }

    before do
      allow(REDIS_POOL).to receive(:with).and_yield(redis)
      allow(redis).to receive(:get).and_return(nil)
      allow(Relationship).to receive(:between).and_return(nil)
    end

    it 'returns hash with permanent and temporary status' do
      result = described_class.permission_status(actor, target, 'dress')

      expect(result).to eq({ permanent: false, temporary: false })
    end

    context 'with permanent permission' do
      let(:relationship) { double('Relationship', accepted?: true, can_dress: true) }

      before do
        allow(Relationship).to receive(:between).and_return(relationship)
      end

      it 'shows permanent as true' do
        result = described_class.permission_status(actor, target, 'dress')

        expect(result[:permanent]).to be true
      end
    end

    context 'with temporary permission' do
      before do
        allow(redis).to receive(:get).and_return('granted')
      end

      it 'shows temporary as true' do
        result = described_class.permission_status(actor, target, 'follow')

        expect(result[:temporary]).to be true
      end
    end
  end

  describe 'private methods' do
    describe 'permission field mapping' do
      it 'maps follow to can_follow' do
        result = described_class.send(:permission_field, 'follow')
        expect(result).to eq(:can_follow)
      end

      it 'maps dress to can_dress' do
        result = described_class.send(:permission_field, 'dress')
        expect(result).to eq(:can_dress)
      end

      it 'maps undress to can_undress' do
        result = described_class.send(:permission_field, 'undress')
        expect(result).to eq(:can_undress)
      end

      it 'maps interact to can_interact' do
        result = described_class.send(:permission_field, 'interact')
        expect(result).to eq(:can_interact)
      end

      it 'returns nil for unknown type' do
        result = described_class.send(:permission_field, 'unknown')
        expect(result).to be_nil
      end
    end
  end

  describe 'has_permanent_permission?' do
    let(:actor) { double('CharacterInstance', character: double('Character')) }
    let(:target) { double('CharacterInstance', character: double('Character')) }

    context 'when relationship exists and accepted' do
      let(:relationship) { double('Relationship', accepted?: true) }

      before do
        allow(Relationship).to receive(:between).and_return(relationship)
      end

      it 'returns true for granted follow permission' do
        allow(relationship).to receive(:can_follow).and_return(true)

        result = described_class.send(:has_permanent_permission?, actor, target, 'follow')

        expect(result).to be true
      end

      it 'returns false for denied permission' do
        allow(relationship).to receive(:can_dress).and_return(false)

        result = described_class.send(:has_permanent_permission?, actor, target, 'dress')

        expect(result).to be false
      end
    end

    context 'when relationship is not accepted' do
      let(:relationship) { double('Relationship', accepted?: false) }

      before do
        allow(Relationship).to receive(:between).and_return(relationship)
      end

      it 'returns false' do
        result = described_class.send(:has_permanent_permission?, actor, target, 'dress')

        expect(result).to be false
      end
    end

    context 'when no relationship exists' do
      before do
        allow(Relationship).to receive(:between).and_return(nil)
      end

      it 'returns false' do
        result = described_class.send(:has_permanent_permission?, actor, target, 'dress')

        expect(result).to be false
      end
    end

    context 'when error occurs' do
      before do
        allow(Relationship).to receive(:between).and_raise(StandardError, 'Error')
      end

      it 'returns false' do
        result = described_class.send(:has_permanent_permission?, actor, target, 'dress')

        expect(result).to be false
      end
    end
  end
end
