# frozen_string_literal: true

module WorldGeneration
  # Simplex noise generator for procedural terrain generation.
  # Produces coherent noise values suitable for height maps, temperature, moisture, etc.
  #
  # Based on Ken Perlin's simplex noise algorithm, which improves upon classic Perlin noise
  # with fewer directional artifacts and O(n) complexity in n dimensions.
  #
  # @example Basic usage
  #   generator = WorldGeneration::NoiseGenerator.new(seed: 12345)
  #   value = generator.noise2d(x, y)  # Returns -1.0 to 1.0
  #
  # @example Multi-octave (fractal) noise for terrain
  #   elevation = generator.octave_noise2d(x, y, octaves: 6, persistence: 0.5, lacunarity: 2.0)
  #
  class NoiseGenerator
    # Skewing factors for 2D simplex noise
    F2 = 0.5 * (Math.sqrt(3.0) - 1.0)
    G2 = (3.0 - Math.sqrt(3.0)) / 6.0

    # Skewing factors for 3D simplex noise
    F3 = 1.0 / 3.0
    G3 = 1.0 / 6.0

    # Gradient vectors for 2D
    GRAD2 = [
      [1, 1], [-1, 1], [1, -1], [-1, -1],
      [1, 0], [-1, 0], [0, 1], [0, -1]
    ].freeze

    # Gradient vectors for 3D
    GRAD3 = [
      [1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0],
      [1, 0, 1], [-1, 0, 1], [1, 0, -1], [-1, 0, -1],
      [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]
    ].freeze

    # @param seed [Integer] Seed for reproducible noise generation
    def initialize(seed: nil)
      @seed = seed || Random.new_seed
      @perm = build_permutation_table(@seed)
    end

    # Generate 2D simplex noise
    #
    # @param x [Float] X coordinate
    # @param y [Float] Y coordinate
    # @return [Float] Noise value between -1.0 and 1.0
    def noise2d(x, y)
      x = x.to_f
      y = y.to_f

      # Skew input space to determine which simplex cell we're in
      s = (x + y) * F2
      i = (x + s).floor
      j = (y + s).floor

      # Unskew back to (x, y) space
      t = (i + j) * G2
      x0 = x - (i - t)
      y0 = y - (j - t)

      # Determine which simplex we're in (upper or lower triangle)
      if x0 > y0
        i1, j1 = 1, 0
      else
        i1, j1 = 0, 1
      end

      # Offsets for middle and last corners
      x1 = x0 - i1 + G2
      y1 = y0 - j1 + G2
      x2 = x0 - 1.0 + 2.0 * G2
      y2 = y0 - 1.0 + 2.0 * G2

      # Hash coordinates of the three simplex corners
      ii = i & 255
      jj = j & 255

      # Calculate contributions from each corner
      n0 = corner_contribution_2d(x0, y0, ii, jj)
      n1 = corner_contribution_2d(x1, y1, ii + i1, jj + j1)
      n2 = corner_contribution_2d(x2, y2, ii + 1, jj + 1)

      # Scale to [-1, 1] range
      # The theoretical max is around 0.87 for 2D simplex, so we scale by ~70
      70.0 * (n0 + n1 + n2)
    end

    # Generate 3D simplex noise
    #
    # @param x [Float] X coordinate
    # @param y [Float] Y coordinate
    # @param z [Float] Z coordinate
    # @return [Float] Noise value between -1.0 and 1.0
    def noise3d(x, y, z)
      x = x.to_f
      y = y.to_f
      z = z.to_f

      # Skew input space
      s = (x + y + z) * F3
      i = (x + s).floor
      j = (y + s).floor
      k = (z + s).floor

      # Unskew back
      t = (i + j + k) * G3
      x0 = x - (i - t)
      y0 = y - (j - t)
      z0 = z - (k - t)

      # Determine which simplex we're in
      i1, j1, k1, i2, j2, k2 = simplex_order_3d(x0, y0, z0)

      # Offsets for remaining corners
      x1 = x0 - i1 + G3
      y1 = y0 - j1 + G3
      z1 = z0 - k1 + G3
      x2 = x0 - i2 + 2.0 * G3
      y2 = y0 - j2 + 2.0 * G3
      z2 = z0 - k2 + 2.0 * G3
      x3 = x0 - 1.0 + 3.0 * G3
      y3 = y0 - 1.0 + 3.0 * G3
      z3 = z0 - 1.0 + 3.0 * G3

      # Hash coordinates
      ii = i & 255
      jj = j & 255
      kk = k & 255

      # Calculate contributions from each corner
      n0 = corner_contribution_3d(x0, y0, z0, ii, jj, kk)
      n1 = corner_contribution_3d(x1, y1, z1, ii + i1, jj + j1, kk + k1)
      n2 = corner_contribution_3d(x2, y2, z2, ii + i2, jj + j2, kk + k2)
      n3 = corner_contribution_3d(x3, y3, z3, ii + 1, jj + 1, kk + 1)

      # Scale to [-1, 1] range
      32.0 * (n0 + n1 + n2 + n3)
    end

    # Generate multi-octave 2D noise (fractal Brownian motion)
    #
    # @param x [Float] X coordinate
    # @param y [Float] Y coordinate
    # @param octaves [Integer] Number of noise layers (default: 4)
    # @param persistence [Float] Amplitude multiplier per octave (default: 0.5)
    # @param lacunarity [Float] Frequency multiplier per octave (default: 2.0)
    # @return [Float] Combined noise value
    def octave_noise2d(x, y, octaves: 4, persistence: 0.5, lacunarity: 2.0)
      total = 0.0
      frequency = 1.0
      amplitude = 1.0
      max_value = 0.0

      octaves.times do
        total += noise2d(x * frequency, y * frequency) * amplitude
        max_value += amplitude
        amplitude *= persistence
        frequency *= lacunarity
      end

      total / max_value
    end

    # Generate multi-octave 3D noise (fractal Brownian motion)
    #
    # @param x [Float] X coordinate
    # @param y [Float] Y coordinate
    # @param z [Float] Z coordinate
    # @param octaves [Integer] Number of noise layers (default: 4)
    # @param persistence [Float] Amplitude multiplier per octave (default: 0.5)
    # @param lacunarity [Float] Frequency multiplier per octave (default: 2.0)
    # @return [Float] Combined noise value
    def octave_noise3d(x, y, z, octaves: 4, persistence: 0.5, lacunarity: 2.0)
      total = 0.0
      frequency = 1.0
      amplitude = 1.0
      max_value = 0.0

      octaves.times do
        total += noise3d(x * frequency, y * frequency, z * frequency) * amplitude
        max_value += amplitude
        amplitude *= persistence
        frequency *= lacunarity
      end

      total / max_value
    end

    private

    # Build a seeded permutation table for hash lookups
    def build_permutation_table(seed)
      rng = Random.new(seed)
      base = (0...256).to_a.shuffle(random: rng)
      # Double the table to avoid index wrapping
      (base + base).freeze
    end

    # Calculate corner contribution for 2D noise
    def corner_contribution_2d(x, y, i, j)
      t = 0.5 - x * x - y * y
      return 0.0 if t < 0

      gi = @perm[(@perm[i & 255] + j) & 255] % 8
      grad = GRAD2[gi]
      t * t * t * t * (grad[0] * x + grad[1] * y)
    end

    # Calculate corner contribution for 3D noise
    def corner_contribution_3d(x, y, z, i, j, k)
      t = 0.6 - x * x - y * y - z * z
      return 0.0 if t < 0

      gi = @perm[(@perm[(@perm[i & 255] + j) & 255] + k) & 255] % 12
      grad = GRAD3[gi]
      t * t * t * t * (grad[0] * x + grad[1] * y + grad[2] * z)
    end

    # Determine simplex traversal order in 3D based on magnitude comparison
    def simplex_order_3d(x0, y0, z0)
      if x0 >= y0
        if y0 >= z0
          [1, 0, 0, 1, 1, 0]
        elsif x0 >= z0
          [1, 0, 0, 1, 0, 1]
        else
          [0, 0, 1, 1, 0, 1]
        end
      else
        if y0 < z0
          [0, 0, 1, 0, 1, 1]
        elsif x0 < z0
          [0, 1, 0, 0, 1, 1]
        else
          [0, 1, 0, 1, 1, 0]
        end
      end
    end
  end
end
