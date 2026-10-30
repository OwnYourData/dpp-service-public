# frozen_string_literal: true

# Google Ads conversion measurement for the start page and the pages around it
# (ConsentController, docs/Consent.md).
#
# Everything comes from the environment. Without a valid GOOGLE_ADS_ID the
# feature is off: no consent banner, no script, no request to Google. A
# conversion without a valid label is not measured; the others still are.
#
#   GOOGLE_ADS_ID                  AW-<digits>, the conversion ID of the account
#   GOOGLE_ADS_LABEL_GET_STARTED   click on "Getting started" or the DPP Manager image
#   GOOGLE_ADS_LABEL_GITHUB        click on a source repository on GitHub
#   GOOGLE_ADS_LABEL_NEWSLETTER    confirmed newsletter subscription
module GoogleAds
  ID_FORMAT = /\AAW-\d{6,15}\z/
  LABEL_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

  CONVERSIONS = {
    "get_started" => "GOOGLE_ADS_LABEL_GET_STARTED",
    "github" => "GOOGLE_ADS_LABEL_GITHUB",
    "newsletter" => "GOOGLE_ADS_LABEL_NEWSLETTER"
  }.freeze

  module_function

  # The conversion ID, or nil when it is missing or malformed. A malformed
  # value counts as missing: a typo must not load a tag nobody can account for.
  def id
    value = ENV["GOOGLE_ADS_ID"].to_s.strip
    value if value.match?(ID_FORMAT)
  end

  def enabled? = !id.nil?

  # send_to targets ("AW-…/label") by conversion name, only those with a valid
  # label.
  def conversions
    return {} unless enabled?

    CONVERSIONS.each_with_object({}) do |(name, variable), targets|
      label = ENV[variable].to_s.strip
      targets[name] = "#{id}/#{label}" if label.match?(LABEL_FORMAT)
    end
  end

  # What the consent script needs, nil when the feature is off.
  def client_config
    return nil unless enabled?

    { "id" => id, "conversions" => conversions }
  end
end
