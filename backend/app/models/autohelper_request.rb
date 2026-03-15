# frozen_string_literal: true

# AutohelperRequest logs every request to the AI help system.
#
# Used for analytics: what questions players ask most, which helpfiles
# they expect but don't exist, and how often the autohelper succeeds.
#
class AutohelperRequest < Sequel::Model
  many_to_one :user
  many_to_one :character_instance

  dataset_module do
    def recent(limit = 50)
      order(Sequel.desc(:created_at)).limit(limit)
    end

    def successful
      where(success: true)
    end

    def failed
      where(success: false)
    end

    def with_tickets
      where(ticket_created: true)
    end
  end

  # Top queries by frequency
  #
  # @param limit [Integer] number of results
  # @return [Array<Hash>] [{ query:, count: }]
  def self.top_queries(limit: 20)
    dataset
      .select(Sequel.function(:lower, :clean_query).as(:query))
      .select_append { count('*').as(count) }
      .group(Sequel.function(:lower, :clean_query))
      .order(Sequel.desc(:count))
      .limit(limit)
      .all
      .map { |r| { query: r[:query], count: r[:count] } }
  end

  # Queries that produced no sources, since a given time, grouped and sorted by frequency.
  #
  # @param since_time [Time, nil] only include requests after this time
  # @param limit [Integer] number of results
  # @return [Array<Hash>] [{ query:, count:, last_seen_at: }]
  def self.unmatched_since(since_time, limit: 200)
    ds = where(Sequel.lit("sources = '{}'::text[]"))
    ds = ds.where(Sequel.lit('created_at > ?', since_time)) if since_time
    ds
      .select(Sequel.function(:lower, :clean_query).as(:query))
      .select_append { count('*').as(count) }
      .select_append { max(:created_at).as(:last_seen_at) }
      .group(Sequel.function(:lower, :clean_query))
      .order(Sequel.desc(:count))
      .limit(limit)
      .all
      .map { |r| { query: r[:query], count: r[:count], last_seen_at: r[:last_seen_at]&.iso8601 } }
  end

  # Queries that produced no sources (helpfiles people expect but don't exist)
  #
  # @param limit [Integer] number of results
  # @return [Array<Hash>] [{ query:, count: }]
  def self.unmatched_queries(limit: 20)
    dataset
      .where(sources: Sequel.pg_array([]))
      .select(Sequel.function(:lower, :clean_query).as(:query))
      .select_append { count('*').as(count) }
      .group(Sequel.function(:lower, :clean_query))
      .order(Sequel.desc(:count))
      .limit(limit)
      .all
      .map { |r| { query: r[:query], count: r[:count] } }
  end
end
