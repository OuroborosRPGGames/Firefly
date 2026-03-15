# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require_relative '../../../lib/puma/sidekiq_settings'

RSpec.describe Puma::SidekiqSettings do
  describe '.load' do
    it 'normalizes sidekiq.yml keys without leading colons' do
      file = Tempfile.new('sidekiq.yml')
      file.write <<~YAML
        :concurrency: 12
        :timeout: 300
        :queues:
          - [llm, 10]
          - [default, 1]
      YAML
      file.rewind

      settings = described_class.load(file.path)
      expect(settings['concurrency']).to eq(12)
      expect(settings['timeout']).to eq(300)
      expect(settings['queues']).to eq([['llm', 10], ['default', 1]])
    ensure
      file.close
      file.unlink
    end

    it 'returns an empty hash when file is invalid' do
      file = Tempfile.new('sidekiq-invalid.yml')
      file.write(":concurrency: [\n")
      file.rewind

      expect(described_class.load(file.path)).to eq({})
    ensure
      file.close
      file.unlink
    end
  end

  describe '.expand_weighted_queues' do
    it 'expands weighted queue entries into duplicate queue names' do
      queues = described_class.expand_weighted_queues([['llm', 3], ['battle_map', 2], ['default', 1]])
      expect(queues).to eq(%w[llm llm llm battle_map battle_map default])
    end

    it 'falls back to default queues when queue settings are missing' do
      expect(described_class.expand_weighted_queues(nil)).to eq(%w[default])
    end
  end
end
