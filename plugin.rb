# name: discourse-telegram-notifications
# about: A plugin which posts all user notifications to a telegram message
# version: 0.1
# authors: David Taylor
# url: https://github.com/davidtaylorhq/discourse-telegram-notifications

require 'cgi'

enabled_site_setting :telegram_notifications_enabled

after_initialize do

  module ::DiscourseTelegramNotifications
    PLUGIN_NAME ||= "discourse_telegram_notifications".freeze

    autoload :TelegramNotifier, "#{Rails.root}/plugins/discourse-telegram-notifications/services/discourse_telegram_notifications/telegram-notifier"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseTelegramNotifications
    end
  end

  DiscourseTelegramNotifications::Engine.routes.draw do
    post "/hook/:key" => "telegram#hook"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseTelegramNotifications::Engine, at: "/telegram"
  end
  
  class DiscourseTelegramNotifications::TelegramController < ::ApplicationController
    requires_plugin DiscourseTelegramNotifications::PLUGIN_NAME

    skip_before_filter :check_xhr, :preload_json, :verify_authenticity_token, :redirect_to_login_if_required

    def hook
      if not SiteSetting.telegram_notifications_enabled
        render status: 404
      end

      if not (defined? params['key'] and params['key'] == SiteSetting.telegram_secret)
        Rails.logger.error("Telegram hook called with incorrect key")
        render status: 403
        return
      end
      
      # If it's a new message (telegram also sends hooks for other reasons that we don't care about)
      if defined? params['message']['chat']['id']

        chat_id = params['message']['chat']['id']
        
        message = I18n.t(
            "discourse_telegram_notifications.initial-contact",
            site_title: CGI::escapeHTML(SiteSetting.title),
            chat_id: chat_id,
          )

        DiscourseTelegramNotifications::TelegramNotifier.sendMessage(message, chat_id)
      end

      # Always give telegram a success message, otherwise we'll stop receiving webhooks
      data = {
        success: true
      }
      render json: data
    end

  end
  DiscoursePluginRegistry.serialized_current_user_fields << "telegram_chat_id"

  add_to_serializer(:user, :custom_fields, false) {
    if object.custom_fields == nil then
      {}
    else
      object.custom_fields
    end
  }

  User.register_custom_field_type('telegram_chat_id', :text)

  DiscourseEvent.on(:post_notification_alert) do |user, payload|
    return unless SiteSetting.telegram_notifications_enabled?
    Jobs.enqueue(:send_telegram_notifications, {user_id: user.id, payload: payload})
  end

  DiscourseEvent.on(:site_setting_saved) do |sitesetting|
    if sitesetting.name == 'telegram_notifications_enabled' or sitesetting.name == 'telegram_access_token'
      Jobs.enqueue(:setup_telegram_webhook)
    end
  end

  require_dependency "jobs/base"
    module ::Jobs
      class SendTelegramNotifications < Jobs::Base
        def execute(args)
          return if !SiteSetting.telegram_notifications_enabled?
          user = User.find(args[:user_id])

          chat_id = user.custom_fields["telegram_chat_id"]

          if not (defined? chat_id) and (chat_id.length < 1)
            return 
          end

          payload = args[:payload]

          message = I18n.t(
              "discourse_telegram_notifications.message.#{Notification.types[payload[:notification_type]]}",
              site_title: CGI::escapeHTML(SiteSetting.title),
              site_url: Discourse.base_url,
              post_url: Discourse.base_url+payload[:post_url],
              post_excerpt: CGI::escapeHTML(payload[:excerpt]),
              topic: CGI::escapeHTML(payload[:topic_title]),
              username: CGI::escapeHTML(payload[:username]),
              user_url: Discourse.base_url+"/u/"+payload[:username]
            )

          DiscourseTelegramNotifications::TelegramNotifier.sendMessage(message, chat_id)

        end
      end

      class SetupTelegramWebhook < Jobs::Base
        def execute(args)
          return if !SiteSetting.telegram_notifications_enabled?
          
          SiteSetting.telegram_secret = SecureRandom.hex

          DiscourseTelegramNotifications::TelegramNotifier.setupWebhook(SiteSetting.telegram_secret)

        end
      end

    end
end