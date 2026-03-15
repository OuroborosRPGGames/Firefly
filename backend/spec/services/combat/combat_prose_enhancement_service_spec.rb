# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatProseEnhancementService do
  describe 'constants' do
    it 'defines DEFAULT_MODEL' do
      expect(described_class::DEFAULT_MODEL).to eq('gemini-3.1-flash-lite-preview')
    end

    it 'defines MIN_PARAGRAPH_LENGTH' do
      expect(described_class::MIN_PARAGRAPH_LENGTH).to eq(20)
    end

    it 'defines TOTAL_TIMEOUT' do
      expect(described_class::TOTAL_TIMEOUT).to eq(10)
    end

    it 'defines REQUEST_TIMEOUT' do
      expect(described_class::REQUEST_TIMEOUT).to eq(8)
    end
  end

  describe '#initialize' do
    it 'uses default model' do
      service = described_class.new

      expect(service.instance_variable_get(:@model)).to eq('gemini-3.1-flash-lite-preview')
    end

    it 'accepts custom model' do
      service = described_class.new(model: 'gemini-pro')

      expect(service.instance_variable_get(:@model)).to eq('gemini-pro')
    end
  end

  describe '#available?' do
    it 'returns false when provider not available' do
      allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(false)

      service = described_class.new

      expect(service.available?).to be false
    end

    it 'returns true when provider is available' do
      allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)

      service = described_class.new

      expect(service.available?).to be true
    end
  end

  describe '.enabled?' do
    it 'checks GameSetting for combat_llm_enhancement_enabled' do
      expect(GameSetting).to receive(:boolean).with('combat_llm_enhancement_enabled').and_return(true)

      expect(described_class.enabled?).to be true
    end

    it 'returns false when disabled' do
      allow(GameSetting).to receive(:boolean).with('combat_llm_enhancement_enabled').and_return(false)

      expect(described_class.enabled?).to be false
    end
  end

  describe '#enhance_paragraphs' do
    let(:service) { described_class.new }

    before do
      allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
      allow(GamePrompts).to receive(:get).and_return('Enhance this: {paragraph}')
    end

    context 'when not available' do
      before do
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(false)
      end

      it 'returns original paragraphs' do
        paragraphs = ['Original text here.']

        result = service.enhance_paragraphs(paragraphs)

        expect(result).to eq(paragraphs)
      end
    end

    context 'with empty paragraphs' do
      it 'returns empty array' do
        result = service.enhance_paragraphs([])

        expect(result).to eq([])
      end
    end

    context 'with short paragraphs' do
      it 'does not enhance paragraphs shorter than MIN_PARAGRAPH_LENGTH' do
        short_paragraph = 'Too short.'  # < 20 chars

        expect(service).not_to receive(:enhance_single)

        result = service.enhance_paragraphs([short_paragraph])

        expect(result).to eq([short_paragraph])
      end
    end

    context 'with enhanceable paragraphs' do
      let(:long_paragraph) { 'This is a longer paragraph that exceeds the minimum length requirement.' }

      before do
        allow(service).to receive(:enhance_single).and_return('Enhanced version of the text.')
      end

      it 'enhances paragraphs above MIN_PARAGRAPH_LENGTH' do
        expect(service).to receive(:enhance_single).with(long_paragraph)

        result = service.enhance_paragraphs([long_paragraph])

        expect(result).to eq(['Enhanced version of the text.'])
      end
    end

    context 'with mixed paragraphs' do
      let(:short) { 'Short.' }
      let(:long1) { 'This is a longer first paragraph for testing enhancement.' }
      let(:long2) { 'And another long paragraph that should also be enhanced.' }

      before do
        allow(service).to receive(:enhance_single).with(long1).and_return('Enhanced 1')
        allow(service).to receive(:enhance_single).with(long2).and_return('Enhanced 2')
      end

      it 'preserves order of results' do
        result = service.enhance_paragraphs([short, long1, long2])

        expect(result).to eq(['Short.', 'Enhanced 1', 'Enhanced 2'])
      end
    end

    context 'when enhancement returns nil' do
      let(:paragraph) { 'A paragraph that fails to enhance properly.' }

      before do
        allow(service).to receive(:enhance_single).and_return(nil)
      end

      it 'uses original on failure' do
        result = service.enhance_paragraphs([paragraph])

        expect(result).to eq([paragraph])
      end
    end
  end

  describe '#enhance_single' do
    let(:service) { described_class.new }
    let(:paragraph) { 'Alpha attacks Beta with a sword.' }

    before do
      allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
      allow(GamePrompts).to receive(:get).with('combat.prose_enhancement', paragraph: paragraph).and_return('Prompt')
    end

    context 'when not available' do
      before do
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(false)
      end

      it 'returns nil' do
        result = service.enhance_single(paragraph)

        expect(result).to be_nil
      end
    end

    context 'with successful LLM call' do
      before do
        allow(LLM::Client).to receive(:generate).and_return(
          { success: true, text: 'Enhanced prose.' }
        )
      end

      it 'returns enhanced text' do
        result = service.enhance_single(paragraph)

        expect(result).to eq('Enhanced prose.')
      end

      it 'uses GamePrompts' do
        expect(GamePrompts).to receive(:get).with('combat.prose_enhancement', paragraph: paragraph)

        service.enhance_single(paragraph)
      end

      it 'calls LLM::Client with correct parameters' do
        expect(LLM::Client).to receive(:generate).with(
          prompt: 'Prompt',
          provider: 'google_gemini',
          model: 'gemini-3.1-flash-lite-preview',
          options: hash_including(max_tokens: 300, temperature: 0.7)
        ).and_return({ success: true, text: 'Enhanced.' })

        service.enhance_single(paragraph)
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return(
          { success: false, error: 'API error' }
        )
      end

      it 'returns nil' do
        result = service.enhance_single(paragraph)

        expect(result).to be_nil
      end
    end

    context 'when exception occurs' do
      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError, 'Network error')
      end

      it 'returns nil' do
        result = service.enhance_single(paragraph)

        expect(result).to be_nil
      end
    end
  end

  describe 'smart quote normalization' do
    let(:service) { described_class.new }

    describe '#normalize_quotes' do
      it 'converts left single smart quote to straight quote' do
        result = service.send(:normalize_quotes, "Linis \u2018Lin\u2019 Dao")
        expect(result).to eq("Linis 'Lin' Dao")
      end

      it 'converts right single smart quote to straight quote' do
        result = service.send(:normalize_quotes, "it\u2019s a test")
        expect(result).to eq("it's a test")
      end

      it 'converts double smart quotes to straight quotes' do
        result = service.send(:normalize_quotes, "\u201CHello,\u201D she said")
        expect(result).to eq('"Hello," she said')
      end

      it 'converts low-9 quotes' do
        result = service.send(:normalize_quotes, "text\u201Aquote\u201E")
        expect(result).to eq("text'quote\"")
      end

      it 'returns nil unchanged' do
        expect(service.send(:normalize_quotes, nil)).to be_nil
      end

      it 'leaves straight quotes unchanged' do
        text = "Linis 'Lin' Dao attacks."
        expect(service.send(:normalize_quotes, text)).to eq(text)
      end
    end

    describe '#enhance_single' do
      let(:paragraph) { "Linis 'Lin' Dao attacks Bob 'Bobby' Jones." }

      before do
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
        allow(GamePrompts).to receive(:get).and_return('Prompt')
      end

      it 'normalizes smart quotes in LLM response' do
        allow(LLM::Client).to receive(:generate).and_return(
          { success: true, text: "Linis \u2018Lin\u2019 Dao strikes at Bob \u2018Bobby\u2019 Jones with precision." }
        )

        result = service.enhance_single(paragraph)
        expect(result).to eq("Linis 'Lin' Dao strikes at Bob 'Bobby' Jones with precision.")
      end

      it 'normalizes mixed smart and straight quotes' do
        allow(LLM::Client).to receive(:generate).and_return(
          { success: true, text: "Linis \u2018Lin' Dao strikes." }
        )

        result = service.enhance_single(paragraph)
        expect(result).to eq("Linis 'Lin' Dao strikes.")
      end
    end
  end

  describe 'parallel processing' do
    let(:service) { described_class.new }

    before do
      allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
    end

    it 'processes multiple paragraphs concurrently' do
      paragraphs = [
        'First long paragraph that needs enhancement.',
        'Second long paragraph that needs enhancement.'
      ]

      allow(service).to receive(:enhance_single) do |para|
        "Enhanced: #{para[0..10]}..."
      end

      result = service.enhance_paragraphs(paragraphs)

      expect(result.length).to eq(2)
      expect(result.all? { |r| r.start_with?('Enhanced:') }).to be true
    end
  end

  describe 'name and HTML pre/post-processing' do
    let(:service) { described_class.new }

    describe '#extract_html_spans' do
      it 'strips color spans and builds mapping' do
        html = '<span style="color:#ff0000">S</span><span style="color:#ff1111">w</span><span style="color:#ff2222">o</span><span style="color:#ff3333">r</span><span style="color:#ff4444">d</span>'
        text = "Alpha swings the #{html} at Beta."

        stripped, mapping = service.send(:extract_html_spans, text)

        expect(stripped).to eq('Alpha swings the Sword at Beta.')
        expect(mapping['Sword']).to eq(html)
      end

      it 'returns text unchanged when no spans present' do
        text = 'Alpha attacks Beta with a sword.'

        stripped, mapping = service.send(:extract_html_spans, text)

        expect(stripped).to eq(text)
        expect(mapping).to be_empty
      end

      it 'handles multiple span groups' do
        span1 = '<span style="color:#ff0000">F</span><span style="color:#ff1111">i</span><span style="color:#ff2222">r</span><span style="color:#ff3333">e</span>'
        span2 = '<span style="color:#0000ff">I</span><span style="color:#1111ff">c</span><span style="color:#2222ff">e</span>'
        text = "#{span1} meets #{span2}."

        stripped, mapping = service.send(:extract_html_spans, text)

        expect(stripped).to eq('Fire meets Ice.')
        expect(mapping['Fire']).to eq(span1)
        expect(mapping['Ice']).to eq(span2)
      end
    end

    describe '#preprocess_for_llm' do
      it 'simplifies full names to short names' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin', "Robert 'Bob' Smith" => 'Bob' }
        text = "Linis 'Lin' Dao attacks Robert 'Bob' Smith with a sword."

        processed, _html = service.send(:preprocess_for_llm, text, name_mapping)

        expect(processed).to eq('Lin attacks Bob with a sword.')
      end

      it 'strips HTML and simplifies names together' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin' }
        html = '<span style="color:#ff0000">S</span><span style="color:#ff1111">w</span><span style="color:#ff2222">o</span><span style="color:#ff3333">r</span><span style="color:#ff4444">d</span>'
        text = "Linis 'Lin' Dao swings the #{html}."

        processed, html_mapping = service.send(:preprocess_for_llm, text, name_mapping)

        expect(processed).to eq('Lin swings the Sword.')
        expect(html_mapping['Sword']).to eq(html)
      end

      it 'does not replace partial name matches' do
        name_mapping = { "Alpha Fighter" => 'Alpha' }
        text = 'Alpha Fighter attacks. Alphabetical order is maintained.'

        processed, _ = service.send(:preprocess_for_llm, text, name_mapping)

        expect(processed).to eq('Alpha attacks. Alphabetical order is maintained.')
      end

      it 'handles empty name mapping' do
        text = 'Alpha attacks Beta.'

        processed, html_mapping = service.send(:preprocess_for_llm, text, {})

        expect(processed).to eq(text)
        expect(html_mapping).to be_empty
      end
    end

    describe '#postprocess_from_llm' do
      it 'restores full names from short names' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin', "Robert 'Bob' Smith" => 'Bob' }
        enhanced = 'Lin strikes at Bob with precision.'

        result = service.send(:postprocess_from_llm, enhanced, name_mapping, {})

        expect(result).to eq("Linis 'Lin' Dao strikes at Robert 'Bob' Smith with precision.")
      end

      it 're-applies color spans where text survived' do
        html = '<span style="color:#ff0000">S</span><span style="color:#ff1111">w</span><span style="color:#ff2222">o</span><span style="color:#ff3333">r</span><span style="color:#ff4444">d</span>'
        html_mapping = { 'Sword' => html }
        enhanced = 'Alpha swings the Sword forcefully.'

        result = service.send(:postprocess_from_llm, enhanced, {}, html_mapping)

        expect(result).to eq("Alpha swings the #{html} forcefully.")
      end

      it 'normalizes smart quotes and restores names' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin' }
        enhanced = "Lin\u2019s blade strikes true."

        result = service.send(:postprocess_from_llm, enhanced, name_mapping, {})

        expect(result).to eq("Linis 'Lin' Dao's blade strikes true.")
      end

      it 'handles both name restoration and HTML re-application' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin' }
        html = '<span style="color:#ff0000">F</span><span style="color:#ff1111">i</span><span style="color:#ff2222">r</span><span style="color:#ff3333">e</span>'
        html_mapping = { 'Fire' => html }
        enhanced = 'Lin conjures Fire from thin air.'

        result = service.send(:postprocess_from_llm, enhanced, name_mapping, html_mapping)

        expect(result).to eq("Linis 'Lin' Dao conjures #{html} from thin air.")
      end
    end

    describe '#enhance_paragraphs with name_mapping' do
      let(:long_paragraph) { "Linis 'Lin' Dao attacks Robert 'Bob' Smith with a powerful strike." }

      before do
        allow(AIProviderService).to receive(:provider_available?).with('google_gemini').and_return(true)
        allow(GamePrompts).to receive(:get).and_return('Prompt')
      end

      it 'pre-processes names before LLM and restores after' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin', "Robert 'Bob' Smith" => 'Bob' }

        allow(service).to receive(:enhance_single).with('Lin attacks Bob with a powerful strike.').and_return(
          'Lin delivers a devastating blow to Bob.'
        )

        result = service.enhance_paragraphs([long_paragraph], name_mapping: name_mapping)

        expect(result.first).to eq("Linis 'Lin' Dao delivers a devastating blow to Robert 'Bob' Smith.")
      end

      it 'falls back to original when LLM returns nil' do
        name_mapping = { "Linis 'Lin' Dao" => 'Lin' }

        allow(service).to receive(:enhance_single).and_return(nil)

        result = service.enhance_paragraphs([long_paragraph], name_mapping: name_mapping)

        expect(result.first).to eq(long_paragraph)
      end

      it 'works with empty name mapping (backward compatible)' do
        allow(service).to receive(:enhance_single).with(long_paragraph).and_return('Enhanced text here.')

        result = service.enhance_paragraphs([long_paragraph])

        expect(result.first).to eq('Enhanced text here.')
      end
    end
  end
end
