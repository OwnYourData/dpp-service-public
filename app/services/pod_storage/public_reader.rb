# frozen_string_literal: true

require "erb"

class PodStorage
  # The custodian's public read paths (EN 18222:2026 Clause 4): no token, no
  # delegation, no key of this service.
  #
  # Everything this service reads of a passport's public part goes this way --
  # the read paths of its own API as well as the read before an UpdateDPP or a
  # change of custodian. A write mandate is therefore never needed to read: a
  # passport stays readable through this service after its delegation has
  # expired or the custodian has stopped accepting writes for it, exactly as it
  # stays readable at the custodian itself (docs/Delegation.md §12).
  #
  # The passport is addressed by its digitalProductPassportId, the field the
  # index card carries, percent-encoded as one path segment. The custodian
  # answers with the bytes it stores: `representation=full` is asked for
  # explicitly, because this service converts to whatever its own client wants
  # (DppRepresentation) and needs the stored document, not a custodian's
  # default.
  class PublicReader
    attr_reader :base_url

    def initialize(base_url)
      @base_url = base_url.to_s.strip.chomp("/")
      raise ConfigError, "storage configuration: base_url is required" if @base_url.empty?
    end

    # The stored document of the passport. Raises Error with
    # ClientErrorResourceNotFound when the custodian does not have it, and
    # ServerErrorBadGateway when it cannot be reached or answers with anything
    # other than a JSON object.
    def document(dpp_id)
      get("/dpp/v1/dpps/#{segment(dpp_id)}?representation=full")
    end

    # State at +date+ (ReadDPPVersionByIdAndDate), or nil when the custodian
    # has no version for that date.
    def version_at(dpp_id, date)
      get("/dpp/v1/dppsByIdAndDate/#{segment(dpp_id)}" \
          "?date=#{ERB::Util.url_encode(date.utc.iso8601)}&representation=full")
    rescue Error => e
      raise e unless e.status_code == "ClientErrorResourceNotFound"

      nil
    end

    private

    def segment(dpp_id)
      ERB::Util.url_encode(dpp_id.to_s)
    end

    # `Cache-Control: no-cache` because the custodian marks these answers as
    # publicly cacheable for a minute. A shared cache in between must not hand
    # back the state before the last write: a merge patch applied to it would
    # silently undo that write.
    def get(path)
      response = OutboundHttp.request(:get, "#{base_url}#{path}",
                                      headers: { "Accept" => "application/json",
                                                 "Cache-Control" => "no-cache" },
                                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      handle(response, path)
    rescue OutboundHttp::TimeoutError
      raise Error, "Pod #{base_url} timed out on GET #{path}"
    rescue OutboundHttp::ConnectionError => e
      raise Error, "Pod #{base_url} unreachable (#{e.message})"
    end

    def handle(response, path)
      case response.code.to_i
      when 200 then parse(response, path)
      when 404
        raise Error.new("Pod: not found (GET #{path})", status_code: "ClientErrorResourceNotFound")
      else
        raise Error, "Pod #{base_url} returned #{response.code} on GET #{path}"
      end
    end

    # Anything but a JSON object is refused rather than read as an empty
    # passport: an UpdateDPP built on an empty document would write the
    # passport back without its content.
    def parse(response, path)
      parsed = JSON.parse(response.body.to_s)
      return parsed if parsed.is_a?(Hash)

      raise Error, "Pod #{base_url} answered GET #{path} with something other than a JSON object"
    rescue JSON::ParserError
      raise Error, "Pod #{base_url} answered GET #{path} with something other than JSON"
    end
  end
end
