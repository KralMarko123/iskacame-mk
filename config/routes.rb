Rails.application.routes.draw do
  root "stories#page"
  get "/info", to: "stories#show"

  namespace :internal do
    resource :story_cache, only: :create
  end
end
