# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ChannelHistoryService do
  let(:ci) { create(:character_instance, messaging_mode: 'channel', last_channel_name: 'ooc') }

  describe '.push' do
    it 'adds current state to history' do
      described_class.push(ci)
      ci.refresh

      history = ci.channel_history
      expect(history.length).to eq(1)
      expect(history[0]['mode']).to eq('channel')
      expect(history[0]['channel_name']).to eq('ooc')
    end

    it 'prepends most recent first' do
      ci.update(messaging_mode: 'channel', last_channel_name: 'newbie')
      described_class.push(ci)

      ci.update(messaging_mode: 'channel', last_channel_name: 'ooc')
      described_class.push(ci)

      ci.refresh
      history = ci.channel_history
      expect(history.length).to eq(2)
      expect(history[0]['channel_name']).to eq('ooc')
      expect(history[1]['channel_name']).to eq('newbie')
    end

    it 'deduplicates entries with the same channel' do
      ci.update(messaging_mode: 'channel', last_channel_name: 'ooc')
      described_class.push(ci)

      ci.update(messaging_mode: 'channel', last_channel_name: 'newbie')
      described_class.push(ci)

      # Push ooc again — should not create a duplicate
      ci.update(messaging_mode: 'channel', last_channel_name: 'ooc')
      described_class.push(ci)

      ci.refresh
      history = ci.channel_history
      expect(history.length).to eq(2)
      expect(history[0]['channel_name']).to eq('ooc')
      expect(history[1]['channel_name']).to eq('newbie')
    end

    it 'deduplicates same ooc targets' do
      ci.update(
        messaging_mode: 'ooc',
        last_channel_name: 'ooc',
        current_ooc_target_ids: Sequel.pg_array([5, 10]),
        ooc_target_names: 'Alice,Bob'
      )
      described_class.push(ci)

      ci.update(messaging_mode: 'channel', last_channel_name: 'newbie')
      described_class.push(ci)

      # Same ooc targets again (different order)
      ci.update(
        messaging_mode: 'ooc',
        last_channel_name: 'ooc',
        current_ooc_target_ids: Sequel.pg_array([10, 5]),
        ooc_target_names: 'Bob,Alice'
      )
      described_class.push(ci)

      ci.refresh
      history = ci.channel_history
      expect(history.length).to eq(2)
      expect(history[0]['mode']).to eq('ooc')
      expect(history[1]['channel_name']).to eq('newbie')
    end

    it 'deduplicates same msg targets' do
      ci.update(
        messaging_mode: 'msg',
        last_channel_name: 'msg',
        msg_target_character_ids: Sequel.pg_array([3, 7]),
        msg_target_names: 'Charlie,Dave'
      )
      described_class.push(ci)

      ci.update(messaging_mode: 'channel', last_channel_name: 'ooc')
      described_class.push(ci)

      # Same msg targets
      ci.update(
        messaging_mode: 'msg',
        last_channel_name: 'msg',
        msg_target_character_ids: Sequel.pg_array([7, 3]),
        msg_target_names: 'Dave,Charlie'
      )
      described_class.push(ci)

      ci.refresh
      history = ci.channel_history
      expect(history.length).to eq(2)
    end

    it 'caps at 25 entries' do
      30.times do |i|
        ci.update(messaging_mode: 'channel', last_channel_name: "chan#{i}")
        described_class.push(ci)
      end

      ci.refresh
      expect(ci.channel_history.length).to eq(25)
    end

    it 'resets cursor to 0' do
      ci.update(channel_history_cursor: 5)
      described_class.push(ci)
      ci.refresh
      expect(ci.channel_history_cursor).to eq(0)
    end
  end

  describe '.cycle' do
    before do
      # Build a history: [channel:ooc (0), channel:newbie (1), ooc:targets (2)]
      ci.update(messaging_mode: 'ooc', last_channel_name: 'ooc',
                current_ooc_target_ids: Sequel.pg_array([5]), ooc_target_names: 'Alice')
      described_class.push(ci)

      ci.update(messaging_mode: 'channel', last_channel_name: 'newbie',
                current_ooc_target_ids: Sequel.pg_array([]))
      described_class.push(ci)

      ci.update(messaging_mode: 'channel', last_channel_name: 'ooc',
                current_ooc_target_ids: Sequel.pg_array([]))
      described_class.push(ci)

      ci.refresh
      # History: [channel:ooc, channel:newbie, ooc:Alice]
    end

    it 'cycles up and applies entry' do
      new_cursor = described_class.cycle(ci, 'up')
      expect(new_cursor).to eq(1)

      ci.refresh
      expect(ci.messaging_mode).to eq('channel')
      expect(ci.last_channel_name).to eq('newbie')
      expect(ci.channel_history_cursor).to eq(1)
    end

    it 'cycles up twice to reach older entry' do
      described_class.cycle(ci, 'up')
      new_cursor = described_class.cycle(ci, 'up')
      expect(new_cursor).to eq(2)

      ci.refresh
      expect(ci.messaging_mode).to eq('ooc')
      expect(ci.ooc_target_names).to eq('Alice')
    end

    it 'cycles down from a non-zero cursor' do
      # First go up twice
      described_class.cycle(ci, 'up')
      described_class.cycle(ci, 'up')

      # Now cycle down
      new_cursor = described_class.cycle(ci, 'down')
      expect(new_cursor).to eq(1)

      ci.refresh
      expect(ci.last_channel_name).to eq('newbie')
    end

    it 'returns nil when at bottom boundary (cursor 0, down)' do
      result = described_class.cycle(ci, 'down')
      expect(result).to be_nil
    end

    it 'returns nil when at top boundary' do
      # Go to the end
      described_class.cycle(ci, 'up')
      described_class.cycle(ci, 'up')
      result = described_class.cycle(ci, 'up')
      expect(result).to be_nil
    end

    it 'returns nil for empty history' do
      empty_ci = create(:character_instance)
      result = described_class.cycle(empty_ci, 'up')
      expect(result).to be_nil
    end

    it 'applies correct msg state' do
      # Add a msg entry
      ci.update(
        messaging_mode: 'msg',
        last_channel_name: 'msg',
        msg_target_character_ids: Sequel.pg_array([10]),
        msg_target_names: 'Bob'
      )
      described_class.push(ci)
      ci.refresh

      # Go back to most recent (already at 0), then cycle up to next
      new_cursor = described_class.cycle(ci, 'up')
      expect(new_cursor).to eq(1)

      ci.refresh
      expect(ci.messaging_mode).to eq('channel')
      expect(ci.last_channel_name).to eq('ooc')
    end

    it 'returns nil for invalid direction' do
      result = described_class.cycle(ci, 'left')
      expect(result).to be_nil
    end
  end

  describe '.reset_cursor' do
    it 'resets cursor to 0' do
      ci.update(channel_history_cursor: 3)
      described_class.reset_cursor(ci)
      ci.refresh
      expect(ci.channel_history_cursor).to eq(0)
    end
  end
end
