# frozen_string_literal: true

module DiscourseTelegramNotifications
  class Poller
    def poll
      message_handler = MessageHandler.new
      TelegramRequest.get_updates.each do |update|
        message_handler.process(update)
      end
    end
  end
end
