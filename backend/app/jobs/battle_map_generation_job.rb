# frozen_string_literal: true

require 'sidekiq'
# CombatQuickmenuHandler is not auto-loaded in Sidekiq context — require it explicitly
require_relative '../handlers/concerns/base_quickmenu_handler'
require_relative '../handlers/concerns/timed_action_handler'
require_relative '../handlers/concerns/handler_response_helper'
require_relative '../handlers/combat_quickmenu_handler'

# Sidekiq job for asynchronous battle map generation.
#
# Runs AI image generation + hex classification in a Sidekiq worker process,
# keeping long-running external API calls out of Puma threads where they would
# block on C-level IO and resist Ruby Timeout interruption.
#
# The BattleMapWatchdog scheduler (config/initializers/scheduler.rb) acts as a
# safety net: if this job hangs, the watchdog detects the stuck fight flag after
# BATTLE_MAP_GENERATION_TIMEOUT seconds and falls back to procedural generation.
#
# Usage (from FightService):
#   BattleMapGenerationJob.perform_async(room.id, fight.id)
#
class BattleMapGenerationJob
  include Sidekiq::Job

  sidekiq_options queue: 'battle_map', retry: 0

  def perform(room_id, fight_id)
    room  = Room[room_id]
    fight = Fight[fight_id]

    unless room && fight
      warn "[BattleMapGenerationJob] Room #{room_id} or fight #{fight_id} not found"
      Fight[fight_id]&.complete_battle_map_generation!
      return
    end

    # Guard against duplicate jobs (watchdog may have already resolved)
    return unless fight.battle_map_generating

    room_width  = (room.max_x.to_f - room.min_x.to_f)
    room_height = (room.max_y.to_f - room.min_y.to_f)
    hex_w, hex_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
    estimated_hexes = hex_w * hex_h

    if GameSetting.boolean('ai_battle_maps_enabled') && estimated_hexes >= 30
      AIBattleMapGeneratorService.new(room).generate_async(fight)
    else
      BattleMapGeneratorService.new(room).generate_with_progress(fight_id)
    end

    # Safety net: complete_battle_map_generation! is called inside generate_async on
    # both success and fallback paths, but call it here too in case it was skipped.
    fight.refresh
    fight.complete_battle_map_generation! if fight.battle_map_generating

    FightService.revalidate_participant_positions(fight)
    FightService.push_quickmenus_to_participants(fight)

    # Dynamic lighting — runs after quickmenus so combat starts immediately.
    # Still in a background process so Puma is unaffected.
    if room.has_battle_map && GameSetting.boolean('dynamic_lighting_enabled')
      begin
        r = Room[room_id]
        f = Fight[fight_id]
        if r && f
          battlemap_url = r.battle_map_image_url
          if battlemap_url
            bm_path = battlemap_url.start_with?('/') ? File.join('public', battlemap_url) : battlemap_url
            AIBattleMapGeneratorService.new(r).detect_and_store_light_sources(r, bm_path) if File.exist?(bm_path)
          end
          snapshot = DynamicLightingService.build_lighting_snapshot(r)
          f.update(lighting_snapshot: Sequel.pg_jsonb_wrap(snapshot))
          DynamicLightingService.render_for_fight(f)
        end
      rescue StandardError => lighting_err
        warn "[BattleMapGenerationJob] Post-generation lighting failed: #{lighting_err.message}"
      end
    end

  rescue StandardError => e
    warn "[BattleMapGenerationJob] Failed for room #{room_id} fight #{fight_id}: #{e.message}"
    begin
      fight = Fight[fight_id]
      if fight
        fight.complete_battle_map_generation!
        FightService.revalidate_participant_positions(fight)
        FightService.push_quickmenus_to_participants(fight)
      end
    rescue StandardError => cleanup_err
      warn "[BattleMapGenerationJob] Cleanup also failed: #{cleanup_err.message}"
    end
  end
end
