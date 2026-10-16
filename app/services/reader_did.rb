# frozen_string_literal: true

require "uri"

# The identities this service reads with as the protected statutory reader of
# DPP hosting collections (docs/Delegation.md §3). One per pod: the reader of
# a staging pod is not the reader of a production pod, so a key that leaks from
# a test cannot open a production collection, and the pod's disclosure shows
# which deployment read.
#
# Separate from ServiceDid, which redeems write delegations. A reader DID is
# never the service DID and never another pod's reader DID; the intermediary
# enters it per environment as a fixed value when a DPP hosting contract is
# signed, and /.well-known/dpp-service lists it as a cross-check.
#
# Configuration, from the environment like the service DID:
#
#   DPP_READERS                 names of the readers, comma-separated
#   DPP_READER_<NAME>_POD       base URL of the pod, exactly as the pod knows it
#   DPP_READER_<NAME>_DID       did:oyd:… of the reader
#   DPP_READER_<NAME>_DOC_KEY   its document key, multibase (z1S5…)
#
# The reader for a passport is the one whose pod is the passport's
# storage_base_url. A configuration with a mistake in it is refused as a
# whole: no reader is published or used, and the problems are logged. Nothing
# else in the service depends on it, so the service keeps running.
class ReaderDid
  class ConfigError < StandardError
    attr_reader :problems

    def initialize(problems)
      @problems = problems
      super("reader DID configuration refused: #{problems.join('; ')}")
    end
  end

  NAME = /\A[A-Z][A-Z0-9_]*\z/

  attr_reader :name, :pod, :did

  def initialize(name:, pod:, did:, doc_key:)
    @name    = name
    @pod     = pod
    @did     = did
    @doc_key = doc_key
  end

  # Ed25519::SigningKey of this reader. Only ever in memory.
  def signing_key
    @signing_key ||= ServiceDid.signing_key_from(@doc_key, "DPP_READER_#{name}_DOC_KEY")
  end

  # Does the configured key belong to the DID as it resolves today?
  def consistent?
    resolved = DidTokenVerifier.public_key_for(did)
    !resolved.nil? && resolved.to_bytes == signing_key.verify_key.to_bytes
  rescue StandardError
    false
  end

  def discovery_entry = { "pod" => pod, "did" => did }

  # Never the key, not even in a console.
  def inspect = "#<ReaderDid #{name} pod=#{pod} did=#{did}>"

  class << self
    # All configured readers. Raises ConfigError when the configuration has
    # any problem; an empty list when none is configured.
    def all
      @all ||= load(ENV)
    end

    def for_pod(base_url)
      wanted = normalize_pod(base_url)
      configured.find { |reader| reader.pod == wanted }
    end

    # The readers, or none when the configuration is refused. For callers
    # that must not fail on it.
    def configured
      all
    rescue ConfigError
      []
    end

    # The "readers" member of /.well-known/dpp-service, or nil when there is
    # nothing to list -- the member is then left out rather than sent empty,
    # so a cross-check cannot read "no readers" as agreement.
    def discovery_entries
      entries = configured.map(&:discovery_entry)
      entries.empty? ? nil : entries
    end

    # Checked when the application starts. Logs, never raises.
    def boot_check(logger = Rails.logger)
      readers = all
      readers.each { |r| logger.info("[readers] #{r.name}: #{r.did} for #{r.pod}") }
      readers
    rescue ConfigError => e
      logger.error("[readers] #{e.message}; no reader DID is published or used")
      []
    end

    def reset!
      @all = nil
    end

    # Reads and checks a configuration. Collects every problem before
    # refusing, so one look at the log is enough to fix all of them.
    def load(env)
      names = env["DPP_READERS"].to_s.split(",").map(&:strip).reject(&:empty?)
      problems = []
      readers = names.map { |name| read_one(env, name, problems) }.compact

      problems << "a reader is listed twice" if names.uniq.size != names.size
      duplicates(readers.map(&:pod)).each { |pod| problems << "#{pod} has more than one reader" }
      duplicates(readers.map(&:did)).each { |did| problems << "#{did} is the reader of more than one pod" }
      service = ServiceDid.did
      readers.each do |reader|
        problems << "reader #{reader.name} is the service DID; it has to be a DID of its own" if reader.did == service
      end

      raise ConfigError, problems unless problems.empty?

      readers.freeze
    end

    def normalize_pod(value) = value.to_s.strip.chomp("/")

    private

    def read_one(env, name, problems)
      unless NAME.match?(name)
        problems << "reader name #{name.inspect} may only use A-Z, 0-9 and _"
        return nil
      end

      prefix  = "DPP_READER_#{name}_"
      pod     = normalize_pod(env["#{prefix}POD"])
      did     = env["#{prefix}DID"].to_s.strip
      doc_key = env["#{prefix}DOC_KEY"].to_s.strip
      before  = problems.size

      problems << "#{prefix}POD has to be an https URL without query or fragment" unless pod_url?(pod)
      problems << "#{prefix}DID has to be a did:oyd" unless did.start_with?("did:oyd:")
      problems << "#{prefix}DOC_KEY is missing" if doc_key.empty?
      return nil if problems.size > before

      reader = new(name: name, pod: pod, did: did, doc_key: doc_key)
      begin
        reader.signing_key
      rescue ServiceDid::NotConfigured => e
        problems << e.message
        return nil
      end
      reader
    end

    def pod_url?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTPS) && uri.host.present? && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def duplicates(values) = values.tally.select { |_, count| count > 1 }.keys
  end
end
