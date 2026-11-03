# frozen_string_literal: true

# Where the log goes when RAILS_LOG_TO_STDOUT is set (config/environments/
# production.rb).
#
# The server logs to stdout, where `kubectl logs` picks it up. A rake task or
# `rails runner` prints its result on stdout, often into a file
# (`bin/rails dpp:writes:export DPP=… > writes.jsonl`); its log goes to stderr,
# so that the result holds nothing but the result. `kubectl logs` shows both
# streams, so nothing is lost.
module LogStream
  module_function

  def for_process(task: command_line_task?)
    task ? $stderr : $stdout
  end

  # True in a rake task (bin/rails <task>, bin/rake) and in `rails runner`.
  def command_line_task?
    rake_task? || runner?
  end

  def rake_task?
    return false unless defined?(::Rake) && ::Rake.respond_to?(:application)

    ::Rake.application.top_level_tasks.any?
  end

  def runner?
    defined?(::Rails::Command::RunnerCommand) ? true : false
  end
end
