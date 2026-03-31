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

      next item if source_url.blank?
      next item if source_url.start_with?("/tmp/story_frames/")

      extension = file_extension_for(type, source_url)
      filename = "#{Time.current.strftime('%Y%m%d')}_#{order}_#{SecureRandom.hex(6)}#{extension}"
      absolute_path = OUTPUT_DIR.join(filename)

      download_file(source_url, absolute_path)

      item.merge(media_url: "/story_cache/#{filename}", type: "image")
    end
  end

  private

  attr_reader :items

  def file_extension_for(_type, url)
    return ".webp" if url.include?(".webp")
    return ".png" if url.include?(".png")
    ".jpg"
  end

  def download_file(url, absolute_path)
    uri = URI.parse(url)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = "Mozilla/5.0"

      response = http.request(request)
      raise "Failed to download #{url} (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

      File.binwrite(absolute_path, response.body)
    end
  end
end