# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.2.8"    # oydid requires >= 3.2.8

# --- Core -------------------------------------------------------------------
gem "rails", "~> 7.1"
gem "puma", ">= 6.0"          # HTTPS/HTTP2 capable app server (TLS terminated per EN 18216:2026)
gem "rack-cors"              # controlled cross-origin access for browser DPP viewers

# --- API docs ---------------------------------------------------------------
# Serves the derived docs/openapi.yaml and a Swagger UI.
gem "rswag-api"
gem "rswag-ui"

# --- Auth (EN 18239:2026 / EN 18216:2026: OAuth 2.0 / OpenID Connect, JWT) -
gem "jwt"                    # verify bearer access tokens (oydid pulls jwt ~> 3.1)
gem "httpx", "~> 1.8"        # outbound HTTPS over HTTP/2 to custodians (EN 18216:2026 4)

# --- Decentralized identifiers (EN 18219:2026: W3C DID; did:oyd) -------------
# require:false — loaded lazily by DidOyd so the app boots without libsodium
# (needed only when a DID is actually minted/revoked, e.g. in production).
#
# The pin is a floor, not a preference: DidOyd relies on :location and
# :doc_location being separate options, on :key_type being accepted, and on
# document keys being published under the ed25519-pub multicodec (z6Mk...).
#
# The floor is 0.9.7 for the reason that surfaces when a DID update fails:
# earlier versions report every rejection by the repository as "invalid response
# from <location>/doc", because they call parsed_response with an argument and
# swallow the real message in a rescue. 0.9.7 passes the repository's own reason
# through — which is what makes a failed payload commitment diagnosable instead
# of a guessing game.
gem "oydid", "~> 0.9", ">= 0.9.7", require: false

# RFC 8785: the controlled part of a split passport is named by a digest over
# its canonical JSON (PassportSplit). Already a dependency of oydid; named here
# because this service relies on it directly.
gem "json-canonicalization", "~> 1.0"

group :development, :test do
  gem "rspec-rails"
  gem "debug"
  gem "sqlite3", "~> 1.7"    # dev/test only; production uses pg (see below)
end

group :production do
  gem "pg", "~> 1.5"
end
