# frozen_string_literal: true

class StaffBulletinRead < Sequel::Model
  many_to_one :staff_bulletin
  many_to_one :user
end
