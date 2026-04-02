require "net/http"
require "uri"
require "fileutils"
require "securerandom"

class StoryMediaDownloader
  OUTPUT_DIR = Rails.root.join("public", "story_cache")

  def initialize(items:)
    @items = items
  end

  def call
    FileUtils.mkdir_p(OUTPUT_DIR)

    items.map do |item|
      type = item[:type] || item["type"]
      source_url = item[:media_url] || item["media_url"]
      order = item[:order] || item["order"]
      fallback_image_url = item[:fallback_image_url] || item["fallback_image_url"]

      next item if source_url.blank?
      next item if source_url.start_with?("/tmp/story_frames/")

      extension = file_extension_for(type, source_url)
      filename = "#{Time.current.strftime('%Y%m%d')}_#{order}_#{SecureRandom.hex(6)}#{extension}"
      absolute_path = OUTPUT_DIR.join(filename)

      begin
        download_file(source_url, absolute_path)
        item.merge(
          type: type,
          media_url: "/story_cache/#{filename}",
          fallback_image_url: fallback_image_url
        )
      rescue => e
        Rails.logger.warn("Story media download failed for #{source_url}: #{e.message}")
        item
      end
    end
  end

  private

  attr_reader :items

  def file_extension_for(type, url)
    return ".mp4" if type.to_s == "video"
    return ".webp" if url.include?(".webp")
    return ".png" if url.include?(".png")
    ".jpg"
  end

  def download_file(url, absolute_path)
    uri = URI.parse(url)

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 10,
      read_timeout: 20
    ) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0 Safari/537.36"

      response = http.request(request)
      raise "Failed to download #{url} (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

      File.binwrite(absolute_path, response.body)
    end
  end
end