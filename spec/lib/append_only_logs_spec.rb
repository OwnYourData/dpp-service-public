# frozen_string_literal: true

require "rails_helper"
require "rake"

# The triggers themselves are PostgreSQL and checked there; what is checked
# here is that they are the ones the migrations create, and that loading the
# schema installs them.
RSpec.describe AppendOnlyLogs do
  it "names the functions, tables and prune settings the migrations and the prune tasks use" do
    expect(described_class::LOGS.to_h { |log| [log.function, [log.tables, log.prune_setting]] }).to eq(
      "access_log_append_only" => [%w[access_events access_event_parties], "dpp.access_log_prune"],
      "write_log_append_only" => [%w[write_events], "dpp.write_log_prune"]
    )
    migrations = Dir[Rails.root.join("db/migrate/*.rb")].map { |file| File.read(file) }.join
    described_class::LOGS.each do |log|
      expect(migrations).to include("CREATE OR REPLACE FUNCTION #{log.function}()",
                                    "current_setting('#{log.prune_setting}', true)",
                                    "FOR EACH ROW EXECUTE FUNCTION #{log.function}()")
      log.tables.each { |table| expect(migrations).to include("DROP TRIGGER IF EXISTS #{table}_append_only ON #{table}") }
    end
  end

  it "refuses UPDATE, DELETE and TRUNCATE and lets only a pruning DELETE through" do
    log = described_class::LOGS.last
    function = described_class.function_sql(log)
    triggers = described_class.triggers_sql(log, "write_events")

    expect(function).to include("current_setting('dpp.write_log_prune', true) = 'on'", "RETURN OLD",
                                "RAISE EXCEPTION 'the write log is append-only")
    expect(triggers).to include("BEFORE UPDATE OR DELETE ON write_events", "BEFORE TRUNCATE ON write_events",
                                "DROP TRIGGER IF EXISTS write_events_append_only ON write_events")
  end

  it "installs nothing outside PostgreSQL" do
    expect(described_class.install!(ActiveRecord::Base.connection)).to eq([])
  end

  describe "after a schema load" do
    before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("dpp:append_only:install") }

    %w[db:schema:load db:prepare].each do |name|
      it "installs the triggers once #{name} has run" do
        allow(described_class).to receive(:install!).and_return(%w[write_events])

        expect { Rake::Task[name].actions.last.call(Rake::Task[name], nil) }
          .to output(/append-only: write_events/).to_stdout
        expect(described_class).to have_received(:install!)
      end
    end
  end
end
