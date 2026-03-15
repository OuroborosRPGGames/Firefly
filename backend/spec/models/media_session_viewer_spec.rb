# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MediaSessionViewer do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality)
  end
  let(:media_session) { create(:media_session) }

  describe 'validations' do
    it 'requires media_session_id' do
      viewer = described_class.new(character_instance_id: character_instance.id)
      expect(viewer.valid?).to be false
    end

    it 'requires character_instance_id' do
      viewer = described_class.new(media_session_id: media_session.id)
      expect(viewer.valid?).to be false
    end

    it 'validates connection_status when present' do
      viewer = described_class.new(
        media_session_id: media_session.id,
        character_instance_id: character_instance.id,
        connection_status: 'invalid'
      )
      expect(viewer.valid?).to be false
    end

    it 'is valid with required fields' do
      viewer = described_class.new(
        media_session_id: media_session.id,
        character_instance_id: character_instance.id
      )
      expect(viewer.valid?).to be true
    end

    it 'accepts valid connection statuses' do
      %w[pending connected disconnected].each do |status|
        viewer = described_class.new(
          media_session_id: media_session.id,
          character_instance_id: character_instance.id,
          connection_status: status
        )
        expect(viewer.valid?).to be true
      end
    end
  end

  describe '#pending?' do
    it 'returns true when status is pending' do
      viewer = described_class.new(connection_status: 'pending')
      expect(viewer.pending?).to be true
    end

    it 'returns false when status is not pending' do
      viewer = described_class.new(connection_status: 'connected')
      expect(viewer.pending?).to be false
    end
  end

  describe '#connected?' do
    it 'returns true when status is connected' do
      viewer = described_class.new(connection_status: 'connected')
      expect(viewer.connected?).to be true
    end

    it 'returns false when status is not connected' do
      viewer = described_class.new(connection_status: 'pending')
      expect(viewer.connected?).to be false
    end
  end

  describe '#disconnected?' do
    it 'returns true when status is disconnected' do
      viewer = described_class.new(connection_status: 'disconnected')
      expect(viewer.disconnected?).to be true
    end

    it 'returns false when status is not disconnected' do
      viewer = described_class.new(connection_status: 'connected')
      expect(viewer.disconnected?).to be false
    end
  end

  describe '#mark_connected!' do
    it 'updates status to connected and sets last_seen' do
      viewer = described_class.create(
        media_session_id: media_session.id,
        character_instance_id: character_instance.id,
        connection_status: 'pending'
      )
      viewer.mark_connected!
      viewer.refresh
      expect(viewer.connection_status).to eq('connected')
      expect(viewer.last_seen).not_to be_nil
    end
  end

  describe '#mark_disconnected!' do
    it 'updates status to disconnected' do
      viewer = described_class.create(
        media_session_id: media_session.id,
        character_instance_id: character_instance.id,
        connection_status: 'connected'
      )
      viewer.mark_disconnected!
      viewer.refresh
      expect(viewer.connection_status).to eq('disconnected')
    end
  end

  describe '#touch!' do
    it 'updates last_seen timestamp' do
      viewer = described_class.create(
        media_session_id: media_session.id,
        character_instance_id: character_instance.id
      )
      original_time = viewer.last_seen
      viewer.touch!
      viewer.refresh
      expect(viewer.last_seen).not_to eq(original_time)
    end
  end

  describe '#to_hash' do
    it 'returns hash with viewer data' do
      viewer = described_class.create(
        media_session_id: media_session.id,
        character_instance_id: character_instance.id,
        connection_status: 'connected',
        peer_id: 'peer123',
        joined_at: Time.now
      )
      hash = viewer.to_hash
      expect(hash[:id]).to eq(viewer.id)
      expect(hash[:session_id]).to eq(media_session.id)
      expect(hash[:character_id]).to eq(character_instance.id)
      expect(hash[:peer_id]).to eq('peer123')
      expect(hash[:status]).to eq('connected')
    end
  end
end
