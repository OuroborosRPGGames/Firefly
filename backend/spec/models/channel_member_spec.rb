# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ChannelMember do
  describe 'constants' do
    it 'defines ROLES' do
      expect(described_class::ROLES).to eq(%w[member moderator admin owner])
    end
  end

  describe 'associations' do
    it 'belongs to channel' do
      expect(described_class.association_reflections[:channel]).not_to be_nil
    end

    it 'belongs to character' do
      expect(described_class.association_reflections[:character]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines moderator?' do
      expect(described_class.instance_methods).to include(:moderator?)
    end

    it 'defines admin?' do
      expect(described_class.instance_methods).to include(:admin?)
    end

    it 'defines owner?' do
      expect(described_class.instance_methods).to include(:owner?)
    end

    it 'defines mute!' do
      expect(described_class.instance_methods).to include(:mute!)
    end

    it 'defines unmute!' do
      expect(described_class.instance_methods).to include(:unmute!)
    end

    it 'defines can_speak?' do
      expect(described_class.instance_methods).to include(:can_speak?)
    end
  end

  describe '#moderator? behavior' do
    it 'returns true for moderator role' do
      member = described_class.new
      member.values[:role] = 'moderator'
      expect(member.moderator?).to be true
    end

    it 'returns true for admin role' do
      member = described_class.new
      member.values[:role] = 'admin'
      expect(member.moderator?).to be true
    end

    it 'returns true for owner role' do
      member = described_class.new
      member.values[:role] = 'owner'
      expect(member.moderator?).to be true
    end

    it 'returns false for member role' do
      member = described_class.new
      member.values[:role] = 'member'
      expect(member.moderator?).to be false
    end
  end

  describe '#admin? behavior' do
    it 'returns true for admin role' do
      member = described_class.new
      member.values[:role] = 'admin'
      expect(member.admin?).to be true
    end

    it 'returns true for owner role' do
      member = described_class.new
      member.values[:role] = 'owner'
      expect(member.admin?).to be true
    end

    it 'returns false for moderator role' do
      member = described_class.new
      member.values[:role] = 'moderator'
      expect(member.admin?).to be false
    end
  end

  describe '#owner? behavior' do
    it 'returns true for owner role' do
      member = described_class.new
      member.values[:role] = 'owner'
      expect(member.owner?).to be true
    end

    it 'returns false for admin role' do
      member = described_class.new
      member.values[:role] = 'admin'
      expect(member.owner?).to be false
    end
  end

  describe '#can_speak? behavior' do
    it 'returns true when not muted' do
      member = described_class.new
      member.values[:is_muted] = false
      expect(member.can_speak?).to be true
    end

    it 'returns false when muted' do
      member = described_class.new
      member.values[:is_muted] = true
      expect(member.can_speak?).to be false
    end
  end
end
