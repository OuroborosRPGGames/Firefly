# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MediaLibrary do
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to character' do
      media = MediaLibrary.new(character_id: character.id)
      expect(media.character.id).to eq(character.id)
    end
  end

  describe 'validations' do
    it 'requires character_id' do
      media = MediaLibrary.new(media_type: 'gradient', name: 'Test', content: 'data')
      expect(media.valid?).to be false
      expect(media.errors[:character_id]).not_to be_empty
    end

    it 'requires media_type' do
      media = MediaLibrary.new(character_id: character.id, name: 'Test', content: 'data')
      expect(media.valid?).to be false
      expect(media.errors[:media_type]).not_to be_empty
    end

    it 'requires name' do
      media = MediaLibrary.new(character_id: character.id, media_type: 'gradient', content: 'data')
      expect(media.valid?).to be false
      expect(media.errors[:name]).not_to be_empty
    end

    it 'requires content' do
      media = MediaLibrary.new(character_id: character.id, media_type: 'gradient', name: 'Test')
      expect(media.valid?).to be false
      expect(media.errors[:content]).not_to be_empty
    end

    it 'validates media_type is in MEDIA_TYPES' do
      media = MediaLibrary.new(character_id: character.id, media_type: 'invalid', name: 'Test', content: 'data')
      expect(media.valid?).to be false
      expect(media.errors[:media_type]).not_to be_empty
    end

    %w[gradient pic vid tpic tvid].each do |type|
      it "accepts #{type} as media_type" do
        media = MediaLibrary.new(character_id: character.id, media_type: type, name: 'Test', content: 'data')
        expect(media.valid?).to be true
      end
    end

    it 'validates name max length of 100' do
      media = MediaLibrary.new(character_id: character.id, media_type: 'gradient', name: 'a' * 101, content: 'data')
      expect(media.valid?).to be false
      expect(media.errors[:name]).not_to be_empty
    end

    it 'validates uniqueness of name within character' do
      MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'MyGradient', content: 'red,blue')
      duplicate = MediaLibrary.new(character_id: character.id, media_type: 'pic', name: 'MyGradient', content: 'url')
      expect(duplicate.valid?).to be false
    end

    it 'allows same name for different characters' do
      other_char = create(:character)
      MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'SameName', content: 'red,blue')
      other_media = MediaLibrary.new(character_id: other_char.id, media_type: 'gradient', name: 'SameName', content: 'green,yellow')
      expect(other_media.valid?).to be true
    end
  end

  describe 'legacy column accessors' do
    let(:media) { MediaLibrary.new(media_type: 'gradient', name: 'MyGrad', content: 'red,blue') }

    describe '#mtype / #mtype=' do
      it 'reads from media_type' do
        expect(media.mtype).to eq('gradient')
      end

      it 'writes to media_type' do
        media.mtype = 'pic'
        expect(media.media_type).to eq('pic')
      end
    end

    describe '#mname / #mname=' do
      it 'reads from name' do
        expect(media.mname).to eq('MyGrad')
      end

      it 'writes to name' do
        media.mname = 'NewName'
        expect(media.name).to eq('NewName')
      end
    end

    describe '#mtext / #mtext=' do
      it 'reads from content' do
        expect(media.mtext).to eq('red,blue')
      end

      it 'writes to content' do
        media.mtext = 'green,yellow'
        expect(media.content).to eq('green,yellow')
      end
    end
  end

  describe 'type helpers' do
    describe '#gradient?' do
      it 'returns true for gradient type' do
        media = MediaLibrary.new(media_type: 'gradient')
        expect(media.gradient?).to be true
      end

      it 'returns false for other types' do
        media = MediaLibrary.new(media_type: 'pic')
        expect(media.gradient?).to be false
      end
    end

    describe '#picture?' do
      it 'returns true for pic type' do
        expect(MediaLibrary.new(media_type: 'pic').picture?).to be true
      end

      it 'returns true for tpic type' do
        expect(MediaLibrary.new(media_type: 'tpic').picture?).to be true
      end

      it 'returns false for other types' do
        expect(MediaLibrary.new(media_type: 'gradient').picture?).to be false
      end
    end

    describe '#video?' do
      it 'returns true for vid type' do
        expect(MediaLibrary.new(media_type: 'vid').video?).to be true
      end

      it 'returns true for tvid type' do
        expect(MediaLibrary.new(media_type: 'tvid').video?).to be true
      end

      it 'returns false for other types' do
        expect(MediaLibrary.new(media_type: 'gradient').video?).to be false
      end
    end

    describe '#text_based?' do
      it 'returns true for tpic' do
        expect(MediaLibrary.new(media_type: 'tpic').text_based?).to be true
      end

      it 'returns true for tvid' do
        expect(MediaLibrary.new(media_type: 'tvid').text_based?).to be true
      end

      it 'returns false for regular types' do
        expect(MediaLibrary.new(media_type: 'pic').text_based?).to be false
      end
    end
  end

  describe 'class methods' do
    describe '.find_by_name' do
      it 'finds by name case-insensitively' do
        media = MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'MyGrad', content: 'red,blue')
        expect(described_class.find_by_name(character, 'MYGRAD')).to eq(media)
      end

      it 'returns nil if not found' do
        expect(described_class.find_by_name(character, 'NotFound')).to be_nil
      end
    end

    describe '.gradients_for' do
      it 'returns only gradients for character' do
        gradient = MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'Grad1', content: 'red,blue')
        pic = MediaLibrary.create(character_id: character.id, media_type: 'pic', name: 'Pic1', content: 'url')

        results = described_class.gradients_for(character).all
        expect(results).to include(gradient)
        expect(results).not_to include(pic)
      end
    end

    describe '.pictures_for' do
      it 'returns pic and tpic types' do
        pic = MediaLibrary.create(character_id: character.id, media_type: 'pic', name: 'Pic1', content: 'url')
        tpic = MediaLibrary.create(character_id: character.id, media_type: 'tpic', name: 'TPic1', content: 'text')
        gradient = MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'Grad', content: 'red')

        results = described_class.pictures_for(character).all
        expect(results).to include(pic, tpic)
        expect(results).not_to include(gradient)
      end
    end

    describe '.videos_for' do
      it 'returns vid and tvid types' do
        vid = MediaLibrary.create(character_id: character.id, media_type: 'vid', name: 'Vid1', content: 'url')
        tvid = MediaLibrary.create(character_id: character.id, media_type: 'tvid', name: 'TVid1', content: 'text')
        gradient = MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'Grad', content: 'red')

        results = described_class.videos_for(character).all
        expect(results).to include(vid, tvid)
        expect(results).not_to include(gradient)
      end
    end

    describe '.for_character' do
      it 'returns all media for a character ordered by name' do
        media_b = MediaLibrary.create(character_id: character.id, media_type: 'gradient', name: 'BBB', content: 'red')
        media_a = MediaLibrary.create(character_id: character.id, media_type: 'pic', name: 'AAA', content: 'url')

        results = described_class.for_character(character).all
        expect(results.map(&:name)).to eq(%w[AAA BBB])
      end
    end
  end

  describe 'gradient helpers' do
    describe '#gradient_data' do
      it 'returns empty hash by default' do
        media = MediaLibrary.new
        expect(media.gradient_data).to eq({})
      end

      it 'returns stored data' do
        media = MediaLibrary.new
        media.gradient_data = { 'colors' => ['red', 'blue'] }
        expect(media.gradient_data).to eq({ 'colors' => ['red', 'blue'] })
      end
    end

    describe '#gradient_colors' do
      it 'returns colors from gradient_data if present' do
        media = MediaLibrary.new
        media.gradient_data = { 'colors' => ['red', 'green', 'blue'] }
        expect(media.gradient_colors).to eq(['red', 'green', 'blue'])
      end

      it 'parses content as comma-separated colors if no gradient_data' do
        media = MediaLibrary.new(content: 'red, green, blue')
        expect(media.gradient_colors).to eq(['red', 'green', 'blue'])
      end

      it 'returns empty array if no data' do
        media = MediaLibrary.new
        expect(media.gradient_colors).to eq([])
      end
    end

    describe '#ciede2000?' do
      it 'returns true if interpolation is ciede2000' do
        media = MediaLibrary.new
        media.gradient_data = { 'interpolation' => 'ciede2000' }
        expect(media.ciede2000?).to be true
      end

      it 'returns false otherwise' do
        media = MediaLibrary.new
        expect(media.ciede2000?).to be false
      end
    end
  end
end
