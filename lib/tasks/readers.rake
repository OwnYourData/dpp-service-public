# frozen_string_literal: true

namespace :dpp do
  namespace :readers do
    desc "Check the service DID and every reader DID: configured, distinct, resolvable, matching its key"
    task check: :environment do
      ok = true
      report = lambda do |label, good, detail|
        ok &&= good
        puts format("%-4s %-22s %s", good ? "ok" : "FAIL", label, detail)
      end

      if ServiceDid.configured?
        report.call("service", ServiceDid.consistent?, ServiceDid.did)
      else
        report.call("service", false, "DPP_SERVICE_DID / DPP_SERVICE_DOC_KEY not set")
      end

      begin
        readers = ReaderDid.all
        report.call("readers", false, "DPP_READERS not set") if readers.empty?
        readers.each do |reader|
          report.call("reader #{reader.name.downcase}", reader.consistent?, "#{reader.did} for #{reader.pod}")
        end
      rescue ReaderDid::ConfigError => e
        e.problems.each { |problem| report.call("readers", false, problem) }
      end

      abort("dpp:readers:check failed") unless ok
    end

    # Reads a pod-held passport the way the protected reader does, and says
    # what came back: whether the pod knows the reader, what the read token is
    # for, the object list, index card and meta of the controlled card, the
    # attribute paths it holds, and whether the public card names exactly that
    # payload. Values of attributes, the grant, the token and keys are never
    # printed.
    #
    #   bin/rails dpp:readers:measure DPP=<digitalProductPassportId>
    desc "Read a pod-held passport's controlled card as protected reader and report what came back"
    task measure: :environment do
      # Reads made here are logged as made for the measurement (AccessLog).
      AccessLog.with_purpose("measure") do
        dpp = Dpp.find(ENV.fetch("DPP"))
        abort("#{dpp.dpp_id} is not held by a custodian") unless dpp.pod?

        at = lambda do
          now = Time.now
          "#{now.utc.iso8601} (Wien #{now.in_time_zone('Europe/Vienna').strftime('%H:%M:%S')})"
        end
        step = lambda do |label, &block|
          value = block.call
          puts "#{at.call} #{label}: #{value}"
          value
        rescue PodStorage::Error => e
          puts "#{at.call} #{label}: #{e.class.name.demodulize} #{e.status_code} #{e.message}"
          nil
        end

        reader = PodStorage::ProtectedReader.for(dpp.storage_base_url, dpp.storage_collection_id, dpp_id: dpp.dpp_id)
        stored = dpp.storage_controlled_object_id
        puts "Pass #{dpp.dpp_id}, Pod #{reader.base_url}, Collection #{reader.collection_id}, " \
             "Leser #{reader.reader.did}, Lese-Vollmacht #{reader.grant_name}"
        puts "gespeicherte Objekt-IDs: oeffentlich #{dpp.storage_object_id}, kontrolliert #{stored.inspect}"

        granted = step.call("Lese-Grant (POST /oauth/token)") do
          reader.token
          answer = reader.last_grant_answer || {}
          "200, scope=#{answer['scope'].inspect}, expires_in=#{answer['expires_in'].inspect}"
        end
        puts "Pod kennt unseren Leser: #{granted ? 'ja' : 'nein'}"
        next unless granted

        step.call("GET /collection/#{reader.collection_id}/objects?page=all") do
          ids = reader.object_ids
          "200, #{ids.size} Objekte, kontrollierte Karte #{ids.include?(stored.to_s) ? 'enthalten' : 'fehlt'}"
        end
        step.call("GET /object/#{stored}") do
          card = reader.card(stored)
          "200, type=#{card['type'].inspect}, Passkennung #{card['digitalProductPassportId'] == dpp.dpp_id ? 'passt' : 'passt nicht'}"
        end
        step.call("GET /object/#{stored}/meta") { "200, updated-at=#{reader.meta(stored)['updated-at'].inspect}" }
        controlled = nil
        step.call("GET /object/#{stored}/read") do
          controlled = reader.read_object(stored)
          "200, Attribute der kontrollierten Karte: #{PassportSplit.attribute_paths(controlled).join(', ')}"
        end
        step.call("Rueckweg ohne gespeicherte Objekt-ID") do
          found = reader.locate_controlled_card(dpp.dpp_id)
          "#{found.inspect} (#{found.to_s == stored.to_s ? 'gleich der gespeicherten' : 'abweichend'})"
        end
        if controlled
          step.call("ControlledData der oeffentlichen Karte gegen die gelesene Nutzlast") do
            named = PassportSplit.named_digest(dpp.pod_reader.document(dpp.dpp_id))
            named.present? && named == PassportSplit.digest(controlled) ? "passt" : "passt nicht"
          end
        end
      end
    end
  end
end
