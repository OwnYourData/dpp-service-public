# frozen_string_literal: true

# Serves the derived OpenAPI document and a Swagger UI at /api-docs.
Rswag::Ui.configure do |c|
  c.swagger_endpoint "/api-docs/openapi.yaml", "DPP Service API v0.1.0"
end
