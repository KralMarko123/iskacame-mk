class StoriesController < ApplicationController
  def show
    payload = Rails.cache.read("daily_instagram_story")

    if payload.present?
      render json: payload
    else
      render json: { items: [], active: false }
    end
  end
end
