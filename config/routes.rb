Rails.application.routes.draw do
  root "stories#page"
  get "/info", to: "stories#show"
  get "/envcheck", to: proc { [ 200, { "Content-Type" => "text/plain" }, [ "Rails.env=#{Rails.env}" ] ] }
end
