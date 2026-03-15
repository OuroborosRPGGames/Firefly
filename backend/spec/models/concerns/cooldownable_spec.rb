# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cooldownable do
  # Create a test class that uses Cooldownable
  let(:test_class) do
    Class.new do
      include Cooldownable

      attr_accessor :expires_at, :duration_seconds

      def initialize(expires_at: nil, duration_seconds: nil)
        @expires_at = expires_at
        @duration_seconds = duration_seconds
      end

      def cooldown_expires_at
        @expires_at
      end

      def cooldown_duration_seconds
        @duration_seconds
      end
    end
  end

  describe '#cooldown_active?' do
    it 'returns false when expires_at is nil' do
      instance = test_class.new(expires_at: nil)
      expect(instance.cooldown_active?).to be false
    end

    it 'returns true when expires_at is in the future' do
      instance = test_class.new(expires_at: Time.now + 60)
      expect(instance.cooldown_active?).to be true
    end

    it 'returns false when expires_at is in the past' do
      instance = test_class.new(expires_at: Time.now - 60)
      expect(instance.cooldown_active?).to be false
    end

    it 'returns false when expires_at is exactly now' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now)
      expect(instance.cooldown_active?).to be false
    end
  end

  describe '#cooldown_available?' do
    it 'returns true when cooldown is not active' do
      instance = test_class.new(expires_at: nil)
      expect(instance.cooldown_available?).to be true
    end

    it 'returns true when cooldown has expired' do
      instance = test_class.new(expires_at: Time.now - 60)
      expect(instance.cooldown_available?).to be true
    end

    it 'returns false when cooldown is still active' do
      instance = test_class.new(expires_at: Time.now + 60)
      expect(instance.cooldown_available?).to be false
    end
  end

  describe '#cooldown_remaining_seconds' do
    it 'returns 0 when expires_at is nil' do
      instance = test_class.new(expires_at: nil)
      expect(instance.cooldown_remaining_seconds).to eq(0)
    end

    it 'returns 0 when cooldown has expired' do
      instance = test_class.new(expires_at: Time.now - 60)
      expect(instance.cooldown_remaining_seconds).to eq(0)
    end

    it 'returns remaining seconds when cooldown is active' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now + 30)
      expect(instance.cooldown_remaining_seconds).to eq(30)
    end

    it 'returns integer value' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now + 30.5)
      expect(instance.cooldown_remaining_seconds).to be_a(Integer)
    end

    it 'never returns negative values' do
      instance = test_class.new(expires_at: Time.now - 1000)
      expect(instance.cooldown_remaining_seconds).to eq(0)
    end
  end

  describe '#cooldown_remaining_ms' do
    it 'returns 0 when expires_at is nil' do
      instance = test_class.new(expires_at: nil)
      expect(instance.cooldown_remaining_ms).to eq(0)
    end

    it 'returns 0 when cooldown has expired' do
      instance = test_class.new(expires_at: Time.now - 60)
      expect(instance.cooldown_remaining_ms).to eq(0)
    end

    it 'returns remaining milliseconds when cooldown is active' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now + 5)
      expect(instance.cooldown_remaining_ms).to eq(5000)
    end

    it 'returns integer value' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now + 5.5)
      expect(instance.cooldown_remaining_ms).to be_a(Integer)
    end

    it 'never returns negative values' do
      instance = test_class.new(expires_at: Time.now - 1000)
      expect(instance.cooldown_remaining_ms).to eq(0)
    end
  end

  describe '#cooldown_remaining_percent' do
    it 'returns 0.0 when duration_seconds is not defined' do
      no_duration_class = Class.new do
        include Cooldownable

        attr_accessor :expires_at

        def initialize(expires_at: nil)
          @expires_at = expires_at
        end

        def cooldown_expires_at
          @expires_at
        end
      end

      instance = no_duration_class.new(expires_at: Time.now + 30)
      expect(instance.cooldown_remaining_percent).to eq(0.0)
    end

    it 'returns 0.0 when duration_seconds is zero' do
      instance = test_class.new(expires_at: Time.now + 30, duration_seconds: 0)
      expect(instance.cooldown_remaining_percent).to eq(0.0)
    end

    it 'returns 0.0 when duration_seconds is nil' do
      instance = test_class.new(expires_at: Time.now + 30, duration_seconds: nil)
      expect(instance.cooldown_remaining_percent).to eq(0.0)
    end

    it 'returns 0.0 when cooldown is not active' do
      instance = test_class.new(expires_at: Time.now - 60, duration_seconds: 60)
      expect(instance.cooldown_remaining_percent).to eq(0.0)
    end

    it 'returns percentage when cooldown is active' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now + 30, duration_seconds: 60)
      expect(instance.cooldown_remaining_percent).to eq(0.5)
    end

    it 'returns 1.0 when full cooldown remains' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now + 60, duration_seconds: 60)
      expect(instance.cooldown_remaining_percent).to eq(1.0)
    end

    it 'clamps value to 1.0 maximum' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      # Edge case: expires_at far in future but short duration
      instance = test_class.new(expires_at: now + 120, duration_seconds: 60)
      expect(instance.cooldown_remaining_percent).to eq(1.0)
    end

    it 'clamps value to 0.0 minimum' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)
      instance = test_class.new(expires_at: now - 10, duration_seconds: 60)
      expect(instance.cooldown_remaining_percent).to eq(0.0)
    end
  end

  describe 'integration with real models' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }

    describe 'with ActionCooldown' do
      let(:cooldown) do
        ActionCooldown.set(character_instance, 'test_ability', 30_000) # 30 seconds in ms
      end

      it 'reports cooldown as active' do
        expect(cooldown.cooldown_active?).to be true
      end

      it 'reports cooldown as unavailable' do
        expect(cooldown.cooldown_available?).to be false
      end

      it 'returns remaining seconds' do
        expect(cooldown.cooldown_remaining_seconds).to be > 0
        expect(cooldown.cooldown_remaining_seconds).to be <= 30
      end
    end
  end
end
