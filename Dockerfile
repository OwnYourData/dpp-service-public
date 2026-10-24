# syntax=docker/dockerfile:1
#
# DPP Service — Rails 7.2 API, PostgreSQL in production.
# Multi-stage: build gems with toolchain, ship a slim runtime image.
# Build for the cluster architecture:
#   docker buildx build --platform linux/amd64 -t ghcr.io/oyd-private/dpp-service:<tag> . --push

# One Ruby for both stages. Keep it equal to .ruby-version and to RUBY VERSION
# in Gemfile.lock -- bundle install does not rewrite the latter on its own.
ARG RUBY_VERSION=3.3.8

############################  build stage  ############################
FROM ruby:${RUBY_VERSION}-slim AS build

ENV BUNDLE_PATH="/usr/local/bundle"

# Build toolchain + libpq headers (pg native extension).
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      build-essential \
      libpq-dev \
      git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the whole app BEFORE resolving gems. If gems were installed first and
# then `COPY . .` ran, that copy would revert the add-platform fix in the
# lockfile (and drag in a host vendor/bundle). vendor/bundle and .bundle are
# excluded via .dockerignore, so mac gems never leak in.
COPY . .

# Dev machines often lock only their native platform (e.g. arm64-darwin), which
# breaks a linux/amd64 build. Add the Linux platforms to the lock, pin the gem
# path explicitly, then install without dev/test.
RUN bundle lock --add-platform x86_64-linux aarch64-linux \
    && bundle config set --local path "${BUNDLE_PATH}" \
    && bundle config set --local without 'development test' \
    && bundle install \
    && rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

############################  runtime stage  ############################
FROM ruby:${RUBY_VERSION}-slim AS runtime

ENV RAILS_ENV="production" \
    RACK_ENV="production" \
    RAILS_LOG_TO_STDOUT="1" \
    RAILS_SERVE_STATIC_FILES="1" \
    BUNDLE_WITHOUT="development test" \
    BUNDLE_PATH="/usr/local/bundle" \
    PORT="3000"

# Runtime libs: libpq for pg, libsodium for rbnacl (oydid / did:oyd),
# curl for the health probe fallback.
RUN apt-get update -qq && apt-get install --no-install-recommends -y \
      libpq5 \
      libsodium23 \
      postgresql-client \
      curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy resolved gems and app from the build stage.
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app

# Run as a non-root user.
RUN groupadd --system --gid 1000 rails \
    && useradd --system --uid 1000 --gid rails --create-home rails \
    && chown -R rails:rails /app
USER rails

# The image tag and the commit it was built from, for GET /version. Handed in
# by k8s/deploy.sh; a build without them answers null there.
ARG DPP_IMAGE_TAG
ARG DPP_COMMIT
ENV DPP_IMAGE_TAG="${DPP_IMAGE_TAG}" \
    DPP_COMMIT="${DPP_COMMIT}"

EXPOSE 3000

# force_ssl is on (EN 18216:2026); TLS is terminated at the ingress, which sets
# X-Forwarded-Proto. Puma binds plain HTTP on :3000 inside the pod.
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:3000", "-e", "production"]
