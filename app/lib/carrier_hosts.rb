# frozen_string_literal: true

# The hosts on which this service answers what a data carrier bears: the
# unique product identifier itself (EN 18219:2026 3.1.25, 4.5.2 (1)), for the
# passports it keeps (CarrierController, docs/Identifiers.md section 3).
#
# A product identifier names a host, and whoever answers on that host
# answers for the passport. For a passport at a custodian that is the
# custodian; for a passport in this service's own database it is this
# service, on the hosts listed in DPP_CARRIER_HOSTS (comma-separated). Each of
# them reaches this service by DNS, and the proxy in front of it needs a rule
# and a certificate for it. On a carrier host nothing but the carrier path is
# served; the API stays on the host it has always had.
#
# The API host itself may be listed as well, for an instance that has one host
# only. There the API, the start page and everything else this service serves
# keep their paths, and only a path that none of them takes is looked up as a
# product identifier (OnApiHost). A product identifier on that host must
# therefore not begin with one of those paths; a GS1 Digital Link never does.
#
# Also a routing constraint: config/routes.rb sends every request for one of
# these hosts to CarrierController.
module CarrierHosts
  VARIABLE = "DPP_CARRIER_HOSTS"

  module_function

  # The configured hosts, lower-cased, in the order given. Read on every call,
  # so that a test or a console can change the variable; it is one ENV lookup.
  def list
    ENV.fetch(VARIABLE, "").split(",").map { |host| host.strip.downcase }.reject(&:empty?).uniq
  end

  def serves?(host)
    list.include?(host.to_s.downcase)
  end

  # The host of this service's API, from DPP_SERVICE_ENDPOINT_BASE.
  def api_host
    URI.parse(DidOyd.endpoint_base).host.to_s.downcase
  rescue URI::InvalidURIError
    ""
  end

  def api_host?(host)
    !api_host.empty? && host.to_s.downcase == api_host
  end

  # Routing constraint for a host that carries identifiers and nothing else.
  def matches?(request)
    serves?(request.host) && !api_host?(request.host)
  end

  # Routing constraint for the API host when it is listed too: drawn after
  # every other route, so that it only sees paths nothing else takes.
  module OnApiHost
    module_function

    def matches?(request)
      CarrierHosts.api_host?(request.host) && CarrierHosts.serves?(request.host)
    end
  end
end
