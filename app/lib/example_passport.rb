# frozen_string_literal: true

require "uri"

# The passport behind "Example passport" on the start page. Without
# DPP_EXAMPLE_PASSPORT_URL it is the reference passport of the public instance;
# an instance with passports of its own names one of them there. Only an
# absolute http(s) address is taken; anything else falls back to the
# reference passport.
module ExamplePassport
  VARIABLE = "DPP_EXAMPLE_PASSPORT_URL"
  DEFAULT = "https://dpp.oydapp.eu/01/09520123456788/21/000001"

  module_function

  def url
    value = ENV[VARIABLE].to_s.strip
    return DEFAULT if value.empty?

    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) && uri.host.to_s != "" ? value : DEFAULT
  rescue URI::InvalidURIError
    DEFAULT
  end
end
