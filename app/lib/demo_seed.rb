# frozen_string_literal: true

# The example passport of db/seeds.rb, and only when asked for.
#
# `bin/rails db:prepare` runs db/seeds.rb on an empty database, and the compose
# file of docs/Standalone.md section 4 sets a new installation up with exactly
# that. A passport nobody created would then sit in a production database,
# readable by anyone. So the example passport is added only with
# DPP_SEED_DEMO=1 (or `true`), in every environment alike; without it nothing
# is added, and the seed run says so.
module DemoSeed
  SWITCH = "DPP_SEED_DEMO"
  ON = %w[1 true].freeze

  PRODUCT_ID = "https://dpp.example.org/01/09520123456788/21/0001"

  module_function

  def wanted?(value = ENV[SWITCH]) = ON.include?(value.to_s.strip.downcase)

  # Example DPP for a battery cell (attributes illustrative of DIN DKE SPEC 99100).
  def seed!
    Dpp.find_or_create_by!(dpp_id: PRODUCT_ID) do |dpp|
      # The product identifier is what the carrier bears (EN 18219:2026 3.1.25, 4.5.2 (1)):
      # a GS1 Digital Link under a host of the operator's own, 49 characters.
      dpp.product_id           = PRODUCT_ID
      dpp.granularity          = "item"
      dpp.dpp_schema_version   = "EN 18223:2026"
      dpp.dpp_status           = "Active"
      dpp.economic_operator_id = "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
      dpp.facility_id          = "https://id.example.org/414/4012345000009"
      dpp.last_update          = Time.now.utc
      dpp.content = {
        "elements" => [
          {
            "elementId" => "generalInformation",
            "objectType" => "DataElementCollection",
            "elements" => [
              { "objectType" => "SingleValuedDataElement", "elementId" => "manufacturer",
                "value" => "ACME Cells GmbH", "valueDataType" => "xsd:string" },
              { "objectType" => "SingleValuedDataElement", "elementId" => "batteryCategory",
                "value" => "EV", "valueDataType" => "xsd:string" }
            ]
          },
          {
            "elementId" => "carbonFootprint",
            "objectType" => "DataElementCollection",
            "elements" => [
              { "objectType" => "SingleValuedDataElement", "elementId" => "totalCarbonFootprint",
                "value" => 84.2, "valueDataType" => "xsd:decimal" }
            ]
          }
        ]
      }
    end
  end

  def run(value = ENV[SWITCH], out: $stdout)
    unless wanted?(value)
      out.puts "No example passport: set #{SWITCH}=1 to add one."
      return nil
    end

    dpp = seed!
    out.puts "Example passport #{PRODUCT_ID} is in the database (#{SWITCH})."
    dpp
  end
end
