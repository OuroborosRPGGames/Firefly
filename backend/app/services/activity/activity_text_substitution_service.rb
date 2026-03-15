# frozen_string_literal: true

# Replaces template tokens in activity text with character-specific values.
# Tokens: (name), (he)/(she)/(they), (him)/(her)/(them), (his)/(her)/(their),
#          (himself)/(herself)/(themselves)
#
# All pronoun tokens resolve to the acting character's actual pronouns
# regardless of which form the author used. So (he) and (she) both resolve
# to the character's pronoun_subject.
#
# Case is preserved: (Name) -> "Kael Stormbringer", (He) -> "He"
#
# Note on (her): This token is ambiguous (object vs possessive). We resolve
# it as possessive since that's far more common in narrative text
# ("opens her bag" vs "push her aside"). Use (him)/(them) for object form.
module ActivityTextSubstitutionService
  # Pronoun token categories — any of these tokens map to the same method
  SUBJECT_TOKENS = %w[he she they].freeze
  OBJECT_TOKENS = %w[him them].freeze
  POSSESSIVE_TOKENS = %w[his her their].freeze
  REFLEXIVE_TOKENS = %w[himself herself themselves themself].freeze

  # Regex to match any token: (name), (he), (His), (HERSELF), etc.
  TOKEN_REGEX = /\(([A-Za-z]+)\)/

  class << self
    # Quick check if text contains any template tokens
    def has_tokens?(text)
      return false if text.nil? || text.empty?

      text.match?(TOKEN_REGEX)
    end

    # Replace tokens in text with character-specific values.
    #
    # @param text [String, nil] Text containing tokens
    # @param character [Character] The acting character
    # @param viewer [CharacterInstance, nil] The viewer (for personalized names)
    # @return [String, nil]
    def substitute(text, character:, viewer: nil)
      return text if text.nil? || text.empty?

      if text.include?('<') && text.match?(/<[a-zA-Z]/)
        # HTML path: tokens may be split across text nodes by tags,
        # so TOKEN_REGEX won't match the raw string. Use a lighter
        # heuristic — if parens exist at all, let Nokogiri sort it out.
        return text unless text.include?('(') && text.include?(')')
        substitute_html(text, character: character, viewer: viewer)
      else
        return text unless text.match?(TOKEN_REGEX)
        substitute_plain(text, character: character, viewer: viewer)
      end
    end

    private

    # Plain text substitution — simple gsub
    def substitute_plain(text, character:, viewer: nil)
      text.gsub(TOKEN_REGEX) do |_match|
        token = ::Regexp.last_match(1)
        resolve_token(token, character: character, viewer: viewer)
      end
    end

    # HTML-aware substitution — walk text nodes with Nokogiri
    def substitute_html(text, character:, viewer: nil)
      doc = Nokogiri::HTML.fragment(text)

      # First pass: reassemble tokens split across text nodes by HTML tags
      # e.g. "(<b>name</b>)" has "(", "name", ")" in separate text nodes
      reassemble_split_tokens(doc, character: character, viewer: viewer)

      # Second pass: handle tokens within single text nodes
      doc.traverse do |node|
        next unless node.text?
        next unless node.content.match?(TOKEN_REGEX)

        parent = node.parent
        old_length = node.content.length
        new_content = node.content.gsub(TOKEN_REGEX) do |_match|
          token = ::Regexp.last_match(1)
          resolve_token(token, character: character, viewer: viewer)
        end

        # Adjust parent element width/gradient if text length changed
        if parent&.element? && new_content.length != old_length
          adjust_element_sizing(parent, old_length, new_content.length)
        end

        node.content = new_content
      end

      doc.to_html
    end

    # Resolve a single token to its replacement value
    def resolve_token(token, character:, viewer: nil)
      lower = token.downcase

      # Determine the raw replacement
      raw = case lower
            when 'name'
              if viewer
                character.display_name_for(viewer)
              else
                character.full_name
              end
            when *SUBJECT_TOKENS
              character.pronoun_subject
            when *OBJECT_TOKENS
              character.pronoun_object
            when *POSSESSIVE_TOKENS
              character.pronoun_possessive
            when *REFLEXIVE_TOKENS
              character.pronoun_reflexive
            else
              return "(#{token})" # Unknown token — leave as-is
            end

      # Apply case from original token
      apply_case(raw, token)
    end

    # Match the case pattern of the original token
    def apply_case(value, token)
      if token == token.upcase && token.length > 1
        value.upcase
      elsif token[0] == token[0].upcase
        value.sub(/\A./) { |c| c.upcase }
      else
        value
      end
    end

    # Handle tokens split across multiple text nodes by HTML tags.
    #
    # When HTML tags appear inside a token, Nokogiri splits the text into
    # separate nodes. Example: "(<b>name</b>)" produces three text nodes:
    #   ["(", "name", ")"]
    # Concatenated they form "(name)" which matches TOKEN_REGEX.
    #
    # Strategy: put the replacement in the first spanning node, clear the
    # matched fragments from the rest. This preserves surrounding HTML
    # structure while ensuring the token resolves.
    def reassemble_split_tokens(doc, character:, viewer: nil)
      text_nodes = []
      doc.traverse { |node| text_nodes << node if node.text? }
      return if text_nodes.size < 2

      # Build position map: each text node's start/end offset in the
      # concatenated string of all text content
      positions = []
      offset = 0
      text_nodes.each do |node|
        len = node.content.length
        positions << { node: node, start: offset, end: offset + len }
        offset += len
      end

      full_text = text_nodes.map(&:content).join

      # Find all token matches in the concatenated text
      matches = []
      full_text.scan(TOKEN_REGEX) do
        m = ::Regexp.last_match
        matches << { start: m.begin(0), finish: m.end(0), token: m[1] }
      end

      # Only process matches that span more than one text node
      multi = matches.select do |match|
        positions.count { |p| p[:end] > match[:start] && p[:start] < match[:finish] } > 1
      end
      return if multi.empty?

      # Process in reverse so earlier positions stay valid
      multi.reverse_each do |match|
        replacement = resolve_token(match[:token], character: character, viewer: viewer)

        spanning = positions.select { |p| p[:end] > match[:start] && p[:start] < match[:finish] }
        spanning.each_with_index do |pos, idx|
          content = pos[:node].content
          node_match_start = [match[:start] - pos[:start], 0].max
          node_match_end   = [match[:finish] - pos[:start], content.length].min

          if idx == 0
            # First node: splice in the full replacement text
            pos[:node].content = content[0...node_match_start] + replacement + content[node_match_end..]
          else
            # Remaining nodes: remove the matched fragment
            pos[:node].content = content[0...node_match_start] + content[node_match_end..]
          end
        end
      end
    end

    # Adjust inline styles when text length changes (for gradients)
    def adjust_element_sizing(element, old_length, new_length)
      return if old_length == 0 || new_length == 0

      style = element['style']
      return unless style

      ratio = new_length.to_f / old_length

      # Adjust background-size width (for gradients)
      if style.include?('background-size')
        element['style'] = style.gsub(/background-size:\s*([\d.]+)(px|em|ch)/) do
          old_val = ::Regexp.last_match(1).to_f
          unit = ::Regexp.last_match(2)
          new_val = (old_val * ratio).round(1)
          "background-size: #{new_val}#{unit}"
        end
      end
    end
  end
end
