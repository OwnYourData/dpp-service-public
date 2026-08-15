# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ApiStatus
  include ErrorHandling
  include TokenAuthenticatable
end
