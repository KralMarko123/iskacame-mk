class FetchInstagramStoryJob < ApplicationJob
  queue_as :default

  def perform
    payload = InstagramStoryScraper.new.call
    return if payload.blank?

    Rails.cache.write(
      "daily_instagram_story",
      payload,
      expires_in: seconds_until_midnight
    )
  end

  private

  def seconds_until_midnight
    now = Time.current
    tomorrow = now.tomorrow.beginning_of_day
    (tomorrow - now).to_i
  end
end
