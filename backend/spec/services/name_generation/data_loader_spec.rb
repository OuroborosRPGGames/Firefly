# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

RSpec.describe NameGeneration::DataLoader do
  around do |example|
    original_root = described_class.data_root

    Dir.mktmpdir do |tmp_root|
      forenames_dir = File.join(tmp_root, 'character', 'forenames')
      FileUtils.mkdir_p(forenames_dir)
      File.write(
        File.join(forenames_dir, 'western_male.yml'),
        <<~YAML
          metadata:
            source: test
            tags:
              - western
              - male
          names:
            - John
            - Robert
        YAML
      )
      File.write(
        File.join(forenames_dir, 'western_female.yml'),
        <<~YAML
          metadata:
            source: test
          names:
            - Alice
            - Mary
        YAML
      )

      described_class.data_root = tmp_root
      described_class.clear_cache!
      example.run
    end
  ensure
    described_class.data_root = original_root
    described_class.clear_cache!
  end

  describe '.load' do
    it 'loads and parses YAML data' do
      data = described_class.load('character/forenames', 'western_male')
      expect(data).to be_a(Hash)
      expect(data).to have_key(:metadata)
      expect(data).to have_key(:names)
      expect(data[:names]).to include('John')
    end

    it 'symbolizes keys recursively' do
      data = described_class.load('character/forenames', 'western_male')
      expect(data[:metadata]).to be_a(Hash)
      expect(data[:metadata].keys).to all(be_a(Symbol))
    end

    it 'caches loaded data' do
      data1 = described_class.load('character/forenames', 'western_male')
      data2 = described_class.load('character/forenames', 'western_male')
      expect(data1.object_id).to eq(data2.object_id)
    end

    it 'raises ArgumentError when file does not exist' do
      expect {
        described_class.load('nonexistent', 'file')
      }.to raise_error(ArgumentError, /Data file not found/)
    end
  end

  describe '.exists?' do
    it 'returns true for existing files' do
      expect(described_class.exists?('character/forenames', 'western_male')).to be true
    end

    it 'returns false for non-existing files' do
      expect(described_class.exists?('nonexistent', 'file')).to be false
    end
  end

  describe '.list_files' do
    it 'returns empty array for non-existing directories' do
      expect(described_class.list_files('nonexistent/path')).to eq([])
    end

    it 'lists files in existing directories' do
      files = described_class.list_files('character/forenames')
      expect(files).to eq(%w[western_female western_male])
    end
  end

  describe '.clear_cache!' do
    it 'clears the cache' do
      described_class.load('character/forenames', 'western_male')
      described_class.clear_cache!

      expect(described_class.instance_variable_get(:@cache)).to be_empty
    end
  end

  describe '.reload' do
    it 'bypasses cache and reloads file' do
      data1 = described_class.load('character/forenames', 'western_male')
      data2 = described_class.reload('character/forenames', 'western_male')

      expect(data1.object_id).not_to eq(data2.object_id)
      expect(data2[:names]).to include('Robert')
    end
  end

  describe '.data_root' do
    it 'points to the configured data root directory' do
      expect(described_class.data_root).to be_a(String)
      expect(File.directory?(described_class.data_root)).to be true
    end

    it 'can be customized for testing' do
      described_class.data_root = '/tmp/test_names'
      expect(described_class.data_root).to eq('/tmp/test_names')
    end
  end
end
