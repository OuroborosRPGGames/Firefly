# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::ProviderThrottle do
  let(:provider) { 'test_provider' }

  before do
    described_class.reset!(provider)
    REDIS_POOL.with { |redis| redis.set("llm:slots:#{provider}:limit", 5) }
  end

  after { described_class.reset!(provider) }

  describe '.acquire_slot / .release_slot' do
    it 'acquires and releases slots' do
      expect(described_class.acquire_slot(provider, timeout: 5)).to be true
      expect(described_class.current_slots(provider)).to eq(1)

      described_class.release_slot(provider)
      expect(described_class.current_slots(provider)).to eq(0)
    end

    it 'blocks when at limit' do
      5.times { described_class.acquire_slot(provider, timeout: 5) }
      expect(described_class.current_slots(provider)).to eq(5)
      expect(described_class.acquire_slot(provider, timeout: 1)).to be false
    end

    it 'allows acquisition after slot released' do
      5.times { described_class.acquire_slot(provider, timeout: 5) }
      Thread.new { sleep 0.3; described_class.release_slot(provider) }
      expect(described_class.acquire_slot(provider, timeout: 5)).to be true
    end

    it 'does not let slot count go below zero on extra release' do
      described_class.release_slot(provider)
      expect(described_class.current_slots(provider)).to eq(0)
    end
  end

  describe '.record_rate_limit' do
    it 'reduces the limit by 25%' do
      described_class.record_rate_limit(provider)
      # 5 * 0.75 = 3.75 -> 3 (to_i)
      expect(described_class.current_limit(provider)).to eq(3)
    end

    it 'sets a backoff period' do
      described_class.record_rate_limit(provider)
      backoff = REDIS_POOL.with { |redis| redis.get("llm:slots:#{provider}:backoff_until") }
      expect(backoff).not_to be_nil
      expect(backoff.to_f).to be > Time.now.to_f
    end

    it 'never reduces limit below 1' do
      10.times { described_class.record_rate_limit(provider) }
      expect(described_class.current_limit(provider)).to be >= 1
    end

    it 'tracks consecutive 429s' do
      3.times { described_class.record_rate_limit(provider) }
      count = REDIS_POOL.with { |redis| redis.get("llm:slots:#{provider}:consecutive_429s").to_i }
      expect(count).to eq(3)
    end
  end

  describe '.record_success' do
    it 'clears backoff' do
      described_class.record_rate_limit(provider)
      described_class.record_success(provider)
      backoff = REDIS_POOL.with { |redis| redis.get("llm:slots:#{provider}:backoff_until") }
      expect(backoff).to be_nil
    end

    it 'resets consecutive 429 count' do
      3.times { described_class.record_rate_limit(provider) }
      described_class.record_success(provider)
      count = REDIS_POOL.with { |redis| redis.get("llm:slots:#{provider}:consecutive_429s").to_i }
      expect(count).to eq(0)
    end

    it 'increases limit after streak of successes' do
      # Use a higher limit so that 10% recovery is visible after to_i truncation
      # limit=20 -> rate_limit -> floor(20*0.75)=15 -> recovery -> floor(15*1.10)=16 > 15
      REDIS_POOL.with { |redis| redis.set("llm:slots:#{provider}:limit", 20) }
      described_class.record_rate_limit(provider)
      reduced_limit = described_class.current_limit(provider)

      # recovery_streak is 20, so need 20+ successes to trigger recovery
      21.times { described_class.record_success(provider) }
      expect(described_class.current_limit(provider)).to be > reduced_limit
    end

    it 'does not increase limit beyond original max' do
      # Default limit for test_provider is 50 (fallback in code)
      # But we set it to 5 above. After rate limit + recovery,
      # recovery is capped at CONCURRENCY_LIMITS[provider.to_sym] || 50
      100.times { described_class.record_success(provider) }
      expect(described_class.current_limit(provider)).to be <= 50
    end
  end

  describe '.current_slots' do
    it 'returns 0 when no slots acquired' do
      expect(described_class.current_slots(provider)).to eq(0)
    end
  end

  describe '.current_limit' do
    it 'returns configured limit' do
      expect(described_class.current_limit(provider)).to eq(5)
    end

    it 'returns fallback of 50 for unknown provider with no stored limit' do
      described_class.reset!('unknown_provider')
      expect(described_class.current_limit('unknown_provider')).to eq(50)
    end
  end

  describe '.reset!' do
    it 'clears all state for provider' do
      described_class.acquire_slot(provider, timeout: 5)
      described_class.record_rate_limit(provider)

      described_class.reset!(provider)

      expect(described_class.current_slots(provider)).to eq(0)
      backoff = REDIS_POOL.with { |redis| redis.get("llm:slots:#{provider}:backoff_until") }
      expect(backoff).to be_nil
    end
  end
end
