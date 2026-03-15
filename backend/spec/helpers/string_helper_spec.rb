# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StringHelper do
  # Create a test class that includes the helper
  let(:test_class) { Class.new { include StringHelper }.new }

  describe '#blank?' do
    it 'returns true for nil' do
      expect(test_class.blank?(nil)).to be true
    end

    it 'returns true for empty string' do
      expect(test_class.blank?('')).to be true
    end

    it 'returns true for whitespace-only string' do
      expect(test_class.blank?('   ')).to be true
      expect(test_class.blank?("\t\n")).to be true
    end

    it 'returns false for non-empty string' do
      expect(test_class.blank?('hello')).to be false
      expect(test_class.blank?('  hello  ')).to be false
    end

    it 'returns true for empty array' do
      expect(test_class.blank?([])).to be true
    end

    it 'returns false for non-empty array' do
      expect(test_class.blank?([1, 2, 3])).to be false
    end

    it 'returns true for empty hash' do
      expect(test_class.blank?({})).to be true
    end

    it 'returns false for non-empty hash' do
      expect(test_class.blank?({ a: 1 })).to be false
    end

    it 'returns true for false' do
      expect(test_class.blank?(false)).to be true
    end

    it 'returns false for numbers' do
      expect(test_class.blank?(0)).to be false
      expect(test_class.blank?(42)).to be false
    end
  end

  describe '#present?' do
    it 'returns false for nil' do
      expect(test_class.present?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(test_class.present?('')).to be false
    end

    it 'returns true for non-empty string' do
      expect(test_class.present?('hello')).to be true
    end

    it 'returns true for numbers' do
      expect(test_class.present?(0)).to be true
      expect(test_class.present?(42)).to be true
    end

    it 'returns true for non-empty arrays' do
      expect(test_class.present?([1])).to be true
    end
  end

  describe '#valid_text?' do
    it 'returns false for nil' do
      expect(test_class.valid_text?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(test_class.valid_text?('')).to be false
    end

    it 'returns false for whitespace-only string' do
      expect(test_class.valid_text?('   ')).to be false
    end

    it 'returns true for non-empty string' do
      expect(test_class.valid_text?('hello')).to be true
    end

    it 'handles non-string inputs' do
      expect(test_class.valid_text?(123)).to be true
    end
  end

  describe '#truncate' do
    it 'returns original if under max length' do
      expect(test_class.truncate('short', 10)).to eq 'short'
    end

    it 'truncates with ellipsis at max length' do
      expect(test_class.truncate('Hello World', 8)).to eq 'Hello...'
    end

    it 'returns empty string for nil' do
      expect(test_class.truncate(nil, 10)).to eq ''
    end

    it 'returns empty string for empty string' do
      expect(test_class.truncate('', 10)).to eq ''
    end

    it 'allows custom omission string' do
      expect(test_class.truncate('Long text here', 10, '…')).to eq 'Long text…'
    end

    it 'handles exact length' do
      expect(test_class.truncate('Hello', 5)).to eq 'Hello'
    end
  end

  describe '#strip_html' do
    it 'removes simple HTML tags' do
      expect(test_class.strip_html('<b>Bold</b>')).to eq 'Bold'
    end

    it 'removes tags with attributes' do
      expect(test_class.strip_html('<span class="red">Hi</span>')).to eq 'Hi'
    end

    it 'removes multiple tags' do
      expect(test_class.strip_html('<div><p>Text</p></div>')).to eq 'Text'
    end

    it 'returns empty string for nil' do
      expect(test_class.strip_html(nil)).to eq ''
    end

    it 'handles self-closing tags' do
      expect(test_class.strip_html('Line<br/>break')).to eq 'Linebreak'
    end
  end

  describe '#decode_html_entities' do
    it 'decodes &lt; and &gt;' do
      expect(test_class.decode_html_entities('&lt;test&gt;')).to eq '<test>'
    end

    it 'decodes &amp;' do
      expect(test_class.decode_html_entities('A &amp; B')).to eq 'A & B'
    end

    it 'decodes &quot;' do
      expect(test_class.decode_html_entities('&quot;hi&quot;')).to eq '"hi"'
    end

    it 'decodes &#39; (apostrophe)' do
      expect(test_class.decode_html_entities("it&#39;s")).to eq "it's"
    end

    it 'decodes &nbsp;' do
      expect(test_class.decode_html_entities('no&nbsp;break')).to eq 'no break'
    end

    it 'returns empty string for nil' do
      expect(test_class.decode_html_entities(nil)).to eq ''
    end
  end

  describe '#strip_and_decode' do
    it 'strips HTML and decodes entities' do
      expect(test_class.strip_and_decode('<b>&lt;sword&gt;</b>')).to eq '<sword>'
    end
  end

  describe '#sanitize_for_canvas' do
    it 'removes HTML tags' do
      expect(test_class.sanitize_for_canvas('<b>Town</b>')).to eq 'Town'
    end

    it 'removes pipe characters' do
      expect(test_class.sanitize_for_canvas('Town|Square')).to eq 'Town Square'
    end

    it 'removes semicolons and colons' do
      expect(test_class.sanitize_for_canvas('Foo;Bar:Baz')).to eq 'Foo Bar Baz'
    end

    it 'returns empty string for nil' do
      expect(test_class.sanitize_for_canvas(nil)).to eq ''
    end
  end

  describe '#plain_name' do
    it 'extracts plain name from styled text' do
      expect(test_class.plain_name('<span class="rare">Magic Sword</span>')).to eq 'Magic Sword'
    end

    it 'trims whitespace' do
      expect(test_class.plain_name('  Sword  ')).to eq 'Sword'
    end
  end

  describe '#time_ago' do
    it 'returns "just now" for very recent times' do
      expect(test_class.time_ago(Time.now - 30)).to eq 'just now'
    end

    it 'returns minutes ago for times under an hour' do
      expect(test_class.time_ago(Time.now - 120)).to eq '2 minutes ago'
    end

    it 'handles singular minute' do
      expect(test_class.time_ago(Time.now - 60)).to eq '1 minute ago'
    end

    it 'returns hours ago for times under a day' do
      expect(test_class.time_ago(Time.now - 7200)).to eq '2 hours ago'
    end

    it 'handles singular hour' do
      expect(test_class.time_ago(Time.now - 3600)).to eq '1 hour ago'
    end

    it 'returns days ago for older times' do
      expect(test_class.time_ago(Time.now - 172_800)).to eq '2 days ago'
    end

    it 'handles singular day' do
      expect(test_class.time_ago(Time.now - 86_400)).to eq '1 day ago'
    end

    it 'returns unknown_text for nil' do
      expect(test_class.time_ago(nil)).to eq 'Unknown'
    end

    it 'allows custom unknown_text' do
      expect(test_class.time_ago(nil, unknown_text: 'N/A')).to eq 'N/A'
    end
  end

  describe '#time_until' do
    it 'returns "In X minutes" for times under an hour' do
      expect(test_class.time_until(Time.now + 1800)).to eq 'In 30 minutes'
    end

    it 'returns "In X hours" for times under a day' do
      expect(test_class.time_until(Time.now + 7200)).to eq 'In 2 hours'
    end

    it 'returns formatted date for times over a day' do
      future = Time.now + 86_400 * 2
      result = test_class.time_until(future)
      expect(result).to match(/\w{3} \d{1,2} at \d{1,2}:\d{2} [AP]M/)
    end

    it 'returns "Started X ago" for past times' do
      result = test_class.time_until(Time.now - 120)
      expect(result).to eq 'Started 2 minutes ago'
    end

    it 'returns fallback for nil' do
      expect(test_class.time_until(nil)).to eq 'TBD'
    end

    it 'allows custom fallback' do
      expect(test_class.time_until(nil, fallback: 'Unknown')).to eq 'Unknown'
    end
  end
end
