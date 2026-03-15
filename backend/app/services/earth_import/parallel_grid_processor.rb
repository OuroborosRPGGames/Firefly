# frozen_string_literal: true

require 'parallel'

module EarthImport
  # Shared concern for applying processing to globe hex grids
  # with optional parallel threading. Used by TerrainClassifier
  # and ElevationMapper which share identical dispatch logic.
  module ParallelGridProcessor
    # Apply processing to all hexes in a grid.
    # Uses parallel processing for multi-core performance when
    # the grid is large enough to benefit (>100K hexes).
    #
    # Subclasses must implement #process_hex(hex, lat_deg, lon_deg)
    #
    # @param grid [WorldGeneration::GlobeHexGrid] The grid to process
    # @param progress_callback [Proc, nil] Optional callback for progress reporting
    def apply_to_grid(grid, progress_callback: nil)
      total = grid.hexes.length
      hexes = grid.hexes

      if @threads <= 1 || total < 100_000
        apply_sequential(hexes, total, progress_callback)
        return
      end

      apply_parallel(hexes, total, progress_callback)
    end

    private

    def apply_sequential(hexes, total, progress_callback)
      hexes.each_with_index do |hex, i|
        lat_deg = hex.lat * 180.0 / Math::PI
        lon_deg = hex.lon * 180.0 / Math::PI

        process_hex(hex, lat_deg, lon_deg)

        progress_callback&.call(i, total) if progress_callback && (i % 1000).zero?
      end
    end

    def apply_parallel(hexes, total, progress_callback)
      processed_count = 0
      last_reported = 0
      mutex = Mutex.new

      Parallel.each_with_index(hexes, in_threads: @threads) do |hex, _i|
        lat_deg = hex.lat * 180.0 / Math::PI
        lon_deg = hex.lon * 180.0 / Math::PI

        process_hex(hex, lat_deg, lon_deg)

        if progress_callback
          mutex.synchronize do
            processed_count += 1
            if processed_count - last_reported >= 10_000
              progress_callback.call(processed_count, total)
              last_reported = processed_count
            end
          end
        end
      end

      progress_callback&.call(total, total)
    end
  end
end
