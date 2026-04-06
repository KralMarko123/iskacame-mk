Rails.application.routes.draw do
  root "stories#page"
  get "/info", to: "stories#show"
end
