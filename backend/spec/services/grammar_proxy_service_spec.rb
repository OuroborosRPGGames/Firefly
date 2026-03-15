# frozen_string_literal: true

require 'spec_helper'
require 'net/http'

RSpec.describe GrammarProxyService do
  describe '.check' do
    let(:text) { 'This is a tset of grammar checking.' }
    let(:language) { 'en-US' }
    let(:http_double) { instance_double(Net::HTTP) }
    let(:lt_response_body) do
      {
        matches: [{
          message: 'Possible spelling mistake found.',
          offset: 10,
          length: 4,
          replacements: [{ value: 'test' }],
          rule: { id: 'MORFOLOGIK_RULE_EN_US', category: { id: 'TYPOS' } }
        }]
      }.to_json
    end

    before do
      allow(Net::HTTP).to receive(:new).with('127.0.0.1', 8742).and_return(http_double)
      allow(http_double).to receive(:open_timeout=)
      allow(http_double).to receive(:read_timeout=)
    end

    context 'when LanguageTool is available' do
      before do
        response = instance_double(Net::HTTPSuccess, body: lt_response_body, code: '200')
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(http_double).to receive(:request).and_return(response)
      end

      it 'returns parsed matches' do
        result = described_class.check(text, language)
        expect(result[:success]).to be true
        expect(result[:matches].length).to eq(1)
        expect(result[:matches][0]['message']).to include('spelling')
      end
    end

    context 'when LanguageTool is down' do
      before do
        allow(http_double).to receive(:request).and_raise(Errno::ECONNREFUSED)
      end

      it 'returns error with 503 status' do
        result = described_class.check(text, language)
        expect(result[:success]).to be false
        expect(result[:status]).to eq(503)
        expect(result[:error]).to include('unavailable')
      end
    end

    context 'when LanguageTool times out' do
      before do
        allow(http_double).to receive(:request).and_raise(Net::ReadTimeout)
      end

      it 'returns error with 503 status' do
        result = described_class.check(text, language)
        expect(result[:success]).to be false
        expect(result[:status]).to eq(503)
      end
    end

    context 'when LanguageTool returns an error' do
      before do
        response = instance_double(Net::HTTPServerError, body: 'Internal Server Error', code: '500')
        allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(http_double).to receive(:request).and_return(response)
      end

      it 'returns error with upstream status' do
        result = described_class.check(text, language)
        expect(result[:success]).to be false
        expect(result[:status]).to eq(500)
      end
    end
  end

  describe '.rate_limited?' do
    let(:user_id) { 999 }

    before do
      REDIS_POOL.with { |r| r.del("grammar_rate:#{user_id}") }
    end

    after do
      REDIS_POOL.with { |r| r.del("grammar_rate:#{user_id}") }
    end

    it 'allows requests under the limit' do
      expect(described_class.rate_limited?(user_id)).to be false
    end

    it 'blocks after 10 requests' do
      10.times { described_class.record_request(user_id) }
      expect(described_class.rate_limited?(user_id)).to be true
    end
  end

  describe '.available_languages' do
    before do
      GrammarLanguage.dataset.delete
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'ready')
      GrammarLanguage.create(language_code: 'fr', language_name: 'French', status: 'pending')
    end

    after do
      GrammarLanguage.dataset.delete
    end

    it 'returns only ready languages' do
      langs = described_class.available_languages
      expect(langs.length).to eq(1)
      expect(langs[0][:code]).to eq('en')
    end
  end
end
