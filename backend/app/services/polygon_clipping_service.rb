# frozen_string_literal: true

# Provides polygon clipping algorithms for room boundary calculations.
# Uses the Sutherland-Hodgman algorithm to calculate the intersection
# of room bounds with zone polygons.
class PolygonClippingService
  class << self
    # Calculate intersection of room bounds with zone polygon
    # @param room [Room] the room to clip
    # @return [Hash, nil] { polygon: Array<Hash>, area: Float, percentage: Float }
    #                     or nil if room is wholly outside
    def clip_room_to_zone(room)
      zone_polygon = room.location&.zone_polygon_in_feet
      return full_room_result(room) unless zone_polygon&.any?

      room_rect = room_to_polygon(room)
      intersection = sutherland_hodgman_clip(room_rect, zone_polygon)

      return nil if intersection.empty? # Room wholly outside polygon

      int_area = polygon_area(intersection)
      room_area = room_area_square_feet(room)

      # Avoid division by zero
      percentage = room_area > 0 ? (int_area / room_area) : 0.0

      # If intersection is same as room (within tolerance), return nil to indicate full room
      if percentage >= 0.999
        return {
          polygon: nil, # null means use full room bounds
          area: room_area,
          percentage: 1.0
        }
      end

      {
        polygon: intersection,
        area: int_area,
        percentage: percentage
      }
    end

    # Clip custom room polygon against zone polygon
    # @param room [Room] room with room_polygon set
    # @return [Hash, nil] same format as clip_room_to_zone
    def clip_polygon_to_zone(room)
      zone_polygon = room.location&.zone_polygon_in_feet
      room_poly = room.shape_polygon

      # No zone polygon = full room polygon usable
      return full_polygon_result(room_poly) unless zone_polygon&.any?
      return nil unless room_poly&.any?

      intersection = sutherland_hodgman_clip(room_poly, zone_polygon)
      return nil if intersection.empty?

      int_area = polygon_area(intersection)
      room_area = polygon_area(room_poly)
      percentage = room_area > 0 ? (int_area / room_area) : 0.0

      if percentage >= 0.999
        return {
          polygon: nil, # null means use full room polygon
          area: room_area,
          percentage: 1.0
        }
      end

      {
        polygon: intersection,
        area: int_area,
        percentage: percentage
      }
    end

    # Check if a point is inside the effective polygon
    # Priority: effective_polygon > room_polygon > rectangular bounds
    # @param room [Room] the room
    # @param x [Float] x coordinate in feet
    # @param y [Float] y coordinate in feet
    # @return [Boolean]
    def point_in_effective_area?(room, x, y)
      # Check effective_polygon first (zone-clipped area)
      eff_poly = room.effective_polygon
      if eff_poly && !eff_poly.empty?
        return point_in_polygon?(x, y, eff_poly)
      end

      # Check room_polygon (custom room shape)
      if room.has_custom_polygon?
        return point_in_polygon?(x, y, room.room_polygon)
      end

      # Fall back to rectangular bounds
      x >= room.min_x && x <= room.max_x && y >= room.min_y && y <= room.max_y
    end

    # Get valid position nearest to requested position
    # Uses the room's usable_polygon (effective_polygon > shape_polygon)
    # @param room [Room] the room
    # @param requested_x [Float] requested x coordinate
    # @param requested_y [Float] requested y coordinate
    # @return [Hash, nil] { x:, y: } or nil if no valid position
    def nearest_valid_position(room, requested_x, requested_y)
      return { x: requested_x, y: requested_y } if point_in_effective_area?(room, requested_x, requested_y)

      # Use the room's usable polygon (accounts for both custom shape and zone clipping)
      polygon = room.usable_polygon
      polygon = room_to_polygon(room) if polygon.nil? || polygon.empty?

      closest_point_on_polygon(requested_x, requested_y, polygon)
    end

    # Calculate the intersection of two convex/concave polygons using Sutherland-Hodgman
    # @param subject [Array<Hash>] array of {x:, y:} points (polygon to be clipped)
    # @param clip [Array<Hash>] array of {x:, y:} points (clipping polygon)
    # @return [Array<Hash>] intersection polygon points
    def sutherland_hodgman_clip(subject, clip)
      return [] if subject.empty? || clip.empty?

      output = normalize_polygon(subject)
      clip_polygon = normalize_polygon(clip)

      # Clip against each edge of the clip polygon
      clip_polygon.each_with_index do |_point, i|
        return [] if output.empty?

        input = output
        output = []

        edge_start = clip_polygon[i]
        edge_end = clip_polygon[(i + 1) % clip_polygon.length]

        input.each_with_index do |current, j|
          previous = input[(j - 1) % input.length]

          current_inside = point_on_left_of_edge?(current, edge_start, edge_end)
          previous_inside = point_on_left_of_edge?(previous, edge_start, edge_end)

          if current_inside
            unless previous_inside
              # Previous outside, current inside - add intersection
              intersection = line_intersection(previous, current, edge_start, edge_end)
              output << intersection if intersection
            end
            # Current inside - add it
            output << current
          elsif previous_inside
            # Previous inside, current outside - add intersection
            intersection = line_intersection(previous, current, edge_start, edge_end)
            output << intersection if intersection
          end
        end
      end

      # Remove duplicate consecutive points
      output = remove_consecutive_duplicates(output)

      output
    end

    # Calculate polygon area using the shoelace formula
    # @param polygon [Array<Hash>] array of {x:, y:} points
    # @return [Float] area in square units
    def polygon_area(polygon)
      return 0.0 if polygon.nil? || polygon.length < 3

      polygon = normalize_polygon(polygon)
      n = polygon.length
      area = 0.0

      n.times do |i|
        j = (i + 1) % n
        area += polygon[i][:x] * polygon[j][:y]
        area -= polygon[j][:x] * polygon[i][:y]
      end

      (area.abs / 2.0)
    end

    # Check if a point is inside a polygon using ray casting
    # @param x [Float] x coordinate
    # @param y [Float] y coordinate
    # @param polygon [Array<Hash>] array of {x:, y:} points
    # @return [Boolean]
    def point_in_polygon?(x, y, polygon)
      return false if polygon.nil? || polygon.length < 3

      polygon = normalize_polygon(polygon)
      n = polygon.length
      inside = false

      j = n - 1
      n.times do |i|
        xi = polygon[i][:x]
        yi = polygon[i][:y]
        xj = polygon[j][:x]
        yj = polygon[j][:y]

        # Ray casting algorithm
        if ((yi > y) != (yj > y)) &&
           (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
          inside = !inside
        end
        j = i
      end

      inside
    end

    # Convert room bounds to polygon array
    # @param room [Room] the room
    # @return [Array<Hash>] array of {x:, y:} corner points
    def room_to_polygon(room)
      [
        { x: room.min_x.to_f, y: room.min_y.to_f },
        { x: room.max_x.to_f, y: room.min_y.to_f },
        { x: room.max_x.to_f, y: room.max_y.to_f },
        { x: room.min_x.to_f, y: room.max_y.to_f }
      ]
    end

    private

    # Normalize polygon to array of hashes with symbol keys
    # Handles both string and symbol keys
    # @param polygon [Array] polygon points
    # @return [Array<Hash>] normalized points
    def normalize_polygon(polygon)
      polygon.map do |p|
        {
          x: (p['x'] || p[:x]).to_f,
          y: (p['y'] || p[:y]).to_f
        }
      end
    end

    # Check if point is on the left side of (or on) an edge
    # Uses cross product to determine which side of line the point is on
    # @param point [Hash] point to test
    # @param edge_start [Hash] edge start point
    # @param edge_end [Hash] edge end point
    # @return [Boolean]
    def point_on_left_of_edge?(point, edge_start, edge_end)
      cross = (edge_end[:x] - edge_start[:x]) * (point[:y] - edge_start[:y]) -
              (edge_end[:y] - edge_start[:y]) * (point[:x] - edge_start[:x])
      cross >= 0
    end

    # Calculate the intersection point of two line segments
    # @param p1 [Hash] first line start
    # @param p2 [Hash] first line end
    # @param p3 [Hash] second line start (edge start)
    # @param p4 [Hash] second line end (edge end)
    # @return [Hash, nil] intersection point or nil if parallel
    def line_intersection(p1, p2, p3, p4)
      x1, y1 = p1[:x], p1[:y]
      x2, y2 = p2[:x], p2[:y]
      x3, y3 = p3[:x], p3[:y]
      x4, y4 = p4[:x], p4[:y]

      denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)

      # Lines are parallel
      return nil if denom.abs < 1e-10

      t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom

      {
        x: x1 + t * (x2 - x1),
        y: y1 + t * (y2 - y1)
      }
    end

    # Find the closest point on a polygon boundary to a given point
    # @param x [Float] point x coordinate
    # @param y [Float] point y coordinate
    # @param polygon [Array<Hash>] polygon points
    # @return [Hash] { x:, y: } closest point on boundary
    def closest_point_on_polygon(x, y, polygon)
      polygon = normalize_polygon(polygon)
      return { x: x, y: y } if polygon.empty?

      closest = nil
      min_distance = Float::INFINITY

      polygon.each_with_index do |p1, i|
        p2 = polygon[(i + 1) % polygon.length]
        point = closest_point_on_segment(x, y, p1, p2)
        distance = Math.sqrt((point[:x] - x)**2 + (point[:y] - y)**2)

        if distance < min_distance
          min_distance = distance
          closest = point
        end
      end

      closest || { x: polygon.first[:x], y: polygon.first[:y] }
    end

    # Find the closest point on a line segment to a given point
    # @param px [Float] point x coordinate
    # @param py [Float] point y coordinate
    # @param p1 [Hash] segment start
    # @param p2 [Hash] segment end
    # @return [Hash] { x:, y: } closest point on segment
    def closest_point_on_segment(px, py, p1, p2)
      x1, y1 = p1[:x], p1[:y]
      x2, y2 = p2[:x], p2[:y]

      # Vector from p1 to p2
      dx = x2 - x1
      dy = y2 - y1

      # If segment is a point
      if dx.abs < 1e-10 && dy.abs < 1e-10
        return { x: x1, y: y1 }
      end

      # Parameter t for projection onto line
      t = ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)

      # Clamp t to [0, 1] to stay on segment
      t = [[0.0, t].max, 1.0].min

      {
        x: x1 + t * dx,
        y: y1 + t * dy
      }
    end

    # Remove consecutive duplicate points from polygon
    # @param polygon [Array<Hash>] polygon points
    # @return [Array<Hash>] cleaned polygon
    def remove_consecutive_duplicates(polygon)
      return polygon if polygon.length < 2

      result = []
      polygon.each_with_index do |point, i|
        prev_point = polygon[(i - 1) % polygon.length]
        unless points_equal?(point, prev_point)
          result << point
        end
      end

      result
    end

    # Check if two points are approximately equal
    # @param p1 [Hash] first point
    # @param p2 [Hash] second point
    # @param tolerance [Float] distance tolerance
    # @return [Boolean]
    def points_equal?(p1, p2, tolerance = 0.01)
      (p1[:x] - p2[:x]).abs < tolerance && (p1[:y] - p2[:y]).abs < tolerance
    end

    # Calculate room area in square feet
    # @param room [Room] the room
    # @return [Float]
    def room_area_square_feet(room)
      width = (room.max_x.to_f - room.min_x.to_f)
      height = (room.max_y.to_f - room.min_y.to_f)
      width * height
    end

    # Generate result for full room (no clipping needed)
    # @param room [Room] the room
    # @return [Hash]
    def full_room_result(room)
      area = room_area_square_feet(room)
      {
        polygon: nil, # null means use full room bounds
        area: area,
        percentage: 1.0
      }
    end

    # Generate result for full polygon (no clipping needed)
    # @param polygon [Array<Hash>] the polygon
    # @return [Hash]
    def full_polygon_result(polygon)
      area = polygon_area(polygon)
      {
        polygon: nil, # null means use full polygon
        area: area,
        percentage: 1.0
      }
    end
  end
end
