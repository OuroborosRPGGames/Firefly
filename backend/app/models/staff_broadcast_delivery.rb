# frozen_string_literal: true

class StaffBroadcastDelivery < Sequel::Model
  many_to_one :staff_broadcast
  many_to_one :character_instance
end
