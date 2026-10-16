# frozen_string_literal: true

# Opens the access log of each request and writes it when the request ends,
# with the HTTP status it ended with (AccessLog, docs/AccessClasses.md §10).
#
# An answer that hands out the controlled part of a passport is not sent if
# its entry cannot be written: it is replaced by 500, and nothing of the
# controlled part leaves.
module AccessLogging
  extend ActiveSupport::Concern

  # The operations of EN 18222:2026 the read paths implement, by controller
  # and action; the collection path is this service's own.
  OPERATIONS = {
    "api/v1/dpps#show" => "ReadDPPById",
    "api/v1/dpps#by_product_id" => "ReadDPPByProductId",
    "api/v1/dpps#by_id_and_date" => "ReadDPPVersionByIdAndDate",
    "api/v1/data_elements#show" => "ReadDataElement",
    "api/v1/data_element_collections#show" => "ReadDataElementCollection"
  }.freeze

  def process_action(*)
    AccessLog.open(request_id: request.request_id,
                   operation: OPERATIONS.fetch("#{controller_path}##{action_name}", "#{controller_path}##{action_name}"))
    super
  ensure
    close_access_log
  end

  private

  def close_access_log
    controlled = AccessLog.controlled_read?
    AccessLog.close!(status: response.status)
  rescue StandardError => e
    Rails.logger.error("[access] the access log of request #{request.request_id} could not be written: " \
                       "#{e.class}: #{e.message}")
    withhold_answer if controlled
  end

  def withhold_answer
    response.delete_header(ReaderAccess::ROLES_HEADER)
    response.set_header("Cache-Control", "no-store")
    response.status = 500
    response.content_type = "application/json"
    response.body = {
      statusCode: "ServerInternalError",
      message: [{ messageType: "Error", text: "the access could not be logged; nothing of the controlled " \
                                              "part is handed out", correlationId: request.request_id,
                  timestamp: Time.now.utc.iso8601 }]
    }.to_json
  end
end
