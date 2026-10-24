# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

# Load db/schema.rb into the test database whenever a migration is outstanding.
# Without this the test database keeps whatever shape it had when it was first
# created: `bin/rails db:migrate` touches development, the specs run against the
# old columns, and every example that uses a new one fails with NoMethodError
# rather than with a word about the schema.
ActiveRecord::Migration.maintain_test_schema!

RSpec.configure do |config|
  # The payload commitment reads the payload back from the custodian and writes
  # to the VDR, so it does not belong in a request spec about something else. It
  # has its own spec (spec/services/payload_commitment_spec.rb), and the wiring
  # into the write paths is checked in spec/requests/payload_commitment_spec.rb
  # against this very stub.
  config.before(type: :request) do
    allow(PayloadCommitment).to receive(:call)
    allow(PayloadCommitment).to receive(:refresh)
  end

  # Whether this service is entered as reader of a collection is kept in the
  # process for a while (ReaderAdmission); each example asks its own custodian.
  config.before { ReaderAdmission.reset! }

  # From DPP_REQUEST_BINDING_FROM on, a write without an rqh claim is refused
  # (RequestBinding). Most examples send tokens without one, as their subject
  # is something else; the binding has examples of its own, which set the day.
  config.before { allow(RequestBinding).to receive(:required_from).and_return(Date.new(2999, 1, 1)) }

  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
