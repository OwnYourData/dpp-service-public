# frozen_string_literal: true

# A Digital Product Passport instance.
#
# The header attributes of the EN 18223:2026 semantic model (Table 1) are stored
# as columns for querying; the full DPP document (header + elements
# + dataElements) is kept in +content+ as the single source of truth.
class Dpp < ApplicationRecord
  self.primary_key = "dpp_id"

  STATUSES     = %w[Active Archived].freeze
  GRANULARITIES = %w[model batch item].freeze

  # NOT dependent: :destroy — DeleteDPPById archives the current version and
  # removes the active passport; the archived versions must survive so that
  # ReadDPPVersionByIdAndDate keeps working (EN 18221:2026 4.2).
  has_many :dpp_versions, foreign_key: "dpp_id", primary_key: "dpp_id",
                          dependent: nil, inverse_of: :dpp

  # The access policy (AccessPolicy) this passport is classified by, if one
  # was named at CreateDPP or a later UpdateDPP. Kept in a column of this
  # service, never in the passport: EN 18223:2026 Table 1 has no attribute for
  # it. It can be replaced, but not removed.
  belongs_to :access_policy_record, class_name: "RegisteredAccessPolicy",
                                    foreign_key: :access_policy_id, optional: true, inverse_of: false

  validates :dpp_id, :product_id, :dpp_schema_version, :economic_operator_id, presence: true
  validates :dpp_status, inclusion: { in: STATUSES }
  validates :granularity, inclusion: { in: GRANULARITIES }

  # The product identifier has to be carrier-borne (see ProductIdentifier).
  # On create only: passports minted before the carrier redesign carry opaque
  # identifiers and must stay updatable.
  validate :product_id_is_a_carrier_identifier, on: :create
  before_validation :assign_product_key
  before_save :split_local_content, unless: :pod?
  before_save :discard_signature, if: :signature_affected?

  # What the public part of a passport is made of. A write that changes any of
  # them changes what the signature of the economic operator covers
  # (OperatorSignature), so that signature does not survive it.
  PUBLIC_ATTRIBUTES = %w[dpp_id product_id granularity dpp_schema_version dpp_status
                         economic_operator_id facility_id last_update content
                         controlled_content access_policy_id].freeze

  scope :active, -> { where(dpp_status: "Active") }

  # Whether the availability period (ESPR Art. 9(2)(i)) still holds the
  # passport on a given day. The last day itself is inside the period.
  def retained?(date = Date.current) = retain_until.present? && date <= retain_until

  # The Unique Product Identifier registered at the EU Registry.
  #
  # EN 18219:2026 3.1.25 defines it as *one* string that identifies the product and
  # "also enables a web link to the digital product passport", and §4.5.2 (1)
  # requires that same string to be retrievable from the data carrier. It is
  # therefore the product identifier itself -- no second carrier token exists.
  #
  # The host belongs to the economic operator and is pointed at the custodian by
  # CNAME, so changing custodian leaves printed carriers intact, which is what
  # 4.6.2 (3) (no vendor lock-in), 4.5.2 (4) (existing ID) and 3.1.25 (usable
  # outside the issuing assigner's control) ask for.
  def upi
    product_id
  end

  # The policy itself, or nil.
  def access_policy
    access_policy_record&.policy
  end

  # Every attribute of the passport as stored, with its access class, or nil
  # without a policy.
  def access_classification(document = to_document)
    access_policy&.classify(document)
  end

  # --- storage backend (S2: hosting pod of the data intermediary) --------------

  STORAGE_BACKENDS = %w[local pod].freeze
  validates :storage_backend, inclusion: { in: STORAGE_BACKENDS }

  # True when the DPP document lives in a hosting pod instead of this database.
  def pod?
    storage_backend == "pod"
  end

  # Writing: under the delegation the economic operator signed.
  def pod_storage
    @pod_storage ||= PodStorage.for(self)
  end

  # Reading: over the custodian's public paths, without a token. Reading never
  # depends on the delegation, so an expired or refused mandate leaves the
  # passport readable here as it does at the custodian.
  def pod_reader
    @pod_reader ||= PodStorage::PublicReader.new(storage_base_url)
  end

  # Attach a pod as the storage backend. What is kept is the delegation the
  # economic operator signed (docs/Delegation.md §9) — in the clear, because
  # without the private key of the service DID it is worth nothing to anyone.
  # No credential of the customer is stored here any more.
  def assign_pod_storage!(storage)
    # from_document put the inbound document into +content+; move it out so
    # nothing of the payload stays in this database.
    document = content.presence || {}
    self.storage_backend       = "pod"
    self.storage_base_url      = storage.base_url
    self.storage_collection_id = storage.collection_id
    self.storage_delegation    = storage.storage_delegation
    @pod_storage = storage
    @pod_reader  = nil
    self.document_content = document
    self
  end

  # Raised when a write would hand attributes that are not public to a
  # custodian that publishes everything it holds (ControlledCards).
  class ControlledPartNotHeld < StandardError; end

  # Raised when a write would hand attributes that are not public to a
  # collection at which the custodian has not entered this service as reader
  # (ReaderAdmission): no one could read them there with access rights. CODE
  # goes into the message of the refusal, so that a client recognises it
  # without reading the text; it is the reason a read of such a passport
  # gives (PassportAccess::READER_NOT_ENTERED).
  class ReaderNotEntered < ControlledPartNotHeld
    CODE = "readerNotEntered"
  end

  # Raised when no reader DID is configured for a custodian that is listed as
  # holding controlled cards (ReaderDid, ControlledCards).
  class ReaderNotConfigured < StandardError; end

  # The whole DPP document, without the header columns: locally the +content+
  # column; for a pod-backed DPP its public card, read over the custodian's
  # public path, and -- for a split passport -- its controlled card, read with
  # the write delegation (PassportSplit). Cached for the lifetime of this
  # instance. This is what a write starts from; the read paths use
  # +published_document+ and never touch the controlled card.
  def document_content
    return local_document unless pod?
    return @document_content if defined?(@document_content) && @document_content

    @document_content = split_stored? ? PassportSplit.merge(public_content, read_controlled_card) : public_content
  end

  def document_content=(value)
    if pod?
      @document_content = PassportSplit.strip(value)
      self.content = {}          # nothing of the payload stays behind locally
    else
      self.content = value
      self.controlled_content = nil
      @local_split_pending = true
    end
  end

  # What a reader without access rights gets: the public card for a pod-backed
  # DPP; for a local passport with an access policy its public part; for any
  # other local passport the whole passport. PassportAccess decides who gets
  # more.
  def published_document
    return with_header(public_content) if pod?
    return to_document if access_policy_record.nil?
    return with_header(content || {}) if controlled_content.present?

    # Kept whole, as before passports here were split: only what is public.
    with_header(access_policy.visible_for([], to_document))
  end

  # The controlled part as stored, with its salt, for a reader with access
  # rights (PassportAccess): for a pod-backed passport its controlled card,
  # read under this service's own read grant, never under the write
  # delegation; for a local passport the column. nil for a passport that is
  # not held as two parts.
  def controlled_part
    return controlled_content unless pod?
    return nil unless split_stored?

    id = controlled_card_id
    if id.nil?
      raise PodStorage::Error, "the public card of #{dpp_id} names a controlled card, and the custodian " \
                               "has none for it"
    end
    protected_reader.read_object(id)
  end

  # Keeps a local passport with an access policy as a public and a controlled
  # part, if it is still kept whole (passports from before this split).
  def split_locally!
    return false if pod? || access_policy_record.nil? || controlled_content.present?

    @local_split_pending = true
    save!
  end

  # This service as protected reader of the passport's collection.
  def protected_reader
    PodStorage::ProtectedReader.for(storage_base_url, storage_collection_id, dpp_id: dpp_id)
  end

  # Forget what was read from the custodian, so the next read asks again.
  def forget_read_content!
    @public_content = nil
    @document_content = nil
  end

  # Is this passport held as two cards? Known from the stored object id, or --
  # should that be lost -- from the public card, which names the controlled
  # one.
  def split_stored?
    return false unless pod?

    storage_controlled_object_id.present? ||
      (storage_object_id.present? && PassportSplit.named_digest(public_content).present?)
  end

  # Is it to be held as two cards from the next write on?
  def split_target?
    pod? && access_policy_record.present? && ControlledCards.held_by?(storage_base_url)
  end

  # Refuses +document+ for collection +collection_id+ at the custodian at
  # +base_url+ if the access policy leaves attributes of it that are not
  # public, and either the custodian does not hold controlled cards -- written
  # there, they would be published -- or it has not entered this service as
  # reader of the collection -- written there, no one could read them with
  # access rights (ReaderAdmission). Checked before anything is written.
  def ensure_controlled_part_held!(document, base_url, collection_id)
    return if access_policy.nil?

    controlled = access_policy.classify(document).classes.reject { |_, c| c == AccessClass.public_class }.keys
    return if controlled.empty?

    unless ControlledCards.held_by?(base_url)
      raise ControlledPartNotHeld,
            "the access policy leaves #{controlled.size} attribute(s) of this passport that are not public, " \
            "and the custodian at #{base_url} does not hold controlled parts: it would publish them"
    end

    ensure_reader_entered!(base_url, collection_id, controlled.size)
  end

  # Hand the passport to a different custodian.
  #
  # The document is read from the current pod while that one is still
  # authoritative -- the public card over its public path, so a mandate there
  # that has run out does not stand in the way of leaving; the controlled card,
  # if there is one, under that mandate -- then written into the new one under
  # fresh cards. What is returned describes the previous custody so the caller
  # can end it -- as a separate act, not as a side effect of this one.
  #
  # Deliberately NOT touched here: the old pod. The overlap is the rollback path
  # while a carrier may still resolve to the old host, and the version history
  # lives in the pod (EN 18221:2026 4.2 requires archived versions to be retained), so
  # releasing before the new custodian has been seen to answer would discard
  # exactly what has to be kept.
  def move_to_pod!(storage)
    raise ArgumentError, "only a pod-backed passport can be moved" unless pod?

    document = to_document
    previous = { storage: pod_storage, object_id: storage_object_id,
                 controlled_object_id: storage_controlled_object_id,
                 base_url: storage_base_url, collection_id: storage_collection_id }

    self.storage_base_url             = storage.base_url
    self.storage_collection_id        = storage.collection_id
    self.storage_delegation           = storage.storage_delegation
    self.storage_object_id            = nil
    self.storage_controlled_object_id = nil
    @pod_storage                      = storage
    @pod_reader                       = nil
    @public_content                   = nil
    @previous_controlled_paths        = []
    self.document_content             = document
    save!
    store_in_pod!

    previous
  end

  # Push the current document into the pod. Creates the cards on first use.
  def store_in_pod!
    return false unless pod?

    if split_target?
      store_split_in_pod!
    elsif split_stored?
      # Held as two cards, but the custodian is no longer listed as holding
      # controlled ones: writing the whole passport into the public card
      # would publish the controlled part.
      raise ControlledPartNotHeld,
            "this passport is held as a public and a controlled card, and the custodian at " \
            "#{storage_base_url} is not configured to hold controlled parts"
    else
      ensure_public_card!
      pod_storage.write_payload(storage_object_id, to_document)
    end
    true
  end

  private

  def ensure_reader_entered!(base_url, collection_id, count)
    case ReaderAdmission.check(base_url, collection_id)
    when :entered then nil
    when :no_reader
      raise ReaderNotConfigured,
            "this service has no reader DID for the custodian at #{base_url}, so the #{count} attribute(s) " \
            "of this passport that are not public could not be read there with access rights; nothing was written"
    else
      reader = ReaderDid.for_pod(base_url)
      raise ReaderNotEntered,
            "the custodian at #{base_url} has no reader entered for collection #{collection_id}, so the " \
            "#{count} attribute(s) of this passport that are not public could not be read there with access " \
            "rights. Nothing was written. Please ask the custodian to enter this service's reader " \
            "#{reader&.did} for the collection"
    end
  end

  # The public card's document, as the custodian serves it.
  def public_content
    return {} unless pod? && storage_object_id.present?

    @public_content ||= pod_reader.document(dpp_id)
  end

  # The controlled card's document, read with the write delegation. Its
  # attribute paths are remembered: a write needs to know what leaves the
  # controlled card.
  def read_controlled_card
    document = begin
      controlled_card_id ? pod_storage.read_object(storage_controlled_object_id) : nil
    rescue PodStorage::Error => e
      raise e unless e.status_code == "ClientErrorResourceNotFound"

      update_column(:storage_controlled_object_id, nil)
      controlled_card_id ? pod_storage.read_object(storage_controlled_object_id) : nil
    end

    if document.nil?
      raise PodStorage::Error, "the public card of #{dpp_id} names a controlled card, and the custodian " \
                               "has none for it; nothing is written, so that its values are not lost"
    end

    @previous_controlled_paths = PassportSplit.attribute_paths(document)
    document
  end

  # The object id of the controlled card, looked up at the custodian when it
  # is not stored here. Looking it up needs the object list and the index
  # cards, which a write delegation may not read; it is done under this
  # service's own read grant (PodStorage::ProtectedReader).
  def controlled_card_id
    if storage_controlled_object_id.blank?
      found = begin
        protected_reader.locate_controlled_card(dpp_id)
      rescue PodStorage::Error => e
        # A custodian that does not accept this service as reader stays
        # recognisable as such (PassportAccess).
        failure = e.is_a?(PodStorage::ProtectedReader::NotAdmitted) ? e.class : PodStorage::Error
        raise failure, "the object id of the controlled card of #{dpp_id} is not known here, " \
                       "and it could not be looked up at the custodian: #{e.message}"
      end
      update_column(:storage_controlled_object_id, found) if found
    end
    storage_controlled_object_id.presence
  end

  def ensure_public_card!
    return if storage_object_id.present?

    update_column(:storage_object_id, pod_storage.create_object(self))
  end

  def ensure_controlled_card!
    return if storage_controlled_object_id.present?

    update_column(:storage_controlled_object_id,
                  pod_storage.create_object(self, type: PodStorage::CONTROLLED_CARD))
  end

  # Writes the passport as two cards, controlled first, in an order in which a
  # write that breaks off at any point loses no value and publishes none
  # early; the same request again reaches the intended state.
  #
  #   1. the controlled card: the new controlled part, and whatever is about
  #      to leave it for the public card;
  #   2. the public card: the new public part, naming the final controlled
  #      payload;
  #   3. only if something left: the controlled card as it is to stay.
  def store_split_in_pod!
    document   = to_document
    controlled = access_policy.classify(document).classes
                              .reject { |_, c| c == AccessClass.public_class }.keys.to_set
    leaving    = Array(@previous_controlled_paths).reject { |path| controlled.include?(path) }

    public_part, controlled_part = PassportSplit.split(document) { |path| controlled.include?(path) }
    final_payload = PassportSplit.controlled_payload(controlled_part)

    first_payload =
      if leaving.empty?
        final_payload
      else
        keep = controlled | leaving
        PassportSplit.controlled_payload(PassportSplit.split(document) { |path| keep.include?(path) }.last)
      end

    ensure_controlled_card!
    pod_storage.write_payload(storage_controlled_object_id, first_payload)

    ensure_public_card!
    published = PassportSplit.public_payload(public_part, final_payload)
    pod_storage.write_payload(storage_object_id, published)
    @public_content = published

    pod_storage.write_payload(storage_controlled_object_id, final_payload) unless leaving.empty?
    @previous_controlled_paths = PassportSplit.attribute_paths(final_payload)
  end

  # +document+ with the header columns laid over it.
  def with_header(document)
    (document || {}).merge(
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier"  => product_id,
      "granularity"              => granularity,
      "dppSchemaVersion"         => dpp_schema_version,
      "dppStatus"                => dpp_status,
      "lastUpdated"              => last_update&.iso8601,
      "economicOperatorId"       => economic_operator_id,
      "facilityId"               => facility_id
    ).compact
  end

  public

  # --- did:oyd private key material (Variante A) ------------------------------
  # Stored encrypted (KeyVault) in the *_enc columns; accessed in the clear via
  # these helpers. Never exposed through to_document.
  def did_doc_key = KeyVault.decrypt(did_doc_key_enc)
  def did_rev_key = KeyVault.decrypt(did_rev_key_enc)
  def did_rev_log = KeyVault.decrypt(did_rev_log_enc)

  def did_doc_key=(value)
    self.did_doc_key_enc = KeyVault.encrypt(value)
  end

  def did_rev_key=(value)
    self.did_rev_key_enc = KeyVault.encrypt(value)
  end

  def did_rev_log=(value)
    self.did_rev_log_enc = KeyVault.encrypt(value)
  end

  # Attach a freshly minted did:oyd (from DidOyd.mint) to this DPP.
  def assign_minted_did!(minted)
    self.dpp_id      = minted[:did]
    self.did_managed = true
    self.did_doc_key = minted[:doc_key]
    self.did_rev_key = minted[:rev_key]
    self.did_rev_log = minted[:rev_log]
  end

  # Build a Dpp from an inbound DPP document (EN 18223:2026 Table 1).
  def self.from_document(doc)
    doc = doc.with_indifferent_access
    new(
      dpp_id:               doc[:digitalProductPassportId],
      product_id:           doc[:uniqueProductIdentifier],
      granularity:          doc[:granularity],
      dpp_schema_version:   doc[:dppSchemaVersion],
      dpp_status:           doc[:dppStatus] || "Active",
      economic_operator_id: doc[:economicOperatorId],
      facility_id:          doc[:facilityId],
      last_update:          Time.now.utc,
      content:              doc.to_h
    )
  end

  # The DPP document as returned to clients: exactly the attributes of
  # EN 18223:2026 Table 1, "Attributes of the DigitalProductPassport class".
  #
  # There is no separate UPI attribute, and the published edition makes the
  # reason plain by naming the attribute +uniqueProductIdentifier+ and defining
  # it as "unique string of characters for the identification of a product, that
  # also enables a web link to the digital product passport" -- the product
  # identifier and the unique product identifier are one value, as EN 18219
  # 3.1.25 also has it. Carrying it twice would be a proprietary attribute and
  # would break conformance for every reader.
  #
  # This is the whole passport, as a write starts from it and as the owner gets
  # it back from a write. What a reader gets is +published_document+.
  def to_document
    with_header(document_content)
  end

  # EN 18222:2026 4.7: every change shall be archived (EN 18221:2026 4.2).
  # The snapshot holds the state *before* the change.
  #
  # For a pod-backed DPP this is a no-op: the pod archives on its own — a
  # changed payload becomes a new object (the old one stays retrievable under
  # its DRI) and is logged with a timestamp. Writing a second copy here would
  # duplicate the history and let the two drift apart.
  def archive_current_version!
    return nil if pod?

    next_no = (DppVersion.where(dpp_id: dpp_id).maximum(:version_number) || 0) + 1
    DppVersion.create!(
      dpp_id:         dpp_id,
      product_id:     product_id,
      version_number: next_no,
      dpp_status:     dpp_status,
      content:        to_document,
      archived_at:    Time.now.utc,
      owner_did:      owner_did,
      access_policy_id: access_policy_id
    )
  end

  # Apply an RFC 7396 merge patch to the DPP document and persist.
  # For a pod-backed DPP the new document goes to the pod, which archives the
  # previous one on its own.
  #
  # Reading needs no mandate, writing does. So for a pod-backed DPP the mandate
  # is checked before anything changes, and the local row is only kept if the
  # pod accepted the write: a refused write leaves nothing behind.
  #
  # A passport with an access policy has to stay classifiable: the result is
  # classified before it is written, and AccessPolicy::InvalidError leaves the
  # passport as it was. Nor may the result hand attributes that are not public
  # to a custodian that would publish them (ControlledPartNotHeld).
  def apply_merge_patch!(patch)
    pod_storage.ensure_covers!("update") if pod?

    merged = JsonMergePatch.apply(to_document, patch.deep_stringify_keys)
    access_classification(merged)
    ensure_controlled_part_held!(merged, storage_base_url, storage_collection_id) if pod?

    transaction do
      archive_current_version!
      assign_from_document(merged)
      save!
      store_in_pod!
    end
    self
  end

  private

  # The host-independent part of the product identifier: the lookup key at the
  # custodian, which is what lets one store serve any number of operator-owned
  # hostnames. nil for an identifier no scheme of EN 18219:2026 Clause 5 covers.
  #
  # The host is kept beside it, lower-cased: together they identify the
  # product, and the unique index over active passports is built on the pair.
  def assign_product_key
    return if product_id.blank?

    identifier        = ProductIdentifier.new(product_id)
    self.product_key  = identifier.product_key
    self.product_host = identifier.host&.downcase
  end

  # A local passport with an access policy is kept as a public and a
  # controlled part (PassportSplit), like one at a custodian that holds
  # controlled cards: +content+ the public part naming the controlled one,
  # +controlled_content+ the controlled part with its salt. Split again only
  # when the document or the policy changed -- a fresh salt on every save
  # would change the public part, and with it the payload hash, for nothing.
  def split_local_content
    return unless new_record? || @local_split_pending || will_save_change_to_access_policy_id?

    @local_split_pending = false
    document = local_document
    policy = access_policy
    if policy.nil?
      self.content = document
      self.controlled_content = nil
      return
    end

    controlled = policy.classify(document).classes.reject { |_, c| c == AccessClass.public_class }.keys.to_set
    public_part, controlled_part = PassportSplit.split(document) { |path| controlled.include?(path) }
    payload = PassportSplit.controlled_payload(controlled_part)
    self.controlled_content = payload
    self.content = PassportSplit.public_payload(public_part, payload)
  end

  # Every write discards the signature of the economic operator, and the
  # passport waits for a new one (docs/Integrity.md section 10). A passport that
  # was never signed stays unsigned rather than becoming "pending".
  def signature_affected?
    signature_state.present? && persisted? &&
      PUBLIC_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def discard_signature
    self.signature_jws        = nil
    self.signature_state      = OperatorSignature::PENDING
    self.signature_checked_at = nil
  end

  # The whole local document, put together again if it is held in two parts.
  def local_document
    return content || {} if controlled_content.blank?

    PassportSplit.merge(content, controlled_content)
  end

  def product_id_is_a_carrier_identifier
    return if product_id.blank?

    ProductIdentifier.parse!(product_id).assert_granularity!(granularity)
  rescue ProductIdentifier::InvalidError => e
    errors.add(:product_id, e.message)
  end

  def assign_from_document(doc)
    doc = doc.with_indifferent_access
    self.granularity        = doc[:granularity] if doc.key?(:granularity)
    self.dpp_schema_version = doc[:dppSchemaVersion] if doc.key?(:dppSchemaVersion)
    self.dpp_status         = doc[:dppStatus] if doc.key?(:dppStatus)
    self.facility_id        = doc[:facilityId] if doc.key?(:facilityId)
    self.last_update        = Time.now.utc
    self.document_content   = doc.to_h
  end
end
