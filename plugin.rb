# frozen_string_literal: true

# name: discourse-telegram-notifications
# about: A plugin which posts all user notifications to a telegram message
# version: 0.1
# authors: David Taylor
# url: https://github.com/davidtaylorhq/discourse-telegram-notifications

enabled_site_setting :telegram_notifications_enabled

$LOAD_PATH.unshift(
  File.join(File.dirname(__FILE__), 'gems', 'gems', 'mini_magick-5.3.1', 'lib')
)
$LOAD_PATH.unshift(
  File.join(File.dirname(__FILE__), 'gems', 'gems', 'mime-types-3.7.0', 'lib')
)

$LOAD_PATH.unshift(
  File.join(
    File.dirname(__FILE__),
    'gems',
    'gems',
    'mime-types-data-3.2025.0909',
    'lib'
  )
)

after_initialize do
  begin
    require 'cgi'
    require 'multipart/post'
    require 'mime/types'
    require 'mini_magick'
  rescue LoadError => e
    Rails.logger.warn(
      "Failed to one of the gems in Telegram Notifications Plugin: #{e.message}\n#{e.backtrace.join("\n")}"
    )
  end

  module ::DiscourseTelegramNotifications
    PLUGIN_NAME = 'discourse_telegram_notifications'.freeze

    autoload :TelegramNotifier,
             "#{Rails.root}/plugins/discourse-telegram-notifications/services/discourse_telegram_notifications/telegram-notifier"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseTelegramNotifications
    end
  end

  DiscourseTelegramNotifications::Engine.routes.draw do
    post '/hook/:key' => 'telegram#hook'
  end

  Discourse::Application.routes.append do
    mount ::DiscourseTelegramNotifications::Engine, at: '/telegram'
  end

  class DiscourseTelegramNotifications::TelegramController < ::ApplicationController
    requires_plugin DiscourseTelegramNotifications::PLUGIN_NAME

    skip_before_action :check_xhr,
                       :preload_json,
                       :verify_authenticity_token,
                       :redirect_to_login_if_required

    def hook
      render status: 404 if not SiteSetting.telegram_notifications_enabled

      if not(defined?(
           params['key'] && (params['key'] == SiteSetting.telegram_secret)
         ))
        Rails.logger.error('Telegram hook called with incorrect key')
        render status: 403
        return
      end

      # If it's a new message (telegram also sends hooks for other reasons that we don't care about)
      if params.key?('message')
        chat_id = params['message']['chat']['id']

        known_user = false

        begin
          user_custom_field =
            UserCustomField.find_by(name: 'telegram_chat_id', value: chat_id)
          user = User.find(user_custom_field.user_id)
          message_text =
            I18n.t(
              'discourse_telegram_notifications.known-user',
              site_title: CGI.escapeHTML(SiteSetting.title),
              username: user.username
            )
          known_user = true
        rescue Discourse::NotFound, NoMethodError
          message_text =
            I18n.t(
              'discourse_telegram_notifications.initial-contact',
              site_title: CGI.escapeHTML(SiteSetting.title),
              chat_id: chat_id
            )
        end

        if known_user && params['message'].key?('reply_to_message')
          begin
            reply_to_message_id =
              params['message']['reply_to_message']['message_id']
            post_id =
              PluginStore.get(
                'telegram-notifications',
                "message_#{reply_to_message_id}"
              )
            reply_to = Post.find(post_id)
            found_post = true
          rescue ActiveRecord::RecordNotFound
            found_post = false
          end

          if found_post
            new_post = {
              raw: params['message']['text'],
              topic_id: reply_to.topic_id,
              reply_to_post_number: reply_to.post_number
            }

            manager = NewPostManager.new(user, new_post)
            result = manager.perform

            if result.errors.any?
              errors = result.errors.full_messages.join("\n")

              message_text =
                I18n.t(
                  'discourse_telegram_notifications.reply-failed',
                  errors: errors
                )
            else
              message_text =
                I18n.t(
                  'discourse_telegram_notifications.reply-success',
                  post_url: result.post.full_url
                )
            end
          else
            message_text =
              I18n.t('discourse_telegram_notifications.reply-error')
          end
        end

        message = {
          chat_id: chat_id,
          text: message_text,
          parse_mode: 'html',
          disable_web_page_preview: true
        }

        DiscourseTelegramNotifications::TelegramNotifier.sendMessage(message)
      elsif params.key?('callback_query')
        chat_id = params['callback_query']['message']['chat']['id']
        user_id =
          UserCustomField
            .where(name: 'telegram_chat_id', value: chat_id)
            .first
            .user_id
        user = User.find(user_id)

        data = params['callback_query']['data'].split(':')

        post = Post.find(data[1])

        string = I18n.t('discourse_telegram_notifications.error-unknown-action')

        if data[0] == 'like'
          begin
            PostActionCreator.create(user, post, :like)
            string = I18n.t('discourse_telegram_notifications.like-success')
          rescue PostAction::AlreadyActed
            string = I18n.t('discourse_telegram_notifications.already-liked')
          rescue Discourse::InvalidAccess
            string = I18n.t('discourse_telegram_notifications.like-fail')
          end

          DiscourseTelegramNotifications::TelegramNotifier.answerCallback(
            params['callback_query']['id'],
            string
          )
        elsif data[0] == 'unlike'
          begin
            guardian = Guardian.new(user)
            post_action_type_id = PostActionType.types[:like]
            post_action =
              user.post_actions.find_by(
                post_id: post.id,
                post_action_type_id: post_action_type_id,
                deleted_at: nil
              )
            raise Discourse::NotFound if post_action.blank?
            guardian.ensure_can_delete!(post_action)
            PostAction.remove_act(user, post, post_action_type_id)

            string = I18n.t('discourse_telegram_notifications.unlike-success')
          rescue Discourse::NotFound, Discourse::InvalidAccess
            string = I18n.t('discourse_telegram_notifications.unlike-failed')
          end
        end

        DiscourseTelegramNotifications::TelegramNotifier.answerCallback(
          params['callback_query']['id'],
          string
        )

        message = {
          chat_id: chat_id,
          message_id: params['callback_query']['message']['message_id'],
          reply_markup:
            DiscourseTelegramNotifications::TelegramNotifier.generateReplyMarkup(
              post,
              user
            )
        }

        DiscourseTelegramNotifications::TelegramNotifier.editKeyboard(message)
      end

      # Always give telegram a success message, otherwise we'll stop receiving webhooks
      data = { success: true }
      render json: data
    end
  end

  DiscoursePluginRegistry.serialized_current_user_fields << 'telegram_chat_id'

  User.register_custom_field_type('telegram_chat_id', :text)
  register_editable_user_custom_field :telegram_chat_id

  DiscourseEvent.on(:push_notification) do |user, payload, notification_type|
    if SiteSetting.telegram_notifications_enabled?
      Jobs.enqueue(
        :send_telegram_notifications,
        user_id: user.id,
        payload: payload
      )
    end
  end

  DiscourseEvent.on(:site_setting_changed) do |name, old, new|
    if (name == :telegram_notifications_enabled) ||
         (name == :telegram_access_token)
      Jobs.enqueue(:setup_telegram_webhook)
    end
  end

  require_dependency 'jobs/base'

  module ::Jobs
    class SendTelegramNotifications < ::Jobs::Base
      def execute(args)
        return if !SiteSetting.telegram_notifications_enabled?

        payload = args[:payload]

        if SiteSetting
             .telegram_enabled_notification_types
             .split('|')
             .exclude?(Notification.types[payload[:notification_type]].to_s)
          return
        end

        user = User.find(args[:user_id])

        chat_id = user.custom_fields['telegram_chat_id']

        return if (not chat_id.present?) || (chat_id.length < 1)

        post =
          Post.where(
            post_number: payload[:post_number],
            topic_id: payload[:topic_id]
          ).first

        doc = Nokogiri.HTML(post.cooked)
        image_paths = []
        animation_paths = []

        doc
          .css('img')
          .reject { |img| img['class'].to_s.include?('emoji') }
          .each do |img|
            src = img['src']
            next unless src

            uri =
              begin
                URI.parse(src)
              rescue StandardError
                nil
              end
            next if uri.nil? || uri.scheme == 'http' || uri.scheme == 'https'

            local_path = File.join(Rails.root, 'public', uri.path)
            classes = img['class'].to_s.split(/\s+/)
            ext = File.extname(local_path).downcase

            if ext == '.gif' && classes.include?('animated')
              animation_paths << local_path
            else
              image_paths << local_path
            end
          end

        message_text =
          I18n.t(
            "discourse_telegram_notifications.message.#{Notification.types[payload[:notification_type]]}",
            site_title: CGI.escapeHTML(SiteSetting.title),
            site_url: Discourse.base_url,
            post_url: Discourse.base_url + payload[:post_url],
            post_excerpt: CGI.escapeHTML(payload[:excerpt]),
            topic: CGI.escapeHTML(payload[:topic_title]),
            username: CGI.escapeHTML(payload[:username]),
            user_url: Discourse.base_url + '/u/' + payload[:username]
          )

        message = {
          chat_id: chat_id,
          text: message_text,
          parse_mode: 'html',
          disable_web_page_preview: true,
          reply_markup:
            DiscourseTelegramNotifications::TelegramNotifier.generateReplyMarkup(
              post,
              user
            )
        }

        response =
          DiscourseTelegramNotifications::TelegramNotifier.sendMessage(message)

        if response
          message_id = response['result']['message_id']

          PluginStore.set(
            'telegram-notifications',
            "message_#{message_id}",
            post.id
          )
        end

        if !image_paths.empty?
          media = []
          files = {}

          image_paths.each_with_index do |path, i|
            if File.extname(path).downcase == '.avif'
              begin
                converted_path = path.sub(/\.avif\z/i, '.jpg')
                image = MiniMagick::Image.open(path)
                image.format('jpg')
                image.write(converted_path)
                path = converted_path
              rescue StandardError => e
                Rails.logger.error(
                  "Error while executing AVIF conversion: #{e.message}"
                )
                break
              end
            end

            field = "photo#{i}"

            begin
              mime_type = MIME::Types.type_for(path).first.to_s
              files[field] = Multipart::Post::UploadIO.new(
                File.open(path),
                mime_type,
                File.basename(path)
              )
              media << { type: 'photo', media: "attach://#{field}" }
            rescue StandardError => e
              Rails.logger.error("Error while executing UploadIO: #{e.message}")
            end
          end

          images_form_data = {
            chat_id: chat_id,
            media: media.to_json,
            reply_markup:
              DiscourseTelegramNotifications::TelegramNotifier.generateReplyMarkup(
                post,
                user
              ).to_json
          }.merge(files)

          begin
            response_media =
              DiscourseTelegramNotifications::TelegramNotifier.sendMediaGroup(
                images_form_data
              )
          rescue StandardError => e
            Rails.logger.error(
              "Error while executing sendMediaGroup: #{e.message}"
            )
          end
        end

        if response_media
          response_media['result'].each do |msg|
            PluginStore.set(
              'telegram-notifications',
              "message_#{msg['message_id']}",
              post.id
            )
          end
        end

        if !animation_paths.empty?
          files = {}
          animation_paths.each_with_index do |path, i|
            field = "animation#{i}"

            begin
              mime_type = MIME::Types.type_for(path).first.to_s
              files[field] = Multipart::Post::UploadIO.new(
                File.open(path),
                mime_type,
                File.basename(path)
              )
            rescue StandardError => e
              Rails.logger.error(
                "Error while executing UploadIO animation: #{e.message}"
              )
              next
            end

            animation_form_data = {
              chat_id: chat_id,
              animation: "attach://#{field}",
              reply_markup:
                DiscourseTelegramNotifications::TelegramNotifier.generateReplyMarkup(
                  post,
                  user
                ).to_json
            }.merge(files)

            begin
              response_animations_media =
                DiscourseTelegramNotifications::TelegramNotifier.sendAnimation(
                  animation_form_data
                )
            rescue StandardError => e
              Rails.logger.error(
                "Error while executing sendAnimation : #{e.message}"
              )
            end

            if response_animations_media
              message_id = response_animations_media['result']['message_id']

              PluginStore.set(
                'telegram-notifications',
                "message_#{message_id}",
                post.id
              )
            end
          end
        end
      end
    end

    class SetupTelegramWebhook < ::Jobs::Base
      def execute(args)
        return if !SiteSetting.telegram_notifications_enabled?

        SiteSetting.telegram_secret = SecureRandom.hex

        DiscourseTelegramNotifications::TelegramNotifier.setupWebhook(
          SiteSetting.telegram_secret
        )
      end
    end
  end
end
