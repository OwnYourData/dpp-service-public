# frozen_string_literal: true

# Serves the derived OpenAPI document and a Swagger UI at /api-docs.
Rswag::Ui.configure do |c|
  # openapi_endpoint, not swagger_endpoint: the old name only warns and then
  # calls this one, and the warning turned up in the output of every rails
  # runner and every spec run.
  c.openapi_endpoint "/api-docs/openapi.yaml", "DPP Service API v0.1.0"
end
