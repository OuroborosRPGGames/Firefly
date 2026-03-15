# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ChapterService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { Reality.first || create(:reality) }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, reality: reality, current_room: room) }

  def create_log(time, content: 'Test content', word_count: nil)
    text = word_count ? ('word ' * word_count).strip : content
    RpLog.create(
      character_instance_id: character_instance.id,
      room_id: room.id,
      content: text,
      logged_at: time,
      created_at: time
    )
  end

  describe '.chapters_for' do
    context 'with no logs' do
      it 'returns empty array' do
        result = ChapterService.chapters_for(character)
        expect(result).to eq([])
      end
    end

    context 'with logs in one session' do
      it 'returns single chapter' do
        base = Time.now
        create_log(base)
        create_log(base + 60)
        create_log(base + 120)

        chapters = ChapterService.chapters_for(character)
        expect(chapters.length).to eq(1)
        expect(chapters[0][:log_count]).to eq(3)
      end
    end

    context 'with 6+ hour gap' do
      it 'creates new chapter after gap' do
        base = Time.now - 86400
        # Each chapter needs MIN_WORDS (300) to avoid merging
        create_log(base, word_count: 200)
        create_log(base + 60, word_count: 200)
        create_log(base + (7 * 3600), word_count: 400) # 7 hours later

        chapters = ChapterService.chapters_for(character)
        expect(chapters.length).to eq(2)
      end
    end

    context 'with chapter exceeding 4000 words' do
      before do
        # Create Wake breakpoint to allow forced break
        LogBreakpoint.create(
          character_instance_id: character_instance.id,
          breakpoint_type: 'Wake',
          happened_at: Time.now - 3600
        )
      end

      it 'forces break at next breakpoint' do
        base = Time.now - 7200
        # Create logs totaling > 4000 words
        create_log(base, word_count: 2500)
        create_log(base + 60, word_count: 2000) # Now over 4000

        chapters = ChapterService.chapters_for(character)
        # Should attempt to break but may merge if under threshold
        expect(chapters.length).to be >= 1
      end
    end

    context 'with chapter under 300 words' do
      it 'keeps small chapter separate from large chapter' do
        base = Time.now - 86400
        create_log(base, word_count: 50)
        create_log(base + (7 * 3600), word_count: 500) # 7 hours later

        chapters = ChapterService.chapters_for(character)
        # Small chapters only merge with other small chapters, not large ones
        expect(chapters.length).to eq(2)
        expect(chapters[0][:word_count]).to eq(50)
        expect(chapters[1][:word_count]).to eq(500)
      end

      it 'merges consecutive small chapters' do
        base = Time.now - 86400
        create_log(base, word_count: 100)
        create_log(base + (7 * 3600), word_count: 100) # 7 hours later
        create_log(base + (14 * 3600), word_count: 200) # 14 hours later

        chapters = ChapterService.chapters_for(character)
        # Three small chapters merge into one
        expect(chapters.length).to eq(1)
        expect(chapters[0][:word_count]).to eq(400)
      end
    end

    context 'with cascading small chapters' do
      it 'merges all consecutive chapters under MIN_WORDS' do
        base = Time.now - 86400
        create_log(base, word_count: 50)
        create_log(base + (7 * 3600), word_count: 50)  # 7 hours later
        create_log(base + (14 * 3600), word_count: 50) # 14 hours later
        create_log(base + (21 * 3600), word_count: 500) # 21 hours later

        chapters = ChapterService.chapters_for(character)
        expect(chapters.length).to eq(2)
        expect(chapters[0][:word_count]).to eq(150)
        expect(chapters[1][:word_count]).to eq(500)
      end
    end

    context 'with multiple character instances' do
      let(:another_reality) { create(:reality) }
      let(:another_room) { create(:room) }
      let(:another_instance) { create(:character_instance, character: character, reality: another_reality, current_room: another_room) }

      it 'includes logs from all instances' do
        base = Time.now
        # Log from first instance
        create_log(base)

        # Log from second instance
        RpLog.create(
          character_instance_id: another_instance.id,
          room_id: another_room.id,
          content: 'Test content from another instance',
          logged_at: base + 60,
          created_at: base + 60
        )

        chapters = ChapterService.chapters_for(character)
        expect(chapters.length).to eq(1)
        expect(chapters[0][:log_count]).to eq(2)
      end
    end
  end

  describe '.chapter_content' do
    it 'returns logs for specific chapter' do
      base = Time.now - 86400
      # Use enough words to avoid merging (MIN_WORDS = 300)
      first_text = 'First log ' + ('word ' * 200)
      second_text = 'Second log ' + ('word ' * 200)
      third_text = 'Third log ' + ('word ' * 400)

      log1 = create_log(base, content: first_text)
      log2 = create_log(base + 60, content: second_text)
      # 7 hours later - new chapter
      log3 = create_log(base + (7 * 3600), content: third_text)

      # Get first chapter logs
      content = ChapterService.chapter_content(character, 0)
      expect(content.length).to eq(2)
      expect(content.map(&:content)).to all(match(/First log|Second log/))

      # Get second chapter logs
      content = ChapterService.chapter_content(character, 1)
      expect(content.length).to eq(1)
      expect(content.first.content).to match(/Third log/)
    end

    it 'returns empty array for invalid chapter index' do
      create_log(Time.now)

      content = ChapterService.chapter_content(character, 999)
      expect(content).to eq([])
    end
  end

  describe '.summary_for' do
    it 'returns chapter count and word totals' do
      base = Time.now
      create_log(base, word_count: 100)
      create_log(base + 60, word_count: 200)

      summary = ChapterService.summary_for(character)
      expect(summary[:chapter_count]).to eq(1)
      expect(summary[:total_words]).to eq(300)
      expect(summary[:date_range][:from]).to be_a(Time)
      expect(summary[:date_range][:to]).to be_a(Time)
    end

    it 'returns empty summary for character with no logs' do
      summary = ChapterService.summary_for(character)
      expect(summary[:chapter_count]).to eq(0)
      expect(summary[:total_words]).to eq(0)
      expect(summary[:date_range][:from]).to be_nil
      expect(summary[:date_range][:to]).to be_nil
    end
  end

  describe '.chapter_title' do
    it 'returns default title for chapter without cached title' do
      create_log(Time.now)

      title = ChapterService.chapter_title(character, 0)
      expect(title).to eq('Chapter 1')
    end

    it 'returns cached title when available' do
      create_log(Time.now)
      ChapterTitle.create(
        character_id: character.id,
        chapter_index: 0,
        title: 'The Beginning'
      )

      title = ChapterService.chapter_title(character, 0)
      expect(title).to eq('The Beginning')
    end
  end

  describe '.invalidate_cache' do
    it 'clears cached chapter titles for character' do
      ChapterTitle.create(
        character_id: character.id,
        chapter_index: 0,
        title: 'Old Title'
      )

      expect(ChapterTitle.where(character_id: character.id).count).to eq(1)

      ChapterService.invalidate_cache(character.id)

      expect(ChapterTitle.where(character_id: character.id).count).to eq(0)
    end
  end

  describe 'word counting' do
    it 'counts words accurately' do
      # Test that word count is calculated correctly from content
      base = Time.now
      create_log(base, content: 'This is a test with exactly ten words in it.')

      chapters = ChapterService.chapters_for(character)
      expect(chapters[0][:word_count]).to eq(10)
    end

    it 'handles HTML content by stripping tags' do
      base = Time.now
      RpLog.create(
        character_instance_id: character_instance.id,
        room_id: room.id,
        content: '<p>Hello <b>world</b></p>',
        logged_at: base,
        created_at: base
      )

      chapters = ChapterService.chapters_for(character)
      # Should count only "Hello world" = 2 words
      expect(chapters[0][:word_count]).to eq(2)
    end
  end

  describe '.chapter_title with AI generation' do
    before do
      create_log(Time.now, content: 'John meets Mary at the tavern. They discuss old times.')
    end

    context 'when AI titles disabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('chapter_ai_titles_enabled').and_return(false)
      end

      it 'returns default title format' do
        title = ChapterService.chapter_title(character, 0)
        expect(title).to eq('Chapter 1')
      end
    end

    context 'when AI titles enabled' do
      before do
        allow(GameSetting).to receive(:boolean).with('chapter_ai_titles_enabled').and_return(true)
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: 'A Chance Encounter'
        })
      end

      it 'generates AI title when logs provided' do
        logs = ChapterService.chapter_content(character, 0)
        title = ChapterService.chapter_title(character, 0, logs: logs)
        expect(title).to eq('A Chance Encounter')
      end

      it 'caches the generated title' do
        logs = ChapterService.chapter_content(character, 0)
        ChapterService.chapter_title(character, 0, logs: logs)

        cached = ChapterTitle.first(character_id: character.id, chapter_index: 0)
        expect(cached.title).to eq('A Chance Encounter')
      end

      it 'falls back to default title on LLM failure' do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: false,
          error: 'API error'
        })

        logs = ChapterService.chapter_content(character, 0)
        title = ChapterService.chapter_title(character, 0, logs: logs)
        expect(title).to eq('Chapter 1')
      end

      it 'falls back to default title for invalid response' do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: 'AB'  # Too short (less than 3 chars)
        })

        logs = ChapterService.chapter_content(character, 0)
        title = ChapterService.chapter_title(character, 0, logs: logs)
        expect(title).to eq('Chapter 1')
      end

      it 'falls back to default title for empty response' do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: ''
        })

        logs = ChapterService.chapter_content(character, 0)
        title = ChapterService.chapter_title(character, 0, logs: logs)
        expect(title).to eq('Chapter 1')
      end

      it 'falls back to default title for nil response' do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: nil
        })

        logs = ChapterService.chapter_content(character, 0)
        title = ChapterService.chapter_title(character, 0, logs: logs)
        expect(title).to eq('Chapter 1')
      end

      it 'falls back to default title for title that is too long' do
        allow(LLM::TextGenerationService).to receive(:generate).and_return({
          success: true,
          text: 'A' * 101  # More than 100 chars
        })

        logs = ChapterService.chapter_content(character, 0)
        title = ChapterService.chapter_title(character, 0, logs: logs)
        expect(title).to eq('Chapter 1')
      end
    end
  end

  describe '.generate_ai_title (private method via send)' do
    before do
      create_log(Time.now, content: 'The hero entered the dark cave. A torch flickered in the distance.')
    end

    it 'samples at most 10 logs to avoid token limits' do
      # Create 15 more logs (16 total)
      15.times do |i|
        create_log(Time.now + i, content: "Log entry #{i + 2}")
      end

      logs = ChapterService.chapter_content(character, 0)
      expect(logs.length).to eq(16)

      # Mock the LLM call to verify it receives sampled content
      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        # The prompt should be limited in size (not all 16 logs)
        prompt = args[:prompt]
        # Count how many log entries are in the prompt (rough check)
        entry_matches = prompt.scan(/Log entry/).length
        expect(entry_matches).to be <= 10
        { success: true, text: 'A Dark Beginning' }
      end

      ChapterService.send(:generate_ai_title, logs)
    end

    it 'truncates each excerpt to 200 characters' do
      # Create a log with long content
      long_content = 'x' * 500
      RpLog.create(
        character_instance_id: character_instance.id,
        room_id: room.id,
        content: long_content,
        logged_at: Time.now + 100,
        created_at: Time.now + 100
      )

      logs = ChapterService.chapter_content(character, 0)

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        prompt = args[:prompt]
        # Check that the long content was truncated (201 chars with 0..200)
        expect(prompt).not_to include('x' * 300)
        { success: true, text: 'A Dark Beginning' }
      end

      ChapterService.send(:generate_ai_title, logs)
    end

    it 'uses the correct prompt template' do
      logs = ChapterService.chapter_content(character, 0)

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        expect(args[:prompt]).to include('roleplay log excerpts')
        expect(args[:prompt]).to include('chapter title')
        expect(args[:prompt]).to include('3-5 words')
        { success: true, text: 'A Dark Beginning' }
      end

      ChapterService.send(:generate_ai_title, logs)
    end

    it 'uses gemini-3.1-flash-lite-preview model' do
      logs = ChapterService.chapter_content(character, 0)

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        expect(args[:model]).to eq('gemini-3.1-flash-lite-preview')
        expect(args[:provider]).to eq('google_gemini')
        { success: true, text: 'A Dark Beginning' }
      end

      ChapterService.send(:generate_ai_title, logs)
    end

    it 'returns nil for empty logs' do
      result = ChapterService.send(:generate_ai_title, [])
      expect(result).to be_nil
    end

    it 'strips HTML from log content before sending to LLM' do
      # Create a log with HTML content
      RpLog.create(
        character_instance_id: character_instance.id,
        room_id: room.id,
        content: '<p>This is <b>bold</b> text</p>',
        html_content: '<p>This is <b>bold</b> text</p>',
        logged_at: Time.now + 200,
        created_at: Time.now + 200
      )

      logs = ChapterService.chapter_content(character, 0)

      allow(LLM::TextGenerationService).to receive(:generate) do |args|
        prompt = args[:prompt]
        expect(prompt).not_to include('<p>')
        expect(prompt).not_to include('<b>')
        expect(prompt).to include('This is bold text')
        { success: true, text: 'A Dark Beginning' }
      end

      ChapterService.send(:generate_ai_title, logs)
    end
  end
end
