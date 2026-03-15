# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GrammarDownloadService do
  let(:ngram_path) { Dir.mktmpdir('lt-ngrams-test') }

  before do
    GrammarLanguage.dataset.delete
    stub_const('GrammarDownloadService::NGRAM_PATH', ngram_path)
  end

  after do
    GrammarLanguage.dataset.delete
    FileUtils.rm_rf(ngram_path)
  end

  describe '.start_download' do
    it 'rejects download if already downloading' do
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'downloading')
      result = described_class.start_download('en')
      expect(result[:success]).to be false
      expect(result[:error]).to include('already downloading')
    end

    it 'rejects unsupported language codes' do
      result = described_class.start_download('xx')
      expect(result[:success]).to be false
      expect(result[:error]).to include('not supported')
    end

    it 'creates language record and sets status to downloading' do
      allow(Thread).to receive(:new)
      result = described_class.start_download('en')
      expect(result[:success]).to be true
      lang = GrammarLanguage.first(language_code: 'en')
      expect(lang).not_to be_nil
      expect(lang.status).to eq('downloading')
    end
  end

  describe '.perform_download' do
    let!(:lang) do
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'downloading')
    end

    it 'sets status to ready on successful download' do
      allow(described_class).to receive(:system_download).and_return(true)
      allow(described_class).to receive(:system_extract).and_return(true)
      allow(described_class).to receive(:restart_container).and_return(true)
      allow(described_class).to receive(:directory_size).and_return(1024)

      described_class.perform_download('en', lang.id)

      lang.refresh
      expect(lang.status).to eq('ready')
      expect(lang.size_bytes).to eq(1024)
    end

    it 'sets status to error on download failure' do
      allow(described_class).to receive(:system_download).and_return(false)

      described_class.perform_download('en', lang.id)

      lang.refresh
      expect(lang.status).to eq('error')
      expect(lang.error_message).to include('Download failed')
    end

    it 'sets status to error on extraction failure' do
      allow(described_class).to receive(:system_download).and_return(true)
      allow(described_class).to receive(:system_extract).and_return(false)

      described_class.perform_download('en', lang.id)

      lang.refresh
      expect(lang.status).to eq('error')
      expect(lang.error_message).to include('Extraction failed')
    end
  end

  describe '.remove_language' do
    it 'removes n-gram data and updates status' do
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'ready', size_bytes: 1000)
      FileUtils.mkdir_p(File.join(ngram_path, 'en'))

      result = described_class.remove_language('en')
      expect(result[:success]).to be true
      expect(File.exist?(File.join(ngram_path, 'en'))).to be false

      lang = GrammarLanguage.first(language_code: 'en')
      expect(lang.status).to eq('pending')
      expect(lang.size_bytes).to eq(0)
    end
  end

  describe '.cancel_download' do
    it 'resets status to pending and cleans up files' do
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'downloading')
      FileUtils.mkdir_p(File.join(ngram_path, 'en'))

      described_class.cancel_download('en')

      lang = GrammarLanguage.first(language_code: 'en')
      expect(lang.status).to eq('pending')
      expect(File.exist?(File.join(ngram_path, 'en'))).to be false
    end
  end

  describe '.status_summary' do
    it 'returns language statuses and service health' do
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'ready')
      allow(GrammarProxyService).to receive(:healthy?).and_return(true)

      summary = described_class.status_summary
      expect(summary[:service_healthy]).to be true
      expect(summary[:languages].length).to eq(1)
    end
  end
end
