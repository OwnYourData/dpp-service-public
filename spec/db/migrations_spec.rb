# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# Every migration has to run on an empty database, one after the other, and
# the result has to be the schema in db/schema.rb. A new instance is set up
# that way (db:migrate on an empty database), and a migration that reads
# through today's models breaks it: the models expect today's schema.
#
# The migrations run in a separate process, against a database of their own,
# so that the test database and its transaction stay untouched. SQLite by
# default; with DPP_MIGRATION_CHECK_DATABASE_URL naming an empty PostgreSQL
# database the same run goes there as well.
RSpec.describe "Database migrations" do
  # Tables, their columns and their indexes, by name: what a migration decides.
  # Column types are left out, because SQLite and PostgreSQL name them apart.
  let(:shape_script) do
    <<~RUBY
      ActiveRecord::Migration.verbose = false
      context = ActiveRecord::Base.connection_pool.migration_context
      context.migrate
      connection = ActiveRecord::Base.connection
      tables = connection.tables - %w[schema_migrations ar_internal_metadata]
      shape = tables.sort.to_h do |table|
        [table, { "columns" => connection.columns(table).map(&:name).sort,
                  "indexes" => connection.indexes(table).map(&:name).sort }]
      end
      puts "SHAPE " + JSON.generate("version" => context.current_version, "tables" => shape)
    RUBY
  end

  def migrate_empty(database_url)
    env = { "RAILS_ENV" => "test", "DATABASE_URL" => database_url }
    output, status = Open3.capture2e(env, "bin/rails", "runner", shape_script, chdir: Rails.root.to_s)
    line = output.lines.reverse.find { |l| l.start_with?("SHAPE ") }
    [status, output, line && JSON.parse(line.delete_prefix("SHAPE "))]
  end

  def schema_rb_shape
    connection = ActiveRecord::Base.connection
    tables = connection.tables - %w[schema_migrations ar_internal_metadata]
    tables.sort.to_h do |table|
      [table, { "columns" => connection.columns(table).map(&:name).sort,
                "indexes" => connection.indexes(table).map(&:name).sort }]
    end
  end

  def latest_version
    Dir[Rails.root.join("db/migrate/*.rb")].map { |file| File.basename(file).to_i }.max
  end

  it "run on an empty SQLite database and arrive at db/schema.rb" do
    Dir.mktmpdir do |dir|
      status, output, shape = migrate_empty("sqlite3:#{File.join(dir, 'empty.sqlite3')}")

      expect(status).to be_success, output
      expect(shape["version"]).to eq(latest_version)
      expect(shape["tables"]).to eq(schema_rb_shape)
    end
  end

  it "run on an empty PostgreSQL database and arrive at db/schema.rb" do
    url = ENV["DPP_MIGRATION_CHECK_DATABASE_URL"].presence
    skip "set DPP_MIGRATION_CHECK_DATABASE_URL to an empty PostgreSQL database" if url.nil?

    status, output, shape = migrate_empty(url)

    expect(status).to be_success, output
    expect(shape["version"]).to eq(latest_version)
    expect(shape["tables"]).to eq(schema_rb_shape)
  end
end
