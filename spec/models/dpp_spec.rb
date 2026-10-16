# frozen_string_literal: true

require "rails_helper"

# The unique index over active passports (one product, one active passport,
# EN 18219:2026 3.1.25) — checked at the database, without the controller.
RSpec.describe Dpp do
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }

  def passport(dpp_id, product: product_id, status: "Active")
    described_class.from_document(
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product,
      "granularity" => "model",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => status,
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
    )
  end

  it "stores the host lower-cased beside the path" do
    dpp = passport("urn:a", product: product_id.sub("id.lumina.example", "ID.Lumina.Example"))
    dpp.save!

    expect(dpp.reload).to have_attributes(product_key: "/01/09520123456788",
                                          product_host: "id.lumina.example")
  end

  it "refuses a second active passport for the same product" do
    passport("urn:a").save!

    expect { passport("urn:b").save! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "treats a host that differs only in case as the same product" do
    passport("urn:a").save!
    shouted = passport("urn:b", product: product_id.sub("id.lumina.example", "ID.LUMINA.EXAMPLE"))

    expect { shouted.save! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows the same path under another host" do
    passport("urn:a").save!

    expect(passport("urn:b", product: product_id.sub("lumina", "other")).save!).to be(true)
  end

  it "does not count an archived passport" do
    passport("urn:a", status: "Archived").save!

    expect(passport("urn:b").save!).to be(true)
  end
end
