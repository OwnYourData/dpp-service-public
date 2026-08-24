# frozen_string_literal: true

# Example DPP for a battery cell (attributes illustrative of DIN DKE SPEC 99100).
Dpp.find_or_create_by!(dpp_id: "https://dpp.example.org/01/09520123456788/21/0001") do |dpp|
  # The ProductID is the identifier the carrier bears (prEN 18219 3.22, 4.5.2 (1)):
  # a GS1 Digital Link under a host of the operator's own, 49 characters.
  dpp.product_id           = "https://dpp.example.org/01/09520123456788/21/0001"
  dpp.granularity          = "item"
  dpp.dpp_schema_version   = "prEN18223:2025"
  dpp.dpp_status           = "Active"
  dpp.economic_operator_id = "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
  dpp.facility_id          = "https://id.example.org/414/4012345000009"
  dpp.last_update          = Time.now.utc
  dpp.content = {
    "dataElementCollections" => [
      {
        "ElementId" => "generalInformation",
        "Name" => "General battery information",
        "DataElements" => [
          { "@type" => "SinglevaluedDataElement", "ElementId" => "manufacturer",
            "Value" => "ACME Cells GmbH", "ValueDataType" => "string" },
          { "@type" => "SinglevaluedDataElement", "ElementId" => "batteryCategory",
            "Value" => "EV", "ValueDataType" => "string" }
        ]
      },
      {
        "ElementId" => "carbonFootprint",
        "Name" => "Carbon footprint",
        "DataElements" => [
          { "@type" => "SinglevaluedDataElement", "ElementId" => "totalCarbonFootprint",
            "Value" => 84.2, "ValueDataType" => "decimal" }
        ]
      }
    ]
  }
end

puts "Seeded #{Dpp.count} DPP(s)."
