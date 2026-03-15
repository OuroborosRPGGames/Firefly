# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VisibilityFilterService do
  let(:reality) { create(:reality) }
  let(:reality_b) { create(:reality, name: 'Secondary Reality') }
  let(:room) { create(:room) }
  let(:room_b) { create(:room, location: room.location) }

  describe '.should_deliver?' do
    let(:sender_instance) { create(:character_instance, reality: reality, current_room: room) }
    let(:viewer_instance) { create(:character_instance, reality: reality, current_room: room) }

    it 'returns true for nil viewer' do
      payload = { visibility_context: { reality_id: reality.id } }
      expect(described_class.should_deliver?(payload, nil)).to be true
    end

    it 'returns true for payload without visibility_context' do
      payload = { type: :system, message: 'Hello' }
      expect(described_class.should_deliver?(payload, viewer_instance)).to be true
    end

    context 'with visibility_context' do
      it 'returns true when viewer can see sender (same reality)' do
        payload = {
          visibility_context: {
            reality_id: reality.id,
            timeline_id: nil,
            private_mode: false,
            invisible: false
          }
        }

        expect(described_class.should_deliver?(payload, viewer_instance)).to be true
      end

      it 'returns false when viewer cannot see sender (different reality)' do
        viewer_in_other_reality = create(:character_instance, reality: reality_b, current_room: room)

        payload = {
          visibility_context: {
            reality_id: reality.id,
            timeline_id: nil,
            private_mode: false,
            invisible: false
          }
        }

        expect(described_class.should_deliver?(payload, viewer_in_other_reality)).to be false
      end

      it 'returns false when sender is invisible (for non-staff)' do
        payload = {
          visibility_context: {
            reality_id: reality.id,
            invisible: true
          }
        }

        expect(described_class.should_deliver?(payload, viewer_instance)).to be false
      end

      it 'handles string keys in visibility_context' do
        payload = {
          'visibility_context' => {
            'reality_id' => reality.id,
            'timeline_id' => nil
          }
        }

        expect(described_class.should_deliver?(payload, viewer_instance)).to be true
      end
    end
  end

  describe '.eligible_recipients_in_room' do
    context 'with no sender (system message)' do
      it 'returns all online characters in the room' do
        ci_a = create(:character_instance, reality: reality, current_room: room)
        ci_b = create(:character_instance, reality: reality_b, current_room: room)

        recipients = described_class.eligible_recipients_in_room(room.id, nil)

        expect(recipients).to include(ci_a, ci_b)
      end

      it 'respects exclude list' do
        ci_a = create(:character_instance, reality: reality, current_room: room)
        ci_b = create(:character_instance, reality: reality, current_room: room)

        recipients = described_class.eligible_recipients_in_room(room.id, nil, exclude: [ci_a.id])

        expect(recipients).not_to include(ci_a)
        expect(recipients).to include(ci_b)
      end

      it 'excludes offline characters' do
        ci_online = create(:character_instance, reality: reality, current_room: room, online: true)
        ci_offline = create(:character_instance, reality: reality, current_room: room, online: false)

        recipients = described_class.eligible_recipients_in_room(room.id, nil)

        expect(recipients).to include(ci_online)
        expect(recipients).not_to include(ci_offline)
      end
    end

    context 'with sender' do
      it 'filters to same reality' do
        sender = create(:character_instance, reality: reality, current_room: room)
        recipient_same = create(:character_instance, reality: reality, current_room: room)
        recipient_diff = create(:character_instance, reality: reality_b, current_room: room)

        recipients = described_class.eligible_recipients_in_room(room.id, sender)

        expect(recipients).to include(recipient_same)
        expect(recipients).not_to include(recipient_diff)
      end

      it 'includes sender if not excluded' do
        sender = create(:character_instance, reality: reality, current_room: room)

        recipients = described_class.eligible_recipients_in_room(room.id, sender)

        expect(recipients).to include(sender)
      end
    end

    context 'with invisible sender' do
      it 'only includes staff with vision enabled' do
        sender = create(:character_instance, reality: reality, current_room: room, invisible: true)
        staff_viewer = create(:character_instance, reality: reality, current_room: room, staff_vision_enabled: true)
        normal_viewer = create(:character_instance, reality: reality, current_room: room, staff_vision_enabled: false)

        recipients = described_class.eligible_recipients_in_room(room.id, sender)

        expect(recipients).to include(staff_viewer)
        expect(recipients).not_to include(normal_viewer)
      end
    end
  end

  describe '.eligible_recipients_in_zone' do
    it 'returns instance IDs for online characters in zone' do
      ci_in_zone = create(:character_instance, reality: reality, current_room: room)
      ci_in_zone_b = create(:character_instance, reality: reality, current_room: room_b)

      recipient_ids = described_class.eligible_recipients_in_zone(room.location.zone.id, nil)

      expect(recipient_ids).to include(ci_in_zone.id, ci_in_zone_b.id)
    end

    it 'filters by visibility context when sender provided' do
      sender = create(:character_instance, reality: reality, current_room: room)
      recipient_same = create(:character_instance, reality: reality, current_room: room_b)
      recipient_diff = create(:character_instance, reality: reality_b, current_room: room_b)

      recipient_ids = described_class.eligible_recipients_in_zone(room.location.zone.id, sender)

      expect(recipient_ids).to include(recipient_same.id)
      expect(recipient_ids).not_to include(recipient_diff.id)
    end
  end

  describe '.eligible_recipients_global' do
    it 'returns instance IDs for all online characters' do
      ci_a = create(:character_instance, reality: reality, current_room: room)
      ci_b = create(:character_instance, reality: reality_b, current_room: room_b)

      recipient_ids = described_class.eligible_recipients_global(nil)

      expect(recipient_ids).to include(ci_a.id, ci_b.id)
    end

    it 'filters by visibility context when sender provided' do
      sender = create(:character_instance, reality: reality, current_room: room)
      recipient_same = create(:character_instance, reality: reality, current_room: room_b)
      recipient_diff = create(:character_instance, reality: reality_b, current_room: room)

      recipient_ids = described_class.eligible_recipients_global(sender)

      expect(recipient_ids).to include(recipient_same.id)
      expect(recipient_ids).not_to include(recipient_diff.id)
    end
  end

  describe '.visible_to' do
    it 'filters instances to those visible to viewer' do
      viewer = create(:character_instance, reality: reality, current_room: room)
      visible_instance = create(:character_instance, reality: reality, current_room: room)
      invisible_instance = create(:character_instance, reality: reality_b, current_room: room)

      result = described_class.visible_to([visible_instance, invisible_instance], viewer)

      expect(result).to include(visible_instance)
      expect(result).not_to include(invisible_instance)
    end

    it 'returns all instances when viewer is nil' do
      ci_a = create(:character_instance, reality: reality, current_room: room)
      ci_b = create(:character_instance, reality: reality_b, current_room: room)

      result = described_class.visible_to([ci_a, ci_b], nil)

      expect(result).to include(ci_a, ci_b)
    end
  end
end
