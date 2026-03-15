# frozen_string_literal: true

# Middleware to detect if request is from an LLM agent
# Sets env['firefly.agent_mode'] = true/false for use by OutputHelper
class AgentModeDetector
  def initialize(app)
    @app = app
  end

  def call(env)
    env['firefly.agent_mode'] = detect_agent_mode(env)
    @app.call(env)
  end

  private

  def detect_agent_mode(env)
    # Path-based detection (primary)
    return true if env['PATH_INFO'].to_s.start_with?('/api/agent')

    # Header-based detection (secondary)
    return true if env['HTTP_X_OUTPUT_MODE'] == 'agent'

    false
  end
end
