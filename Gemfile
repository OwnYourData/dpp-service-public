# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2.8"    # oydid requires >= 3.2.8

# --- Core -------------------------------------------------------------------
gem "rails", "~> 7.1"
gem "puma", ">= 6.0"          # HTTPS/HTTP2 capable app server (TLS terminated per prEN 18216)
gem "rack-cors"              # controlled cross-origin access for browser DPP viewers

# --- API docs ---------------------------------------------------------------
# Serves the derived docs/openapi.yaml and a Swagger UI.
gem "rswag-api"
gem "rswag-ui"

# --- Auth (prEN 18239 / prEN 18216: OAuth 2.0 / OpenID Connect, JWT) ---------
gem "jwt"                    # verify bearer access tokens (oydid pulls jwt ~> 3.1)

# --- Decentralized identifiers (prEN 18219: W3C DID; did:oyd) -----------------
# require:false — loaded lazily by DidOyd so the app boots without libsodium
# (needed only when a DID is actually minted/revoked, e.g. in production).
#
# Pinned to >= 0.6.4: 0.5 split :doc_location into :location + :doc_location and
# made :key_type mandatory, 0.6 corrected the public-key multicodec encoding
# (z6Mv... -> z6Mk...). Anything below 0.6 mints DIDs whose keys carry the old,
# non-conformant encoding, so this must not float downwards.
gem "oydid", "~> 0.6", ">= 0.6.4", require: false

group :development, :test do
  gem "rspec-rails"
  gem "debug"
  gem "sqlite3", "~> 1.7"    # dev/test only; production uses pg (see below)
end

group :production do
  gem "pg", "~> 1.5"
end
