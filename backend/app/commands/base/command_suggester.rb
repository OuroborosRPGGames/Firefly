# frozen_string_literal: true

module Commands
  module Base
    # Provides Levenshtein-based command suggestions for typo correction.
    #
    # Extracted from Registry to separate command registration from
    # user-facing suggestion logic.
    module CommandSuggester
      def suggest_commands(input, context: nil)
        command_word = input.strip.split.first&.downcase
        return [] if StringHelper.blank?(command_word)

        all_names = @commands.keys + @aliases.keys

        if context
          contexts = context.is_a?(Array) ? context : [context]
          contexts.each do |ctx|
            all_names += @contextual_aliases[ctx]&.keys || []
          end
        end

        all_names.uniq!

        scored_suggestions = all_names.map do |name|
          distance = levenshtein_distance(name, command_word)
          prefix_match = 0
          command_word.chars.each_with_index do |char, i|
            break if i >= name.length || name[i] != char
            prefix_match += 1
          end
          [name, distance - (prefix_match * 0.5)]
        end

        scored_suggestions
          .select { |_, score| score <= 3 }
          .sort_by { |_, score| score }
          .first(3)
          .map(&:first)
      end

      def levenshtein_distance(str1, str2)
        return str2.length if str1.empty?
        return str1.length if str2.empty?

        matrix = Array.new(str1.length + 1) { Array.new(str2.length + 1) }

        (0..str1.length).each { |i| matrix[i][0] = i }
        (0..str2.length).each { |j| matrix[0][j] = j }

        (1..str1.length).each do |i|
          (1..str2.length).each do |j|
            cost = str1[i - 1] == str2[j - 1] ? 0 : 1
            matrix[i][j] = [
              matrix[i - 1][j] + 1,
              matrix[i][j - 1] + 1,
              matrix[i - 1][j - 1] + cost
            ].min
          end
        end

        matrix[str1.length][str2.length]
      end
    end
  end
end
