# frozen_string_literal: true

# Example DPP for a battery cell (attributes illustrative of DIN DKE SPEC 99100).
Dpp.find_or_create_by!(dpp_id: "https://dpp.example.org/01/09520123456788/21/0001") do |dpp|
  # The product identifier is what the carrier bears (EN 18219:2026 3.1.25, 4.5.2 (1)):
  # a GS1 Digital Link under a host of the operator's own, 49 characters.
  dpp.product_id           = "https://dpp.example.org/01/09520123456788/21/0001"
  dpp.granularity          = "item"
  dpp.dpp_schema_version   = "EN18223:2026"
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

puts "Seeded #{Dpp.count} DPP(s)."
