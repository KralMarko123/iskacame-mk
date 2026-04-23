require "base64"
require "digest"
require "fileutils"
require "set"

module Internal
  class StoryCachesController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      unless valid_write_token?
        Rails.logger.warn(
          "[Internal::StoryCachesController] Unauthorized story cache write: #{token_status}"
        )
        return render json: { ok: false, error: "unauthorized", token_status: token_status }, status: :unauthorized
      end

      payload = story_payload
      payload["items"] = persist_uploaded_media(payload["items"] || [])

      Rails.cache.write(
        STORY_CACHE_KEY,
        payload,
        expires_in: seconds_until_midnight
      )
      deleted_count = cleanup_story_cache_except(referenced_story_cache_filenames(payload))

      render json: {
        ok: true,
        items_count: payload["items"].size,
        deleted_count: deleted_count,
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

    def token_status
      expected = ENV.fetch("STORY_CACHE_WRITE_TOKEN", "")
      supplied = request.headers["X-Story-Cache-Token"].to_s

      return "server_token_missing" if expected.blank?
      return "request_token_missing" if supplied.blank?

      "token_mismatch"
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

      "/media/story_cache/#{filename}"
    end

    def referenced_story_cache_filenames(payload)
      Array(payload["items"]).flat_map do |item|
        item = item.deep_stringify_keys
        [
          story_cache_filename(item["media_url"]),
          story_cache_filename(item["fallback_image_url"])
        ]
      end.compact.to_set
    end

    def story_cache_filename(url)
      url = url.to_s
      return nil unless url.start_with?("/media/story_cache/") || url.start_with?("/story_cache/")

      File.basename(url)
    end

    def cleanup_story_cache_except(keep_filenames)
      output_dir = Rails.root.join("public", "story_cache")
      return 0 unless Dir.exist?(output_dir)

      deleted_count = 0

      Dir.glob(output_dir.join("*")).each do |path|
        next unless File.file?(path)
        next if keep_filenames.include?(File.basename(path))

        File.delete(path)
        deleted_count += 1
      rescue => e
        Rails.logger.warn("[Internal::StoryCachesController] Could not delete #{path}: #{e.message}")
      end

      deleted_count
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
