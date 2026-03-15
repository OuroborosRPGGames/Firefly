# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldGeneration::NoiseGenerator do
  let(:seed) { 12345 }
  let(:generator) { described_class.new(seed: seed) }

  describe '#initialize' do
    it 'accepts a seed parameter' do
      expect { described_class.new(seed: 42) }.not_to raise_error
    end

    it 'uses a default seed if none provided' do
      gen = described_class.new
      expect(gen).to be_a(described_class)
    end
  end

  describe 'seed reproducibility' do
    it 'produces identical noise2d output for the same seed' do
      gen1 = described_class.new(seed: seed)
      gen2 = described_class.new(seed: seed)

      10.times do
        x = rand * 100
        y = rand * 100
        expect(gen1.noise2d(x, y)).to eq(gen2.noise2d(x, y))
      end
    end

    it 'produces identical noise3d output for the same seed' do
      gen1 = described_class.new(seed: seed)
      gen2 = described_class.new(seed: seed)

      10.times do
        x = rand * 100
        y = rand * 100
        z = rand * 100
        expect(gen1.noise3d(x, y, z)).to eq(gen2.noise3d(x, y, z))
      end
    end

    it 'produces different output for different seeds' do
      gen1 = described_class.new(seed: 1)
      gen2 = described_class.new(seed: 2)

      # Sample multiple points - they should differ
      differences = 0
      20.times do
        x = rand * 100
        y = rand * 100
        differences += 1 if gen1.noise2d(x, y) != gen2.noise2d(x, y)
      end

      expect(differences).to be > 15 # Most should differ
    end
  end

  describe '#noise2d' do
    it 'returns values between -1.0 and 1.0' do
      100.times do
        x = rand * 1000 - 500
        y = rand * 1000 - 500
        value = generator.noise2d(x, y)
        expect(value).to be_between(-1.0, 1.0)
      end
    end

    it 'returns Float values' do
      expect(generator.noise2d(0.0, 0.0)).to be_a(Float)
    end

    it 'handles negative coordinates' do
      value = generator.noise2d(-50.5, -30.3)
      expect(value).to be_between(-1.0, 1.0)
    end

    it 'handles large coordinates' do
      value = generator.noise2d(10000.0, 10000.0)
      expect(value).to be_between(-1.0, 1.0)
    end

    it 'produces smooth gradients (nearby points have similar values)' do
      base_value = generator.noise2d(10.0, 10.0)
      nearby_value = generator.noise2d(10.001, 10.001)

      # Very close points should have very similar values
      expect((base_value - nearby_value).abs).to be < 0.01
    end
  end

  describe '#noise3d' do
    it 'returns values between -1.0 and 1.0' do
      100.times do
        x = rand * 1000 - 500
        y = rand * 1000 - 500
        z = rand * 1000 - 500
        value = generator.noise3d(x, y, z)
        expect(value).to be_between(-1.0, 1.0)
      end
    end

    it 'returns Float values' do
      expect(generator.noise3d(0.0, 0.0, 0.0)).to be_a(Float)
    end

    it 'handles negative coordinates' do
      value = generator.noise3d(-50.5, -30.3, -20.1)
      expect(value).to be_between(-1.0, 1.0)
    end

    it 'produces smooth gradients (nearby points have similar values)' do
      base_value = generator.noise3d(10.0, 10.0, 10.0)
      nearby_value = generator.noise3d(10.001, 10.001, 10.001)

      expect((base_value - nearby_value).abs).to be < 0.01
    end

    it 'is useful for sphere surface noise' do
      # Sample points on a unit sphere
      values = []
      10.times do
        theta = rand * 2 * Math::PI
        phi = rand * Math::PI
        x = Math.sin(phi) * Math.cos(theta)
        y = Math.sin(phi) * Math.sin(theta)
        z = Math.cos(phi)
        values << generator.noise3d(x, y, z)
      end

      # All values should be in valid range
      values.each do |v|
        expect(v).to be_between(-1.0, 1.0)
      end
    end
  end

  describe '#octave_noise2d' do
    it 'returns values in a valid range' do
      value = generator.octave_noise2d(5.0, 5.0, octaves: 4, persistence: 0.5, lacunarity: 2.0)
      # Multi-octave noise can exceed -1 to 1, but should be bounded
      expect(value).to be_a(Float)
      expect(value.finite?).to be true
    end

    it 'produces more detailed noise with more octaves' do
      # More octaves = more variation at small scales
      low_octave = generator.octave_noise2d(5.0, 5.0, octaves: 1, persistence: 0.5, lacunarity: 2.0)
      high_octave = generator.octave_noise2d(5.0, 5.0, octaves: 6, persistence: 0.5, lacunarity: 2.0)

      # Values should differ due to additional detail
      expect(low_octave).not_to eq(high_octave)
    end

    it 'defaults octaves, persistence, and lacunarity' do
      expect { generator.octave_noise2d(5.0, 5.0) }.not_to raise_error
    end

    it 'respects persistence parameter' do
      # Lower persistence = less influence from higher octaves
      low_persist = generator.octave_noise2d(5.0, 5.0, octaves: 4, persistence: 0.25, lacunarity: 2.0)
      high_persist = generator.octave_noise2d(5.0, 5.0, octaves: 4, persistence: 0.75, lacunarity: 2.0)

      # They should be different
      expect(low_persist).not_to eq(high_persist)
    end

    it 'respects lacunarity parameter' do
      low_lacunarity = generator.octave_noise2d(5.0, 5.0, octaves: 4, persistence: 0.5, lacunarity: 1.5)
      high_lacunarity = generator.octave_noise2d(5.0, 5.0, octaves: 4, persistence: 0.5, lacunarity: 3.0)

      expect(low_lacunarity).not_to eq(high_lacunarity)
    end
  end

  describe '#octave_noise3d' do
    it 'returns values in a valid range' do
      value = generator.octave_noise3d(5.0, 5.0, 5.0, octaves: 4, persistence: 0.5, lacunarity: 2.0)
      expect(value).to be_a(Float)
      expect(value.finite?).to be true
    end

    it 'produces more detailed noise with more octaves' do
      # Use coordinates that produce non-zero base noise
      low_octave = generator.octave_noise3d(3.7, 2.1, 4.5, octaves: 1, persistence: 0.5, lacunarity: 2.0)
      high_octave = generator.octave_noise3d(3.7, 2.1, 4.5, octaves: 6, persistence: 0.5, lacunarity: 2.0)

      expect(low_octave).not_to eq(high_octave)
    end

    it 'defaults octaves, persistence, and lacunarity' do
      expect { generator.octave_noise3d(5.0, 5.0, 5.0) }.not_to raise_error
    end

    it 'is reproducible with the same seed' do
      gen1 = described_class.new(seed: seed)
      gen2 = described_class.new(seed: seed)

      value1 = gen1.octave_noise3d(5.0, 5.0, 5.0, octaves: 4, persistence: 0.5, lacunarity: 2.0)
      value2 = gen2.octave_noise3d(5.0, 5.0, 5.0, octaves: 4, persistence: 0.5, lacunarity: 2.0)

      expect(value1).to eq(value2)
    end
  end

  describe 'performance characteristics' do
    it 'can generate many samples quickly' do
      start_time = Time.now
      1000.times do |i|
        generator.noise2d(i * 0.1, i * 0.1)
      end
      elapsed = Time.now - start_time

      # Should generate 1000 samples in under 1 second
      expect(elapsed).to be < 1.0
    end
  end
end
