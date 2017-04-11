require 'json'
require 'net/http'

module DiscourseTelegramNotifications
  class TelegramNotifier
    def self.sendMessage(message)
      return self.doRequest('sendMessage', message)
    end

    def self.answerCallback(callback_id, text)
      message = {
        callback_query_id: callback_id,
        text: text
      }

      return self.doRequest('answerCallbackQuery', message)
    end

    def self.setupWebhook(key)
      message = {
        url: Discourse.base_url+'/telegram/hook/'+SiteSetting.telegram_secret,
      }

      return self.doRequest('setWebhook', message)
    end

    def self.editKeyboard(message)
      return self.doRequest('editMessageReplyMarkup', message)
    end

    def self.doRequest(methodName, message)
      http = Net::HTTP.new("api.telegram.org", 443)
      http.use_ssl = true

      access_token = SiteSetting.telegram_access_token

      uri = URI("https://api.telegram.org/bot#{access_token}/#{methodName}")

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

    def self.generateReplyMarkup(post, user)
      likes = UserAction.where(action_type: UserAction::LIKE, user_id: user.id, target_post_id: post.id).count

      if likes > 0
        likeButtonText = I18n.t("discourse_telegram_notifications.unlike")
        likeButtonAction = "unlike:#{post.id}"
      else
        likeButtonText = I18n.t("discourse_telegram_notifications.like")
        likeButtonAction = "like:#{post.id}"
      end
      {
        inline_keyboard:[
          [
            {text: I18n.t("discourse_telegram_notifications.view_online"), url:post.full_url},
            {text: likeButtonText, callback_data:likeButtonAction}
          ]
        ]
      }
    end

  end
end