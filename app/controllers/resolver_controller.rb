# frozen_string_literal: true

# Short-link resolver for the EU DPP Registry Unique Product Identifier (UPI).
#
# The Registry requires the UPI to be an https URL (<= 50 chars) that resolves
# with a DIRECT 200 — no redirect chains, no auth. This serves the public DPP
# document under a short path (https://r.oydapp.eu/p/<short_id>).
class ResolverController < ApplicationController
  # GET /p/:short_id  — public, unauthenticated, direct 200.
  def show
    dpp = Dpp.find_by!(short_id: params[:short_id])
    render_dpp(dpp.to_document)
  end
end
