# frozen_string_literal: true

# The start page of the instance: what the service is, the tools around it,
# the DPP services that are available and the source code.
#
# Most of it is fixed text. The list of available DPP services is rendered here
# from the JSON that dpp-validator publishes (AvailableServices), so the page
# shows the latest results without a release of this service.
class LandingController < ActionController::Base
  layout false

  def show
    @services = AvailableServices.entries
    @services_notice = AvailableServices.notice
    render :show, formats: :html
  end
end
