# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/log_stream")
require "rake"

# With RAILS_LOG_TO_STDOUT the server logs to stdout and a task to stderr, so
# that `bin/rails dpp:writes:export DPP=… > writes.jsonl` writes nothing but the
# write log into the file (docs/Integrity.md, bin/verify_writes).
RSpec.describe LogStream do
  it "sends the log of a task to stderr and that of the server to stdout" do
    expect(described_class.for_process(task: true)).to be($stderr)
    expect(described_class.for_process(task: false)).to be($stdout)
  end

  it "counts a rake task with top-level tasks as a task" do
    application = instance_double(Rake::Application, top_level_tasks: ["dpp:writes:export"])
    allow(Rake).to receive(:application).and_return(application)
    expect(described_class.rake_task?).to be(true)
  end

  it "does not count a loaded Rake without top-level tasks (the server) as a task" do
    application = instance_double(Rake::Application, top_level_tasks: [])
    allow(Rake).to receive(:application).and_return(application)
    expect(described_class.rake_task?).to be(false)
  end

  it "counts rails runner as a task" do
    stub_const("Rails::Command::RunnerCommand", Class.new)
    expect(described_class.runner?).to be(true)
    expect(described_class.command_line_task?).to be(true)
  end

  it "makes the production logger use the stream of the process" do
    source = Rails.root.join("config/environments/production.rb").read
    expect(source).to include("LogStream.for_process")
    expect(source).not_to match(/Logger\.new\(\$stdout\)/)
  end
end
