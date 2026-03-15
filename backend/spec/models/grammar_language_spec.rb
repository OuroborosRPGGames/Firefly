# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GrammarLanguage do
  describe 'validations' do
    it 'requires language_code' do
      lang = GrammarLanguage.new(language_name: 'English')
      expect(lang.valid?).to be false
    end

    it 'requires language_name' do
      lang = GrammarLanguage.new(language_code: 'en')
      expect(lang.valid?).to be false
    end

    it 'validates status values' do
      lang = GrammarLanguage.new(language_code: 'en', language_name: 'English', status: 'invalid')
      expect(lang.valid?).to be false
    end

    it 'creates with valid attributes' do
      lang = GrammarLanguage.create(language_code: 'en', language_name: 'English')
      expect(lang.status).to eq('pending')
      expect(lang.size_bytes).to eq(0)
    end
  end

  describe '.ready' do
    it 'returns only ready languages' do
      GrammarLanguage.create(language_code: 'en', language_name: 'English', status: 'ready')
      GrammarLanguage.create(language_code: 'fr', language_name: 'French', status: 'pending')
      expect(GrammarLanguage.ready.count).to eq(1)
      expect(GrammarLanguage.ready.first.language_code).to eq('en')
    end
  end

  describe 'SUPPORTED_LANGUAGES' do
    it 'contains expected languages' do
      expect(GrammarLanguage::SUPPORTED_LANGUAGES).to include(
        hash_including(code: 'en', name: 'English (US)')
      )
    end
  end
end
