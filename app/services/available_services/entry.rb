# frozen_string_literal: true

require "uri"

class AvailableServices
  # One row of the list on the start page, read from one entry of the JSON.
  # Missing fields are tolerated: what is not there is not shown.
  class Entry
    # What the page says for a service the validator has not checked, by status.
    STATUS_TEXT = {
      "pending" => "first run pending",
      "needs_credentials" => "needs credentials",
      "no_public_instance" => "no public instance",
      "no_en18222_paths" => "no EN 18222 paths yet"
    }.freeze
    OTHER_STATUS_TEXT = "not checked"

    # A count of checks with the tone it is shown in: :pass when all passed,
    # :warn from 75 % on, :fail below, :neutral when nothing was counted.
    Count = Struct.new(:passed, :total) do
      def text
        "#{passed} of #{total}"
      end

      def tone
        return :neutral unless total.positive?
        return :pass if passed >= total
        return :warn if passed * 4 >= total * 3

        :fail
      end
    end

    # One example passport and what the DPP Linter found.
    Passport = Struct.new(:label, :lint_url, :count, :warnings, :note, keyword_init: true) do
      # What is said after the count: the warnings and the note of the entry.
      def details
        list = []
        list << "#{warnings} #{warnings == 1 ? 'warning' : 'warnings'}" if warnings.positive?
        list << note if note
        list
      end
    end

    def self.sorted(services)
      services.map { |s| new(s) }.sort_by(&:sort_key)
    end

    def initialize(data)
      @data = data
    end

    def name
      @data["name"].to_s.strip
    end

    def url
      web_url(@data["url"])
    end

    def this_service?
      @data["this_service"] == true
    end

    def provider
      [dig("provider", "name"), dig("provider", "country")].map { |v| v.to_s.strip }.reject(&:empty?).join(" · ")
    end

    # :operator, :research or nil.
    def source
      case dig("entry", "source")
      when "operator" then :operator
      when "research" then :research
      end
    end

    def as_of
      dig("entry", "as_of").to_s.strip.presence
    end

    def sort_key
      rank = if this_service? then 0
             elsif source == :operator then 1
             else 2
             end
      [rank, name.downcase, name]
    end

    def licence
      dig("licence", "text").to_s.strip.presence
    end

    # The counts are shown as the list gives them: +passed+ includes the checks
    # that ended in a warning, +total+ is passed plus failed. The warnings are
    # named beside the count.
    def passports
      Array(dig("linter", "passports")).select { |p| p.is_a?(Hash) }.map do |p|
        warnings = integer(p["warnings"]) || 0
        passed = integer(p["passed"])
        total = integer(p["total"])
        count = (Count.new(passed, total) if passed && total && passed.between?(0, total))
        Passport.new(label: p["label"].to_s.strip.presence || "example passport",
                     lint_url: web_url(p["lint_url"]),
                     count: count,
                     warnings: warnings,
                     note: p["note"].to_s.strip.presence)
      end
    end

    def linter_note
      dig("linter", "note").to_s.strip.presence
    end

    def validator_checked?
      dig("validator", "status") == "checked"
    end

    def validator_count
      passed = integer(dig("validator", "passed"))
      total = integer(dig("validator", "total"))
      Count.new(passed, total) if passed && total
    end

    # Checks of the service that passed with a warning; like the linter's, they
    # are included in the count and named beside it.
    def validator_warnings
      integer(dig("validator", "warnings")) || 0
    end

    def validator_warnings_text
      w = validator_warnings
      "#{w} #{w == 1 ? 'warning' : 'warnings'}" if w.positive?
    end

    def validator_details_url
      web_url(dig("validator", "details_url"))
    end

    def proposed_failed
      integer(dig("validator", "proposed_failed")) || 0
    end

    # For a service that was not checked: why, in a few words.
    def validator_status_text
      STATUS_TEXT.fetch(dig("validator", "status").to_s, OTHER_STATUS_TEXT)
    end

    # The line under the result or the status: the note of the entry, or how
    # the service is checked.
    def validator_detail
      note = dig("validator", "note").to_s.strip.presence
      parts = []
      parts << proposed_failed_text if validator_checked? && proposed_failed.positive?
      if note && !validator_checked?
        parts << note
      elsif dig("validator", "mode") == "read-only"
        parts << ["read paths only", cadence].compact.join(" · ")
      elsif cadence
        parts << cadence
      end
      parts.join(" · ").presence
    end

    private

    def proposed_failed_text
      "#{proposed_failed} proposed #{proposed_failed == 1 ? 'criterion' : 'criteria'} failed"
    end

    def cadence
      dig("validator", "cadence").to_s.strip.presence
    end

    def dig(*keys)
      keys.reduce(@data) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end

    def integer(value)
      value.is_a?(Integer) ? value : nil
    end

    # Only web addresses become links; anything else in the list is not one.
    def web_url(value)
      uri = URI.parse(value.to_s.strip)
      uri.to_s if (uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end
  end
end
