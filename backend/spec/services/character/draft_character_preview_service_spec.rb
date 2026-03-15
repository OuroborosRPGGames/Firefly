# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DraftCharacterPreviewService do
  let(:character) do
    create(:character,
      forename: 'Test',
      surname: 'Character',
      short_desc: 'A tall mysterious figure',
      gender: 'Male',
      body_type: 'Athletic',
      ethnicity: 'Caucasian',
      height_cm: 188, # ~6'2"
      hair_color: 'Black',
      hair_style: 'Short',
      eye_color: 'Blue'
    )
  end

  subject(:service) { described_class.new(character) }

  describe '#build_display' do
    it 'returns a hash with display data matching CharacterDisplayService format' do
      display = service.build_display

      expect(display).to be_a(Hash)
      expect(display).to have_key(:name)
      expect(display).to have_key(:short_desc)
      expect(display).to have_key(:intro)
      expect(display).to have_key(:profile_pic_url)
    end

    it 'includes the character name' do
      display = service.build_display
      expect(display[:name]).to eq('Test Character')
    end

    it 'includes the short description' do
      display = service.build_display
      expect(display[:short_desc]).to eq('A tall mysterious figure')
    end

    it 'builds an intro with gender and body type' do
      display = service.build_display
      expect(display[:intro]).to include('He is')
      expect(display[:intro]).to include('athletic')  # lowercase mid-sentence
    end

    it 'includes height in intro' do
      display = service.build_display
      # Now uses "standing at" for single-sentence format
      expect(display[:intro]).to include('standing at')
    end

    it 'returns eyes_hair_line with defaults when none exist' do
      display = service.build_display

      # Eyes and hair now go in a dedicated line, not descriptions array
      expect(display[:eyes_hair_line]).to be_a(String)
      expect(display[:eyes_hair_line]).to include('eyes')
      expect(display[:eyes_hair_line]).to include('and')
    end

    it 'excludes eyes and hair from descriptions array' do
      display = service.build_display

      # Descriptions array should not include eyes/hair (those go in eyes_hair_line)
      eyes_desc = display[:descriptions].find { |d| d[:body_position] == 'eyes' }
      hair_desc = display[:descriptions].find { |d| d[:body_position] == 'scalp' }

      expect(eyes_desc).to be_nil
      expect(hair_desc).to be_nil
    end

    it 'returns empty clothing array (no clothing during creation)' do
      display = service.build_display
      expect(display[:clothing]).to eq([])
    end

    it 'returns empty held_items array (no items during creation)' do
      display = service.build_display
      expect(display[:held_items]).to eq([])
    end
  end

  describe '#render_html' do
    it 'returns HTML string' do
      html = service.render_html
      expect(html).to be_a(String)
      expect(html).to include('preview-')
    end

    it 'includes the character name in HTML' do
      html = service.render_html
      expect(html).to include('Test Character')
    end

    it 'includes the short description in HTML (with lowercase start for grammar)' do
      html = service.render_html
      # short_desc first letter is lowercased for grammatical flow in name_line
      expect(html).to include('a tall mysterious figure')
    end

    it 'escapes HTML entities in user content' do
      xss_character = create(:character,
        forename: 'XSS',
        surname: 'Test',
        short_desc: '<script>alert("xss")</script>',
        gender: 'Male'
      )
      service = described_class.new(xss_character)
      html = service.render_html

      expect(html).not_to include('<script>')
      expect(html).to include('&lt;script&gt;')
    end
  end

  describe 'with minimal character' do
    let(:minimal_character) do
      # Character with only required forename, no appearance data
      create(:character,
        forename: 'Minimal',
        surname: nil,
        short_desc: nil,
        gender: nil,
        body_type: nil
      )
    end

    it 'returns HTML even with minimal data' do
      service = described_class.new(minimal_character)
      html = service.render_html

      # With just a forename, still shows the name
      expect(html).to be_a(String)
      expect(html).to include('Minimal')
    end

    it 'returns has_content false when has_displayable_content? returns false' do
      # Build an in-memory character with nothing set
      char = Character.new
      char.values[:forename] = nil  # bypass mass assignment
      service = described_class.new(char)
      display = service.build_display

      expect(display[:has_content]).to be false
    end
  end

  describe 'with picture_url' do
    let(:character_with_picture) do
      create(:character,
        forename: 'Pic',
        surname: 'Test',
        picture_url: 'https://example.com/pic.jpg',
        gender: 'Female'
      )
    end

    it 'includes profile_pic_url in display' do
      service = described_class.new(character_with_picture)
      display = service.build_display

      expect(display[:profile_pic_url]).to eq('https://example.com/pic.jpg')
    end

    it 'renders picture in HTML' do
      service = described_class.new(character_with_picture)
      html = service.render_html

      expect(html).to include('portrait-container')
      expect(html).to include('preview-profile-pic')
      expect(html).to include('https://example.com/pic.jpg')
    end
  end

  describe 'gender-specific language' do
    it 'uses correct pronouns for female' do
      female_character = create(:character,
        forename: 'Female',
        surname: 'Character',
        gender: 'Female',
        body_type: 'Slim'
      )
      service = described_class.new(female_character)
      display = service.build_display

      expect(display[:intro]).to include('She is')
    end

    it 'uses correct pronouns for male' do
      male_character = create(:character,
        forename: 'Male',
        surname: 'Character',
        gender: 'Male',
        body_type: 'Athletic'
      )
      service = described_class.new(male_character)
      display = service.build_display

      expect(display[:intro]).to include('He is')
    end
  end

  describe 'DraftInstanceStub' do
    it 'provides CharacterInstance interface' do
      stub = described_class::DraftInstanceStub.new(character)

      expect(stub.character).to eq(character)
      expect(stub.status).to be_nil
      expect(stub.roomtitle).to be_nil
      expect(stub.wetness).to eq(0)
      expect(stub.health).to eq(6)
      expect(stub.max_health).to eq(6)
      expect(stub.at_place?).to be false
      expect(stub.current_place).to be_nil
      expect(stub.held_items).to eq([])
    end

    it 'returns empty dataset for descriptions_for_display' do
      stub = described_class::DraftInstanceStub.new(character)
      dataset = stub.descriptions_for_display

      expect(dataset.eager(:something).all).to eq([])
    end
  end
end
