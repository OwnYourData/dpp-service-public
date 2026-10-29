# frozen_string_literal: true

require "rails_helper"

# An image built from this repository holds no more than the public snapshot:
# every pattern the mirror leaves out (.publish-exclude) is left out of the
# build context as well (.dockerignore). The public repository has no
# .publish-exclude, so there is nothing to compare there.
RSpec.describe ".dockerignore" do
  def patterns(file)
    File.readlines(Rails.root.join(file), chomp: true).map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
  end

  it "leaves out everything the public snapshot leaves out" do
    mirror = Rails.root.join(".publish-exclude")
    skip "no .publish-exclude in this repository" unless File.exist?(mirror)

    docker = patterns(".dockerignore")
    missing = patterns(".publish-exclude").map { |pattern| pattern.delete_suffix("/") }.reject do |pattern|
      # rsync applies a pattern without "/" at every depth, Docker at the root only.
      pattern.include?("/") ? docker.include?(pattern) : docker.include?("**/#{pattern}")
    end

    expect(missing).to be_empty, "in .publish-exclude but not in .dockerignore: #{missing.join(', ')}"
  end
end
