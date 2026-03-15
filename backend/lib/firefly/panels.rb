# frozen_string_literal: true

module Firefly
  # Panel definitions for output targeting.
  # Commands return target_panel to specify WHERE output renders.
  #
  # The webclient uses these to route content to the correct UI element.
  # MCP agents use these to understand output context and significance.
  module Panels
    # Main content feeds - scrolling message streams
    LEFT_MAIN_FEED = :left_main_feed     # OOC chat, channels, tells
    RIGHT_MAIN_FEED = :right_main_feed   # RP content, room, emotes, combat

    # Observation panels - temporary inspection results
    LEFT_OBSERVE = :left_observe_window   # Inspect OOC items/profiles
    RIGHT_OBSERVE = :right_observe_window # Inspect RP targets (characters, items, exits)

    # Status displays - persistent state summaries
    LEFT_STATUS = :left_status_bar   # Channel, time, connection status
    RIGHT_STATUS = :right_status_bar # Location, health, RP status

    # Special panels
    LEFT_MINIMAP = :left_minimap           # Area map
    RIGHT_EFFECTS = :right_effect_dropdown # Combat effects, buffs, debuffs
    POPOUT_FORM = :popout_form             # Modal forms requiring input
    IMPRINT = :imprint                     # System notifications (top banner)

    # All valid panels
    ALL = [
      LEFT_MAIN_FEED, RIGHT_MAIN_FEED,
      LEFT_OBSERVE, RIGHT_OBSERVE,
      LEFT_STATUS, RIGHT_STATUS,
      LEFT_MINIMAP, RIGHT_EFFECTS,
      POPOUT_FORM, IMPRINT
    ].freeze

    # Default panel routing based on content/display type.
    # Commands can override by passing explicit target_panel.
    DEFAULTS = {
      # OOC content -> left main feed
      ooc: LEFT_MAIN_FEED,
      channel: LEFT_MAIN_FEED,
      tell: LEFT_MAIN_FEED,
      whisper: LEFT_MAIN_FEED,
      page: LEFT_MAIN_FEED,

      # RP content -> right main feed
      say: RIGHT_MAIN_FEED,
      emote: RIGHT_MAIN_FEED,
      room: RIGHT_MAIN_FEED,
      combat: RIGHT_MAIN_FEED,
      action: RIGHT_MAIN_FEED,
      narrate: RIGHT_MAIN_FEED,
      movement: RIGHT_MAIN_FEED,

      # Look results -> observe windows
      character: RIGHT_OBSERVE,
      item: RIGHT_OBSERVE,
      decoration: RIGHT_OBSERVE,
      place: RIGHT_OBSERVE,
      exit: RIGHT_OBSERVE,
      feature: RIGHT_OBSERVE,

      # Interactive elements
      quickmenu: POPOUT_FORM,
      form: POPOUT_FORM,

      # Status updates
      effect: RIGHT_EFFECTS,
      buff: RIGHT_EFFECTS,
      debuff: RIGHT_EFFECTS,
      cooldown: RIGHT_EFFECTS,

      # Map updates
      map_update: LEFT_MINIMAP,

      # System notifications
      system: IMPRINT,
      error: RIGHT_MAIN_FEED
    }.freeze

    class << self
      # Infer target panel from type and display_type
      def infer(type: nil, display_type: nil)
        DEFAULTS[display_type&.to_sym] ||
          DEFAULTS[type&.to_sym] ||
          RIGHT_MAIN_FEED
      end

      # Check if a panel name is valid
      def valid?(panel)
        ALL.include?(panel&.to_sym)
      end
    end
  end
end
