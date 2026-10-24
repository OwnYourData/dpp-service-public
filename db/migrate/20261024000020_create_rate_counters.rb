# frozen_string_literal: true

# The request counts behind the rate limit (RateCounter): one row per client
# address, kind of request and window. Kept in the database every replica
# shares, so that the limit holds for the service as a whole and not once per
# process. Rows of past windows are pruned as new ones come in.
class CreateRateCounters < ActiveRecord::Migration[7.2]
  def change
    create_table :rate_counters do |t|
      t.string  :bucket, null: false
      t.integer :hits, null: false, default: 0
      t.bigint  :window_ends_at, null: false
    end
    add_index :rate_counters, :bucket, unique: true
    add_index :rate_counters, :window_ends_at
  end
end
