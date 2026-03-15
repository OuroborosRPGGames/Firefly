# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmoteTurnService do
  let(:room) { create(:room) }
  let(:redis) { instance_double('Redis') }

  before do
    allow(REDIS_POOL).to receive(:with).and_yield(redis)
    allow(redis).to receive(:hset)
    allow(redis).to receive(:expire)
    allow(redis).to receive(:hgetall).and_return({})
    allow(redis).to receive(:publish)
    allow(redis).to receive(:del)
  end

  describe '.record_emote' do
    it 'stores the emote timestamp and refreshes TTL' do
      character_instance = create(:character_instance, current_room: room)
      now = Time.utc(2024, 1, 1, 12, 0, 0)
      key = "emote_turns:room:#{room.id}"

      allow(Time).to receive(:now).and_return(now)

      expect(redis).to receive(:hset).with(key, character_instance.id.to_s, now.to_f.to_s)
      expect(redis).to receive(:expire).with(key, 3600)

      described_class.record_emote(room.id, character_instance.id)
    end
  end

  describe '.next_turn' do
    it 'returns nil when fewer than two active player characters are present' do
      create(:character_instance, current_room: room, online: true, afk: false)
      create(:character_instance, current_room: room, online: false, afk: false)
      create(:character_instance, current_room: room, character: create(:character, :npc), online: true, afk: false)

      expect(described_class.next_turn(room.id)).to be_nil
    end

    it 'chooses the active player who emoted longest ago' do
      active_one = create(:character_instance, current_room: room, online: true, afk: false)
      active_two = create(:character_instance, current_room: room, online: true, afk: false)
      create(:character_instance, current_room: room, online: true, afk: true)
      create(:character_instance, current_room: room, online: true, afk: false, character: create(:character, :npc))

      allow(redis).to receive(:hgetall).and_return(
        active_one.id.to_s => '250.0',
        active_two.id.to_s => '100.0'
      )

      expect(described_class.next_turn(room.id)).to eq(active_two.id)
    end

    it 'prioritizes active players who have never emoted' do
      known = create(:character_instance, current_room: room, online: true, afk: false)
      never_emoted = create(:character_instance, current_room: room, online: true, afk: false)

      allow(redis).to receive(:hgetall).and_return(known.id.to_s => '100.0')

      expect(described_class.next_turn(room.id)).to eq(never_emoted.id)
    end
  end

  describe '.broadcast_turn' do
    it 'publishes a turn update payload to the room channel' do
      character_instance = create(:character_instance, current_room: room)
      allow(described_class).to receive(:next_turn).with(room.id).and_return(character_instance.id)

      expect(redis).to receive(:publish) do |channel, payload|
        parsed = JSON.parse(payload)
        expect(channel).to eq("room:#{room.id}")
        expect(parsed['type']).to eq('turn_update')
        expect(parsed.dig('message', 'turn_instance_id')).to eq(character_instance.id)
        expect(parsed['timestamp']).to be_a(String)
      end

      described_class.broadcast_turn(room.id)
    end

    it 'does not publish when there is no next turn' do
      allow(described_class).to receive(:next_turn).with(room.id).and_return(nil)

      expect(redis).not_to receive(:publish)
      described_class.broadcast_turn(room.id)
    end
  end

  describe '.clear_room' do
    it 'deletes the room turn key' do
      expect(redis).to receive(:del).with("emote_turns:room:#{room.id}")

      described_class.clear_room(room.id)
    end
  end
end
