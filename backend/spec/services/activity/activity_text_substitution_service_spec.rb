# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityTextSubstitutionService do
  let(:character) do
    double('Character',
      full_name: 'Kael Stormbringer',
      gender: 'male',
      pronoun_subject: 'he',
      pronoun_object: 'him',
      pronoun_possessive: 'his',
      pronoun_reflexive: 'himself',
      display_name_for: 'Kael Stormbringer')
  end

  describe '.substitute' do
    context 'with plain text (no HTML)' do
      it 'replaces (name) with character name' do
        result = described_class.substitute('(name) opens the door.', character: character)
        expect(result).to eq('Kael Stormbringer opens the door.')
      end

      it 'replaces pronoun tokens with character pronouns' do
        result = described_class.substitute('(he) hurts (his) fists. (he) blames (himself).', character: character)
        expect(result).to eq('he hurts his fists. he blames himself.')
      end

      it 'replaces (she)/(her) tokens using character gender' do
        result = described_class.substitute('(she) opens (her) bag.', character: character)
        # Male character: (she) -> he, (her) -> his (possessive context)
        expect(result).to eq('he opens his bag.')
      end

      it 'preserves capitalization: (Name) capitalizes' do
        result = described_class.substitute('(Name) arrives.', character: character)
        expect(result).to eq('Kael Stormbringer arrives.')
      end

      it 'preserves capitalization: (He) capitalizes' do
        result = described_class.substitute('(He) opens the door.', character: character)
        expect(result).to eq('He opens the door.')
      end

      it 'handles (him)/(them) object pronouns' do
        result = described_class.substitute('They push (him) aside.', character: character)
        expect(result).to eq('They push him aside.')
      end
    end

    context 'with female character' do
      let(:female_char) do
        double('Character',
          full_name: 'Aria Moonwhisper',
          gender: 'female',
          pronoun_subject: 'she',
          pronoun_object: 'her',
          pronoun_possessive: 'her',
          pronoun_reflexive: 'herself',
          display_name_for: 'Aria Moonwhisper')
      end

      it 'uses female pronouns regardless of token form' do
        result = described_class.substitute('(he) draws (his) sword.', character: female_char)
        expect(result).to eq('she draws her sword.')
      end
    end

    context 'with non-binary character' do
      let(:nb_char) do
        double('Character',
          full_name: 'Riven',
          gender: nil,
          pronoun_subject: 'they',
          pronoun_object: 'them',
          pronoun_possessive: 'their',
          pronoun_reflexive: 'themselves',
          display_name_for: 'Riven')
      end

      it 'uses they/them pronouns' do
        result = described_class.substitute('(he) draws (his) sword.', character: nb_char)
        expect(result).to eq('they draws their sword.')
      end
    end

    context 'with viewer-specific name' do
      let(:viewer) do
        double('CharacterInstance')
      end

      it 'uses display_name_for when viewer provided' do
        allow(character).to receive(:display_name_for).with(viewer).and_return('a tall stranger')
        result = described_class.substitute('(name) arrives.', character: character, viewer: viewer)
        expect(result).to eq('a tall stranger arrives.')
      end
    end

    context 'with no tokens' do
      it 'returns text unchanged' do
        result = described_class.substitute('Nothing special here.', character: character)
        expect(result).to eq('Nothing special here.')
      end
    end

    context 'with nil/empty input' do
      it 'returns nil for nil' do
        expect(described_class.substitute(nil, character: character)).to be_nil
      end

      it 'returns empty for empty' do
        expect(described_class.substitute('', character: character)).to eq('')
      end
    end
  end

  describe '.has_tokens?' do
    it 'returns true when text contains tokens' do
      expect(described_class.has_tokens?('(name) arrives.')).to be true
    end

    it 'returns false for plain text' do
      expect(described_class.has_tokens?('No tokens here.')).to be false
    end

    it 'returns false for nil' do
      expect(described_class.has_tokens?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(described_class.has_tokens?('')).to be false
    end
  end

  describe '.substitute with HTML' do
    let(:character) do
      double('Character',
        full_name: 'Kael',
        gender: 'male',
        pronoun_subject: 'he',
        pronoun_object: 'him',
        pronoun_possessive: 'his',
        pronoun_reflexive: 'himself',
        display_name_for: 'Kael')
    end

    it 'replaces tokens inside HTML elements' do
      html = '<span style="color: red">(name) attacks!</span>'
      result = described_class.substitute(html, character: character)
      expect(result).to include('Kael attacks!')
      expect(result).to include('color: red')
    end

    it 'does not corrupt HTML tags' do
      html = '<b>(name)</b> opens <em>(his)</em> bag.'
      result = described_class.substitute(html, character: character)
      expect(result).to include('<b>Kael</b>')
      expect(result).to include('<em>his</em>')
    end

    it 'adjusts background-size for gradients' do
      html = '<span style="background-size: 60px 100%">(name)</span>'
      result = described_class.substitute(html, character: character)
      # "(name)" text node = 6 chars, "Kael" = 4 chars. Ratio 4/6=0.667. 60*0.667=40.0
      expect(result).to match(/background-size:\s*40\.0px/)
    end

    context 'with tokens split across text nodes by HTML tags' do
      it 'handles token fully wrapped: (<b>name</b>)' do
        html = '(<b>name</b>) attacks!'
        result = described_class.substitute(html, character: character)
        expect(result).to include('Kael')
        expect(result).not_to include('(')
        expect(result).not_to include(')')
      end

      it 'handles token partially wrapped: (na<b>me</b>)' do
        html = '(na<b>me</b>) attacks!'
        result = described_class.substitute(html, character: character)
        expect(result).to include('Kael')
        expect(result).not_to include('(na')
      end

      it 'handles pronoun split: (<em>his</em>)' do
        html = '(<em>his</em>) sword gleams.'
        result = described_class.substitute(html, character: character)
        expect(result).to include('his')
        expect(result).not_to include('(')
        expect(result).not_to include(')')
      end

      it 'handles token split across multiple spans' do
        html = '<span>(</span><span>name</span><span>)</span> arrives.'
        result = described_class.substitute(html, character: character)
        expect(result).to include('Kael')
        expect(result).not_to include('(')
        expect(result).not_to include(')')
      end

      it 'preserves surrounding text in nodes' do
        html = 'Hello (<b>name</b>), welcome!'
        result = described_class.substitute(html, character: character)
        expect(result).to include('Hello Kael')
        expect(result).to include('welcome!')
      end

      it 'handles mix of split and unsplit tokens' do
        html = '(<b>name</b>) draws (his) sword.'
        result = described_class.substitute(html, character: character)
        expect(result).to include('Kael')
        expect(result).to include('his')
        expect(result).not_to match(/\([a-z]+\)/i)
      end

      it 'preserves case: (<b>Name</b>) capitalizes' do
        html = '(<b>Name</b>) arrives.'
        result = described_class.substitute(html, character: character)
        expect(result).to include('Kael')
      end
    end
  end
end
