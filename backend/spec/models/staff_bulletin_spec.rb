# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StaffBulletin do
  describe 'associations' do
    it 'belongs to created_by_user' do
      expect(described_class.association_reflections[:created_by_user]).not_to be_nil
    end

    it 'has many staff_bulletin_reads' do
      expect(described_class.association_reflections[:staff_bulletin_reads]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'defines NEWS_TYPES' do
      expect(described_class::NEWS_TYPES).to include('announcement', 'ic', 'ooc')
    end
  end

  describe 'instance methods' do
    it 'defines type_display' do
      expect(described_class.instance_methods).to include(:type_display)
    end

    it 'defines type_badge_class' do
      expect(described_class.instance_methods).to include(:type_badge_class)
    end

    it 'defines read_by?' do
      expect(described_class.instance_methods).to include(:read_by?)
    end

    it 'defines mark_read_by!' do
      expect(described_class.instance_methods).to include(:mark_read_by!)
    end

    it 'defines to_hash' do
      expect(described_class.instance_methods).to include(:to_hash)
    end
  end

  describe 'class methods' do
    it 'defines unread_counts_for' do
      expect(described_class).to respond_to(:unread_counts_for)
    end

    it 'defines total_unread_for' do
      expect(described_class).to respond_to(:total_unread_for)
    end
  end

  describe 'dataset methods' do
    it 'has published scope' do
      expect(described_class.dataset).to respond_to(:published)
    end

    it 'has by_type scope' do
      expect(described_class.dataset).to respond_to(:by_type)
    end

    it 'has recent scope' do
      expect(described_class.dataset).to respond_to(:recent)
    end
  end

  describe '#type_display behavior' do
    it 'returns Announcement for announcement type' do
      bulletin = described_class.new
      bulletin.values[:news_type] = 'announcement'
      expect(bulletin.type_display).to eq('Announcement')
    end

    it 'returns IC News for ic type' do
      bulletin = described_class.new
      bulletin.values[:news_type] = 'ic'
      expect(bulletin.type_display).to eq('IC News')
    end

    it 'returns OOC News for ooc type' do
      bulletin = described_class.new
      bulletin.values[:news_type] = 'ooc'
      expect(bulletin.type_display).to eq('OOC News')
    end
  end
end
