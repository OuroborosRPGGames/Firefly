# frozen_string_literal: true

# ChapterService computes and manages chapter boundaries for character stories.
#
# Chapters are determined by analyzing RP log timestamps and using breakpoints
# (Wake/Sleep events) to create natural narrative divisions.
#
# Chapter boundary rules:
# 1. A time gap of 6+ hours between logs starts a new chapter
# 2. Chapters exceeding GameConfig::Content::CHAPTER_MAX_WORDS are split at the next breakpoint
# 3. Chapters under GameConfig::Content::CHAPTER_MIN_WORDS are merged with adjacent chapters
#
# Usage:
#   ChapterService.chapters_for(character) -> Array of chapter metadata
#   ChapterService.chapter_content(character, index) -> Array of RpLog records
#   ChapterService.summary_for(character) -> Hash with total stats
#   ChapterService.chapter_title(character, index) -> String title
#   ChapterService.invalidate_cache(character_id) -> clears cached titles
#
module ChapterService
  # Seconds in an hour (for gap calculation)
  SECONDS_PER_HOUR = 3600

  class << self
    # Get all chapters for a character with metadata
    #
    # @param character [Character] The character
    # @return [Array<Hash>] Array of chapter metadata hashes:
    #   - :index [Integer] Chapter index (0-based)
    #   - :log_count [Integer] Number of logs in chapter
    #   - :word_count [Integer] Total words in chapter
    #   - :start_time [Time] First log timestamp
    #   - :end_time [Time] Last log timestamp
    #   - :location [String, nil] Most common room name
    def chapters_for(character)
      logs = fetch_all_logs(character)
      return [] if logs.empty?

      breakpoints = fetch_breakpoints(character)
      raw_chapters = compute_chapters(logs, breakpoints)

      # Merge small chapters
      merged_chapters = merge_small_chapters(raw_chapters)

      # Build metadata for each chapter
      merged_chapters.each_with_index.map do |chapter_logs, index|
        build_chapter_metadata(chapter_logs, index)
      end
    end

    # Get the logs for a specific chapter
    #
    # @param character [Character] The character
    # @param index [Integer] Chapter index (0-based)
    # @return [Array<RpLog>] Logs in the chapter
    def chapter_content(character, index)
      logs = fetch_all_logs(character)
      return [] if logs.empty?

      breakpoints = fetch_breakpoints(character)
      raw_chapters = compute_chapters(logs, breakpoints)
      merged_chapters = merge_small_chapters(raw_chapters)

      merged_chapters[index] || []
    end

    # Get summary statistics for character's story
    #
    # @param character [Character] The character
    # @return [Hash] Summary with:
    #   - :chapter_count [Integer]
    #   - :total_words [Integer]
    #   - :total_logs [Integer]
    #   - :date_range [Hash] with :from and :to
    def summary_for(character)
      chapters = chapters_for(character)

      if chapters.empty?
        return {
          chapter_count: 0,
          total_words: 0,
          total_logs: 0,
          date_range: { from: nil, to: nil }
        }
      end

      total_words = chapters.sum { |c| c[:word_count] }
      total_logs = chapters.sum { |c| c[:log_count] }

      {
        chapter_count: chapters.length,
        total_words: total_words,
        total_logs: total_logs,
        date_range: {
          from: chapters.first[:start_time],
          to: chapters.last[:end_time]
        }
      }
    end

    # Get or generate a title for a chapter
    #
    # @param character [Character] The character
    # @param chapter_index [Integer] Chapter index (0-based)
    # @param logs [Array<RpLog>, nil] Optional logs to use for generation
    # @return [String] Chapter title
    def chapter_title(character, chapter_index, logs: nil)
      # Check for cached title
      cached = ChapterTitle.first(character_id: character.id, chapter_index: chapter_index)
      return cached.title if cached

      # Check if AI title generation is enabled
      if ai_titles_enabled? && logs
        ai_title = generate_ai_title(logs)
        if ai_title
          # Cache the generated title
          ChapterTitle.find_or_create_for(character.id, chapter_index, default_title: ai_title)
          return ai_title
        end
      end

      # Default title
      "Chapter #{chapter_index + 1}"
    end

    # Clear all cached chapter data for a character
    #
    # @param character_id [Integer] The character ID
    def invalidate_cache(character_id)
      ChapterTitle.clear_for(character_id)
    end

    private

    # Fetch all RP logs for a character's instances, ordered by time
    #
    # @param character [Character]
    # @return [Array<RpLog>]
    def fetch_all_logs(character)
      instance_ids = CharacterInstance.where(character_id: character.id).select_map(:id)
      return [] if instance_ids.empty?

      RpLog.where(character_instance_id: instance_ids)
           .order(:logged_at)
           .all
    end

    # Fetch Wake/Sleep breakpoints for chapter boundary detection
    #
    # @param character [Character]
    # @return [Array<LogBreakpoint>]
    def fetch_breakpoints(character)
      instance_ids = CharacterInstance.where(character_id: character.id).select_map(:id)
      return [] if instance_ids.empty?

      LogBreakpoint.where(character_instance_id: instance_ids)
                   .where(breakpoint_type: %w[Wake Sleep])
                   .order(:happened_at)
                   .all
    end

    # Compute initial chapter boundaries based on time gaps and word limits
    #
    # @param logs [Array<RpLog>]
    # @param breakpoints [Array<LogBreakpoint>]
    # @return [Array<Array<RpLog>>] Array of log arrays, one per chapter
    def compute_chapters(logs, breakpoints)
      return [] if logs.empty?

      chapters = []
      current_chapter = []
      current_word_count = 0
      last_log_time = nil

      # Index breakpoints by time for quick lookup
      breakpoint_times = breakpoints.map(&:happened_at).sort

      logs.each do |log|
        log_time = log.logged_at || log.created_at
        log_words = count_words(log.content)

        # Check if we should start a new chapter
        should_break = false

        if last_log_time
          # Time gap check
          gap_hours = (log_time - last_log_time) / SECONDS_PER_HOUR
          should_break = true if gap_hours >= GameConfig::Content::CHAPTER_TIME_GAP_HOURS

          # Word limit check - break at next breakpoint if over GameConfig::Content::CHAPTER_MAX_WORDS
          if current_word_count >= GameConfig::Content::CHAPTER_MAX_WORDS
            # Find a breakpoint between last_log_time and now
            breakpoint_in_range = breakpoint_times.any? do |bp_time|
              bp_time > last_log_time && bp_time <= log_time
            end
            should_break = true if breakpoint_in_range
          end
        end

        if should_break && !current_chapter.empty?
          chapters << current_chapter
          current_chapter = []
          current_word_count = 0
        end

        current_chapter << log
        current_word_count += log_words
        last_log_time = log_time
      end

      # Don't forget the last chapter
      chapters << current_chapter unless current_chapter.empty?

      chapters
    end

    # Merge chapters that are under GameConfig::Content::CHAPTER_MIN_WORDS with adjacent chapters
    #
    # Handles cascading merges: if multiple consecutive chapters are all under
    # GameConfig::Content::CHAPTER_MIN_WORDS, they all merge together until the combined total reaches GameConfig::Content::CHAPTER_MIN_WORDS.
    # If a large chapter (>= GameConfig::Content::CHAPTER_MIN_WORDS) is encountered, any pending small chapters
    # are finalized first, and the large chapter stands alone.
    #
    # @param chapters [Array<Array<RpLog>>]
    # @return [Array<Array<RpLog>>]
    def merge_small_chapters(chapters)
      return chapters if chapters.length <= 1

      result = []
      pending_merge = nil

      chapters.each do |chapter|
        chapter_word_count = chapter.sum { |log| count_words(log.content) }

        if pending_merge
          # Check if current chapter is large enough on its own
          if chapter_word_count >= GameConfig::Content::CHAPTER_MIN_WORDS
            # Finalize pending (even if small) and let large chapter stand alone
            result << pending_merge
            result << chapter
            pending_merge = nil
          else
            # Merge small chapter with pending
            pending_merge = pending_merge + chapter
            # Check if combined total reaches GameConfig::Content::CHAPTER_MIN_WORDS
            combined_word_count = pending_merge.sum { |log| count_words(log.content) }
            if combined_word_count >= GameConfig::Content::CHAPTER_MIN_WORDS
              result << pending_merge
              pending_merge = nil
            end
          end
        elsif chapter_word_count < GameConfig::Content::CHAPTER_MIN_WORDS
          # Start accumulating small chapters
          pending_merge = chapter
        else
          # Large chapter stands alone
          result << chapter
        end
      end

      # Don't forget the last group (may still be under GameConfig::Content::CHAPTER_MIN_WORDS but no more chapters to merge)
      result << pending_merge if pending_merge

      result
    end

    # Build metadata hash for a chapter
    #
    # @param logs [Array<RpLog>]
    # @param index [Integer]
    # @return [Hash]
    def build_chapter_metadata(logs, index)
      return {} if logs.empty?

      word_count = logs.sum { |log| count_words(log.content) }

      # Find most common room (location)
      room_counts = logs.group_by(&:room_id)
                        .transform_values(&:count)
      most_common_room_id = room_counts.max_by { |_, count| count }&.first
      location = most_common_room_id ? Room[most_common_room_id]&.name : nil

      start_time = logs.first.logged_at || logs.first.created_at
      end_time = logs.last.logged_at || logs.last.created_at

      {
        index: index,
        log_count: logs.length,
        word_count: word_count,
        start_time: start_time,
        end_time: end_time,
        location: location
      }
    end

    # Count words in text, stripping HTML
    #
    # @param text [String, nil]
    # @return [Integer]
    def count_words(text)
      return 0 if text.nil? || text.empty?

      # Strip HTML tags
      stripped = text.gsub(/<[^>]+>/, ' ')

      # Normalize whitespace and split (reject empty handles leading/trailing whitespace)
      stripped.split(/\s+/).reject(&:empty?).length
    end

    # Check if AI title generation is enabled
    #
    # @return [Boolean]
    def ai_titles_enabled?
      return false unless defined?(GameSetting)

      GameSetting.boolean('chapter_ai_titles_enabled')
    rescue StandardError => e
      warn "[ChapterService] Error checking AI titles setting: #{e.message}"
      false
    end

    # Generate an AI-powered chapter title using LLM
    #
    # Samples up to 10 logs to avoid token limits, strips HTML,
    # truncates each excerpt to 200 characters, and uses the
    # character_story.chapter_title prompt template.
    #
    # @param logs [Array<RpLog>]
    # @return [String, nil] Generated title or nil on failure
    def generate_ai_title(logs)
      return nil unless logs.any?

      # Sample up to 10 logs for context (avoid token limits)
      sample_logs = logs.length > 10 ? logs.sample(10) : logs

      # Strip HTML and truncate each log excerpt
      excerpts = sample_logs.map do |log|
        text = if log.html_content.nil? || log.html_content.empty?
          log.content
        else
          log.html_content
        end
        CharacterStoryExporter.strip_html(text.to_s)[0..200]
      end.join("\n\n")

      prompt = GamePrompts.get('character_story.chapter_title', excerpts: excerpts)
      return nil unless prompt

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'gemini-3.1-flash-lite-preview',
        provider: 'google_gemini',
        options: { max_tokens: 50, temperature: 0.7 }
      )

      return nil unless result[:success]

      title = result[:text]&.strip
      # Validate title - must be 3-100 chars and not empty
      return nil if title.nil? || title.empty? || title.length > 100 || title.length < 3

      title
    rescue StandardError => e
      warn "[ChapterService] Failed to generate AI title: #{e.message}"
      nil
    end
  end
end
