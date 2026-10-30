# frozen_string_literal: true

# GET /privacy: the privacy policy of the start page, the API, the Knowledge
# Base and the DPP Linter. Fixed text; the start page and the pages around it
# link to it from their footers.
class PrivacyController < ActionController::Base
  layout false

  def show
    render :show, formats: :html
  end
end
