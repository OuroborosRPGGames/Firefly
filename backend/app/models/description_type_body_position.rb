# frozen_string_literal: true

class DescriptionTypeBodyPosition < Sequel::Model
  many_to_one :description_type
  many_to_one :body_position
end
