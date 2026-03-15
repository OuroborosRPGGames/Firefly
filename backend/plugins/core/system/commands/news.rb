# frozen_string_literal: true

module Commands
  module System
    class News < ::Commands::Base::Command
      command_name 'news'
      aliases 'bulletin', 'announcements'
      category :system
      help_text 'View staff announcements and news'
      usage 'news [category|id]'
      examples 'news', 'news announcement', 'news ic', 'news ooc', 'news 1', 'news read 5'

      protected

      def perform_command(parsed_input)
        input = parsed_input[:text]&.strip

        if input.nil? || input.empty?
          return show_categories
        end

        # Handle "news read <id>" syntax
        if input.downcase.start_with?('read ')
          article_id = input[5..].strip.to_i
          return read_article(article_id)
        end

        # Check if the input is a numeric ID
        if input.match?(/^\d+$/)
          return read_article(input.to_i)
        end

        # Otherwise, treat as category
        show_articles(input.downcase)
      end

      private

      def show_categories
        counts = ::StaffBulletin.unread_counts_for(character.user)

        lines = ['<h3>News</h3>']
        lines << ''

        ::StaffBulletin::NEWS_TYPES.each do |type|
          unread = counts[type] || 0
          label = case type
                  when 'announcement' then 'Announcements'
                  when 'ic' then 'IC News'
                  when 'ooc' then 'OOC News'
                  else type.upcase
                  end

          if unread.positive?
            lines << "#{label}: #{unread} unread"
          else
            lines << "#{label}: up to date"
          end
        end

        lines << ''
        lines << "Use 'news <category>' to view articles."
        lines << "Categories: announcement, ic, ooc"

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'news_categories', counts: counts }
        )
      end

      def show_articles(category)
        # Normalize category names
        normalized = case category
                     when 'announcements', 'announce' then 'announcement'
                     when 'icnews' then 'ic'
                     when 'oocnews' then 'ooc'
                     else category
                     end

        unless ::StaffBulletin::NEWS_TYPES.include?(normalized)
          return error_result("Unknown category: #{category}. Valid categories: announcement, ic, ooc")
        end

        articles = ::StaffBulletin.published.by_type(normalized).recent.all

        if articles.empty?
          return success_result(
            "No #{normalized} news articles published yet.",
            type: :message
          )
        end

        type_label = case normalized
                     when 'announcement' then 'Announcements'
                     when 'ic' then 'IC News'
                     when 'ooc' then 'OOC News'
                     else normalized.upcase
                     end

        lines = ["<h3>#{type_label}</h3>"]
        lines << ''

        articles.each do |article|
          is_unread = !article.read_by?(character.user)
          marker = is_unread ? '[NEW] ' : '      '
          date = article.published_at&.strftime('%Y-%m-%d')

          lines << "#{marker}##{article.id} #{article.title}"
          lines << "        Posted: #{date} by #{article.created_by_user&.username || 'Staff'}"
          lines << ''
        end

        lines << "Use 'news <id>' to read an article."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'list_news',
            category: normalized,
            count: articles.length,
            articles: articles.map(&:to_hash)
          }
        )
      end

      def read_article(article_id)
        if article_id <= 0
          return error_result("Please specify an article ID. Usage: news <id>")
        end

        article = ::StaffBulletin.published.first(id: article_id)

        unless article
          return error_result("Article ##{article_id} not found or not published.")
        end

        # Mark as read
        article.mark_read_by!(character.user)

        # Build display
        lines = ["<h3>#{article.title}</h3><div class=\"text-sm opacity-70\">[#{article.type_display.upcase}]</div>"]
        lines << ''
        lines << "Posted by #{article.created_by_user&.username || 'Staff'} on #{article.published_at&.strftime('%Y-%m-%d %H:%M')}"
        lines << ''
        lines << article.content
        lines << ''
        lines << '<hr>'
        lines << "Use 'news' to see all categories."

        success_result(
          lines.join("\n"),
          type: :message,
          data: article.to_hash
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::News)
