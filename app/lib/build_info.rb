# frozen_string_literal: true

require "json"

# What this instance was built from, for GET /version: the image tag and the
# commit, handed in as build arguments (Dockerfile, k8s/deploy.sh) and kept in
# the environment of the container. Public, like /up: a deploy check reads the
# running state without access to the cluster, and neither value is a secret.
#
# A value that was not handed in is null rather than a guess, so a build
# without the arguments says so instead of naming a state it does not know.
module BuildInfo
  module_function

  def image_tag = value("DPP_IMAGE_TAG")
  def commit = value("DPP_COMMIT")

  def to_h
    { "service" => "dpp-service", "imageTag" => image_tag, "commit" => commit }
  end

  def to_json(*) = JSON.generate(to_h)

  def value(name)
    ENV.fetch(name, "").strip.presence
  end
end
