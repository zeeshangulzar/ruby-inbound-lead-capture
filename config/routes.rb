Rails.application.routes.draw do
  root "leads#index"

  resources :leads, only: %i[index show]

  namespace :webhooks do
    namespace :mailtrap do
      post "inbound", to: "inbound#create"
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
