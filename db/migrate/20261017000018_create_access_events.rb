# frozen_string_literal: true

# The access log (AccessEvent, docs/AccessClasses.md §10): one entry per read
# of the controlled part of a passport, per refused read, per read this
# service makes at a custodian under its own read grant, and per access grant
# registered or revoked. Who may see an entry is kept apart, one row per DID
# and relation (AccessEventParty), so that an owner, a reader and an issuer
# each find theirs with one index.
#
# Entries are only ever added. In PostgreSQL a trigger refuses UPDATE, DELETE
# and TRUNCATE on both tables; only a transaction that sets
# dpp.access_log_prune (the pruning task, AccessLog.prune!) may delete.
class CreateAccessEvents < ActiveRecord::Migration[7.2]
  def up
    create_table :access_events do |t|
      t.datetime :occurred_at, null: false, precision: 6
      t.string   :event, null: false
      t.string   :dpp_id
      t.string   :owner_did
      t.string   :reader_did
      t.json     :roles
      t.string   :basis
      t.json     :grants
      t.string   :operation
      t.datetime :version_date
      t.integer  :status
      t.string   :reason
      t.string   :custodian
      t.string   :pod_object_id
      t.string   :pod_path
      t.string   :controlled_digest
      t.string   :request_id
      t.json     :details
      t.datetime :created_at, null: false, precision: 6
    end
    add_index :access_events, :occurred_at
    add_index :access_events, %i[dpp_id occurred_at]

    create_table :access_event_parties do |t|
      t.references :access_event, null: false, foreign_key: true
      t.string :did, null: false
      t.string :relation, null: false
    end
    add_index :access_event_parties, %i[did access_event_id]

    add_column :access_grants, :revocation_reason, :string

    append_only! if postgresql?
  end

  def down
    if postgresql?
      execute "DROP TRIGGER IF EXISTS access_event_parties_append_only ON access_event_parties"
      execute "DROP TRIGGER IF EXISTS access_event_parties_no_truncate ON access_event_parties"
      execute "DROP TRIGGER IF EXISTS access_events_append_only ON access_events"
      execute "DROP TRIGGER IF EXISTS access_events_no_truncate ON access_events"
      execute "DROP FUNCTION IF EXISTS access_log_append_only()"
    end
    remove_column :access_grants, :revocation_reason
    drop_table :access_event_parties
    drop_table :access_events
  end

  private

  def postgresql? = connection.adapter_name.downcase.include?("postg")

  def append_only!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION access_log_append_only() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND current_setting('dpp.access_log_prune', true) = 'on' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION 'the access log is append-only (% on %)', TG_OP, TG_TABLE_NAME;
      END
      $$ LANGUAGE plpgsql;
    SQL
    %w[access_events access_event_parties].each do |table|
      execute <<~SQL
        CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
          FOR EACH ROW EXECUTE FUNCTION access_log_append_only();
        CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
          FOR EACH STATEMENT EXECUTE FUNCTION access_log_append_only();
      SQL
    end
  end
end
