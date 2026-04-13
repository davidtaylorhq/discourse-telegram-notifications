# frozen_string_literal: true

require 'json'
require 'net/http'
require 'net/http/post/multipart'

module DiscourseTelegramNotifications
  class TelegramNotifier
    def self.sendMessage(message)
      doRequest('sendMessage', message)
    end

    def self.sendAnimation(message)
      doMultipartRequest('sendAnimation', message)
    end

    def self.sendMediaGroup(message)
      doMultipartRequest('sendMediaGroup', message)
    end

    def self.answerCallback(callback_id, text)
      message = { callback_query_id: callback_id, text: text }

      doRequest('answerCallbackQuery', message)
    end

    def self.setupWebhook(_key)
      message = {
        url:
          "#{Discourse.base_url}/telegram/hook/#{SiteSetting.telegram_secret}"
      }

      doRequest('setWebhook', message)
    end

    def self.editKeyboard(message)
      doRequest('editMessageReplyMarkup', message)
    end

    def self.doRequest(methodName, message)
      http = Net::HTTP.new('api.telegram.org', 443)
      http.use_ssl = true
      access_token = SiteSetting.telegram_access_token

      uri = URI("https://api.telegram.org/bot#{access_token}/#{methodName}")

      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = message.to_json
      response = http.request(req)

      responseData = JSON.parse(response.body)

      if responseData['ok'] != true
        Rails.logger.error(
          "Failed to send Telegram message. Message data= #{req.body.to_json} response=#{response.body.to_json}"
        )
        return false
      end

      responseData
    end

    def self.doMultipartRequest(methodName, form_data)
      http = Net::HTTP.new('api.telegram.org', 443)
      http.use_ssl = true
      access_token = SiteSetting.telegram_access_token

      uri = URI("https://api.telegram.org/bot#{access_token}/#{methodName}")

      req = Net::HTTP::Post::Multipart.new(uri, form_data)
      response = http.request(req)

      responseData = JSON.parse(response.body)

      if responseData['ok'] != true
        Rails.logger.error(
          "Failed to send Telegram message. Message data= #{req.body.to_json} response=#{response.body.to_json}"
        )
        return false
      end

      responseData
    end

    def self.generateReplyMarkup(post, user)
      likes =
        UserAction.where(
          action_type: UserAction::LIKE,
          user_id: user.id,
          target_post_id: post.id
        ).count

      if likes.positive?
        likeButtonText = I18n.t('discourse_telegram_notifications.unlike')
        likeButtonAction = "unlike:#{post.id}"
      else
        likeButtonText = I18n.t('discourse_telegram_notifications.like')
        likeButtonAction = "like:#{post.id}"
      end
      post_url = "#{Discourse.base_url}#{post.url({ without_slug: true })}"
      {
        inline_keyboard: [
          [
            { text: likeButtonText, callback_data: likeButtonAction },
            {
              text: I18n.t('discourse_telegram_notifications.view_online'),
              url: post_url
            }
          ]
        ]
      }
    end
  end
end
