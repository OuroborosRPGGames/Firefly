# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ConsentOverride do
  let(:character) { create(:character) }
  let(:target_character) { create(:character) }
  let(:content_restriction) { create(:content_restriction) }

  describe 'associations' do
    it 'belongs to character' do
      override = create(:consent_override, character: character, target_character: target_character, content_restriction: content_restriction)
      expect(override.character.id).to eq(character.id)
    end

    it 'belongs to target_character' do
      override = create(:consent_override, character: character, target_character: target_character, content_restriction: content_restriction)
      expect(override.target_character.id).to eq(target_character.id)
    end

    it 'belongs to content_restriction' do
      override = create(:consent_override, character: character, target_character: target_character, content_restriction: content_restriction)
      expect(override.content_restriction.id).to eq(content_restriction.id)
    end
  end

  describe 'validations' do
    it 'requires character_id' do
      override = ConsentOverride.new(
        target_character_id: target_character.id,
        content_restriction_id: content_restriction.id
      )
      expect(override.valid?).to be false
      expect(override.errors[:character_id]).not_to be_empty
    end

    it 'requires target_character_id' do
      override = ConsentOverride.new(
        character_id: character.id,
        content_restriction_id: content_restriction.id
      )
      expect(override.valid?).to be false
      expect(override.errors[:target_character_id]).not_to be_empty
    end

    it 'requires content_restriction_id' do
      override = ConsentOverride.new(
        character_id: character.id,
        target_character_id: target_character.id
      )
      expect(override.valid?).to be false
      expect(override.errors[:content_restriction_id]).not_to be_empty
    end

    it 'validates uniqueness of combination' do
      create(:consent_override, character: character, target_character: target_character, content_restriction: content_restriction)

      duplicate = ConsentOverride.new(
        character_id: character.id,
        target_character_id: target_character.id,
        content_restriction_id: content_restriction.id
      )
      expect(duplicate.valid?).to be false
    end

    it 'prevents self-targeting' do
      override = ConsentOverride.new(
        character_id: character.id,
        target_character_id: character.id,
        content_restriction_id: content_restriction.id
      )
      expect(override.valid?).to be false
      expect(override.errors[:target_character_id]).not_to be_empty
    end

    it 'is valid with all required fields' do
      override = ConsentOverride.new(
        character_id: character.id,
        target_character_id: target_character.id,
        content_restriction_id: content_restriction.id
      )
      expect(override.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'sets granted_at when allowed' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: true,
                        granted_at: nil)
      expect(override.granted_at).not_to be_nil
    end
  end

  describe '#allowed?' do
    it 'returns true when allowed and not revoked' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: true,
                        revoked_at: nil)
      expect(override.allowed?).to be true
    end

    it 'returns false when not allowed' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: false)
      expect(override.allowed?).to be false
    end

    it 'returns false when revoked' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: true,
                        revoked_at: Time.now)
      expect(override.allowed?).to be false
    end
  end

  describe '#revoke!' do
    it 'sets allowed to false' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: true)
      override.revoke!
      override.refresh

      expect(override.allowed).to be false
    end

    it 'sets revoked_at' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: true)
      override.revoke!
      override.refresh

      expect(override.revoked_at).not_to be_nil
    end
  end

  describe '#grant!' do
    it 'sets allowed to true' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: false)
      override.grant!
      override.refresh

      expect(override.allowed).to be true
    end

    it 'sets granted_at' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: false)
      override.grant!
      override.refresh

      expect(override.granted_at).not_to be_nil
    end

    it 'clears revoked_at' do
      override = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction,
                        allowed: true,
                        revoked_at: Time.now - 60)
      override.grant!
      override.refresh

      expect(override.revoked_at).to be_nil
    end
  end

  describe '.has_override?' do
    it 'returns true when allowed override exists' do
      create(:consent_override,
             character: character,
             target_character: target_character,
             content_restriction: content_restriction,
             allowed: true,
             revoked_at: nil)

      expect(ConsentOverride.has_override?(character, target_character, content_restriction)).to be true
    end

    it 'returns false when no override exists' do
      expect(ConsentOverride.has_override?(character, target_character, content_restriction)).to be_falsey
    end

    it 'returns false when override is not allowed' do
      create(:consent_override,
             character: character,
             target_character: target_character,
             content_restriction: content_restriction,
             allowed: false)

      expect(ConsentOverride.has_override?(character, target_character, content_restriction)).to be false
    end
  end

  describe '.mutual_override?' do
    it 'returns true when both parties have allowed overrides' do
      create(:consent_override,
             character: character,
             target_character: target_character,
             content_restriction: content_restriction,
             allowed: true)
      create(:consent_override,
             character: target_character,
             target_character: character,
             content_restriction: content_restriction,
             allowed: true)

      expect(ConsentOverride.mutual_override?(character, target_character, content_restriction)).to be true
    end

    it 'returns false when only one party has override' do
      create(:consent_override,
             character: character,
             target_character: target_character,
             content_restriction: content_restriction,
             allowed: true)

      expect(ConsentOverride.mutual_override?(character, target_character, content_restriction)).to be_falsey
    end
  end

  describe '.overrides_between' do
    it 'returns allowed overrides between characters' do
      override1 = create(:consent_override,
                         character: character,
                         target_character: target_character,
                         content_restriction: content_restriction,
                         allowed: true)

      other_restriction = create(:content_restriction)
      override2 = create(:consent_override,
                         character: character,
                         target_character: target_character,
                         content_restriction: other_restriction,
                         allowed: true)

      results = ConsentOverride.overrides_between(character, target_character)

      expect(results.map(&:id)).to include(override1.id, override2.id)
    end

    it 'excludes revoked overrides' do
      create(:consent_override,
             character: character,
             target_character: target_character,
             content_restriction: content_restriction,
             allowed: true,
             revoked_at: Time.now)

      results = ConsentOverride.overrides_between(character, target_character)

      expect(results).to be_empty
    end
  end

  describe '.find_or_create_between' do
    it 'returns existing override' do
      existing = create(:consent_override,
                        character: character,
                        target_character: target_character,
                        content_restriction: content_restriction)

      result = ConsentOverride.find_or_create_between(character, target_character, content_restriction)

      expect(result.id).to eq(existing.id)
    end

    it 'creates new override if none exists' do
      result = ConsentOverride.find_or_create_between(character, target_character, content_restriction)

      expect(result).not_to be_nil
      expect(result.character_id).to eq(character.id)
      expect(result.target_character_id).to eq(target_character.id)
      expect(result.content_restriction_id).to eq(content_restriction.id)
      expect(result.allowed).to be false
    end
  end
end
