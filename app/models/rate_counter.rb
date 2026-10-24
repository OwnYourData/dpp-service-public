# frozen_string_literal: true

# Counts requests per bucket and fixed window, in the database every replica
# shares (ApplicationController's rate limit). One statement per request: the
# row of the current window is created with one hit or has its hits raised by
# one, and the count after this request comes back.
#
# A window is aligned to multiples of its length, so all replicas agree on it
# without talking to each other. Rows of past windows are pruned now and then
# as requests come in.
class RateCounter < ApplicationRecord
  PRUNE_EVERY = 200

  # The hits of +name+ in the current window of +within+ seconds, this one
  # included. When the count cannot be kept, the request is let through and
  # the failure logged: the limit protects the service, it is not a reason to
  # refuse public data while the database is struggling.
  def self.hit!(name, within:, now: Time.now.to_i)
    window = now / within
    result = upsert({ bucket: "#{name}:#{window}", hits: 1, window_ends_at: (window + 1) * within },
                    unique_by: :bucket, returning: %w[hits],
                    on_duplicate: Arel.sql("hits = #{quoted_table_name}.hits + 1"))
    prune!(now) if rand(PRUNE_EVERY).zero?
    result.rows.dig(0, 0).to_i
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[rate-limit] the count could not be kept, the request goes through: #{e.class}")
    0
  end

  def self.prune!(now = Time.now.to_i) = where(window_ends_at: ...now).delete_all
end
