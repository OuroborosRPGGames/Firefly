# frozen_string_literal: true

class StaffBroadcast < Sequel::Model
  plugin :timestamps, update_on_create: true

  many_to_one :created_by_user, class: :User
  one_to_many :staff_broadcast_deliveries

  # Broadcast to all online players and track delivery
  def deliver!
    online_instances = CharacterInstance.where(online: true).all

    # Deliver to online players immediately
    online_instances.each do |ci|
      BroadcastService.to_character(ci, formatted_message, type: :broadcast)
      StaffBroadcastDelivery.create(
        staff_broadcast_id: id,
        character_instance_id: ci.id,
        delivered_at: Time.now
      )
    end

    # Offline players will be delivered on login (no record yet)
    online_instances.count
  end

  def formatted_message
    {
      content: "[BROADCAST] #{content}",
      html: "<div class='broadcast-message'><strong class='text-warning'>[BROADCAST]</strong> #{content}</div>"
    }
  end

  def delivered_to?(character_instance)
    StaffBroadcastDelivery.where(
      staff_broadcast_id: id,
      character_instance_id: character_instance.id
    ).first
  end

  # Get undelivered broadcasts for a character instance
  def self.undelivered_for(character_instance)
    return [] unless character_instance

    # Get broadcasts without delivery records for this character
    # Only look at broadcasts from the last 24 hours
    delivered_ids = StaffBroadcastDelivery
      .where(character_instance_id: character_instance.id)
      .select_map(:staff_broadcast_id)

    where { created_at > Time.now - GameConfig::Timeouts::STAFF_BROADCAST_WINDOW_SECONDS }
      .exclude(id: delivered_ids)
      .order(:created_at)
      .all
  end

  # Get delivery count
  def delivery_count
    staff_broadcast_deliveries_dataset.count
  end

  # Get online delivery count
  def online_delivery_count
    staff_broadcast_deliveries_dataset.exclude(delivered_at: nil).count
  end

  # Get login delivery count
  def login_delivery_count
    staff_broadcast_deliveries_dataset.exclude(login_delivered_at: nil).count
  end
end
