# frozen_string_literal: true

module Commands
  module Info
    class Score < Commands::Base::Command
      command_name 'score'
      aliases 'stats', 'status'
      category :info
      output_category :info
      help_text 'View your character statistics'
      usage 'score'
      examples 'score', 'stats', 'status'

      protected

      def perform_command(_parsed_input)
        display_score
      end

      private

      def display_score
        ci = character_instance

        # HP lives on character_instance.health (the one true HP pool)
        current_hp = ci.health || GameConfig::Mechanics::DEFAULT_HP[:current]
        max_hp = ci.max_health || GameConfig::Mechanics::DEFAULT_HP[:max]

        html = build_score_html(ci, current_hp, max_hp)

        success_result(
          html,
          type: :message,
          data: {
            action: 'score',
            current_hp: current_hp,
            max_hp: max_hp
          }
        )
      end

      def build_score_html(ci, current_hp, max_hp)
        name = h(ci.full_name)
        hp_pips = render_hp_pips(current_hp, max_hp)
        stats_html = render_stats(ci)

        <<~HTML
          <div style="font-family: inherit; max-width: 360px;">
            <div style="text-align: center; margin-bottom: 8px;">
              <span style="font-size: 1.15em; font-weight: bold; letter-spacing: 0.5px;">#{name}</span>
            </div>
            <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 6px; padding: 10px 14px; margin-bottom: 8px;">
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 2px;">
                <span style="font-size: 0.8em; text-transform: uppercase; letter-spacing: 1px; opacity: 0.6;">HP</span>
                <span style="font-size: 0.8em; opacity: 0.6;">#{current_hp} / #{max_hp}</span>
              </div>
              <div style="display: flex; gap: 4px;">#{hp_pips}</div>
            </div>
            #{stats_html}
          </div>
        HTML
      end

      def render_hp_pips(current_hp, max_hp)
        pips = (1..max_hp).map do |i|
          if i <= current_hp
            color = hp_color(current_hp, max_hp)
            "<div style=\"flex: 1; height: 10px; border-radius: 3px; background: #{color};\"></div>"
          else
            "<div style=\"flex: 1; height: 10px; border-radius: 3px; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.1);\"></div>"
          end
        end
        pips.join("\n")
      end

      def hp_color(current, max)
        ratio = current.to_f / max
        if ratio > 0.6
          '#4ade80'
        elsif ratio > 0.3
          '#fbbf24'
        else
          '#f87171'
        end
      end

      def render_stats(ci)
        stats = ci.character_stats
        return '' if stats.empty?

        sorted = stats.sort_by { |cs| cs.stat.display_order }
        rows = sorted.map { |cs| render_stat_row(cs) }.join("\n")

        <<~HTML
          <div style="background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.1); border-radius: 6px; padding: 10px 14px;">
            <div style="font-size: 0.8em; text-transform: uppercase; letter-spacing: 1px; opacity: 0.6; margin-bottom: 6px;">Attributes</div>
            #{rows}
          </div>
        HTML
      end

      def render_stat_row(char_stat)
        stat = char_stat.stat
        value = char_stat.current_value
        max = stat.max_value
        pct = [(value.to_f / max * 100), 100].min

        abbr = h(stat.abbreviation)
        name = h(stat.name)

        modifier_text = ''
        if char_stat.temp_modifier && char_stat.temp_modifier != 0
          sign = char_stat.temp_modifier > 0 ? '+' : ''
          modifier_text = " <span style=\"opacity: 0.5; font-size: 0.85em;\">(#{sign}#{char_stat.temp_modifier})</span>"
        end

        <<~HTML
          <div style="display: flex; align-items: center; margin-bottom: 5px;">
            <span style="width: 36px; font-weight: bold; font-size: 0.85em; opacity: 0.8;" title="#{name}">#{abbr}</span>
            <div style="flex: 1; height: 6px; background: rgba(255,255,255,0.08); border-radius: 3px; margin: 0 8px; overflow: hidden;">
              <div style="width: #{pct}%; height: 100%; background: #60a5fa; border-radius: 3px;"></div>
            </div>
            <span style="font-size: 0.9em; min-width: 20px; text-align: right;">#{value}#{modifier_text}</span>
          </div>
        HTML
      end

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Info::Score)
