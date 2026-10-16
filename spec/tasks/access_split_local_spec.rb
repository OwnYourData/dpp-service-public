# frozen_string_literal: true

require "rails_helper"
require "rake"

# bin/rails dpp:access:split_local -- local passports with an access policy
# that are still kept whole are split, and nothing else is touched.
RSpec.describe "dpp:access:split_local" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "dpp:access:split_local" }
  end

  let(:task) { Rake::Task["dpp:access:split_local"] }

  let(:policy) do
    RegisteredAccessPolicy.register!(nil, { "id" => "https://example.org/p/1", "scheme" => AccessClass::SCHEME,
                                            "default" => "public",
                                            "rules" => [{ "path" => "Serial", "accessClass" => "authority" }] }).first
  end

  def element(id, value) = { "elementId" => id, "objectType" => "SingleValuedDataElement", "value" => value }

  def passport(dpp_id, product_id, policy_record)
    dpp = Dpp.create!(dpp_id: dpp_id, product_id: product_id, granularity: "model",
                      dpp_schema_version: "EN 18223:2026", economic_operator_id: "did:oyd:zQmOp",
                      last_update: Time.now.utc,
                      content: { "elements" => [element("Brand", "Lumina"), element("Serial", "S-1")] })
    # As before the split: the policy attached, the passport kept whole.
    dpp.update_columns(access_policy_id: policy_record&.id, controlled_content: nil,
                       content: { "elements" => [element("Brand", "Lumina"), element("Serial", "S-1")] })
    dpp
  end

  before do
    task.reenable
    allow(PayloadCommitment).to receive(:call).and_return("committed")
  end

  it "splits a passport kept whole and commits it again, and leaves one without a policy alone" do
    whole = passport("https://dpp.example.org/x/1", "https://id.lumina.example/01/09520123456788", policy)
    plain = passport("https://dpp.example.org/x/2", "https://id.lumina.example/01/09520123456795", nil)

    expect { task.invoke }.to output(%r{1 local passport.*x/1: split, commitment committed}m).to_stdout

    expect(PassportSplit.attribute_paths(whole.reload.controlled_content)).to eq(["Serial"])
    expect(whole.content.to_json).not_to include("S-1")
    expect(plain.reload.controlled_content).to be_nil
    expect(PayloadCommitment).to have_received(:call).once
  end
end
