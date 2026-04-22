require "base64"
require "json"
require "net/http"
require "uri"

namespace :stories do
  desc "Fetch Instagram stories and publish them to the configured cache write endpoint"
  task fetch_and_publish: :environment do
    profile_username = ENV.fetch("INSTAGRAM_TARGET_PROFILE")
    publish_url = ENV.fetch("STORY_CACHE_WRITE_URL")
    publish_token = ENV.fetch("STORY_CACHE_WRITE_TOKEN")

    payload = InstagramStoryScraper.new(profile_username: profile_username).call
    payload = payload.deep_stringify_keys
    payload["items"] = embed_local_media_uploads(payload["items"] || [])

    uri = URI.parse(publish_url)
    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 10,
      read_timeout: 60
    ) do |http|
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["X-Story-Cache-Token"] = publish_token
      request.body = JSON.generate(story: payload)

      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise "Story cache publish failed: HTTP #{response.code} #{response.body}"
    end

    puts "Published #{payload["items"].size} story items to #{publish_url}"
  end
end

def embed_local_media_uploads(items)
  items.map do |item|
    item = item.deep_stringify_keys

    if local_story_cache_url?(item["media_url"])
      item["media_upload"] = upload_for_story_cache_url(item["media_url"])
    end

    if local_story_cache_url?(item["fallback_image_url"])
      item["fallback_image_upload"] = upload_for_story_cache_url(item["fallback_image_url"])
    end

    item
  end
end

def local_story_cache_url?(url)
  url.to_s.start_with?("/story_cache/")
end

def upload_for_story_cache_url(url)
  filename = File.basename(url)
  path = Rails.root.join("public", "story_cache", filename)
  raise "Missing local media file for #{url}: #{path}" unless File.file?(path)

  {
    filename: filename,
    data: Base64.strict_encode64(File.binread(path))
  }
end
