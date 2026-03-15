# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterSegmentInstance do
  let(:fight) { create(:fight) }
  let(:monster_template) { create(:monster_template) }
  let(:monster_instance) { create(:large_monster_instance, monster_template: monster_template, fight: fight) }
  let(:segment_template) do
    create(:monster_segment_template,
           monster_template: monster_template,
           name: 'Body',
           segment_type: 'body',
           hp_percent: 25,
           attacks_per_round: 2,
           hex_offset_x: 0,
           hex_offset_y: 0)
  end

  # Helper to create a valid segment instance
  def create_segment(attrs = {})
    seg = MonsterSegmentInstance.new
    seg.large_monster_instance = attrs[:monster_instance] || monster_instance
    seg.monster_segment_template = attrs[:monster_segment_template] || segment_template
    seg.current_hp = attrs[:current_hp] || 100
    seg.max_hp = attrs[:max_hp] || 100
    seg.status = attrs[:status] || 'healthy'
    seg.can_attack = attrs.key?(:can_attack) ? attrs[:can_attack] : true
    seg.attacks_remaining_this_round = attrs[:attacks_remaining_this_round] || 2
    seg.save
    seg
  end

  # Build without saving
  def build_segment(attrs = {})
    seg = MonsterSegmentInstance.new
    seg.large_monster_instance = attrs[:monster_instance] || monster_instance
    seg.monster_segment_template = attrs[:monster_segment_template] || segment_template
    seg.current_hp = attrs[:current_hp] || 100
    seg.max_hp = attrs[:max_hp] || 100
    seg.status = attrs[:status] if attrs[:status]
    seg.can_attack = attrs[:can_attack] if attrs.key?(:can_attack)
    seg.attacks_remaining_this_round = attrs[:attacks_remaining_this_round] if attrs[:attacks_remaining_this_round]
    seg
  end

  describe 'associations' do
    it 'belongs to monster_instance' do
      segment = create_segment
      expect(segment.large_monster_instance.id).to eq(monster_instance.id)
    end

    it 'belongs to monster_segment_template' do
      segment = create_segment
      expect(segment.monster_segment_template.id).to eq(segment_template.id)
    end
  end

  describe 'validations' do
    it 'requires large_monster_instance_id' do
      seg = MonsterSegmentInstance.new
      seg.monster_segment_template = segment_template
      seg.current_hp = 100
      seg.max_hp = 100
      expect(seg.valid?).to be false
      expect(seg.errors[:large_monster_instance_id]).not_to be_empty
    end

    it 'requires monster_segment_template_id' do
      seg = MonsterSegmentInstance.new
      seg.large_monster_instance = monster_instance
      seg.current_hp = 100
      seg.max_hp = 100
      expect(seg.valid?).to be false
      expect(seg.errors[:monster_segment_template_id]).not_to be_empty
    end

    it 'requires current_hp' do
      seg = MonsterSegmentInstance.new
      seg.large_monster_instance = monster_instance
      seg.monster_segment_template = segment_template
      seg.max_hp = 100
      expect(seg.valid?).to be false
      expect(seg.errors[:current_hp]).not_to be_empty
    end

    it 'requires max_hp' do
      seg = MonsterSegmentInstance.new
      seg.large_monster_instance = monster_instance
      seg.monster_segment_template = segment_template
      seg.current_hp = 100
      expect(seg.valid?).to be false
      expect(seg.errors[:max_hp]).not_to be_empty
    end

    it 'validates status is in STATUSES' do
      seg = build_segment(status: 'invalid')
      expect(seg.valid?).to be false
      expect(seg.errors[:status]).not_to be_empty
    end

    %w[healthy damaged broken destroyed].each do |status|
      it "accepts #{status} as status" do
        seg = build_segment(status: status)
        expect(seg.valid?).to be true
      end
    end
  end

  describe '#hp_percent' do
    let(:segment) { create_segment(current_hp: 50, max_hp: 100) }

    it 'returns the percentage of current HP' do
      expect(segment.hp_percent).to eq(50.0)
    end

    it 'returns 0 when max_hp is zero' do
      segment.update(max_hp: 0)
      expect(segment.hp_percent).to eq(0)
    end

    it 'rounds to one decimal place' do
      segment.update(current_hp: 33, max_hp: 100)
      expect(segment.hp_percent).to eq(33.0)
    end
  end

  describe '#update_status_from_hp!' do
    let(:segment) do
      create_segment(current_hp: 100, max_hp: 100, status: 'healthy', can_attack: true)
    end

    it 'sets status to healthy when HP > 50%' do
      segment.update(current_hp: 75)
      segment.update_status_from_hp!
      segment.refresh

      expect(segment.status).to eq('healthy')
      expect(segment.can_attack).to be true
    end

    it 'sets status to damaged when HP is 25-50%' do
      segment.update(current_hp: 40)
      segment.update_status_from_hp!
      segment.refresh

      expect(segment.status).to eq('damaged')
      expect(segment.can_attack).to be true
    end

    it 'sets status to broken when HP is 0.01-25%' do
      segment.update(current_hp: 10)
      segment.update_status_from_hp!
      segment.refresh

      expect(segment.status).to eq('broken')
      expect(segment.can_attack).to be true
    end

    it 'sets status to destroyed when HP is 0' do
      segment.update(current_hp: 0)
      segment.update_status_from_hp!
      segment.refresh

      expect(segment.status).to eq('destroyed')
      expect(segment.can_attack).to be false
    end
  end

  describe '#apply_damage!' do
    let(:segment) do
      create_segment(current_hp: 100, max_hp: 100, status: 'healthy', can_attack: true)
    end

    it 'reduces current_hp by damage amount' do
      segment.apply_damage!(30)
      segment.refresh

      expect(segment.current_hp).to eq(70)
    end

    it 'does not reduce HP below 0' do
      segment.apply_damage!(150)
      segment.refresh

      expect(segment.current_hp).to eq(0)
    end

    it 'updates status based on new HP' do
      segment.apply_damage!(90)
      segment.refresh

      expect(segment.status).to eq('broken')
    end

    it 'returns segment_hp_lost and new_status' do
      result = segment.apply_damage!(30)

      expect(result[:segment_hp_lost]).to eq(30)
      expect(result[:new_status]).to eq('healthy')
    end

    it 'correctly calculates segment_hp_lost when capped at 0' do
      result = segment.apply_damage!(150)

      expect(result[:segment_hp_lost]).to eq(100)
      expect(result[:new_status]).to eq('destroyed')
    end
  end

  describe '#can_attack_this_round?' do
    let(:segment) do
      create_segment(can_attack: true, attacks_remaining_this_round: 2)
    end

    it 'returns true when can_attack and attacks_remaining > 0' do
      expect(segment.can_attack_this_round?).to be true
    end

    it 'returns false when can_attack is false' do
      segment.update(can_attack: false)
      expect(segment.can_attack_this_round?).to be false
    end

    it 'returns false when attacks_remaining is 0' do
      segment.update(attacks_remaining_this_round: 0)
      expect(segment.can_attack_this_round?).to be false
    end

    it 'returns false when attacks_remaining is nil' do
      segment.update(attacks_remaining_this_round: nil)
      expect(segment.can_attack_this_round?).to be false
    end
  end

  describe '#use_attack!' do
    let(:segment) { create_segment(attacks_remaining_this_round: 2) }

    it 'decrements attacks_remaining_this_round' do
      segment.use_attack!
      segment.refresh

      expect(segment.attacks_remaining_this_round).to eq(1)
    end

    it 'does not go below 0' do
      segment.update(attacks_remaining_this_round: 0)
      segment.use_attack!
      segment.refresh

      expect(segment.attacks_remaining_this_round).to eq(0)
    end
  end

  describe '#record_attack!' do
    let(:segment) { create_segment(attacks_remaining_this_round: 2) }

    it 'uses an attack' do
      segment.record_attack!(50)
      segment.refresh

      expect(segment.attacks_remaining_this_round).to eq(1)
    end

    it 'records the segment number' do
      segment.record_attack!(50)
      segment.refresh

      expect(segment.last_attack_segment).to eq(50)
    end
  end

  describe 'template delegation methods' do
    let(:weak_point_template) do
      create(:monster_segment_template,
             monster_template: monster_template,
             name: 'Weak Point',
             segment_type: 'core',
             is_weak_point: true,
             required_for_mobility: false)
    end

    let(:mobility_template) do
      create(:monster_segment_template,
             monster_template: monster_template,
             name: 'Leg',
             segment_type: 'limb',
             is_weak_point: false,
             required_for_mobility: true)
    end

    describe '#name' do
      it 'returns the template name' do
        segment = create_segment
        expect(segment.name).to eq('Body')
      end
    end

    describe '#segment_type' do
      it 'returns the template segment_type' do
        segment = create_segment
        expect(segment.segment_type).to eq('body')
      end
    end

    describe '#weak_point?' do
      it 'returns true when template is_weak_point' do
        segment = create_segment(monster_segment_template: weak_point_template)
        expect(segment.weak_point?).to be true
      end

      it 'returns false when template is not weak point' do
        segment = create_segment
        expect(segment.weak_point?).to be false
      end
    end

    describe '#required_for_mobility?' do
      it 'returns true when template required_for_mobility' do
        segment = create_segment(monster_segment_template: mobility_template)
        expect(segment.required_for_mobility?).to be true
      end

      it 'returns false when template not required for mobility' do
        segment = create_segment
        expect(segment.required_for_mobility?).to be false
      end
    end
  end

  describe '#display_status' do
    let(:segment) do
      create_segment(current_hp: 75, max_hp: 100, status: 'healthy', can_attack: true)
    end

    it 'returns a hash with all display fields' do
      status = segment.display_status

      expect(status[:name]).to eq('Body')
      expect(status[:hp]).to eq(75)
      expect(status[:max_hp]).to eq(100)
      expect(status[:hp_percent]).to eq(75.0)
      expect(status[:status]).to eq('healthy')
      expect(status[:can_attack]).to be true
      expect(status[:is_weak_point]).to be false
    end
  end
end
