# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

# Client für einen Hosting-Pod des Datenintermediärs (dc-pod / pod-dpp).
#
# Der Pod wird vom Intermediär vorab provisioniert; das DPP Service bekommt je
# Speicherort ein JWT mit den OAuth2-Parametern:
#
#   { "base_url": "https://dpp.go-data.at", "collection_id": "1",
#     "client_id": "…", "client_secret": "…" }
#
# Daraus erzeugt dieser Client per client_credentials einen Bearer-Token und
# schreibt bzw. liest über die Standard-API des Pods. Ein DPP besteht dort aus
# zwei Objekten: der Karteikarte (POST /object) und dem Payload
# (PUT /object/:id/write) — das eigentliche DPP-Dokument nach prEN 18223.
#
# Bewusst ohne zusätzliche Gems: Net::HTTP aus der Standardbibliothek.
class PodStorage
  # Fehler des Pods werden auf die generischen Statuscodes aus prEN 18222
  # (Tabelle 16) abgebildet.
  class Error < StandardError
    attr_reader :status_code

    def initialize(message, status_code: "ServerErrorBadGateway")
      super(message)
      @status_code = status_code
    end
  end

  class ConfigError < Error
    def initialize(message)
      super(message, status_code: "ClientErrorBadRequest")
    end
  end

  # Die EU-Registry verlangt für den UPI eine https-URL von höchstens
  # 50 Zeichen: len(base_url) + len("/p/") + len(short_id) <= 50.
  MAX_BASE_URL_LENGTH = 50 - "/p/".length - Dpp::SHORT_ID_LENGTH

  OPEN_TIMEOUT = Integer(ENV.fetch("POD_OPEN_TIMEOUT", 5))
  READ_TIMEOUT = Integer(ENV.fetch("POD_READ_TIMEOUT", 15))

  attr_reader :base_url, :collection_id, :client_id

  # --- Konstruktion ----------------------------------------------------------

  # Aus dem Storage-JWT, wie es der Datenintermediär ausstellt.
  # TODO: Signatur gegen den Schlüssel des Intermediärs prüfen, sobald geklärt
  # ist, wer das JWT ausstellt (siehe docs/Prompts_Datenintermediaer_260812.md).
  def self.from_jwt(raw)
    raise ConfigError, "Missing storage token" if raw.blank?

    payload = begin
      JWT.decode(raw.to_s, nil, false).first
    rescue JWT::DecodeError => e
      raise ConfigError, "Invalid storage token (#{e.message})"
    end
    from_hash(payload)
  end

  def self.from_hash(payload)
    payload = (payload || {}).with_indifferent_access
    new(base_url:      payload[:base_url],
        collection_id: payload[:collection_id],
        client_id:     payload[:client_id],
        client_secret: payload[:client_secret])
  end

  # Aus den verschlüsselt gespeicherten Zugangsdaten eines DPP.
  def self.for(dpp)
    return nil unless dpp.pod?

    raw = KeyVault.decrypt(dpp.storage_credentials_enc)
    raise ConfigError, "No storage credentials stored for this DPP" if raw.blank?

    from_hash(JSON.parse(raw))
  end

  def initialize(base_url:, collection_id:, client_id:, client_secret:)
    @base_url      = base_url.to_s.strip.chomp("/")
    @collection_id = collection_id.to_s.strip
    @client_id     = client_id.to_s
    @client_secret = client_secret.to_s
    validate!
  end

  # Für die verschlüsselte Ablage am DPP.
  def credentials_json
    { "base_url"      => base_url,
      "collection_id" => collection_id,
      "client_id"     => client_id,
      "client_secret" => @client_secret }.to_json
  end

  # --- Objekt-Lebenszyklus ---------------------------------------------------

  # Legt die Karteikarte an, über die pod-dpp den Passport wiederfindet.
  # Liefert die object-id.
  def create_object(dpp)
    body = {
      "collection-id"            => numeric_collection_id,
      "type"                     => "DigitalProductPassport",
      "short_id"                 => dpp.short_id,
      "DigitalProductPassportID" => dpp.dpp_id,
      "ProductID"                => dpp.product_id
    }
    response = request(:post, "/object", body: body, auth: true)
    id = response["object-id"] || response[:"object-id"]
    raise Error, "Pod did not return an object-id" if id.blank?

    id.to_s
  end

  # Schreibt das DPP-Dokument als Payload. Jede inhaltliche Änderung erzeugt im
  # Pod eine neue Payload-Row; die alte bleibt unter ihrem DRI abrufbar — das
  # ist die Versionshistorie nach prEN 18221.
  def write_payload(object_id, document)
    request(:put, "/object/#{object_id}/write", body: document, auth: true)
    true
  end

  def read_payload(object_id)
    request(:get, "/object/#{object_id}/read", auth: true)
  end

  # Soft-Delete: die Archivversionen bleiben erhalten (prEN 18221).
  def delete_object(object_id)
    request(:delete, "/object/#{object_id}", auth: true)
    true
  end

  # Stand zum Zeitpunkt +date+ — bedient von pod-dpp, öffentlich, ohne Token.
  def version_at(product_id, date)
    path = "/dpp/v1/dppsByProductIdAndDate/#{CGI.escape(product_id.to_s)}" \
           "?date=#{CGI.escape(date.utc.iso8601)}"
    request(:get, path, auth: false)
  rescue Error => e
    raise e unless e.status_code == "ClientErrorResourceNotFound"

    nil
  end

  # --- Token -----------------------------------------------------------------

  # Access Token, gecacht bis kurz vor Ablauf. dc-pod gibt keine Refresh Tokens
  # aus, Tokens sind per Default 2 Stunden gültig.
  def token
    key = [base_url, client_id]
    cached = self.class.token_cache_get(key)
    return cached if cached

    response = form_post("/oauth/token",
                         "grant_type"    => "client_credentials",
                         "client_id"     => client_id,
                         "client_secret" => @client_secret,
                         "scope"         => "write")
    access = response["access_token"].to_s
    raise Error.new("Pod returned no access_token", status_code: "ClientNotAuthorized") if access.empty?

    ttl = response["expires_in"].to_i
    ttl = 3600 if ttl <= 0
    self.class.token_cache_put(key, access, ttl)
    access
  end

  # Prüft Erreichbarkeit und Zugangsdaten, bevor irgendetwas Bleibendes
  # passiert (insbesondere bevor eine DID gemintet wird).
  def reachable!
    token
    true
  end

  class << self
    def token_cache_get(key)
      mutex.synchronize do
        entry = cache[key]
        next nil if entry.nil?
        next nil if entry[:expires_at] <= Time.now.utc

        entry[:token]
      end
    end

    def token_cache_put(key, token, ttl_seconds)
      mutex.synchronize do
        # 60 s Sicherheitsabstand, damit kein Request mit einem gerade
        # ablaufenden Token losläuft.
        cache[key] = { token: token,
                       expires_at: Time.now.utc + [ttl_seconds - 60, 30].max }
      end
    end

    def reset_token_cache!
      mutex.synchronize { cache.clear }
    end

    private

    def cache = (@cache ||= {})
    def mutex = (@mutex ||= Mutex.new)
  end

  private

  def validate!
    raise ConfigError, "storage token: base_url is required"      if base_url.empty?
    raise ConfigError, "storage token: collection_id is required" if collection_id.empty?
    raise ConfigError, "storage token: client_id is required"     if client_id.empty?
    raise ConfigError, "storage token: client_secret is required" if @client_secret.empty?

    unless base_url.start_with?("https://")
      raise ConfigError, "storage token: base_url must use https (prEN 18216 §6.2)"
    end

    if base_url.length > MAX_BASE_URL_LENGTH
      raise ConfigError,
            "storage token: base_url must not exceed #{MAX_BASE_URL_LENGTH} characters " \
            "so that the UPI stays within the Registry's 50-character limit"
    end

    URI.parse(base_url)
  rescue URI::InvalidURIError
    raise ConfigError, "storage token: base_url is not a valid URL"
  end

  # dc-pod erwartet die collection-id numerisch.
  def numeric_collection_id
    Integer(collection_id)
  rescue ArgumentError, TypeError
    collection_id
  end

  def request(method, path, body: nil, auth: true)
    headers = { "Accept" => "application/json" }
    headers["Content-Type"]  = "application/json" unless body.nil?
    headers["Authorization"] = "Bearer #{token}" if auth

    perform(method, path, headers, body.nil? ? nil : JSON.generate(body))
  end

  def form_post(path, form)
    perform(:post, path,
            { "Accept" => "application/json",
              "Content-Type" => "application/x-www-form-urlencoded" },
            URI.encode_www_form(form))
  end

  def perform(method, path, headers, payload)
    uri = URI.parse("#{base_url}#{path}")
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post,
              put: Net::HTTP::Put, delete: Net::HTTP::Delete }.fetch(method)

    req = klass.new(uri)
    headers.each { |k, v| req[k] = v }
    req.body = payload if payload

    response = Net::HTTP.start(uri.hostname, uri.port,
                               use_ssl: uri.scheme == "https",
                               open_timeout: OPEN_TIMEOUT,
                               read_timeout: READ_TIMEOUT) { |http| http.request(req) }

    handle(response, method, path)
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "Pod #{base_url} timed out on #{method.to_s.upcase} #{path}"
  rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
    raise Error, "Pod #{base_url} unreachable (#{e.class}: #{e.message})"
  end

  def handle(response, method, path)
    parsed = begin
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    case response.code.to_i
    when 200, 201, 204 then parsed
    when 401, 403
      self.class.reset_token_cache!
      raise Error.new("Pod rejected the credentials (#{response.code})",
                      status_code: "ClientNotAuthorized")
    when 404
      raise Error.new("Pod: not found (#{method.to_s.upcase} #{path})",
                      status_code: "ClientErrorResourceNotFound")
    else
      detail = parsed["error"] || parsed["message"] || response.message
      raise Error, "Pod #{base_url} returned #{response.code} on " \
                   "#{method.to_s.upcase} #{path}: #{detail}"
    end
  end
end
