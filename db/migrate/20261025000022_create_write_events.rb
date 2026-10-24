# frozen_string_literal: true

# The write log (WriteLog, docs/Integrity.md section 11): for every request
# that changes something, an entry written before the change ("request") and
# one written when the request ends ("outcome"). The request entry keeps the
# accepted bearer token, which is spent with its first use, and what it binds:
# method, request-target and the digest of the body. Nothing of the body or of
# the passport is kept.
#
# Entries are only ever added. In PostgreSQL a trigger refuses UPDATE, DELETE
# and TRUNCATE; only a transaction that sets dpp.write_log_prune (the pruning
# task, WriteLog.prune!) may delete.
class CreateWriteEvents < ActiveRecord::Migration[7.2]
  def up
    create_table :write_events do |t|
      t.datetime :occurred_at, null: false, precision: 6
      t.string   :phase, null: false
      t.string   :request_id, null: false
      t.string   :operation
      t.string   :dpp_id
      t.string   :issuer
      t.string   :jti
      t.text     :token
      t.string   :request_hash
      t.boolean  :bound
      t.string   :http_method
      t.text     :target
      t.string   :body_digest
      t.integer  :status
      t.integer  :version_number
    end
    add_index :write_events, %i[request_id phase], unique: true
    add_index :write_events, %i[dpp_id occurred_at]
    add_index :write_events, :occurred_at

    append_only! if postgresql?
  end

  def down
    if postgresql?
      execute "DROP TRIGGER IF EXISTS write_events_append_only ON write_events"
      execute "DROP TRIGGER IF EXISTS write_events_no_truncate ON write_events"
      execute "DROP FUNCTION IF EXISTS write_log_append_only()"
    end
    drop_table :write_events
  end

  private

  def postgresql? = connection.adapter_name.downcase.include?("postg")

  def append_only!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION write_log_append_only() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND current_setting('dpp.write_log_prune', true) = 'on' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'the write log is append-only (% on %)', TG_OP, TG_TABLE_NAME;
      END
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER write_events_append_only BEFORE UPDATE OR DELETE ON write_events
        FOR EACH ROW EXECUTE FUNCTION write_log_append_only();
      CREATE TRIGGER write_events_no_truncate BEFORE TRUNCATE ON write_events
        FOR EACH STATEMENT EXECUTE FUNCTION write_log_append_only();
    SQL
  end
end
