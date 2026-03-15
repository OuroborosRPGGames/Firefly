# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RouteHelpers do
  # Create a test class that includes the helpers
  let(:helper) do
    Class.new do
      include RouteHelpers

      # Stub render for partial tests
      def render(path, locals: {})
        "[rendered: #{path}]"
      end
    end.new
  end

  describe '#partial' do
    it 'converts template path to partial path' do
      # partial('admin/sidebar') should render 'admin/_sidebar'
      result = helper.partial('admin/sidebar')
      expect(result).to eq('[rendered: admin/_sidebar]')
    end

    it 'handles templates without directory' do
      result = helper.partial('footer')
      expect(result).to eq('[rendered: _footer]')
    end

    it 'handles nested paths' do
      result = helper.partial('admin/users/form')
      expect(result).to eq('[rendered: admin/users/_form]')
    end
  end

  describe '#activity_icon' do
    it 'returns compass for mission' do
      expect(helper.activity_icon('mission')).to eq('compass')
    end

    it 'returns trophy for competition' do
      expect(helper.activity_icon('competition')).to eq('trophy')
    end

    it 'returns people for tcompetition' do
      expect(helper.activity_icon('tcompetition')).to eq('people')
    end

    it 'returns check2-square for task' do
      expect(helper.activity_icon('task')).to eq('check2-square')
    end

    it 'returns crosshair for elimination' do
      expect(helper.activity_icon('elimination')).to eq('crosshair')
    end

    it 'returns chat-heart for intersym' do
      expect(helper.activity_icon('intersym')).to eq('chat-heart')
    end

    it 'returns chat-heart for interasym' do
      expect(helper.activity_icon('interasym')).to eq('chat-heart')
    end

    it 'returns journal-text for unknown types' do
      expect(helper.activity_icon('unknown')).to eq('journal-text')
      expect(helper.activity_icon(nil)).to eq('journal-text')
    end
  end

  describe '#activity_badge_color' do
    it 'returns primary for mission' do
      expect(helper.activity_badge_color('mission')).to eq('primary')
    end

    it 'returns warning for competition' do
      expect(helper.activity_badge_color('competition')).to eq('warning')
    end

    it 'returns warning for tcompetition' do
      expect(helper.activity_badge_color('tcompetition')).to eq('warning')
    end

    it 'returns info for task' do
      expect(helper.activity_badge_color('task')).to eq('info')
    end

    it 'returns danger for elimination' do
      expect(helper.activity_badge_color('elimination')).to eq('danger')
    end

    it 'returns pink for intersym' do
      expect(helper.activity_badge_color('intersym')).to eq('pink')
    end

    it 'returns pink for interasym' do
      expect(helper.activity_badge_color('interasym')).to eq('pink')
    end

    it 'returns secondary for unknown types' do
      expect(helper.activity_badge_color('unknown')).to eq('secondary')
      expect(helper.activity_badge_color(nil)).to eq('secondary')
    end
  end

  describe '#round_type_icon' do
    it 'returns play-circle for standard' do
      expect(helper.round_type_icon('standard')).to eq('play-circle')
    end

    it 'returns sword for combat' do
      expect(helper.round_type_icon('combat')).to eq('sword')
    end

    it 'returns signpost-split for branch' do
      expect(helper.round_type_icon('branch')).to eq('signpost-split')
    end

    it 'returns lightning for reflex' do
      expect(helper.round_type_icon('reflex')).to eq('lightning')
    end

    it 'returns people for group_check' do
      expect(helper.round_type_icon('group_check')).to eq('people')
    end

    it 'returns dice-6 for free_roll' do
      expect(helper.round_type_icon('free_roll')).to eq('dice-6')
    end

    it 'returns chat-heart for persuade' do
      expect(helper.round_type_icon('persuade')).to eq('chat-heart')
    end

    it 'returns cup-hot for rest' do
      expect(helper.round_type_icon('rest')).to eq('cup-hot')
    end

    it 'returns pause-circle for break' do
      expect(helper.round_type_icon('break')).to eq('pause-circle')
    end

    it 'returns circle for unknown types' do
      expect(helper.round_type_icon('unknown')).to eq('circle')
      expect(helper.round_type_icon(nil)).to eq('circle')
    end
  end

  describe '#round_type_color' do
    it 'returns primary for standard' do
      expect(helper.round_type_color('standard')).to eq('primary')
    end

    it 'returns danger for combat' do
      expect(helper.round_type_color('combat')).to eq('danger')
    end

    it 'returns purple for branch' do
      expect(helper.round_type_color('branch')).to eq('purple')
    end

    it 'returns warning for reflex' do
      expect(helper.round_type_color('reflex')).to eq('warning')
    end

    it 'returns success for group_check' do
      expect(helper.round_type_color('group_check')).to eq('success')
    end

    it 'returns info for free_roll' do
      expect(helper.round_type_color('free_roll')).to eq('info')
    end

    it 'returns pink for persuade' do
      expect(helper.round_type_color('persuade')).to eq('pink')
    end

    it 'returns success for rest' do
      expect(helper.round_type_color('rest')).to eq('success')
    end

    it 'returns secondary for break' do
      expect(helper.round_type_color('break')).to eq('secondary')
    end

    it 'returns light for unknown types' do
      expect(helper.round_type_color('unknown')).to eq('light')
      expect(helper.round_type_color(nil)).to eq('light')
    end
  end
end
