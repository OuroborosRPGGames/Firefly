# frozen_string_literal: true

# Service for rendering draft character appearance preview
# Uses CharacterDisplayService directly with a stub instance to ensure
# preview matches exactly what the in-game look command shows
#
# Used during character creation to show live preview as user fills in fields
class DraftCharacterPreviewService
  attr_reader :character

  def initialize(character)
    @character = character
  end

  # Build preview data using CharacterDisplayService for parity with in-game look
  # @return [Hash] structured character display data (same format as look command)
  def build_display
    return empty_display unless has_displayable_content?

    # Create stub instance and call CharacterDisplayService
    stub = DraftInstanceStub.new(@character)
    CharacterDisplayService.new(stub).build_display
  end

  # Render as HTML for direct display in the preview panel
  # Matches new webclient format:
  # - Name line (name, short_desc)
  # - Intro (single sentence with build, ethnicity, height)
  # - Eyes/hair line
  # - Descriptions with separators
  # @return [String] HTML preview
  def render_html
    display = build_display
    return empty_preview_html unless display[:has_content] != false

    parts = []

    # Profile picture - float left to match in-game display
    if display[:profile_pic_url] && !display[:profile_pic_url].to_s.strip.empty?
      parts << %(<div class="portrait-container"><img src="#{h(display[:profile_pic_url])}" alt="Character preview" class="preview-profile-pic rounded-lg"></div>)
    end

    # Name line: "Bob, a tall man" (combined name + short_desc)
    name_line = display[:name_line]
    if name_line && !name_line.to_s.strip.empty?
      parts << %(<h5 class="preview-name-line mb-2">#{h(name_line)}</h5>)
    elsif display[:name] && !display[:name].to_s.strip.empty?
      # Fallback to separate name + short_desc
      name = display[:name]
      short_desc = display[:short_desc]
      combined = short_desc && !short_desc.to_s.strip.empty? ? "#{name}, #{short_desc}" : name
      parts << %(<h5 class="preview-name-line mb-2">#{h(combined)}</h5>)
    end

    # Intro paragraph (single sentence: "He is a muscular Asian man standing at 5'10\".")
    if display[:intro] && !display[:intro].to_s.strip.empty?
      parts << %(<p class="preview-intro mb-2">#{h(display[:intro])}</p>)
    end

    # Eyes/hair line: "He has brown eyes and blonde hair."
    if display[:eyes_hair_line] && !display[:eyes_hair_line].to_s.strip.empty?
      parts << %(<p class="preview-eyes-hair mb-2">#{h(display[:eyes_hair_line])}</p>)
    end

    # Descriptions with prefix/suffix - won't have any during creation, but included for completeness
    if display[:descriptions]&.any?
      desc_parts = []
      previous_suffix = nil
      display[:descriptions].each_with_index do |desc, index|
        next unless desc[:content]

        content = safe_html(desc[:content])

        # Get prefix text
        prefix = desc[:prefix] || 'none'
        prefix_text = case prefix
                      when 'pronoun_has'
                        pronoun = @character.pronoun_subject.capitalize
                        verb = %w[male female].include?(@character.gender&.downcase) ? 'has' : 'have'
                        "#{pronoun} #{verb} "
                      when 'pronoun_is'
                        pronoun = @character.pronoun_subject.capitalize
                        verb = %w[male female].include?(@character.gender&.downcase) ? 'is' : 'are'
                        "#{pronoun} #{verb} "
                      when 'and' then 'and '
                      else ''
                      end

        # Apply capitalization based on prefix and PREVIOUS suffix
        # Content after prefix should be lowercase
        # First description or after sentence-ending suffix: capitalize
        # After comma/space: lowercase first letter
        if prefix_text.length > 0
          content = lowercase_first_letter(content) if content && content.length > 0
        elsif index > 0 && previous_suffix && %w[comma space].include?(previous_suffix)
          content = lowercase_first_letter(content) if content && content.length > 0
        else
          content = capitalize_first_letter(content) if content && content.length > 0
        end

        # Add suffix after each description (including last)
        suffix = desc[:suffix] || 'period'
        suffix_text = case suffix
                      when 'newline' then '.<br>'
                      when 'double_newline' then '.<br><br>'
                      when 'comma' then ', '
                      when 'space' then ' '
                      else '. '
                      end
        desc_parts << "#{prefix_text}#{content}#{suffix_text}"
        previous_suffix = suffix
      end
      parts << %(<p class="preview-descriptions">#{desc_parts.join('')}</p>) if desc_parts.any?
    end

    # Thumbnails row - show images for body descriptions
    if display[:thumbnails]&.any?
      thumbnail_html = display[:thumbnails].map do |thumb|
        url = thumb[:url] || thumb[:full_url]
        next unless url
        %(<img src="#{h(url)}" alt="#{h(thumb[:desc_type] || thumb[:item_name] || 'thumbnail')}" class="preview-image preview-thumbnail-clickable rounded" data-full-url="#{h(url)}" title="Click to view full size">)
      end.compact.join('')
      parts << %(<div class="preview-thumbnails mt-2 clearfix">#{thumbnail_html}</div>) if thumbnail_html && !thumbnail_html.empty?
    end

    return empty_preview_html if parts.empty?

    parts.join("\n")
  end

  private

  def has_displayable_content?
    !!(@character.short_desc && !@character.short_desc.to_s.strip.empty? ||
      @character.picture_url && !@character.picture_url.to_s.strip.empty? ||
      @character.forename && !@character.forename.to_s.strip.empty? ||
      @character.gender ||
      @character.body_type ||
      @character.ethnicity ||
      @character.height_cm ||
      @character.height_ft)
  end

  def empty_display
    { has_content: false }
  end

  def empty_preview_html
    <<~HTML
      <p class="text-muted text-center py-3">
        <i class="bi bi-person-bounding-box display-6 d-block mb-2"></i>
        Fill in the appearance fields to see your character preview.
      </p>
    HTML
  end

  def h(text)
    return '' unless text

    text.to_s
        .gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
  end

  def capitalize_first_letter(text)
    return text if text.nil? || text.empty?

    text[0].upcase + text[1..]
  end

  def lowercase_first_letter(text)
    return text if text.nil? || text.empty?

    text[0].downcase + text[1..]
  end

  # Safe HTML sanitization that allows formatting tags but escapes dangerous content
  # Allows: span (with style for color), font (with color), b, i, u, s, strong, em
  # Removes: script, event handlers, other dangerous content
  def safe_html(text)
    return '' unless text

    content = text.to_s

    # Remove script tags and event handlers
    content = content.gsub(/<script\b[^>]*>.*?<\/script>/mi, '')
    content = content.gsub(/\s+on\w+\s*=\s*["'][^"']*["']/i, '')

    # Only allow specific safe tags
    # First, escape everything
    escaped = h(content)

    # Then restore safe tags: span with style, font with color, b, i, u, s, strong, em
    # Restore opening span with style attribute (only color/font-weight/font-style allowed)
    escaped = escaped.gsub(
      /&lt;span\s+style=&quot;((?:color|font-weight|font-style|text-decoration):[^&"]+(?:;\s*(?:color|font-weight|font-style|text-decoration):[^&"]+)*)&quot;&gt;/i,
      '<span style="\1">'
    )
    # Restore closing span
    escaped = escaped.gsub('&lt;/span&gt;', '</span>')

    # Restore font tag with color attribute (legacy HTML)
    escaped = escaped.gsub(
      /&lt;font\s+color=&quot;(#[0-9a-fA-F]{3,6}|[a-zA-Z]+)&quot;&gt;/i,
      '<font color="\1">'
    )
    escaped = escaped.gsub('&lt;/font&gt;', '</font>')

    # Restore simple formatting tags
    %w[b i u s strong em].each do |tag|
      escaped = escaped.gsub("&lt;#{tag}&gt;", "<#{tag}>")
      escaped = escaped.gsub("&lt;/#{tag}&gt;", "</#{tag}>")
    end

    escaped
  end

  # Stub class that provides the CharacterInstance interface for draft characters
  # Returns sensible defaults for fields that don't apply during character creation
  class DraftInstanceStub
    attr_reader :character

    def initialize(character)
      @character = character
    end

    # CharacterInstance interface - basic state
    def status; nil; end
    def roomtitle; nil; end
    def wetness; 0; end
    def health; 6; end
    def max_health; 6; end

    # Delegate age-related methods to the character for preview
    def age; character.age; end
    def apparent_age_bracket; character.apparent_age_bracket; end

    # CharacterInstance interface - location
    def at_place?; false; end
    def current_place; nil; end

    # CharacterInstance interface - load actual descriptions for the draft character
    # Uses CharacterDefaultDescription which stores pre-activation descriptions with character_id
    def descriptions_for_display
      # Profile descriptions aren't created during draft - return empty dataset
      # This needs to respond to .eager(:description_type).all
      EmptyDataset.new
    end

    def body_descriptions_for_display
      # Load body descriptions from the draft character
      # Descriptions can have body positions via:
      # 1. Legacy body_position_id column, OR
      # 2. Join table (character_description_positions)
      #
      # We load all active descriptions and filter to those with any body position
      # CharacterDefaultDescription is compatible with CharacterDisplayService interface
      BodyDescriptionDataset.new(@character.id)
    end

    # Custom dataset wrapper that filters to descriptions with body positions
    # and supports eager loading
    class BodyDescriptionDataset
      def initialize(character_id)
        @character_id = character_id
      end

      def eager(*associations)
        @eager_associations = associations
        self
      end

      def all
        # Load all active descriptions for this character
        base = CharacterDefaultDescription
          .where(character_id: @character_id)
          .where(active: true)
          .order(:display_order, :id)

        # Eager load body_position and body_positions
        base = base.eager(:body_position, :body_positions)

        # Filter to those with any body position (legacy or join table)
        base.all.select { |desc| desc.all_positions.any? }
      end
    end

    def held_items; []; end
    def worn_items; EmptyDataset.new; end
    def objects_dataset; EmptyDataset.new; end

    # Stub for empty Sequel dataset - supports chaining like Sequel datasets
    class EmptyDataset
      def eager(*); self; end
      def where(*); self; end
      def order(*); self; end
      def all; []; end
    end
  end
end
