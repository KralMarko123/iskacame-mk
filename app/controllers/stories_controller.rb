class StoriesController < ApplicationController
  STORY_CACHE_KEY = "instagram_story:today"

  def show
    payload = Rails.cache.read(STORY_CACHE_KEY)

    if payload.present?
      render json: payload
    else
      render json: {
        active: false,
        source: ENV["INSTAGRAM_TARGET_PROFILE"],
        fetched_at: nil,
        expires_at: nil,
        items: []
      }
    end
  end

  def page
    @story = Rails.cache.read(STORY_CACHE_KEY)
  end
end
