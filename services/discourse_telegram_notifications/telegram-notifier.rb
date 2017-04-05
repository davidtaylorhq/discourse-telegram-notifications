require 'json'
require 'net/http'

module DiscourseTelegramNotifications
  class TelegramNotifier
    def self.sendMessage(message, chat_id)
      
      http = Net::HTTP.new("api.telegram.org", 443)
      http.use_ssl = true

      access_token = SiteSetting.telegram_access_token

      uri = URI("https://api.telegram.org/bot#{access_token}/sendMessage")

      message = {
        chat_id: chat_id,
        text: message,
        parse_mode: "html"
      }

      req = Net::HTTP::Post.new(uri, 'Content-Type' =>'application/json')
      req.body = message.to_json
      response = http.request(req)

      responseData = JSON.parse(response.body)

      if not responseData['ok'] == true
        Rails.logger.error("Failed to send Telegram message. Message data= "+req.body.to_json+ " response="+response.body.to_json)
        return false
      end

      return true
    end

    def self.setupWebhook(key)
      http = Net::HTTP.new("api.telegram.org", 443)
      http.use_ssl = true

      access_token = SiteSetting.telegram_access_token

      uri = URI("https://api.telegram.org/bot#{access_token}/setWebhook")

      message = {
        url: Discourse.base_url+'/telegram/hook/'+SiteSetting.telegram_secret,
      }

      req = Net::HTTP::Post.new(uri, 'Content-Type' =>'application/json')
      req.body = message.to_json
      response = http.request(req)

      responseData = JSON.parse(response.body)

      if not responseData['ok'] == true
        Rails.logger.error("Failed to set telegram webhook. Message data= "+req.body.to_json+ " response="+response.body.to_json)
        return false
      end

      return true
    end

  end
end