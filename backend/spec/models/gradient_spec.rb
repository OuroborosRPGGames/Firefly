# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Gradient do
  describe 'validations' do
    it 'requires a name' do
      gradient = Gradient.new(colors: ['#ff0000', '#0000ff'])
      expect(gradient.valid?).to be false
      expect(gradient.errors[:name]).not_to be_empty
    end

    it 'requires at least 2 colors' do
      gradient = Gradient.new(name: 'Test', colors: ['#ff0000'])
      expect(gradient.valid?).to be false
      expect(gradient.errors[:colors]).to include('must have at least 2 colors')
    end

    it 'validates hex color format' do
      gradient = Gradient.new(name: 'Test', colors: ['red', 'blue'])
      expect(gradient.valid?).to be false
      expect(gradient.errors[:colors]).to include('color 1 must be a valid hex color (e.g., #FF0000)')
    end

    it 'is valid with proper colors' do
      gradient = Gradient.new(name: 'Test', colors: ['#ff0000', '#0000ff'])
      expect(gradient.valid?).to be true
    end
  end

  describe '#to_api_hash' do
    it 'returns the expected structure' do
      gradient = Gradient.create(name: 'Rainbow', colors: ['#ff0000', '#00ff00', '#0000ff'])
      hash = gradient.to_api_hash

      expect(hash[:id]).to eq(gradient.id)
      expect(hash[:name]).to eq('Rainbow')
      expect(hash[:colors]).to eq(['#ff0000', '#00ff00', '#0000ff'])
      expect(hash[:easings]).to eq([])
      expect(hash[:interpolation]).to eq('ciede2000')
    end
  end

  describe '#record_use!' do
    it 'increments use_count and sets last_used_at' do
      gradient = Gradient.create(name: 'Test', colors: ['#ff0000', '#0000ff'])
      expect(gradient.use_count).to eq(0)
      expect(gradient.last_used_at).to be_nil

      gradient.record_use!
      gradient.refresh

      expect(gradient.use_count).to eq(1)
      expect(gradient.last_used_at).not_to be_nil
    end
  end

  describe '.for_user' do
    let!(:user) { User.create(username: 'testuser', password: 'test1234', email: 'test@example.com') }
    let!(:other_user) { User.create(username: 'other', password: 'test1234', email: 'other@example.com') }
    let!(:user_gradient) { Gradient.create(name: 'UserGrad', colors: ['#ff0000', '#0000ff'], user_id: user.id) }
    let!(:other_gradient) { Gradient.create(name: 'OtherGrad', colors: ['#00ff00', '#ffff00'], user_id: other_user.id) }
    let!(:shared_gradient) { Gradient.create(name: 'Shared', colors: ['#ffffff', '#000000'], user_id: nil) }

    it 'returns only gradients for the specified user' do
      result = Gradient.for_user(user.id)
      expect(result.map(&:id)).to include(user_gradient.id)
      expect(result.map(&:id)).not_to include(other_gradient.id)
      expect(result.map(&:id)).not_to include(shared_gradient.id)
    end
  end

  describe '.shared' do
    let!(:user) { User.create(username: 'testuser2', password: 'test1234', email: 'test2@example.com') }
    let!(:user_gradient) { Gradient.create(name: 'Private', colors: ['#ff0000', '#0000ff'], user_id: user.id) }
    let!(:shared_gradient) { Gradient.create(name: 'Shared', colors: ['#ffffff', '#000000'], user_id: nil) }

    it 'returns only shared gradients' do
      result = Gradient.shared
      expect(result.map(&:id)).to include(shared_gradient.id)
      expect(result.map(&:id)).not_to include(user_gradient.id)
    end
  end
end
