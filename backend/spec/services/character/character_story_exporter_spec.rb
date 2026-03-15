# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterStoryExporter do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'John', surname: 'Smith') }
  let(:character_instance) { create(:character_instance, character: character) }
  let(:room) { create(:room, name: 'The Tavern') }

  def create_log(time, content:, html_content: nil)
    RpLog.create(
      character_instance_id: character_instance.id,
      room_id: room.id,
      content: content,
      html_content: html_content,
      logged_at: time,
      created_at: time
    )
  end

  describe '.to_text' do
    it 'generates formatted text output' do
      base = Time.new(2026, 1, 15, 14, 30, 0)
      create_log(base, content: 'John waves hello.')
      create_log(base + 60, content: '<b>Mary</b> smiles warmly.')

      text = CharacterStoryExporter.to_text(character)

      expect(text).to include('THE STORY OF JOHN SMITH')
      expect(text).to include('CHAPTER 1')
      expect(text).to include('Location: The Tavern')
      expect(text).to include('John waves hello.')
      expect(text).to include('Mary smiles warmly.') # HTML stripped
      expect(text).not_to include('<b>')
    end

    it 'returns empty message for character with no logs' do
      text = CharacterStoryExporter.to_text(character)
      expect(text).to include('No story content')
    end

    it 'uses html_content when available' do
      base = Time.new(2026, 1, 15, 14, 30, 0)
      create_log(
        base,
        content: 'John waves hello.',
        html_content: '<span class="emote">John waves hello.</span>'
      )

      text = CharacterStoryExporter.to_text(character)

      expect(text).to include('John waves hello.')
      expect(text).not_to include('<span')
    end

    it 'includes generation date' do
      base = Time.new(2026, 1, 15, 14, 30, 0)
      create_log(base, content: 'John waves hello.')

      text = CharacterStoryExporter.to_text(character)

      expect(text).to include('Generated:')
      expect(text).to include(Time.now.strftime('%B %d, %Y'))
    end

    it 'uses CRLF line endings' do
      base = Time.new(2026, 1, 15, 14, 30, 0)
      create_log(base, content: 'John waves hello.')

      text = CharacterStoryExporter.to_text(character)

      expect(text).to include("\r\n")
    end

    it 'falls back to content when html_content is empty string' do
      base = Time.new(2026, 1, 15, 14, 30, 0)
      log = create_log(base, content: 'This should appear')
      log.update(html_content: '') # Set to empty string

      text = CharacterStoryExporter.to_text(character)
      expect(text).to include('This should appear')
    end

    it 'returns error message when export fails' do
      # Force an error by making ChapterService.chapters_for raise
      allow(ChapterService).to receive(:chapters_for).and_raise(StandardError, 'Database error')

      text = CharacterStoryExporter.to_text(character)

      expect(text).to include('THE STORY OF JOHN SMITH')
      expect(text).to include('Error: Unable to generate story export.')
      expect(text).to include('Please try again later.')
    end
  end

  describe '.strip_html' do
    it 'removes HTML tags but preserves text' do
      html = '<b>Bold</b> and <i>italic</i>'
      result = CharacterStoryExporter.strip_html(html)
      expect(result).to eq('Bold and italic')
    end

    it 'converts <br> to newlines' do
      html = 'Line one<br>Line two<br/>Line three'
      result = CharacterStoryExporter.strip_html(html)
      expect(result).to include("Line one\nLine two\nLine three")
    end

    it 'handles nil input' do
      result = CharacterStoryExporter.strip_html(nil)
      expect(result).to eq('')
    end

    it 'removes span tags with attributes' do
      html = '<span class="combat red">Critical hit!</span>'
      result = CharacterStoryExporter.strip_html(html)
      expect(result).to eq('Critical hit!')
    end

    it 'handles nested tags' do
      html = '<div><b>Nested <i>tags</i></b></div>'
      result = CharacterStoryExporter.strip_html(html)
      expect(result).to eq('Nested tags')
    end

    it 'decodes HTML entities' do
      html = 'Price: &lt;5 &nbsp; Items &amp; more'
      result = CharacterStoryExporter.strip_html(html)
      expect(result).to include('<5')
      expect(result).to include('Items & more')
    end

    it 'decodes common HTML entities' do
      html = '&quot;Hello&quot; &apos;World&apos;'
      result = CharacterStoryExporter.strip_html(html)
      expect(result).to include('"Hello"')
    end
  end
end
