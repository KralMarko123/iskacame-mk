Rails.application.routes.draw do
  root "stories#page"
  get "/info", to: "stories#show"
  get "/story_cache/:filename", to: "story_media#show", constraints: { filename: /[^\/]+/ }

  namespace :internal do
    resource :story_cache, only: :create
  end
end
