# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VisibilityContext do
  let(:reality) { create(:reality) }
  let(:reality_b) { create(:reality, name: 'Secondary Reality') }

  describe '.from_character_instance' do
    let(:character_instance) { create(:character_instance, reality: reality) }

    it 'extracts reality_id from character instance' do
      context = described_class.from_character_instance(character_instance)

      expect(context.reality_id).to eq(reality.id)
    end

    it 'extracts timeline_id from character instance' do
      # Timeline is optional, test with nil first
      context = described_class.from_character_instance(character_instance)
      expect(context.timeline_id).to be_nil
    end

    it 'extracts private_mode from character instance' do
      ci_private = create(:character_instance, reality: reality, private_mode: true)
      context = described_class.from_character_instance(ci_private)

      expect(context.private_mode).to be true
    end

    it 'extracts invisible from character instance' do
      ci_invisible = create(:character_instance, reality: reality, invisible: true)
      context = described_class.from_character_instance(ci_invisible)

      expect(context.invisible).to be true
    end
  end

  describe '#to_h' do
    it 'returns hash representation for JSON serialization' do
      context = described_class.new(
        reality_id: 1,
        timeline_id: 2,
        private_mode: true,
        invisible: false
      )

      expect(context.to_h).to eq({
        reality_id: 1,
        timeline_id: 2,
        private_mode: true,
        invisible: false,
        flashback_instanced: false,
        flashback_co_travelers: [],
        character_instance_id: nil,
        in_event_id: nil
      })
    end
  end

  describe '#can_see?' do
    context 'same reality, same timeline (both nil)' do
      let(:sender_context) { described_class.new(reality_id: reality.id, timeline_id: nil) }
      let(:viewer_context) { described_class.new(reality_id: reality.id, timeline_id: nil) }

      it 'returns true' do
        expect(viewer_context.can_see?(sender_context)).to be true
      end
    end

    context 'different realities' do
      let(:sender_context) { described_class.new(reality_id: reality.id) }
      let(:viewer_context) { described_class.new(reality_id: reality_b.id) }

      it 'returns false' do
        expect(viewer_context.can_see?(sender_context)).to be false
      end
    end

    context 'same reality, different timelines' do
      let(:sender_context) { described_class.new(reality_id: reality.id, timeline_id: 1) }
      let(:viewer_context) { described_class.new(reality_id: reality.id, timeline_id: 2) }

      it 'returns false' do
        expect(viewer_context.can_see?(sender_context)).to be false
      end
    end

    context 'same reality, one in timeline, one not' do
      it 'returns false when sender in timeline, viewer not' do
        sender = described_class.new(reality_id: reality.id, timeline_id: 1)
        viewer = described_class.new(reality_id: reality.id, timeline_id: nil)

        expect(viewer.can_see?(sender)).to be false
      end

      it 'returns false when viewer in timeline, sender not' do
        sender = described_class.new(reality_id: reality.id, timeline_id: nil)
        viewer = described_class.new(reality_id: reality.id, timeline_id: 1)

        expect(viewer.can_see?(sender)).to be false
      end
    end

    context 'same reality, same timeline (both non-nil)' do
      let(:sender_context) { described_class.new(reality_id: reality.id, timeline_id: 1) }
      let(:viewer_context) { described_class.new(reality_id: reality.id, timeline_id: 1) }

      it 'returns true' do
        expect(viewer_context.can_see?(sender_context)).to be true
      end
    end

    context 'invisible sender' do
      let(:sender_context) { described_class.new(reality_id: reality.id, invisible: true) }
      let(:viewer_context) { described_class.new(reality_id: reality.id) }

      it 'returns false for non-staff viewers' do
        expect(viewer_context.can_see?(sender_context)).to be false
      end

      it 'returns true for staff with vision enabled' do
        expect(viewer_context.can_see?(sender_context, viewer_staff_vision: true)).to be true
      end
    end

    context 'staff vision' do
      it 'bypasses reality check' do
        sender = described_class.new(reality_id: reality.id)
        viewer = described_class.new(reality_id: reality_b.id)

        expect(viewer.can_see?(sender, viewer_staff_vision: true)).to be true
      end

      it 'bypasses timeline check' do
        sender = described_class.new(reality_id: reality.id, timeline_id: 1)
        viewer = described_class.new(reality_id: reality.id, timeline_id: 2)

        expect(viewer.can_see?(sender, viewer_staff_vision: true)).to be true
      end

      it 'bypasses invisibility check' do
        sender = described_class.new(reality_id: reality.id, invisible: true)
        viewer = described_class.new(reality_id: reality.id)

        expect(viewer.can_see?(sender, viewer_staff_vision: true)).to be true
      end
    end

    context 'private mode' do
      let(:sender_context) { described_class.new(reality_id: reality.id, private_mode: true) }
      let(:viewer_context) { described_class.new(reality_id: reality.id) }

      it 'allows normal viewers to see' do
        expect(viewer_context.can_see?(sender_context)).to be true
      end

      it 'blocks staff vision (content consent)' do
        expect(viewer_context.can_see?(sender_context, viewer_staff_vision: true)).to be false
      end
    end
  end

  describe '#same_context?' do
    it 'returns true for matching reality and timeline' do
      ctx1 = described_class.new(reality_id: 1, timeline_id: 2)
      ctx2 = described_class.new(reality_id: 1, timeline_id: 2)

      expect(ctx1.same_context?(ctx2)).to be true
    end

    it 'returns false for different realities' do
      ctx1 = described_class.new(reality_id: 1, timeline_id: nil)
      ctx2 = described_class.new(reality_id: 2, timeline_id: nil)

      expect(ctx1.same_context?(ctx2)).to be false
    end

    it 'returns false for different timelines' do
      ctx1 = described_class.new(reality_id: 1, timeline_id: 1)
      ctx2 = described_class.new(reality_id: 1, timeline_id: 2)

      expect(ctx1.same_context?(ctx2)).to be false
    end

    it 'ignores invisible and private_mode' do
      ctx1 = described_class.new(reality_id: 1, invisible: true, private_mode: true)
      ctx2 = described_class.new(reality_id: 1, invisible: false, private_mode: false)

      expect(ctx1.same_context?(ctx2)).to be true
    end
  end
end
