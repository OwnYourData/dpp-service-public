# frozen_string_literal: true

require "erb"

# Where the AAS view of a passport is, and where the passport it is derived
# from is (docs/AAS.md). The read paths name the view in a Link header; the
# view names the passport, in its own Link header and in the shell.
module AasViewLink
  extend ActiveSupport::Concern

  # Not a registered relation of its own: an alternate representation of the
  # passport, which a client tells apart by the title.
  AAS_LINK_TITLE = "Asset Administration Shell (AAS V3.0)"

  # The address of the AAS view, which is also the identifier of its shell.
  def aas_view_url(dpp) = "#{api_base_url}/dpp/v1/dpps/#{ERB::Util.url_encode(dpp.dpp_id)}/aas"

  # ReadDPPById in the full representation: the form the signature of the
  # economic operator and the payload commitment cover (docs/Integrity.md).
  def source_passport_url(dpp)
    "#{api_base_url}/dpp/v1/dpps/#{ERB::Util.url_encode(dpp.dpp_id)}?representation=full"
  end

  # On ReadDPPById, ReadDPPByProductId and the carrier path.
  def link_aas_view(dpp)
    add_link(%(<#{aas_view_url(dpp)}>; rel="alternate"; type="application/json"; title="#{AAS_LINK_TITLE}"))
  end

  def add_link(value)
    current = response.get_header("Link").to_s
    response.set_header("Link", current.empty? ? value : "#{current}, #{value}")
  end

  private

  def api_base_url = DidOyd.endpoint_base.to_s.delete_suffix("/")
end
