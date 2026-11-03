# frozen_string_literal: true

# Keeps an instance out of search engines, when DPP_NOINDEX says so.
#
# Meant for instances that are not for the public: a test instance, a staging
# copy. With DPP_NOINDEX set to 1 or true, every response carries
# X-Robots-Tag: noindex, nofollow, and /robots.txt disallows everything.
# Without it nothing changes: no header, and /robots.txt is not answered here.
#
# A middleware rather than a controller, so that the header is also on the
# answers no controller gives: redirects to https, static files, errors.
# A proxy in front may set the same header; it replaces this one rather than
# adding a second.
class Noindex
  VARIABLE = "DPP_NOINDEX"
  ON = %w[1 true].freeze
  HEADER = "x-robots-tag"
  VALUE = "noindex, nofollow"
  ROBOTS_PATH = "/robots.txt"
  ROBOTS = "User-agent: *\nDisallow: /\n"

  def self.enabled?(value = ENV[VARIABLE]) = ON.include?(value.to_s.strip.downcase)

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless self.class.enabled?
    return robots(env) if robots?(env)

    status, headers, body = @app.call(env)
    headers[HEADER] = VALUE
    [status, headers, body]
  end

  private

  def robots?(env)
    env["PATH_INFO"] == ROBOTS_PATH && %w[GET HEAD].include?(env["REQUEST_METHOD"])
  end

  def robots(env)
    body = env["REQUEST_METHOD"] == "HEAD" ? [] : [ROBOTS]
    [200, { "content-type" => "text/plain; charset=utf-8", "content-length" => ROBOTS.bytesize.to_s,
            HEADER => VALUE }, body]
  end
end
