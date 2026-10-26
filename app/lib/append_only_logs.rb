# frozen_string_literal: true

# The two logs whose entries are only ever added: the access log
# (docs/AccessClasses.md section 10) and the write log (docs/Integrity.md
# section 11). In PostgreSQL a trigger on each of their tables refuses UPDATE,
# DELETE and TRUNCATE; the one exception is a DELETE inside a transaction that
# sets the log's prune setting, which is how the prune tasks remove entries
# past their retention period.
#
# The migrations that create the tables install the triggers. A database that
# is loaded from db/schema.rb instead -- `bin/rails db:prepare` on an empty
# database, `db:schema:load`, `db:reset` -- would carry none, because the
# schema file records tables and indexes but no triggers. lib/tasks/
# append_only.rake therefore installs them again after every schema load, with
# the same functions and trigger names as the migrations. Installing is
# idempotent, and outside PostgreSQL it does nothing.
module AppendOnlyLogs
  Log = Struct.new(:function, :description, :prune_setting, :tables, keyword_init: true)

  LOGS = [
    Log.new(function: "access_log_append_only", description: "the access log",
            prune_setting: "dpp.access_log_prune", tables: %w[access_events access_event_parties]),
    Log.new(function: "write_log_append_only", description: "the write log",
            prune_setting: "dpp.write_log_prune", tables: %w[write_events])
  ].freeze

  module_function

  def postgresql?(connection) = connection.adapter_name.downcase.include?("postg")

  # Creates or replaces the functions and triggers of every log whose tables
  # exist. Returns the tables now protected; empty outside PostgreSQL.
  def install!(connection = ActiveRecord::Base.connection)
    return [] unless postgresql?(connection)

    LOGS.select { |log| log.tables.all? { |table| connection.table_exists?(table) } }.flat_map do |log|
      connection.execute(function_sql(log))
      log.tables.each { |table| connection.execute(triggers_sql(log, table)) }
      log.tables
    end
  end

  def function_sql(log)
    <<~SQL
      CREATE OR REPLACE FUNCTION #{log.function}() RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND current_setting('#{log.prune_setting}', true) = 'on' THEN
          RETURN OLD;
        END IF;
        RAISE EXCEPTION '#{log.description} is append-only (% on %)', TG_OP, TG_TABLE_NAME;
      END
      $$ LANGUAGE plpgsql;
    SQL
  end

  def triggers_sql(log, table)
    <<~SQL
      DROP TRIGGER IF EXISTS #{table}_append_only ON #{table};
      DROP TRIGGER IF EXISTS #{table}_no_truncate ON #{table};
      CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{log.function}();
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION #{log.function}();
    SQL
  end
end
