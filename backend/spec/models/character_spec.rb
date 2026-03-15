# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Character do
  # Factory automatically creates full world hierarchy
  let!(:room) { create(:room) }
  let!(:reality) { create(:reality) }

  let!(:user) { create(:user) }
  let!(:other_user) { create(:user) }

  describe '#display_name_for' do
    let!(:character) do
      Character.create(
        user: user,
        forename: 'John',
        surname: 'Doe',
        race: 'human',
        character_class: 'warrior',
        is_npc: false,
        short_desc: 'A tall warrior',
        nickname: 'Johnny'
      )
    end

    let!(:viewer_character) do
      Character.create(
        user: other_user,
        forename: 'Jane',
        surname: 'Smith',
        race: 'elf',
        character_class: 'mage',
        is_npc: false
      )
    end

    let!(:viewer_shape) { CharacterShape.create(character: viewer_character, shape_name: 'Default', description: 'Default', is_default_shape: true) }
    let!(:viewer_instance) do
      CharacterInstance.create(
        character: viewer_character,
        reality: reality,
        current_room: room,
        current_shape: viewer_shape,
        level: 1
      )
    end

    context 'when no viewer is provided' do
      it 'returns the full name with nickname' do
        # Character has nickname 'Johnny' which differs from forename 'John'
        expect(character.display_name_for(nil)).to eq("John 'Johnny' Doe")
      end

      context 'when character has no nickname' do
        before { character.update(nickname: nil) }

        it 'returns the full name without nickname' do
          expect(character.display_name_for(nil)).to eq('John Doe')
        end
      end

      context 'when nickname matches forename' do
        before { character.update(nickname: 'John') }

        it 'returns the full name without repeated nickname' do
          expect(character.display_name_for(nil)).to eq('John Doe')
        end
      end
    end

    context 'when character is unknown to viewer' do
      context 'and character has short_desc' do
        it 'returns the short description' do
          expect(character.display_name_for(viewer_instance)).to eq('A tall warrior')
        end
      end

      context 'and character has no short_desc but has nickname' do
        before { character.update(short_desc: nil) }

        it 'returns the nickname' do
          expect(character.display_name_for(viewer_instance)).to eq('Johnny')
        end
      end

      context 'and character has neither short_desc nor nickname' do
        before { character.update(short_desc: nil, nickname: nil) }

        it 'returns "someone"' do
          expect(character.display_name_for(viewer_instance)).to eq('someone')
        end
      end

      context 'and character has empty short_desc and nickname' do
        before { character.update(short_desc: '', nickname: '') }

        it 'returns "someone"' do
          expect(character.display_name_for(viewer_instance)).to eq('someone')
        end
      end
    end

    context 'when character is known to viewer' do
      let!(:knowledge) do
        CharacterKnowledge.create(
          knower_character: viewer_character,
          known_character: character,
          is_known: true,
          known_name: 'Sir John'
        )
      end

      it 'returns the shortest known name part (forename)' do
        # known_name "Sir John" contains forename "John", so prefer shorter form
        expect(character.display_name_for(viewer_instance)).to eq('John')
      end

      context 'when known_name is empty' do
        before { knowledge.update(known_name: '') }

        it 'returns the full name with nickname' do
          expect(character.display_name_for(viewer_instance)).to eq("John 'Johnny' Doe")
        end
      end

      context 'when known_name is nil' do
        before { knowledge.update(known_name: nil) }

        it 'returns the full name with nickname' do
          expect(character.display_name_for(viewer_instance)).to eq("John 'Johnny' Doe")
        end
      end
    end

    context 'when knowledge exists but character is not marked as known' do
      let!(:knowledge) do
        CharacterKnowledge.create(
          knower_character: viewer_character,
          known_character: character,
          is_known: false,
          known_name: 'Sir John'
        )
      end

      it 'returns the short description' do
        expect(character.display_name_for(viewer_instance)).to eq('A tall warrior')
      end
    end
  end

  describe '#known_by?' do
    let!(:character) do
      Character.create(
        user: user,
        forename: 'John',
        surname: 'Doe',
        race: 'human',
        character_class: 'warrior',
        is_npc: false
      )
    end

    let!(:viewer_character) do
      Character.create(
        user: other_user,
        forename: 'Jane',
        surname: 'Smith',
        race: 'elf',
        character_class: 'mage',
        is_npc: false
      )
    end

    context 'when no knowledge exists' do
      it 'returns false' do
        expect(character.known_by?(viewer_character)).to be false
      end
    end

    context 'when knowledge exists but is_known is false' do
      before do
        CharacterKnowledge.create(
          knower_character: viewer_character,
          known_character: character,
          is_known: false
        )
      end

      it 'returns false' do
        expect(character.known_by?(viewer_character)).to be false
      end
    end

    context 'when knowledge exists and is_known is true' do
      before do
        CharacterKnowledge.create(
          knower_character: viewer_character,
          known_character: character,
          is_known: true
        )
      end

      it 'returns true' do
        expect(character.known_by?(viewer_character)).to be true
      end
    end

    context 'when viewer_character is nil' do
      it 'returns false' do
        expect(character.known_by?(nil)).to be false
      end
    end
  end

  describe '#introduce_to' do
    let!(:character) do
      Character.create(
        user: user,
        forename: 'John',
        surname: 'Doe',
        race: 'human',
        character_class: 'warrior',
        is_npc: false
      )
    end

    let!(:other_character) do
      Character.create(
        user: other_user,
        forename: 'Jane',
        surname: 'Smith',
        race: 'elf',
        character_class: 'mage',
        is_npc: false
      )
    end

    context 'when no knowledge exists' do
      it 'creates new knowledge record' do
        expect {
          character.introduce_to(other_character, 'Sir John')
        }.to change { CharacterKnowledge.count }.by(1)

        knowledge = CharacterKnowledge.last
        expect(knowledge.knower_character_id).to eq(other_character.id)
        expect(knowledge.known_character_id).to eq(character.id)
        expect(knowledge.is_known).to be true
        expect(knowledge.known_name).to eq('Sir John')
      end

      it 'uses full name if no known_as provided' do
        character.introduce_to(other_character)
        
        knowledge = CharacterKnowledge.last
        expect(knowledge.known_name).to eq('John Doe')
      end

      it 'returns true' do
        expect(character.introduce_to(other_character)).to be true
      end
    end

    context 'when knowledge already exists' do
      let!(:existing_knowledge) do
        CharacterKnowledge.create(
          knower_character: other_character,
          known_character: character,
          is_known: false,
          known_name: 'Unknown Person'
        )
      end

      it 'updates existing knowledge' do
        expect {
          character.introduce_to(other_character, 'Sir John')
        }.not_to change { CharacterKnowledge.count }

        existing_knowledge.reload
        expect(existing_knowledge.is_known).to be true
        expect(existing_knowledge.known_name).to eq('Sir John')
      end

      it 'updates last_seen_at' do
        old_time = existing_knowledge.last_seen_at
        allow(Time).to receive(:now).and_return(Time.now + 1)
        character.introduce_to(other_character)
        
        existing_knowledge.reload
        expect(existing_knowledge.last_seen_at).to be > old_time
      end
    end

    context 'when other_character is nil' do
      it 'returns false' do
        expect(character.introduce_to(nil)).to be false
      end

      it 'does not create knowledge record' do
        expect {
          character.introduce_to(nil)
        }.not_to change { CharacterKnowledge.count }
      end
    end
  end

  describe 'validations' do
    it 'requires forename' do
      char = Character.new(user: user)
      expect(char.valid?).to be false
      expect(char.errors[:forename]).not_to be_empty
    end

    it 'requires user_id for player characters' do
      char = Character.new(forename: 'Test', is_npc: false)
      expect(char.valid?).to be false
      expect(char.errors[:user_id]).not_to be_empty
    end

    it 'does not allow user_id for NPCs' do
      char = Character.new(forename: 'Test', is_npc: true, user_id: user.id)
      expect(char.valid?).to be false
      expect(char.errors[:user_id]).not_to be_empty
    end

    it 'validates forename length' do
      char = Character.new(forename: 'A' * 51, user: user)
      expect(char.valid?).to be false
    end

    it 'validates uniqueness of forename+surname for PCs' do
      Character.create(forename: 'John', surname: 'Doe', user: user)
      duplicate = Character.new(forename: 'John', surname: 'Doe', user: other_user)
      expect(duplicate.valid?).to be false
    end
  end

  describe 'before_save callbacks' do
    it 'strips whitespace from forename' do
      char = create(:character, forename: '  John  ')
      expect(char.forename).to eq('John')
    end

    it 'titlecases forename' do
      char = create(:character, forename: 'JOHN')
      expect(char.forename).to eq('John')
    end

    it 'titlecases surname' do
      char = create(:character, forename: 'John', surname: 'van der berg')
      expect(char.surname).to eq('Van Der Berg')
    end

    it 'handles hyphenated names' do
      char = create(:character, forename: 'mary-jane')
      expect(char.forename).to eq('Mary-Jane')
    end

    it 'clears empty surname' do
      char = create(:character, forename: 'John', surname: '')
      expect(char.surname).to be_nil
    end
  end

  describe '#full_name' do
    it 'returns forename when no surname' do
      char = create(:character, forename: 'John', surname: nil)
      expect(char.full_name).to eq('John')
    end

    it 'returns forename and surname when both present' do
      char = create(:character, forename: 'John', surname: 'Doe')
      expect(char.full_name).to eq('John Doe')
    end

    it 'includes nickname when different from forename' do
      char = create(:character, forename: 'John', surname: 'Doe', nickname: 'Johnny')
      expect(char.full_name).to eq("John 'Johnny' Doe")
    end

    it 'excludes nickname when same as forename' do
      char = create(:character, forename: 'John', surname: 'Doe', nickname: 'John')
      expect(char.full_name).to eq('John Doe')
    end
  end

  describe 'soft delete methods' do
    let!(:character) { create(:character) }

    describe '#deleted?' do
      it 'returns false when deleted_at is nil' do
        expect(character.deleted?).to be false
      end

      it 'returns true when deleted_at is set' do
        character.update(deleted_at: Time.now)
        expect(character.deleted?).to be true
      end
    end

    describe '#deletion_expired?' do
      it 'returns false when not deleted' do
        expect(character.deletion_expired?).to be false
      end

      it 'returns false when deleted recently' do
        character.update(deleted_at: Time.now - (10 * 24 * 3600))
        expect(character.deletion_expired?).to be false
      end

      it 'returns true when deleted and past retention period' do
        character.update(deleted_at: Time.now - (31 * 24 * 3600))
        expect(character.deletion_expired?).to be true
      end
    end

    describe '#days_until_permanent_deletion' do
      it 'returns nil when not deleted' do
        expect(character.days_until_permanent_deletion).to be_nil
      end

      it 'returns days remaining when deleted recently' do
        character.update(deleted_at: Time.now - (10 * 24 * 3600))
        days = character.days_until_permanent_deletion
        expect(days).to eq(20)
      end

      it 'returns 0 when deletion expired' do
        character.update(deleted_at: Time.now - (40 * 24 * 3600))
        expect(character.days_until_permanent_deletion).to eq(0)
      end
    end

    describe 'scopes' do
      before do
        @active = create(:character)
        @deleted_recent = create(:character, deleted_at: Time.now - (10 * 24 * 3600))
        @deleted_expired = create(:character, deleted_at: Time.now - (40 * 24 * 3600))
      end

      it '.not_deleted returns only non-deleted characters' do
        result = Character.not_deleted.all
        expect(result.map(&:id)).to include(@active.id)
        expect(result.map(&:id)).not_to include(@deleted_recent.id, @deleted_expired.id)
      end

      it '.deleted returns only deleted characters' do
        result = Character.deleted.all
        expect(result.map(&:id)).to include(@deleted_recent.id, @deleted_expired.id)
        expect(result.map(&:id)).not_to include(@active.id)
      end

      it '.expired_deleted returns only characters past retention' do
        result = Character.expired_deleted.all
        expect(result.map(&:id)).to include(@deleted_expired.id)
        expect(result.map(&:id)).not_to include(@active.id, @deleted_recent.id)
      end
    end
  end

  describe 'pronoun helpers' do
    let(:male_char) { create(:character, gender: 'male') }
    let(:female_char) { create(:character, gender: 'female') }
    let(:nonbinary_char) { create(:character, gender: 'non-binary') }
    let(:no_gender_char) { create(:character, gender: nil) }

    describe '#pronoun_subject' do
      it 'returns "he" for male' do
        expect(male_char.pronoun_subject).to eq('he')
      end

      it 'returns "she" for female' do
        expect(female_char.pronoun_subject).to eq('she')
      end

      it 'returns "they" for non-binary' do
        expect(nonbinary_char.pronoun_subject).to eq('they')
      end

      it 'returns "they" when gender is nil' do
        expect(no_gender_char.pronoun_subject).to eq('they')
      end
    end

    describe '#pronoun_possessive' do
      it 'returns "his" for male' do
        expect(male_char.pronoun_possessive).to eq('his')
      end

      it 'returns "her" for female' do
        expect(female_char.pronoun_possessive).to eq('her')
      end

      it 'returns "their" for non-binary' do
        expect(nonbinary_char.pronoun_possessive).to eq('their')
      end
    end

    describe '#pronoun_object' do
      it 'returns "him" for male' do
        expect(male_char.pronoun_object).to eq('him')
      end

      it 'returns "her" for female' do
        expect(female_char.pronoun_object).to eq('her')
      end

      it 'returns "them" for non-binary' do
        expect(nonbinary_char.pronoun_object).to eq('them')
      end
    end

    describe '#pronoun_reflexive' do
      it 'returns "himself" for male' do
        expect(male_char.pronoun_reflexive).to eq('himself')
      end

      it 'returns "herself" for female' do
        expect(female_char.pronoun_reflexive).to eq('herself')
      end

      it 'returns "themselves" for non-binary' do
        expect(nonbinary_char.pronoun_reflexive).to eq('themselves')
      end
    end
  end

  describe 'NPC type methods' do
    let(:pc) { create(:character, is_npc: false) }
    let(:unique_npc) { create(:character, :npc, is_unique_npc: true) }
    let(:template_npc) { create(:character, :npc, is_unique_npc: false) }

    describe '#npc?' do
      it 'returns false for player character' do
        expect(pc.npc?).to be false
      end

      it 'returns true for NPC' do
        expect(unique_npc.npc?).to be true
      end
    end

    describe '#unique_npc?' do
      it 'returns true for unique NPCs' do
        expect(unique_npc.unique_npc?).to be true
      end

      it 'returns false for template NPCs' do
        expect(template_npc.unique_npc?).to be false
      end

      it 'returns false for PCs' do
        expect(pc.unique_npc?).to be false
      end
    end

    describe '#template_npc?' do
      it 'returns true for template NPCs' do
        expect(template_npc.template_npc?).to be true
      end

      it 'returns false for unique NPCs' do
        expect(unique_npc.template_npc?).to be false
      end

      it 'returns false for PCs' do
        expect(pc.template_npc?).to be false
      end
    end
  end

  describe 'height and age display' do
    let(:character) { create(:character) }

    describe '#height_display' do
      it 'returns nil when height_cm is nil' do
        character.update(height_cm: nil)
        expect(character.height_display).to be_nil
      end

      it 'returns formatted height in imperial and metric' do
        character.update(height_cm: 180)
        expect(character.height_display).to match(/\d+'\d+" \/ \d+cm/)
      end

      it 'calculates correctly for 180cm' do
        character.update(height_cm: 180)
        expect(character.height_display).to eq("5'11\" / 180cm")
      end
    end

    describe '#apparent_age_bracket' do
      it 'returns nil when age is nil' do
        character.update(age: nil)
        expect(character.apparent_age_bracket).to be_nil
      end

      it 'returns nil when age is under 18' do
        character.update(age: 17)
        expect(character.apparent_age_bracket).to be_nil
      end

      it 'returns "late teens" for 18-19' do
        character.update(age: 19)
        expect(character.apparent_age_bracket).to eq('late teens')
      end

      it 'returns "early twenties" for 20-24' do
        character.update(age: 23)
        expect(character.apparent_age_bracket).to eq('early twenties')
      end

      it 'returns "mid thirties" for 35-37' do
        character.update(age: 36)
        expect(character.apparent_age_bracket).to eq('mid thirties')
      end

      it 'returns "late forties" for 48-49' do
        character.update(age: 49)
        expect(character.apparent_age_bracket).to eq('late forties')
      end

      it 'returns "very old" for 100+' do
        character.update(age: 105)
        expect(character.apparent_age_bracket).to eq('very old')
      end
    end
  end

  describe 'name change cooldown' do
    let(:character) { create(:character) }

    describe '#can_change_name?' do
      it 'returns true when last_name_change is nil' do
        character.update(last_name_change: nil)
        expect(character.can_change_name?).to be true
      end

      it 'returns true when cooldown has passed' do
        character.update(last_name_change: Time.now - Character::NAME_CHANGE_COOLDOWN - 1)
        expect(character.can_change_name?).to be true
      end

      it 'returns false when within cooldown' do
        character.update(last_name_change: Time.now - 60)
        expect(character.can_change_name?).to be false
      end
    end

    describe '#days_until_name_change' do
      it 'returns 0 when can change name' do
        character.update(last_name_change: nil)
        expect(character.days_until_name_change).to eq(0)
      end

      it 'returns days remaining when within cooldown' do
        character.update(last_name_change: Time.now - (10 * 24 * 3600))
        days = character.days_until_name_change
        expect(days).to be > 0
        expect(days).to be <= 21
      end
    end
  end

  describe 'voice settings' do
    let(:character) { create(:character) }

    describe '#voice_settings' do
      it 'returns default values when not set' do
        settings = character.voice_settings
        expect(settings[:voice_type]).to eq('Kore')
        expect(settings[:voice_pitch]).to eq(0.0)
        expect(settings[:voice_speed]).to eq(1.0)
      end

      it 'returns configured values when set' do
        character.update(voice_type: 'Charon', voice_pitch: 5.0, voice_speed: 1.5)
        settings = character.voice_settings
        expect(settings[:voice_type]).to eq('Charon')
        expect(settings[:voice_pitch]).to eq(5.0)
        expect(settings[:voice_speed]).to eq(1.5)
      end
    end

    describe '#set_voice!' do
      it 'sets voice configuration' do
        character.set_voice!(type: 'Fenrir', pitch: 10.0, speed: 2.0)
        character.reload
        expect(character.voice_type).to eq('Fenrir')
        expect(character.voice_pitch).to eq(10.0)
        expect(character.voice_speed).to eq(2.0)
      end

      it 'clamps pitch to valid range' do
        character.set_voice!(type: 'Test', pitch: 50.0, speed: 1.0)
        expect(character.voice_pitch).to eq(20.0)

        character.set_voice!(type: 'Test', pitch: -50.0, speed: 1.0)
        expect(character.voice_pitch).to eq(-20.0)
      end

      it 'clamps speed to valid range' do
        character.set_voice!(type: 'Test', pitch: 0.0, speed: 10.0)
        expect(character.voice_speed).to eq(4.0)

        character.set_voice!(type: 'Test', pitch: 0.0, speed: 0.1)
        expect(character.voice_speed).to eq(0.25)
      end
    end

    describe '#has_voice?' do
      it 'returns false when voice_type is empty' do
        character.update(voice_type: '')
        expect(character.has_voice?).to be false
      end

      it 'returns true when voice_type is set' do
        character.update(voice_type: 'Kore')
        expect(character.has_voice?).to be true
      end
    end
  end

  describe 'profile visibility' do
    let(:character) { create(:character, profile_visible: true) }

    describe '#publicly_visible?' do
      it 'returns false for NPCs' do
        npc = create(:character, :npc)
        expect(npc.publicly_visible?).to be false
      end

      it 'returns false when profile_visible is false' do
        character.update(profile_visible: false)
        expect(character.publicly_visible?).to be false
      end

      it 'returns false for agent users' do
        character.user.update(api_token_digest: BCrypt::Password.create('test'))
        expect(character.publicly_visible?).to be false
      end

      it 'returns true for normal visible PC' do
        expect(character.publicly_visible?).to be true
      end
    end

    describe '#touch_last_seen!' do
      it 'updates last_seen_at' do
        old_time = character.last_seen_at
        allow(Time).to receive(:now).and_return(Time.now + 1)
        character.touch_last_seen!
        character.reload
        expect(character.last_seen_at).to be_within(5).of(Time.now)
      end
    end

    describe '#increment_profile_score!' do
      it 'increments profile_score by 1 by default' do
        character.update(profile_score: 5)
        character.increment_profile_score!
        character.reload
        expect(character.profile_score).to eq(6)
      end

      it 'increments by specified amount' do
        character.update(profile_score: 5)
        character.increment_profile_score!(3)
        character.reload
        expect(character.profile_score).to eq(8)
      end

      it 'handles nil profile_score' do
        character.update(profile_score: nil)
        character.increment_profile_score!
        character.reload
        expect(character.profile_score).to eq(1)
      end
    end
  end

  describe 'staff character methods' do
    let(:regular_char) { create(:character) }
    let(:admin_user) { create(:user, :admin) }
    let(:staff_char) { create(:character, user: admin_user, is_staff_character: true) }

    describe '#staff_character?' do
      it 'returns false for regular character' do
        expect(regular_char.staff_character?).to be false
      end

      it 'returns true for staff character' do
        expect(staff_char.staff_character?).to be true
      end
    end

    describe '#staff?' do
      it 'is an alias for staff_character?' do
        expect(staff_char.staff?).to eq(staff_char.staff_character?)
      end
    end
  end
end