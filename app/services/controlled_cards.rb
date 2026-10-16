# frozen_string_literal: true

# Which custodians hold controlled cards (DigitalProductPassportControlled, see
# PassportSplit). A pod holds them once it lets a write delegation cover the
# controlled card of its passport and serves only the public card on its
# public paths; until then a passport with an access policy is not split
# there.
#
# Configuration, from the environment like the reader DIDs:
#
#   DPP_CONTROLLED_CARD_PODS   base URLs of the pods, comma-separated, exactly
#                              as the pod knows itself (no trailing slash)
#
# A passport whose access policy leaves attributes that are not public is
# refused for a pod not listed here: the custodian would publish them, and a
# value it has published cannot be called back.
module ControlledCards
  ENV_NAME = "DPP_CONTROLLED_CARD_PODS"

  module_function

  def pods(env = ENV)
    env[ENV_NAME].to_s.split(",").map { |url| normalize(url) }.reject(&:empty?).uniq
  end

  def held_by?(base_url, env = ENV)
    url = normalize(base_url)
    !url.empty? && pods(env).include?(url)
  end

  def normalize(url) = url.to_s.strip.chomp("/")
end
