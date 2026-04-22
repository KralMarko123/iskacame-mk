# app/jobs/fetch_instagram_story_job.rb
class FetchInstagramStoryJob < ApplicationJob
  queue_as :default

  def perform
    payload = InstagramStoryScraper.new(
      profile_username: ENV.fetch("INSTAGRAM_TARGET_PROFILE")
    ).call
    return if payload.blank? || payload[:items].blank?

    Rails.cache.write(
      STORY_CACHE_KEY,
      payload.deep_stringify_keys,
      expires_in: seconds_until_midnight
    )
  rescue => e
    Rails.logger.error("[FetchInstagramStoryJob] #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
  end

  private

  def seconds_until_midnight
    now = Time.current
    tomorrow = now.tomorrow.beginning_of_day
    (tomorrow - now).to_i
  end
end
