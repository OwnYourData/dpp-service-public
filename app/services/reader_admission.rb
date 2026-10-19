# frozen_string_literal: true

# Whether the custodian has entered this service as protected reader of a
# collection (docs/Delegation.md §3). Asked before a passport with attributes
# that are not public is written there (docs/AccessClasses.md §6): the
# controlled card is held for readers with access rights, and this service
# reads it for them under its own read grant. At a collection without that
# reader no one could read the controlled part through this service, so such a
# passport is refused there before anything is written (Dpp::ReaderNotEntered).
#
# The answer is the custodian's token endpoint: a token under the read grant
# means the reader is entered; 400 invalid_grant means it is not. A token this
# service already holds for the collection counts as a yes without asking
# again.
#
# Each answer is kept in this process for a while, keyed by pod, collection and
# reader DID: an entered reader for ADMITTED_TTL, a missing one for REFUSED_TTL,
# so that a reader the custodian enters meanwhile is seen within a minute. A
# custodian that cannot be asked leaves the question open: nothing is kept, and
# the write is refused as an upstream failure. Neither grant nor token is kept
# here or written to the log.
module ReaderAdmission
  ADMITTED_TTL = 900
  REFUSED_TTL  = 60

  module_function

  # :entered, :not_entered, or :no_reader when no reader DID is configured for
  # the pod. Raises PodStorage::Error when the custodian cannot be asked.
  def check(base_url, collection_id, now: Time.now.utc)
    reader = ReaderDid.for_pod(base_url)
    return :no_reader if reader.nil?

    key = [ControlledCards.normalize(base_url), collection_id.to_s, reader.did]
    known = lookup(key, now)
    return known if known

    answer = ask(reader, collection_id)
    remember(key, answer, now)
    Rails.logger.info("[reader] collection #{collection_id} at #{base_url}: reader #{reader.did} " \
                      "#{answer == :entered ? 'entered' : 'not entered'} (kept #{ttl(answer)} s)")
    answer
  end

  def reset!
    mutex.synchronize { cache.clear }
  end

  def ask(reader, collection_id)
    PodStorage::ProtectedReader.new(reader, collection_id).token
    :entered
  rescue PodStorage::ProtectedReader::NotAdmitted
    :not_entered
  rescue PodStorage::Error => e
    raise PodStorage::Error, "whether this service is entered as reader of collection #{collection_id} at " \
                             "the custodian #{reader.pod} could not be checked (#{e.message}); nothing was written"
  end
  private_class_method :ask

  def ttl(answer) = answer == :entered ? ADMITTED_TTL : REFUSED_TTL
  private_class_method :ttl

  def lookup(key, now)
    mutex.synchronize do
      entry = cache[key]
      entry && entry[:until] > now ? entry[:answer] : nil
    end
  end
  private_class_method :lookup

  def remember(key, answer, now)
    mutex.synchronize { cache[key] = { answer: answer, until: now + ttl(answer) } }
  end
  private_class_method :remember

  def cache = (@cache ||= {})
  private_class_method :cache

  def mutex = (@mutex ||= Mutex.new)
  private_class_method :mutex
end
