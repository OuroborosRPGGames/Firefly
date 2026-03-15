# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Firefly::Scheduler do
  let(:scheduler) { described_class.new }

  after do
    scheduler.stop if scheduler.running
  end

  describe '#initialize' do
    it 'starts with tick_count at 0' do
      expect(scheduler.tick_count).to eq(0)
    end

    it 'starts not running' do
      expect(scheduler.running).to be false
    end
  end

  describe '#on_tick' do
    it 'registers a tick handler' do
      called = false
      scheduler.on_tick { called = true }
      scheduler.fire_tick!

      expect(called).to be true
    end

    it 'passes tick event to handler' do
      received_event = nil
      scheduler.on_tick { |event| received_event = event }
      scheduler.fire_tick!

      expect(received_event).to be_a(Firefly::TickEvent)
      expect(received_event.tick_number).to eq(1)
    end

    it 'respects interval parameter' do
      call_count = 0
      scheduler.on_tick(3) { call_count += 1 }

      5.times { scheduler.fire_tick! }

      expect(call_count).to eq(1) # Only on tick 3
    end

    it 'calls handler at multiples of interval' do
      call_ticks = []
      scheduler.on_tick(2) { |event| call_ticks << event.tick_number }

      6.times { scheduler.fire_tick! }

      expect(call_ticks).to eq([2, 4, 6])
    end
  end

  describe '#on_cron' do
    it 'registers a cron handler' do
      called = false
      spec = { minutes: [], hours: [], days: [], weekdays: [] }
      scheduler.on_cron(spec) { called = true }
      scheduler.process_cron!

      expect(called).to be true
    end

    it 'only calls matching specs' do
      called = false
      # This spec will never match (minute 99 doesn't exist)
      spec = { minutes: [99], hours: [], days: [], weekdays: [] }
      scheduler.on_cron(spec) { called = true }
      scheduler.process_cron!

      expect(called).to be false
    end
  end

  describe '#status' do
    it 'returns scheduler status' do
      status = scheduler.status

      expect(status[:running]).to be false
      expect(status[:tick_count]).to eq(0)
      expect(status[:tick_handlers]).to eq(0)
      expect(status[:cron_handlers]).to eq(0)
    end

    it 'tracks tick handlers' do
      scheduler.on_tick {}
      scheduler.on_tick {}

      expect(scheduler.status[:tick_handlers]).to eq(2)
    end
  end

  describe '#fire_tick!' do
    it 'increments tick count' do
      expect { scheduler.fire_tick! }.to change { scheduler.tick_count }.by(1)
    end
  end
end

RSpec.describe Firefly::TickEvent do
  describe '#initialize' do
    it 'stores tick number and timestamp' do
      time = Time.now
      event = described_class.new(42, time)

      expect(event.tick_number).to eq(42)
      expect(event.timestamp).to eq(time)
    end
  end
end

RSpec.describe Firefly::CronEvent do
  describe '#initialize' do
    it 'stores timestamp' do
      time = Time.new(2025, 1, 15, 14, 30)
      event = described_class.new(time)

      expect(event.timestamp).to eq(time)
      expect(event.hour).to eq(14)
      expect(event.minute).to eq(30)
      expect(event.day).to eq(15)
    end
  end
end
