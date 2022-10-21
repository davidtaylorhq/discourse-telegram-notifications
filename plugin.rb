# frozen_string_literal: true

# name: discourse-telegram-notifications
# about: A plugin which posts all user notifications to a telegram message
# version: 0.21
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

    skip_before_action :check_xhr, :preload_json, :verify_authenticity_token, :redirect_to_login_if_required

    def hook
      if not SiteSetting.telegram_notifications_enabled
        render status: 404
      end

      if not (defined? params['key'] && (params['key'] == SiteSetting.telegram_secret))
        Rails.logger.error("Telegram hook called with incorrect key")
        render status: 403
        return
      end

      # If it's a new message (telegram also sends hooks for other reasons that we don't care about)
      if params.key?('message')

        chat_id = params['message']['chat']['id']

        known_user = false

        begin
          user_custom_field = UserCustomField.find_by(name: "telegram_chat_id", value: chat_id)
          user = User.find(user_custom_field.user_id)
          message_text = I18n.t(
            "discourse_telegram_notifications.known-user",
            site_title: CGI::escapeHTML(SiteSetting.title),
            username: user.username
          )
          known_user = true
        rescue Discourse::NotFound, NoMethodError
          message_text = I18n.t(
            "discourse_telegram_notifications.initial-contact",
            site_title: CGI::escapeHTML(SiteSetting.title),
            chat_id: chat_id,
          )
        end

        if known_user && params['message'].key?('reply_to_message')

          begin
            reply_to_message_id = params['message']['reply_to_message']['message_id']
            post_id = PluginStore.get("telegram-notifications", "message_#{reply_to_message_id}")
            reply_to = Post.find(post_id)
            found_post = true
          rescue ActiveRecord::RecordNotFound
            found_post = false
          end

          if found_post

            new_post = {
              raw: params['message']['text'],
              topic_id: reply_to.topic_id,
              reply_to_post_number: reply_to.post_number,
            }

            manager = NewPostManager.new(user, new_post)
            result = manager.perform

            if result.errors.any?
              errors = result.errors.full_messages.join("\n")

              message_text = I18n.t(
                "discourse_telegram_notifications.reply-failed",
                errors: errors
              )
            else
              message_text = I18n.t(
                "discourse_telegram_notifications.reply-success",
                post_url: result.post.full_url
              )
            end
          else
            message_text = I18n.t("discourse_telegram_notifications.reply-error")
          end

        end

        message = {
          chat_id: chat_id,
          text: message_text,
          parse_mode: "html",
          disable_web_page_preview: true,
        }

        DiscourseTelegramNotifications::TelegramNotifier.sendMessage(message)
      elsif params.key?('callback_query')
        chat_id = params['callback_query']['message']['chat']['id']
        user_id = UserCustomField.where(name: "telegram_chat_id", value: chat_id).first.user_id
        user = User.find(user_id)

        data = params['callback_query']['data'].split(":")

        post = Post.find(data[1])

        string = I18n.t("discourse_telegram_notifications.error-unknown-action")

        if data[0] == "like"
          begin
            PostActionCreator.create(user, post, :like)
            string = I18n.t("discourse_telegram_notifications.like-success")
          rescue PostAction::AlreadyActed
            string = I18n.t("discourse_telegram_notifications.already-liked")
          rescue Discourse::InvalidAccess
            string = I18n.t("discourse_telegram_notifications.like-fail")
          end

          DiscourseTelegramNotifications::TelegramNotifier.answerCallback(params['callback_query']['id'], string)
        elsif data[0] == 'unlike'

          begin
            guardian = Guardian.new(user)
            post_action_type_id = PostActionType.types[:like]
            post_action = user.post_actions.find_by(post_id: post.id, post_action_type_id: post_action_type_id, deleted_at: nil)
            raise Discourse::NotFound if post_action.blank?
            guardian.ensure_can_delete!(post_action)
            PostAction.remove_act(user, post, post_action_type_id)

            string = I18n.t("discourse_telegram_notifications.unlike-success")
          rescue Discourse::NotFound, Discourse::InvalidAccess
            string = I18n.t("discourse_telegram_notifications.unlike-failed")
          end

        end

        DiscourseTelegramNotifications::TelegramNotifier.answerCallback(params['callback_query']['id'], string)

        message = {
         chat_id: chat_id,
         message_id: params['callback_query']['message']['message_id'],
         reply_markup: DiscourseTelegramNotifications::TelegramNotifier.generateReplyMarkup(post, user)
        }

        DiscourseTelegramNotifications::TelegramNotifier.editKeyboard(message)
      end

      # Always give telegram a success message, otherwise we'll stop receiving webhooks
      data = {
        success: true
      }
      render json: data
    end

  end
  DiscoursePluginRegistry.serialized_current_user_fields << "telegram_chat_id"

  User.register_custom_field_type('telegram_chat_id', :text)
  register_editable_user_custom_field :telegram_chat_id

  DiscourseEvent.on(:post_notification_alert) do |user, payload|
    if SiteSetting.telegram_notifications_enabled?
      Jobs.enqueue(:send_telegram_notifications, user_id: user.id, payload: payload)
    end
  end

  DiscourseEvent.on(:site_setting_changed) do |name, old, new|
    if (name == :telegram_notifications_enabled) || (name == :telegram_access_token)
      Jobs.enqueue(:setup_telegram_webhook)
    end
  end

  require_dependency "jobs/base"
    module ::Jobs
      class SendTelegramNotifications < ::Jobs::Base
        def execute(args)
          return if !SiteSetting.telegram_notifications_enabled?

          unless telegram_enable_all_notification_types
            return unless telegram_enabled_notification_types.split("|").include?(Notification.types[payload[:notification_type]].to_s)
          end

          user = User.find(args[:user_id])

          chat_id = user.custom_fields["telegram_chat_id"]

          if (not chat_id.present?) || (chat_id.length < 1)
            return
          end

          payload = args[:payload]

          post = Post.where(post_number: payload[:post_number], topic_id: payload[:topic_id]).first

          message_text = I18n.t(
              "discourse_telegram_notifications.message.#{Notification.types[payload[:notification_type]]}",
              site_title: CGI::escapeHTML(SiteSetting.title),
              site_url: Discourse.base_url,
              post_url: Discourse.base_url + payload[:post_url],
              post_excerpt: CGI::escapeHTML(payload[:excerpt]),
              topic: CGI::escapeHTML(payload[:topic_title]),
              username: CGI::escapeHTML(payload[:username]),
              user_url: Discourse.base_url + "/u/" + payload[:username]
            )

          message = {
            chat_id: chat_id,
            text: message_text,
            parse_mode: "html",
            disable_web_page_preview: true,
            reply_markup: DiscourseTelegramNotifications::TelegramNotifier.generateReplyMarkup(post, user),
          }

          response = DiscourseTelegramNotifications::TelegramNotifier.sendMessage(message)

          if response
            message_id = response['result']['message_id']

            PluginStore.set("telegram-notifications", "message_#{message_id}", post.id)
          end

        end
      end

      class SetupTelegramWebhook < ::Jobs::Base
        def execute(args)
          return if !SiteSetting.telegram_notifications_enabled?

          SiteSetting.telegram_secret = SecureRandom.hex

          DiscourseTelegramNotifications::TelegramNotifier.setupWebhook(SiteSetting.telegram_secret)

        end
      end

    end
end
