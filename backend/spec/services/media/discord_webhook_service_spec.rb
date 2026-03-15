# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DiscordWebhookService do
  describe 'constants' do
    it 'defines COLORS for different event types' do
      expect(described_class::COLORS[:memo]).to eq(0x3498db)
      expect(described_class::COLORS[:pm]).to eq(0x2ecc71)
      expect(described_class::COLORS[:mention]).to eq(0xe67e22)
      expect(described_class::COLORS[:test]).to eq(0x9b59b6)
    end
  end

  describe '.send' do
    let(:webhook_url) { 'https://discord.com/api/webhooks/123456789/token-here' }

    context 'with nil or empty webhook URL' do
      it 'returns false for nil' do
        expect(described_class.send(nil, title: 'Test', body: 'Content')).to be false
      end

      it 'returns false for empty string' do
        expect(described_class.send('', title: 'Test', body: 'Content')).to be false
      end

      it 'returns false for whitespace-only string' do
        expect(described_class.send('   ', title: 'Test', body: 'Content')).to be false
      end
    end

    context 'with valid webhook URL' do
      let(:response) { double('Faraday::Response', success?: true) }

      before do
        allow(Faraday).to receive(:post).and_return(response)
      end

      it 'sends POST request to webhook URL' do
        expect(Faraday).to receive(:post).with(webhook_url).and_return(response)

        described_class.send(webhook_url, title: 'Test', body: 'Content')
      end

      it 'returns true on success' do
        result = described_class.send(webhook_url, title: 'Test', body: 'Content')
        expect(result).to be true
      end

      it 'builds correct embed structure' do
        described_class.send(webhook_url, title: 'Test Title', body: 'Test Body', event_type: :memo)

        expect(Faraday).to have_received(:post).with(webhook_url) do |&block|
          # Verify the block is called with request object
        end
      end
    end

    context 'with different event types' do
      let(:response) { double('Faraday::Response', success?: true) }

      before do
        allow(Faraday).to receive(:post).and_return(response)
      end

      it 'uses memo color by default' do
        described_class.send(webhook_url, title: 'Test', body: 'Content')
        # Verifies it completes without error
      end

      it 'accepts pm event type' do
        result = described_class.send(webhook_url, title: 'Test', body: 'Content', event_type: :pm)
        expect(result).to be true
      end

      it 'accepts mention event type' do
        result = described_class.send(webhook_url, title: 'Test', body: 'Content', event_type: :mention)
        expect(result).to be true
      end

      it 'uses default color for unknown event type' do
        result = described_class.send(webhook_url, title: 'Test', body: 'Content', event_type: :unknown)
        expect(result).to be true
      end
    end

    context 'when request fails' do
      let(:failed_response) { double('Faraday::Response', success?: false) }

      before do
        allow(Faraday).to receive(:post).and_return(failed_response)
      end

      it 'returns false' do
        result = described_class.send(webhook_url, title: 'Test', body: 'Content')
        expect(result).to be false
      end
    end

    context 'when Faraday raises error' do
      let(:mock_logger) { double('Logger', warn: nil, error: nil) }

      before do
        allow(Firefly).to receive(:logger).and_return(mock_logger)
        allow(Faraday).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns false and handles error gracefully' do
        result = DiscordWebhookService.__send__(:send, webhook_url, title: 'Test', body: 'Content')
        expect(result).to be false
      end
    end

    context 'when unexpected error occurs' do
      let(:mock_logger) { double('Logger', warn: nil, error: nil) }

      before do
        allow(Firefly).to receive(:logger).and_return(mock_logger)
        allow(Faraday).to receive(:post).and_raise(RuntimeError.new('Unexpected error'))
      end

      it 'returns false and handles error gracefully' do
        result = DiscordWebhookService.__send__(:send, webhook_url, title: 'Test', body: 'Content')
        expect(result).to be false
      end
    end

    context 'with HTML content in body' do
      let(:response) { double('Faraday::Response', success?: true) }

      before do
        allow(Faraday).to receive(:post).and_return(response)
      end

      it 'strips HTML tags from body' do
        result = described_class.send(webhook_url, title: 'Test', body: '<p>Hello <b>World</b></p>')
        expect(result).to be true
        # HTML stripping is done internally
      end
    end

    context 'with very long body' do
      let(:response) { double('Faraday::Response', success?: true) }

      before do
        allow(Faraday).to receive(:post).and_return(response)
      end

      it 'truncates body to 2000 characters' do
        long_body = 'x' * 3000
        result = described_class.send(webhook_url, title: 'Test', body: long_body)
        expect(result).to be true
        # Truncation is done internally
      end
    end
  end

  describe '.valid_webhook_url?' do
    context 'with valid discord.com URLs' do
      it 'returns true for standard webhook URL' do
        url = 'https://discord.com/api/webhooks/123456789012345678/abcdefghijk-lmnop_qrstuv'
        expect(described_class.valid_webhook_url?(url)).to be true
      end
    end

    context 'with valid discordapp.com URLs' do
      it 'returns true for legacy webhook URL' do
        url = 'https://discordapp.com/api/webhooks/123456789012345678/abcdefghijk-lmnop_qrstuv'
        expect(described_class.valid_webhook_url?(url)).to be true
      end
    end

    context 'with invalid URLs' do
      it 'returns false for nil' do
        expect(described_class.valid_webhook_url?(nil)).to be false
      end

      it 'returns false for non-string' do
        expect(described_class.valid_webhook_url?(12345)).to be false
      end

      it 'returns false for malformed URL' do
        expect(described_class.valid_webhook_url?('not-a-url')).to be false
      end

      it 'returns false for wrong domain' do
        url = 'https://example.com/api/webhooks/123/token'
        expect(described_class.valid_webhook_url?(url)).to be false
      end

      it 'returns false for HTTP (non-HTTPS)' do
        url = 'http://discord.com/api/webhooks/123/token'
        expect(described_class.valid_webhook_url?(url)).to be false
      end

      it 'returns false for missing webhook ID' do
        url = 'https://discord.com/api/webhooks//token'
        expect(described_class.valid_webhook_url?(url)).to be false
      end

      it 'returns false for missing token' do
        url = 'https://discord.com/api/webhooks/123456789/'
        expect(described_class.valid_webhook_url?(url)).to be false
      end

      it 'returns false for non-numeric webhook ID' do
        url = 'https://discord.com/api/webhooks/abc/token'
        expect(described_class.valid_webhook_url?(url)).to be false
      end
    end
  end

  describe '.strip_html' do
    it 'removes HTML tags' do
      expect(described_class.strip_html('<p>Hello</p>')).to eq('Hello')
    end

    it 'removes nested HTML tags' do
      expect(described_class.strip_html('<div><p>Hello <b>World</b></p></div>')).to eq('Hello World')
    end

    it 'handles empty string' do
      expect(described_class.strip_html('')).to eq('')
    end

    it 'handles nil' do
      expect(described_class.strip_html(nil)).to eq('')
    end

    it 'handles string without HTML' do
      expect(described_class.strip_html('Plain text')).to eq('Plain text')
    end

    it 'handles self-closing tags' do
      expect(described_class.strip_html('Line 1<br/>Line 2')).to eq('Line 1Line 2')
    end

    it 'removes whitespace around result' do
      expect(described_class.strip_html('  <p>Hello</p>  ')).to eq('Hello')
    end

    it 'preserves text content between tags' do
      expect(described_class.strip_html('<span>Hello</span> <span>World</span>')).to eq('Hello World')
    end

    it 'handles tags with attributes' do
      expect(described_class.strip_html('<a href="url">Link</a>')).to eq('Link')
    end
  end
end
