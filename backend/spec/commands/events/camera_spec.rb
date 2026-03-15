# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::Camera do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }
  let(:target_character) { create_test_character(forename: 'Alice') }
  let(:target_instance) { create_test_character_instance(character: target_character, room: room, reality: reality, online: true) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'without a target name' do
      it 'returns an error' do
        result = subject.execute('camera')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Spotlight whom")
      end
    end

    context 'when not hosting or staffing an event' do
      it 'returns an error' do
        result = subject.execute('camera Alice')
        expect(result[:success]).to be false
        expect(result[:error]).to include("not hosting or staffing")
      end
    end

    context 'when hosting an active event' do
      let!(:event) do
        Event.create(
          name: 'Test Event',
          title: 'Test Event',
          organizer_id: character.id,
          status: 'active',
          room_id: room.id,
          event_type: 'party',
          starts_at: Time.now
        )
      end

      context 'and target is in the room' do
        before { target_instance }

        it 'toggles spotlight on the target' do
          expect(target_instance.spotlighted?).to be false
          result = subject.execute('camera Alice')
          expect(result[:success]).to be true
          expect(result[:message]).to include("spotlight")
          expect(result[:message]).to include("Alice")
          target_instance.reload
          expect(target_instance.spotlighted?).to be true
        end

        it 'can toggle spotlight off' do
          target_instance.spotlight_on!
          result = subject.execute('camera Alice')
          expect(result[:success]).to be true
          expect(result[:message]).to include("away from")
          target_instance.reload
          expect(target_instance.spotlighted?).to be false
        end

        context 'with count argument' do
          it 'sets spotlight with remaining count' do
            result = subject.execute('spotlight Alice 3')
            expect(result[:success]).to be true
            expect(result[:message]).to include('3 emotes')
            target_instance.reload
            expect(target_instance.spotlighted?).to be true
            expect(target_instance.spotlight_remaining).to eq(3)
          end

          it 'decrements count after each emote' do
            target_instance.spotlight_on!(count: 3)
            expect(target_instance.spotlight_remaining).to eq(3)

            target_instance.decrement_spotlight!
            target_instance.reload
            expect(target_instance.spotlight_remaining).to eq(2)
            expect(target_instance.spotlighted?).to be true
          end

          it 'turns off spotlight when count reaches zero' do
            target_instance.spotlight_on!(count: 1)
            target_instance.decrement_spotlight!
            target_instance.reload
            expect(target_instance.spotlighted?).to be false
            expect(target_instance.spotlight_remaining).to be_nil
          end

          it 'overrides existing spotlight with new count' do
            target_instance.spotlight_on!
            result = subject.execute('spotlight Alice 5')
            expect(result[:success]).to be true
            target_instance.reload
            expect(target_instance.spotlight_remaining).to eq(5)
          end
        end
      end

      context 'and target is not in the room' do
        it 'returns an error' do
          result = subject.execute('camera Unknown')
          expect(result[:success]).to be false
          expect(result[:error]).to include("not here")
        end
      end
    end
  end
end
