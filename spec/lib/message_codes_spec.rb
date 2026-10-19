# frozen_string_literal: true

require "rails_helper"

# The codes in the messages of a Result object (EN 18222:2026 Table 13,
# `code`) are camelCase, like the reasons in X-DPP-Controlled-Part. A client
# recognises a refusal by its code, so every code the service can send is
# listed here, and the documentation shows the same spelling. The OAuth error
# codes between this service and a custodian (invalid_grant,
# insufficient_scope) are RFC 6749's and never reach a message.
RSpec.describe "Message codes" do
  camel_case = /\A[a-z][a-z0-9]*(?:[A-Z][a-z0-9]*)*\z/

  let(:sent) do
    (Dir[Rails.root.join("app/controllers/**/*.rb")] + Dir[Rails.root.join("app/models/**/*.rb")])
      .sort.flat_map { |file| File.read(file).scan(/\b(?:code: |CODE = )"([^"]+)"/).flatten }
  end

  it "are all camelCase" do
    expect(sent).to contain_exactly("registryNotConnected", "readerNotEntered")
    expect(sent).to all(match(camel_case))
  end

  it "are spelled the same way in the documentation of the responses" do
    %w[docs/openapi.yaml docs/EXAMPLES.md docs/examples-lightbulb.md .publish-overlay/README.md
       .publish-overlay/docs/Standalone.md].each do |doc|
      text = File.read(Rails.root.join(doc))
      expect(text).to include("registryNotConnected"), doc
      expect(text).not_to match(/\b[a-z]+(?:_[a-z]+)+_connected\b/), doc
    end
  end
end
