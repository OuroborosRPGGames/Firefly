# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::CacheManager do
  let(:cache_dir) { Dir.mktmpdir('earth_cache_test') }
  let(:manager) { described_class.new(cache_dir: cache_dir) }

  after { FileUtils.rm_rf(cache_dir) }

  describe '#cache_path' do
    it 'returns path within cache directory' do
      path = manager.cache_path('coastlines.shp')
      expect(path).to eq(File.join(cache_dir, 'coastlines.shp'))
    end
  end

  describe '#cached?' do
    it 'returns false when file does not exist' do
      expect(manager.cached?('missing.shp')).to be false
    end

    it 'returns true when file exists and not expired' do
      path = manager.cache_path('test.shp')
      FileUtils.touch(path)
      expect(manager.cached?('test.shp')).to be true
    end

    it 'returns false when file is expired (older than 30 days)' do
      path = manager.cache_path('old.shp')
      FileUtils.touch(path, mtime: Time.now - (31 * 24 * 60 * 60))
      expect(manager.cached?('old.shp')).to be false
    end
  end

  describe '#store' do
    it 'writes content to cache file' do
      manager.store('test.txt', 'hello world')
      expect(File.read(manager.cache_path('test.txt'))).to eq('hello world')
    end

    it 'records checksum' do
      manager.store('test.txt', 'hello world')
      checksums = JSON.parse(File.read(File.join(cache_dir, 'checksums.json')))
      expect(checksums['test.txt']).to be_a(String)
    end

    it 'stores correct SHA256 checksum' do
      content = 'hello world'
      manager.store('test.txt', content)
      checksums = JSON.parse(File.read(File.join(cache_dir, 'checksums.json')))
      expected_checksum = Digest::SHA256.hexdigest(content)
      expect(checksums['test.txt']).to eq(expected_checksum)
    end
  end

  describe '#valid_checksum?' do
    it 'returns true for file with matching checksum' do
      manager.store('test.txt', 'hello world')
      expect(manager.valid_checksum?('test.txt')).to be true
    end

    it 'returns false for corrupted file' do
      manager.store('test.txt', 'hello world')
      File.write(manager.cache_path('test.txt'), 'corrupted')
      expect(manager.valid_checksum?('test.txt')).to be false
    end

    it 'returns false for file without recorded checksum' do
      path = manager.cache_path('no_checksum.txt')
      File.write(path, 'content')
      expect(manager.valid_checksum?('no_checksum.txt')).to be false
    end

    it 'returns false for non-existent file' do
      expect(manager.valid_checksum?('missing.txt')).to be false
    end
  end

  describe '#clear_expired' do
    it 'removes files older than 30 days' do
      fresh = manager.cache_path('fresh.shp')
      old = manager.cache_path('old.shp')
      FileUtils.touch(fresh)
      FileUtils.touch(old, mtime: Time.now - (31 * 24 * 60 * 60))

      manager.clear_expired

      expect(File.exist?(fresh)).to be true
      expect(File.exist?(old)).to be false
    end

    it 'preserves checksums.json file' do
      manager.store('test.txt', 'content')
      checksums_path = File.join(cache_dir, 'checksums.json')
      # Make checksums.json old
      FileUtils.touch(checksums_path, mtime: Time.now - (31 * 24 * 60 * 60))

      manager.clear_expired

      expect(File.exist?(checksums_path)).to be true
    end

    it 'does not remove files exactly 30 days old' do
      path = manager.cache_path('boundary.shp')
      FileUtils.touch(path, mtime: Time.now - (30 * 24 * 60 * 60) + 60) # 30 days minus 1 minute

      manager.clear_expired

      expect(File.exist?(path)).to be true
    end
  end

  describe '#age_days' do
    it 'returns nil for non-existent file' do
      expect(manager.age_days('missing.txt')).to be_nil
    end

    it 'returns age in days for existing file' do
      path = manager.cache_path('test.txt')
      FileUtils.touch(path, mtime: Time.now - (5 * 24 * 60 * 60))
      age = manager.age_days('test.txt')
      expect(age).to be_within(0.1).of(5)
    end

    it 'returns approximately 0 for newly created file' do
      path = manager.cache_path('new.txt')
      FileUtils.touch(path)
      expect(manager.age_days('new.txt')).to be < 1
    end
  end

  describe 'initialization' do
    it 'creates cache directory if it does not exist' do
      new_dir = File.join(cache_dir, 'nested', 'cache')
      described_class.new(cache_dir: new_dir)
      expect(Dir.exist?(new_dir)).to be true
    end

    it 'uses default cache directory when none provided' do
      # Test that it doesn't raise when using defaults
      expect { described_class.new }.not_to raise_error
    end
  end

  describe 'corrupted checksums.json handling' do
    it 'handles corrupted checksums.json gracefully' do
      File.write(File.join(cache_dir, 'checksums.json'), 'not valid json')
      expect(manager.valid_checksum?('test.txt')).to be false
    end

    it 'overwrites corrupted checksums.json on store' do
      File.write(File.join(cache_dir, 'checksums.json'), 'not valid json')
      manager.store('test.txt', 'content')
      checksums = JSON.parse(File.read(File.join(cache_dir, 'checksums.json')))
      expect(checksums).to have_key('test.txt')
    end
  end
end
