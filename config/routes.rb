# frozen_string_literal: true

# Routes mirror the HTTPS/REST mappings of EN 18222:2026 (Tables 17, 18, 19).
#
# Identifiers (EN 18219:2026) are URIs/URLs and therefore contain "/", ":" and ".".
# Clients MUST percent-encode them into a single path segment. Two Rails
# defaults have to be switched off for that to work:
#
#   * the default segment constraint is /[^.\/?]+/ — it stops at the first dot,
#     so "https%3A%2F%2Fdpp.example.org%2F01%2F..." would never match. It is
#     widened to /[^\/]+/ (anything but an unencoded slash).
#   * the implicit "(.:format)" suffix would otherwise swallow the ".org" of a
#     host name, so it is disabled via `format: false`; the JSON format is
#     supplied through `defaults:` instead.
#
# The fine-granular element path stays a glob because an absolute ElementId
# path legitimately contains "/".
Rails.application.routes.draw do
  # A percent-encoded identifier: any character except an unencoded "/".
  id = %r{[^/]+}

  scope path: "dpp/v1", defaults: { format: :json }, format: false do
    # --- 4  Life Cycle API (Main Methods) — Table 17 ----------------------
    post "dpps", to: "api/v1/dpps#create" # CreateDPP

    scope constraints: { dpp_id: id } do
      get    "dpps/:dpp_id", to: "api/v1/dpps#show"    # ReadDPPById
      patch  "dpps/:dpp_id", to: "api/v1/dpps#update"  # UpdateDPP  (RFC 7396)
      delete "dpps/:dpp_id", to: "api/v1/dpps#destroy" # DeleteDPPById

      # Not in EN 18222:2026: the standard says what a service does with a
      # passport, not where it keeps it. This is the operation the exit claim
      # rests on.
      post "dpps/:dpp_id/custody", to: "api/v1/dpps#move_custody"

      # --- 6  Fine Granular Life Cycle API — Table 19 ---------------------
      get   "dpps/:dpp_id/collections/:element_id",
            to: "api/v1/data_element_collections#show"   # ReadDataElementCollection
      patch "dpps/:dpp_id/collections/:element_id",
            to: "api/v1/data_element_collections#update" # UpdateDataElementCollection

      get   "dpps/:dpp_id/elements/*element_path",
            to: "api/v1/data_elements#show"              # ReadDataElement
      patch "dpps/:dpp_id/elements/*element_path",
            to: "api/v1/data_elements#update"            # UpdateDataElement
    end

    get "dppsByProductId/:product_id",
        to: "api/v1/dpps#by_product_id",                 # ReadDPPByProductId
        constraints: { product_id: id }

    # EN 18222:2026 Table 16 keys this method on the passport identifier, not on
    # the product identifier as the 2025 draft did.
    get "dppsByIdAndDate/:dpp_id",
        to: "api/v1/dpps#by_id_and_date",                # ReadDPPVersionByIdAndDate
        constraints: { dpp_id: id }

    post "dppsByProductIds",
         to: "api/v1/dpps#ids_by_product_ids"            # ReadDPPIdsByProductIds

    # --- 5  Registry API for Register — Table 17 --------------------------
    post "registerDPP", to: "api/v1/registry#create" # RegisterProductDPP
  end

  # Discovery for the delegation model (docs/Delegation.md §6): the DID a
  # customer names in the `sub` of their delegation assertion.
  get ".well-known/dpp-service", to: "discovery#dpp_service",
                                 defaults: { format: :json }, format: false

  # OpenAPI document + Swagger UI (served from docs/openapi.yaml).
  mount Rswag::Api::Engine => "/api-docs"
  mount Rswag::Ui::Engine => "/api-docs"

  # Health check
  get "up", to: proc { [200, { "Content-Type" => "application/json" }, ['{"status":"ok"}']] }
end
