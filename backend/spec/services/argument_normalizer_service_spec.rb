# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ArgumentNormalizerService do
  describe '.normalize' do
    describe 'say command variations' do
      it 'normalizes "say to bob hello" to target-first format' do
        result = described_class.normalize('say', 'to bob hello there')
        expect(result).to eq({ target: 'bob', message: 'hello there' })
      end

      it 'normalizes "say hello to bob" to target-first format' do
        result = described_class.normalize('say', 'hello to bob')
        expect(result).to eq({ target: 'bob', message: 'hello' })
      end

      it 'normalizes "tell bob hello" to target-first format' do
        result = described_class.normalize('tell', 'bob hello there')
        expect(result).to eq({ target: 'bob', message: 'hello there' })
      end

      it 'handles comma-prefix direct address' do
        result = described_class.normalize_direct_address('bob, hello there')
        expect(result).to eq({ command: 'say', target: 'bob', message: 'hello there' })
      end

      it 'returns nil for non-direct-address input' do
        result = described_class.normalize_direct_address('just some text')
        expect(result).to be_nil
      end
    end

    describe 'give command variations' do
      it 'normalizes "give sword to bob" to target-first format' do
        result = described_class.normalize('give', 'sword to bob')
        expect(result).to eq({ target: 'bob', item: 'sword' })
      end

      it 'normalizes "give bob the sword" to target-first format' do
        result = described_class.normalize('give', 'bob the sword')
        expect(result).to eq({ target: 'bob', item: 'sword' })
      end

      it 'normalizes "give bob sword" (already correct)' do
        result = described_class.normalize('give', 'bob sword')
        expect(result).to eq({ target: 'bob', item: 'sword' })
      end
    end

    describe 'communication aliases' do
      %w[mutter grumble scream moan gasp sob stutter murmur whi wh].each do |cmd|
        it "#{cmd} normalizes 'hello to bob' correctly" do
          result = described_class.normalize(cmd, 'hello to bob')
          expect(result).to eq({ target: 'bob', message: 'hello' })
        end
      end

      %w[sayto order instruct beg demand tease mock taunt].each do |cmd|
        it "#{cmd} normalizes 'to bob hello' correctly" do
          result = described_class.normalize(cmd, 'to bob hello')
          expect(result).to eq({ target: 'bob', message: 'hello' })
        end
      end
    end

    describe 'transfer aliases' do
      %w[offer pass slip gift display present].each do |cmd|
        it "#{cmd} normalizes 'sword to bob' correctly" do
          result = described_class.normalize(cmd, 'sword to bob')
          expect(result).to eq({ target: 'bob', item: 'sword' })
        end

        it "#{cmd} normalizes 'bob the sword' correctly" do
          result = described_class.normalize(cmd, 'bob the sword')
          expect(result).to eq({ target: 'bob', item: 'sword' })
        end
      end
    end

    describe 'pemit/subtle as communication' do
      %w[pemit semit subtle].each do |cmd|
        it "#{cmd} normalizes 'to bob hello' correctly" do
          result = described_class.normalize(cmd, 'to bob hello')
          expect(result).to eq({ target: 'bob', message: 'hello' })
        end

        it "#{cmd} normalizes 'bob hello there' correctly" do
          result = described_class.normalize(cmd, 'bob hello there')
          expect(result).to eq({ target: 'bob', message: 'hello there' })
        end
      end
    end

    describe 'container commands' do
      describe 'get/take variations' do
        it 'strips articles: "get the sword"' do
          result = described_class.normalize('get', 'the sword')
          expect(result).to eq({ item: 'sword' })
        end

        it 'strips articles: "take a potion"' do
          result = described_class.normalize('take', 'a potion')
          expect(result).to eq({ item: 'potion' })
        end

        it 'extracts container: "get sword from bag"' do
          result = described_class.normalize('get', 'sword from bag')
          expect(result).to eq({ item: 'sword', container: 'bag', preposition: 'from' })
        end

        it 'extracts container: "take the sword from the table"' do
          result = described_class.normalize('take', 'the sword from the table')
          expect(result).to eq({ item: 'sword', container: 'table', preposition: 'from' })
        end

        it 'extracts container: "get sword off shelf"' do
          result = described_class.normalize('get', 'sword off shelf')
          expect(result).to eq({ item: 'sword', container: 'shelf', preposition: 'off' })
        end

        it 'passes through simple items without articles' do
          result = described_class.normalize('get', 'sword')
          expect(result).to eq({ raw: 'sword' })
        end

        it 'passes through "all"' do
          result = described_class.normalize('get', 'all')
          expect(result).to eq({ raw: 'all' })
        end
      end

      describe 'drop/put variations' do
        it 'strips articles: "drop the sword"' do
          result = described_class.normalize('drop', 'the sword')
          expect(result).to eq({ item: 'sword' })
        end

        it 'extracts container: "put sword in bag"' do
          result = described_class.normalize('put', 'sword in bag')
          expect(result).to eq({ item: 'sword', container: 'bag', preposition: 'in' })
        end

        it 'extracts container: "put the sword on the table"' do
          result = described_class.normalize('put', 'the sword on the table')
          expect(result).to eq({ item: 'sword', container: 'table', preposition: 'on' })
        end

        it 'extracts container: "drop sword into chest"' do
          result = described_class.normalize('drop', 'sword into chest')
          expect(result).to eq({ item: 'sword', container: 'chest', preposition: 'into' })
        end

        it 'handles "discard" alias' do
          result = described_class.normalize('discard', 'the old sword')
          expect(result).to eq({ item: 'old sword' })
        end
      end

      describe 'grab/pickup aliases' do
        it 'grab strips articles' do
          result = described_class.normalize('grab', 'the key')
          expect(result).to eq({ item: 'key' })
        end

        it 'pickup extracts container' do
          result = described_class.normalize('pickup', 'key from drawer')
          expect(result).to eq({ item: 'key', container: 'drawer', preposition: 'from' })
        end
      end
    end

    describe 'passthrough for non-matching patterns' do
      it 'returns original text when no pattern matches' do
        result = described_class.normalize('look', 'around')
        expect(result).to eq({ raw: 'around' })
      end
    end
  end
end
