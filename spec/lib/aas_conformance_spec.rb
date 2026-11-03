# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# Every environment of the AAS vectors handed to the AAS test engines of the
# IDTA (aas-test-engines, Apache 2.0), which check a file against the
# metamodel and the constraints of AAS V3.0.
#
# The engines are a Python tool, and version 1.0.3 needs Python 3.13 or older:
# under 3.14 it does not even load. Without AAS_TEST_ENGINES naming the
# executable these examples are skipped; to run them (on macOS /usr/bin/python3
# is such a Python):
#
#   /usr/bin/python3 -m venv tmp/aas-test-engines
#   tmp/aas-test-engines/bin/pip install aas_test_engines==1.0.3
#   AAS_TEST_ENGINES=tmp/aas-test-engines/bin/aas_test_engines bundle exec rspec
#
# An engine that does not run at all is reported as such, not as a finding
# about the environment.
RSpec.describe "AAS conformance" do
  vectors = JSON.parse(Rails.root.join("spec/fixtures/aas-vectors/aas-vectors.json").read)

  let(:engines) { ENV["AAS_TEST_ENGINES"].to_s.strip }

  before do
    skip "set AAS_TEST_ENGINES to the aas_test_engines executable" if engines.empty?
  end

  vectors["cases"].each do |vector|
    it "finds the environment of #{vector['name']} conformant to AAS V3.0" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "#{vector['name']}.json")
        File.write(file, JSON.generate(vector["environment"]))

        output, status = Open3.capture2e(File.expand_path(engines, Rails.root), "check_file", file, "--format", "json")
        text = output.gsub(/\e\[[0-9;]*m/, "")
        if !status.success? && text.include?("Traceback (most recent call last)")
          raise "aas_test_engines did not run (it needs Python 3.13 or older): #{text.lines.last.to_s.strip}"
        end

        expect(status).to be_success, text
      end
    end
  end
end
