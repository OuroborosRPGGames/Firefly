# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/lib/safe_json_helper'

RSpec.describe SafeJSONHelper do
  let(:klass) { Class.new { extend SafeJSONHelper } }

  describe '#safe_json_parse' do
    it 'parses valid JSON' do
      result = klass.safe_json_parse('{"key":"value"}', fallback: {}, context: 'test')
      expect(result).to eq({ 'key' => 'value' })
    end

    it 'returns fallback for invalid JSON' do
      result = klass.safe_json_parse('not json', fallback: {}, context: 'test')
      expect(result).to eq({})
    end

    it 'returns fallback for nil input' do
      result = klass.safe_json_parse(nil, fallback: [], context: 'test')
      expect(result).to eq([])
    end

    it 'warns with context on parse error' do
      expect { klass.safe_json_parse('bad', fallback: nil, context: 'MyService') }
        .to output(/\[MyService\]/).to_stderr
    end
  end
end
