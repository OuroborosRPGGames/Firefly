# frozen_string_literal: true

require_relative '../../../lib/core_extensions'

# Service for logging mission/activity events with rich HTML formatting.
#
# Usage:
#   ActivityLoggingService.log_round_start(instance, round)
#   ActivityLoggingService.log_action(instance, participant, action, outcome)
#   ActivityLoggingService.log_narrative(instance, "The door creaks open...")
#   ActivityLoggingService.log_combat(instance, fight, events)
#   ActivityLoggingService.log_summary(instance)
#
class ActivityLoggingService
  extend CoreExtensions
  class << self
    # ===== Core Logging Methods =====

    # Log a narrative/story entry
    def log_narrative(instance, text, html: nil, title: nil, round_number: nil)
      return unless logging_enabled?(instance)

      create_log(instance,
                 log_type: 'narrative',
                 title: title,
                 text: text,
                 html_content: html,
                 round_number: round_number || instance.rounds_done)
    end

    # Log the start of a round
    def log_round_start(instance, round)
      return unless logging_enabled?(instance)

      round_num = instance.rounds_done + 1
      title = round_title(round, round_num)
      description = round_description(round, title)
      html = build_round_start_html(instance, round)

      create_log(instance,
                 log_type: 'round_start',
                 title: title,
                 text: description,
                 html_content: html,
                 round_number: round_num,
                 activity_round_id: round.id)
    end

    # Log the end of a round with outcomes
    def log_round_end(instance, round, outcomes = {})
      return unless logging_enabled?(instance)

      html = build_round_end_html(instance, round, outcomes)

      create_log(instance,
                 log_type: 'round_end',
                 title: "Round #{instance.rounds_done} Complete",
                 text: outcomes[:summary] || "Round complete",
                 html_content: html,
                 round_number: instance.rounds_done,
                 activity_round_id: round.id)
    end

    # Log a character's action choice
    def log_action(instance, participant, action_name, details = {})
      return unless logging_enabled?(instance)

      character = participant.character
      html = build_action_html(character, action_name, details)

      create_log(instance,
                 log_type: 'action',
                 title: action_name,
                 text: "#{character.full_name} chose: #{action_name}",
                 html_content: html,
                 round_number: instance.rounds_done,
                 character_id: character.id,
                 action_name: action_name)
    end

    # Log the outcome of an action
    def log_outcome(instance, participant, outcome, details = {})
      return unless logging_enabled?(instance)

      character = participant.character
      html = build_outcome_html(character, outcome, details)

      create_log(instance,
                 log_type: 'outcome',
                 title: outcome_title(outcome),
                 text: details[:text] || "#{character.full_name}: #{outcome}",
                 html_content: html,
                 round_number: instance.rounds_done,
                 character_id: character.id,
                 outcome: outcome,
                 roll_result: details[:roll],
                 difficulty: details[:difficulty])
    end

    # Log combat events
    def log_combat(instance, description, details = {})
      return unless logging_enabled?(instance)

      html = build_combat_html(description, details)

      create_log(instance,
                 log_type: 'combat',
                 title: details[:title] || 'Combat',
                 text: description,
                 html_content: html,
                 round_number: instance.rounds_done,
                 character_id: details[:character_id])
    end

    # Log system messages
    def log_system(instance, message, details = {})
      return unless logging_enabled?(instance)

      create_log(instance,
                 log_type: 'system',
                 title: details[:title] || 'System',
                 text: message,
                 html_content: "<div class=\"activity-log-system\">#{escape_html(message)}</div>",
                 round_number: instance.rounds_done)
    end

    # Log final summary when activity completes
    def log_summary(instance, custom_summary = nil)
      return unless logging_enabled?(instance)

      summary = custom_summary || build_auto_summary(instance)
      html = build_summary_html(instance, summary)

      # Save summary to instance too
      instance.update(log_summary: summary[:text], completed_at: Time.now)

      create_log(instance,
                 log_type: 'summary',
                 title: 'Mission Complete',
                 text: summary[:text],
                 html_content: html)
    end

    # ===== Retrieval Methods =====

    # Get formatted logs for an instance
    def logs_for_instance(instance, viewer: nil)
      return [] unless can_view_logs?(instance, viewer)

      ActivityLog.for_instance(instance.id).map(&:to_api_hash)
    end

    # Get logs grouped by round
    def logs_by_round(instance, viewer: nil)
      return {} unless can_view_logs?(instance, viewer)

      logs = ActivityLog.for_instance(instance.id).all
      logs.group_by(&:round_number)
    end

    # Get full HTML document for logs
    def logs_as_html(instance, viewer: nil)
      return nil unless can_view_logs?(instance, viewer)

      logs = ActivityLog.for_instance(instance.id).all
      build_full_html_document(instance, logs)
    end

    # ===== Permission Checking =====

    def can_view_logs?(instance, viewer)
      return false unless instance

      activity = instance.activity
      return true if activity.nil? # Default allow if no activity

      visibility = activity.logs_visible_to || 'participants'

      case visibility
      when 'public'
        true
      when 'participants'
        return true if viewer.nil? # API access
        instance.participants.any? { |p| p.character&.id == viewer.id }
      when 'private'
        false
      else
        true
      end
    end

    private

    def logging_enabled?(instance)
      return false unless instance
      return true if instance.activity.nil?

      instance.activity.logging_enabled != false
    end

    def create_log(instance, attrs)
      ActivityLog.create(
        attrs.merge(
          activity_instance_id: instance.id,
          sequence: ActivityLog.next_sequence(instance.id)
        )
      )
    end

    # escape_html is now provided by CoreExtensions

    def outcome_title(outcome)
      case outcome
      when 'success' then 'Success!'
      when 'partial' then 'Partial Success'
      when 'failure' then 'Failure'
      else outcome&.capitalize || 'Result'
      end
    end

    # ===== HTML Builders =====

    def build_round_start_html(instance, round)
      round_num = instance.rounds_done + 1
      total = instance.rcount || '?'
      title = round_title(round, round_num)
      description = round_description(round, title)

      <<~HTML
        <div class="activity-log-round-start">
          <div class="round-header">
            <span class="round-number">Round #{round_num} of #{total}</span>
            <h3 class="round-title">#{escape_html(title)}</h3>
          </div>
          #{description ? "<div class=\"round-description\">#{escape_html(description)}</div>" : ''}
          #{round.round_type != 'standard' ? "<div class=\"round-type\">Type: #{escape_html(round.round_type)}</div>" : ''}
        </div>
      HTML
    end

    def build_round_end_html(_instance, _round, outcomes)
      participants_html = if outcomes[:participants]
                            outcomes[:participants].map do |p|
                              status_class = p[:outcome] || 'neutral'
                              <<~PHTML
                                <div class="participant-outcome outcome-#{status_class}">
                                  <span class="participant-name">#{escape_html(p[:name])}</span>
                                  #{p[:roll] ? "<span class=\"roll-result\">Roll: #{p[:roll]}</span>" : ''}
                                  <span class="outcome-text">#{escape_html(p[:result] || p[:outcome])}</span>
                                </div>
                              PHTML
                            end.join("\n")
                          else
                            ''
                          end

      <<~HTML
        <div class="activity-log-round-end">
          #{outcomes[:summary] ? "<div class=\"round-summary\">#{escape_html(outcomes[:summary])}</div>" : ''}
          #{participants_html.empty? ? '' : "<div class=\"participants-outcomes\">#{participants_html}</div>"}
        </div>
      HTML
    end

    def build_action_html(character, action_name, details)
      <<~HTML
        <div class="activity-log-action">
          <span class="character-name">#{escape_html(character.full_name)}</span>
          <span class="action-choice">chose <strong>#{escape_html(action_name)}</strong></span>
          #{details[:risk] ? "<span class=\"risk-level\">Risk: #{escape_html(details[:risk])}</span>" : ''}
        </div>
      HTML
    end

    def build_outcome_html(character, outcome, details)
      outcome_class = case outcome
                      when 'success' then 'success'
                      when 'partial' then 'partial'
                      when 'failure' then 'failure'
                      else 'neutral'
                      end

      roll_html = if details[:roll] && details[:difficulty]
                    "<div class=\"roll-info\">Roll: #{details[:roll]} vs DC #{details[:difficulty]}</div>"
                  elsif details[:roll]
                    "<div class=\"roll-info\">Roll: #{details[:roll]}</div>"
                  else
                    ''
                  end

      <<~HTML
        <div class="activity-log-outcome outcome-#{outcome_class}">
          <div class="outcome-header">
            <span class="character-name">#{escape_html(character.full_name)}</span>
            <span class="outcome-badge">#{escape_html(outcome_title(outcome))}</span>
          </div>
          #{roll_html}
          #{details[:text] ? "<div class=\"outcome-text\">#{escape_html(details[:text])}</div>" : ''}
        </div>
      HTML
    end

    def build_combat_html(description, details)
      <<~HTML
        <div class="activity-log-combat">
          #{details[:title] ? "<h4 class=\"combat-title\">#{escape_html(details[:title])}</h4>" : ''}
          <div class="combat-description">#{escape_html(description)}</div>
          #{details[:damage] ? "<div class=\"combat-damage\">Damage: #{details[:damage]}</div>" : ''}
        </div>
      HTML
    end

    def build_auto_summary(instance)
      activity = instance.activity
      participants = instance.participants

      # Gather stats
      total_rounds = instance.rounds_done
      participant_summaries = participants.map do |p|
        status = p.status_text

        {
          name: p.character&.full_name || 'Unknown',
          score: p.score || 0,
          status: status
        }
      end

      winner = participant_summaries.max_by { |p| p[:score] }

      {
        text: "#{activity&.name || 'Mission'} completed in #{total_rounds} rounds.",
        participants: participant_summaries,
        winner: winner,
        total_rounds: total_rounds
      }
    end

    def build_summary_html(instance, summary)
      activity = instance.activity

      participants_html = if summary[:participants]
                            summary[:participants].map do |p|
                              <<~PHTML
                                <div class="summary-participant">
                                  <span class="participant-name">#{escape_html(p[:name])}</span>
                                  <span class="participant-score">Score: #{p[:score]}</span>
                                </div>
                              PHTML
                            end.join("\n")
                          else
                            ''
                          end

      <<~HTML
        <div class="activity-log-summary">
          <h2 class="summary-title">#{escape_html(activity&.name || 'Mission')} Complete</h2>
          <div class="summary-stats">
            <div class="stat">Rounds: #{summary[:total_rounds] || instance.rounds_done}</div>
            #{summary[:winner] ? "<div class=\"stat winner\">Winner: #{escape_html(summary[:winner][:name])}</div>" : ''}
          </div>
          #{participants_html.empty? ? '' : "<div class=\"summary-participants\">#{participants_html}</div>"}
          <div class="summary-text">#{escape_html(summary[:text])}</div>
        </div>
      HTML
    end

    def build_full_html_document(instance, logs)
      activity = instance.activity
      title = activity&.name || "Mission Log ##{instance.id}"

      logs_html = logs.map(&:formatted_content).join("\n<hr class=\"log-separator\">\n")

      <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>#{escape_html(title)}</title>
          <style>
            #{activity_log_css}
          </style>
        </head>
        <body>
          <div class="activity-log-container">
            <header class="activity-header">
              <h1>#{escape_html(title)}</h1>
              <div class="activity-meta">
                <span class="activity-type">#{escape_html(activity&.activity_type || 'Mission')}</span>
                <span class="activity-date">#{instance.completed_at&.strftime('%B %d, %Y') || 'In Progress'}</span>
              </div>
            </header>
            <main class="activity-logs">
              #{logs_html}
            </main>
          </div>
        </body>
        </html>
      HTML
    end

    def round_title(round, round_num)
      title = round.display_name
      title = "Round #{round_num}" if blank_text?(title)
      title
    end

    def round_description(round, fallback)
      description = round.emit_text
      description = fallback if blank_text?(description)
      description
    end

    def blank_text?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def activity_log_css
      <<~CSS
        body { font-family: Georgia, serif; max-width: 800px; margin: 0 auto; padding: 20px; background: #f5f5f5; }
        .activity-log-container { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .activity-header { border-bottom: 2px solid #333; padding-bottom: 15px; margin-bottom: 25px; }
        .activity-header h1 { margin: 0 0 10px 0; color: #2c3e50; }
        .activity-meta { color: #666; font-size: 0.9em; }
        .activity-meta span { margin-right: 20px; }
        .log-separator { border: none; border-top: 1px solid #ddd; margin: 20px 0; }

        .activity-log-round-start { background: #e8f4f8; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .round-header { display: flex; align-items: center; gap: 15px; }
        .round-number { background: #3498db; color: white; padding: 5px 10px; border-radius: 3px; font-size: 0.85em; }
        .round-title { margin: 0; color: #2c3e50; }
        .round-description { margin-top: 10px; font-style: italic; color: #555; }
        .round-type { margin-top: 8px; font-size: 0.85em; color: #666; }

        .activity-log-round-end { background: #f8f8e8; padding: 15px; border-radius: 5px; margin: 15px 0; }
        .round-summary { font-weight: bold; margin-bottom: 10px; }
        .participant-outcome { padding: 8px; margin: 5px 0; border-radius: 3px; display: flex; justify-content: space-between; }
        .outcome-success { background: #d4edda; }
        .outcome-partial { background: #fff3cd; }
        .outcome-failure { background: #f8d7da; }

        .activity-log-action { padding: 10px; background: #f9f9f9; border-left: 3px solid #3498db; margin: 10px 0; }
        .character-name { font-weight: bold; color: #2c3e50; }
        .action-choice { margin-left: 10px; }
        .risk-level { margin-left: 15px; font-size: 0.85em; color: #666; }

        .activity-log-outcome { padding: 12px; border-radius: 5px; margin: 10px 0; }
        .outcome-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
        .outcome-badge { padding: 3px 10px; border-radius: 3px; font-weight: bold; }
        .outcome-success .outcome-badge { background: #27ae60; color: white; }
        .outcome-partial .outcome-badge { background: #f39c12; color: white; }
        .outcome-failure .outcome-badge { background: #e74c3c; color: white; }
        .roll-info { font-size: 0.85em; color: #666; }
        .outcome-text { margin-top: 8px; }

        .activity-log-combat { background: #fce4ec; padding: 15px; border-radius: 5px; margin: 10px 0; border-left: 3px solid #c0392b; }
        .combat-title { margin: 0 0 10px 0; color: #c0392b; }

        .activity-log-system { background: #ecf0f1; padding: 10px; border-radius: 3px; font-style: italic; color: #666; }

        .activity-log-summary { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 25px; border-radius: 8px; margin-top: 25px; }
        .summary-title { margin: 0 0 15px 0; }
        .summary-stats { display: flex; gap: 20px; margin-bottom: 15px; }
        .summary-stats .stat { background: rgba(255,255,255,0.2); padding: 5px 12px; border-radius: 3px; }
        .summary-stats .winner { background: gold; color: #333; }
        .summary-participants { background: rgba(255,255,255,0.1); padding: 10px; border-radius: 5px; margin-bottom: 15px; }
        .summary-participant { padding: 5px 0; display: flex; justify-content: space-between; }
      CSS
    end
  end
end
