# frozen_string_literal: true

# Routes mirror the HTTPS/REST mappings of EN 18222:2026 (Tables 16, 17, 18).
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
  # A carrier host (DPP_CARRIER_HOSTS) answers the product identifiers printed
  # on products and nothing else: every path there is looked up as one
  # (CarrierController, docs/Identifiers.md section 3). Drawn first, so that no
  # route below is reachable under such a host.
  constraints(CarrierHosts) do
    # GET routes answer HEAD as well. Naming HEAD here would make the router
    # prefer these routes for every HEAD request and leave the API without one.
    get "/", to: "carrier#index", as: :carrier_root
    get "*identifier", to: "carrier#show", format: false, as: :carrier
    match "/", to: "carrier#refuse", via: :all
    match "*identifier", to: "carrier#refuse", via: :all, format: false
  end

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

      # Also outside EN 18222:2026: the mandate under which this service reaches
      # the custodian has a lifetime, the passport does not. GET says which
      # mandate is held, POST hands over a fresh one; neither moves the
      # passport.
      get  "dpps/:dpp_id/delegation", to: "api/v1/dpps#show_delegation"
      post "dpps/:dpp_id/delegation", to: "api/v1/dpps#renew_delegation"

      # Outside EN 18222:2026 as well: which attributes of the passport its
      # access policy leaves to the default, and which rules reach nothing.
      # For the owner only.
      get "dpps/:dpp_id/access-policy", to: "api/v1/dpps#show_access_policy"
      put "dpps/:dpp_id/signature", to: "api/v1/signatures#update"

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

    # EN 18222:2026 Table 16 keys this method on the passport identifier.
    get "dppsByIdAndDate/:dpp_id",
        to: "api/v1/dpps#by_id_and_date",                # ReadDPPVersionByIdAndDate
        constraints: { dpp_id: id }

    post "dppsByProductIds",
         to: "api/v1/dpps#ids_by_product_ids"            # ReadDPPIdsByProductIds

    # Access policies, registered once per product type and named by
    # passports in X-DPP-Access-Policy. Not in EN 18222:2026.
    put "access-policies", to: "api/v1/access_policies#update"

    # Access grants: who may read the controlled part of which passports in
    # which access classes. Not in EN 18222:2026.
    put "access-grants", to: "api/v1/access_grants#update"
    get "access-grants", to: "api/v1/access_grants#index"
    delete "access-grants/:jti", to: "api/v1/access_grants#destroy", constraints: { jti: %r{[^/]+} }

    # The access log: the entries that concern the presenting DID. Not in
    # EN 18222:2026.
    get "access-log", to: "api/v1/access_log#index"

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

  # The start page. Rendered rather than served from public/ because the list
  # of available DPP services on it comes from dpp-validator.
  root "landing#show"

  # The privacy policy of the start page, the API and the pages around them.
  get "privacy", to: "privacy#show", format: false

  # The consent banner and the conversion tag (docs/Consent.md); an empty
  # script while no conversion ID is configured.
  get "consent.js", to: "consent#show", format: false

  # Health check
  get "up", to: proc { [200, { "Content-Type" => "application/json" }, ['{"status":"ok"}']] }
  get "version", to: proc { [200, { "Content-Type" => "application/json" }, [BuildInfo.to_json]] }
end
