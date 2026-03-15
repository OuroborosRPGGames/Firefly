# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterDisplayConcern do
  # Create a test class that includes the concern
  let(:test_class) do
    Class.new do
      include CharacterDisplayConcern

      def initialize(character, viewer = nil)
        @character = character
        @viewer = viewer
      end
    end
  end

  let(:user) { create(:user) }
  let(:character) do
    create(:character,
           user: user,
           forename: 'Elena',
           surname: 'Blackwood',
           gender: 'female')
  end

  describe '#display_name' do
    context 'without a viewer' do
      subject { test_class.new(character) }

      it 'returns the full name' do
        expect(subject.display_name).to eq('Elena Blackwood')
      end
    end

    context 'with a viewer' do
      let(:viewer_user) { create(:user) }
      let(:viewer_character) { create(:character, user: viewer_user, forename: 'Viewer') }
      subject { test_class.new(character, viewer_character) }

      it 'delegates to character.display_name_for' do
        allow(character).to receive(:display_name_for).with(viewer_character).and_return('some stranger')
        expect(subject.display_name).to eq('some stranger')
      end
    end
  end

  describe 'pronoun methods' do
    subject { test_class.new(character) }

    describe '#pronoun_subject' do
      it 'returns capitalized subject pronoun' do
        allow(character).to receive(:pronoun_subject).and_return('she')
        expect(subject.pronoun_subject).to eq('She')
      end
    end

    describe '#pronoun_possessive' do
      it 'returns capitalized possessive pronoun' do
        allow(character).to receive(:pronoun_possessive).and_return('her')
        expect(subject.pronoun_possessive).to eq('Her')
      end
    end

    describe '#pronoun_object' do
      it 'returns object pronoun' do
        allow(character).to receive(:pronoun_object).and_return('her')
        expect(subject.pronoun_object).to eq('her')
      end
    end

    describe '#pronoun_reflexive' do
      it 'returns reflexive pronoun' do
        allow(character).to receive(:pronoun_reflexive).and_return('herself')
        expect(subject.pronoun_reflexive).to eq('herself')
      end
    end
  end
end
