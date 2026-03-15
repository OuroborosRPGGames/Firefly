# frozen_string_literal: true

# Shared vector math utilities for battle map generation services.
module VectorMathHelper
  # Compute the centroid (element-wise average) of an array of vectors.
  # Returns a zero vector of dimension 6 when input is empty.
  def vector_centroid(vectors)
    return Array.new(6, 0.0) if vectors.empty?

    dim = vectors.first.length
    sums = Array.new(dim, 0.0)
    vectors.each { |v| dim.times { |i| sums[i] += v[i] } }
    sums.map { |s| s / vectors.length.to_f }
  end

  # Compute Euclidean distance between two equal-length numeric vectors.
  def vector_distance(a, b)
    Math.sqrt(a.zip(b).map { |ai, bi| (ai - bi)**2 }.sum)
  end
end
