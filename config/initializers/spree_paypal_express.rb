if Rails.env.development?
  Rails.application.config.client_host = "http://localhost:8080"
  Rails.application.config.server_host = "http://localhost:3000"
elsif Rails.env.staging?
  Rails.application.config.client_host = ""
  Rails.application.config.server_host = ""
else
  Rails.application.config.client_host = ""
  Rails.application.config.server_host = ""
end