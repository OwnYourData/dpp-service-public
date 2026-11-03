# frozen_string_literal: true

require "rails_helper"
require "yaml"

# The daily CronJob for bin/rails newsletter:prune runs the image, the
# configuration and the secrets of the service itself, so that one apply sets
# them together. The cluster manifest stays in the private repository.
RSpec.describe "k8s/dpp-service.yaml: newsletter:prune" do
  let(:path) { Rails.root.join("k8s/dpp-service.yaml") }
  let(:docs) { YAML.load_stream(path.read) }
  let(:deployment) { docs.find { |d| d["kind"] == "Deployment" } }
  let(:cronjob) { docs.find { |d| d["kind"] == "CronJob" && d.dig("metadata", "name") == "dpp-service-newsletter-prune" } }
  let(:service_container) { deployment.dig("spec", "template", "spec", "containers").first }
  let(:job_spec) { cronjob.dig("spec", "jobTemplate", "spec") }
  let(:job_container) { job_spec.dig("template", "spec", "containers").first }

  before { skip "no cluster manifest in this repository" unless path.exist? }

  it "runs once a day, never twice at the same time, and gives up after one retry" do
    expect(cronjob.dig("spec", "schedule")).to match(/\A\d{1,2} \d{1,2} \* \* \*\z/)
    expect(cronjob.dig("spec", "concurrencyPolicy")).to eq("Forbid")
    expect(job_spec["backoffLimit"]).to eq(1)
    expect(job_spec.dig("template", "spec", "restartPolicy")).to eq("Never")
    expect(job_container["command"]).to eq(%w[bundle exec rake newsletter:prune])
  end

  it "uses the image, the configuration and the secrets of the service" do
    expect(job_container["image"]).to eq(service_container["image"])
    expect(job_container["envFrom"]).to eq(service_container["envFrom"])
    expect(job_container["env"]).to eq(service_container["env"])
    expect(job_spec.dig("template", "spec", "imagePullSecrets")).to eq(deployment.dig("spec", "template", "spec", "imagePullSecrets"))
    expect(job_spec.dig("template", "spec", "securityContext")).to eq(deployment.dig("spec", "template", "spec", "securityContext"))
  end

  it "has requests and a memory limit" do
    expect(job_container.dig("resources", "requests").keys).to contain_exactly("cpu", "memory")
    expect(job_container.dig("resources", "limits", "memory")).to be_present
  end
end
