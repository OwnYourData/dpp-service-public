# frozen_string_literal: true

# The append-only triggers of the access log and the write log after every
# schema load (AppendOnlyLogs). db/schema.rb records no triggers, so a database
# loaded from it would otherwise accept changes to entries that are meant to be
# final. db:prepare loads the schema without going through db:schema:load, so
# it is hooked as well; on an existing database the install only replaces what
# is there.
namespace :dpp do
  namespace :append_only do
    desc "Install the append-only triggers of the access log and the write log (PostgreSQL)"
    task install: :environment do
      tables = AppendOnlyLogs.install!
      puts(tables.any? ? "append-only: #{tables.join(', ')}" : "append-only: nothing to install")
    end
  end
end

%w[db:schema:load db:prepare].each do |name|
  next unless Rake::Task.task_defined?(name)

  Rake::Task[name].enhance do
    Rake::Task["dpp:append_only:install"].reenable
    Rake::Task["dpp:append_only:install"].invoke
  end
end
