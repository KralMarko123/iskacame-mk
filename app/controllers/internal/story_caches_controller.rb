require "base64"
require "digest"
require "fileutils"

module Internal
  class StoryCachesController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      return head :unauthorized unless valid_write_token?

      payload = story_payload
      payload["items"] = persist_uploaded_media(payload["items"] || [])

      Rails.cache.write(
        STORY_CACHE_KEY,
        payload,
        expires_in: seconds_until_midnight
      )

      render json: {
        ok: true,
        items_count: payload["items"].size,
        expires_in: seconds_until_midnight
      }
    rescue ActionController::ParameterMissing => e
      render json: { ok: false, error: e.message }, status: :bad_request
    rescue => e
      Rails.logger.error("[Internal::StoryCachesController] #{e.class}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
      render json: { ok: false, error: "cache write failed" }, status: :internal_server_error
    end

    private

    def story_payload
      params.require(:story).to_unsafe_h.deep_stringify_keys
    end

    def valid_write_token?
      expected = ENV.fetch("STORY_CACHE_WRITE_TOKEN", "")
      supplied = request.headers["X-Story-Cache-Token"].to_s

      return false if expected.blank? || supplied.blank?

      expected_digest = Digest::SHA256.hexdigest(expected)
      supplied_digest = Digest::SHA256.hexdigest(supplied)

      ActiveSupport::SecurityUtils.secure_compare(supplied_digest, expected_digest)
    end

    def persist_uploaded_media(items)
      output_dir = Rails.root.join("public", "story_cache")
      FileUtils.mkdir_p(output_dir)

      items.map do |item|
        item = item.deep_stringify_keys
        upload = item.delete("media_upload")
        fallback_upload = item.delete("fallback_image_upload")

        if upload.present?
          item["media_url"] = write_upload(output_dir, upload)
        end

        if fallback_upload.present?
          item["fallback_image_url"] = write_upload(output_dir, fallback_upload)
        end

        item
      end
    end

    def write_upload(output_dir, upload)
      upload = upload.deep_stringify_keys
      filename = safe_filename(upload.fetch("filename"))
      data = Base64.strict_decode64(upload.fetch("data"))

      File.binwrite(output_dir.join(filename), data)

      "/story_cache/#{filename}"
    end

    def safe_filename(filename)
      basename = File.basename(filename.to_s)
      raise "Invalid upload filename" if basename.blank?
      raise "Invalid upload filename" unless basename.match?(/\A[a-zA-Z0-9._-]+\z/)

      basename
    end

    def seconds_until_midnight
      now = Time.current
      (now.tomorrow.beginning_of_day - now).to_i
    end
  end
end
