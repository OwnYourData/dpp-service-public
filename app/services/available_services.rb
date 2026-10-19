# frozen_string_literal: true

require "json"
require "uri"

# The list of DPP services on the start page, with what the DPP Linter and the
# DPP Service Validator found about each.
#
# The list is published as JSON by dpp-validator. This class fetches it, keeps
# it for an hour and, when fetching fails or brings back something that is not
# such a list, goes on showing the last good one. Until a source is configured
# (DPP_AVAILABLE_SERVICES_URL), or before the first fetch has succeeded, the
# list shipped in config/available_services.json is the last good one.
#
# Fetching happens while the start page is being answered, so it is short: a
# few seconds at most, by one thread at a time. A thread that finds another one
# fetching shows what is there instead of waiting.
class AvailableServices
  SOURCE_ENV = "DPP_AVAILABLE_SERVICES_URL"
  SEED = File.expand_path("../../config/available_services.json", __dir__)
  TTL = 3600
  RETRY_AFTER = 300
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3
  MAX_BYTES = 1_000_000

  class InvalidList < StandardError; end

  class << self
    def default
      @default_lock.synchronize { @default ||= new(url: ENV[SOURCE_ENV]) }
    end

    def entries
      default.entries
    end

    def notice
      default.notice
    end

    # For specs: the next call to +default+ reads the environment again.
    def reset!
      @default_lock.synchronize { @default = nil }
    end
  end
  @default_lock = Mutex.new

  attr_reader :url

  def initialize(url:, seed: SEED, ttl: TTL, retry_after: RETRY_AFTER,
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @url = usable_url(url)
    @ttl = ttl
    @retry_after = retry_after
    @clock = clock
    @lock = Mutex.new
    @list = parse(File.read(seed, encoding: "UTF-8"))
    @next_fetch_at = @clock.call
  end

  # The services in the order of the page: this service first, then the
  # entries their operators maintain, then those from our research, each
  # group by name.
  def entries
    Entry.sorted(list.fetch("services"))
  end

  # What the list says about its results, shown under the table.
  def notice
    list.fetch("notice").strip
  end

  # The last good list, fetched again when it is due.
  def list
    refresh if due?
    @list
  end

  private

  def due?
    !@url.nil? && @clock.call >= @next_fetch_at
  end

  def refresh
    return unless @lock.try_lock

    begin
      return unless due?

      @list = parse(fetch)
      @next_fetch_at = @clock.call + @ttl
    rescue StandardError => e
      Rails.logger.warn("available services: keeping the last good list (#{e.class}: #{e.message})")
      @next_fetch_at = @clock.call + @retry_after
    ensure
      @lock.unlock
    end
  end

  def fetch
    res = OutboundHttp.request(:get, @url, headers: { "Accept" => "application/json" },
                                           open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
    raise InvalidList, "HTTP #{res.code}" unless res.code == "200"
    raise InvalidList, "more than #{MAX_BYTES} bytes" if res.body.to_s.bytesize > MAX_BYTES

    res.body
  end

  # A list is good when it carries its notice, names at least one service and
  # every entry has a name. The notice says what the results are and are not;
  # the page shows it under the table and has no wording of its own for it, so
  # a list without one is not taken. Everything else in an entry is optional;
  # what is missing is not shown.
  def parse(body)
    doc = JSON.parse(body.to_s)
    services = doc.is_a?(Hash) ? doc["services"] : nil
    raise InvalidList, "no list of services" unless services.is_a?(Array) && services.any?
    raise InvalidList, "no notice" unless doc["notice"].is_a?(String) && !doc["notice"].strip.empty?

    unless services.all? { |s| s.is_a?(Hash) && s["name"].is_a?(String) && !s["name"].strip.empty? }
      raise InvalidList, "an entry without a name"
    end

    doc
  rescue JSON::ParserError
    raise InvalidList, "not JSON"
  end

  def usable_url(value)
    return nil if value.to_s.strip.empty?

    uri = URI.parse(value.strip)
    return uri.to_s if uri.is_a?(URI::HTTPS) && uri.host.present?

    Rails.logger.warn("available services: #{SOURCE_ENV} is not an https URL, the shipped list is shown")
    nil
  rescue URI::InvalidURIError
    Rails.logger.warn("available services: #{SOURCE_ENV} is not a URL, the shipped list is shown")
    nil
  end
end
