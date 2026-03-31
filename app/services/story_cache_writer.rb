class StoryCacheWriter
  def initialize(payload:)
    @payload = payload
  end

  def call
    Rails.cache.write(
      STORY_CACHE_KEY,
      payload,
      expires_in: seconds_until_midnight
    )
  end

  private

  attr_reader :payload

  def seconds_until_midnight
    now = Time.current
    (now.tomorrow.beginning_of_day - now).to_i
  end
end
