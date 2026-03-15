# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HelpRequestCache do
  describe 'class structure' do
    it 'is a class' do
      expect(described_class).to be_a(Class)
    end
  end

  describe 'constants' do
    it 'defines TTL_SECONDS' do
      expect(described_class::TTL_SECONDS).to eq(600)
    end

    it 'defines MAX_ENTRIES' do
      expect(described_class::MAX_ENTRIES).to eq(1000)
    end
  end

  describe 'class methods' do
    it 'defines store' do
      expect(described_class).to respond_to(:store)
    end

    it 'defines recent_for' do
      expect(described_class).to respond_to(:recent_for)
    end

    it 'defines clear!' do
      expect(described_class).to respond_to(:clear!)
    end

    it 'defines stats' do
      expect(described_class).to respond_to(:stats)
    end
  end

  describe 'caching behavior' do
    before { described_class.clear! }
    after { described_class.clear! }

    it 'can store and retrieve values' do
      described_class.store(
        character_instance_id: 123,
        query: 'test query',
        response: 'test response',
        matched_topics: ['topic1']
      )
      result = described_class.recent_for(123)
      expect(result).not_to be_nil
      expect(result[:query]).to eq('test query')
      expect(result[:response]).to eq('test response')
    end

    it 'returns nil for missing keys' do
      result = described_class.recent_for(999)
      expect(result).to be_nil
    end

    it 'can clear all entries' do
      described_class.store(
        character_instance_id: 1,
        query: 'q1',
        response: 'r1',
        matched_topics: []
      )
      described_class.store(
        character_instance_id: 2,
        query: 'q2',
        response: 'r2',
        matched_topics: []
      )
      described_class.clear!
      expect(described_class.stats[:entries]).to eq(0)
    end
  end
end
