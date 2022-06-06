require 'active_support/core_ext/module/attribute_accessors'

module DeadlockRetry
  def self.included(base)
    base.extend(ClassMethods)
    base.class_eval do
      class << self
        alias_method_chain :transaction, :deadlock_handling
      end
    end
  end

  module ClassMethods
    DEADLOCK_ERROR_MESSAGES = [
      "Deadlock found when trying to get lock",
      "Lock wait timeout exceeded",
      "deadlock detected"
    ]

    MAXIMUM_RETRIES_ON_DEADLOCK = 3


    def transaction_with_deadlock_handling(*objects, &block)
      retry_count = 0

      begin
        transaction_without_deadlock_handling(*objects, &block)
      rescue ActiveRecord::StatementInvalid => error
        raise if in_nested_transaction?
        if DEADLOCK_ERROR_MESSAGES.any? { |msg| error.message =~ /#{Regexp.escape(msg)}/ }
          raise if retry_count >= MAXIMUM_RETRIES_ON_DEADLOCK
          retry_count += 1
          logger.info "Deadlock detected on retry #{retry_count}, restarting transaction"
          exponential_pause(retry_count)
          retry
        else
          raise
        end
      end
    end

    private

    WAIT_TIMES = [0, 1, 2, 4, 8, 16, 32]

    def exponential_pause(count)
      sec = WAIT_TIMES[count-1] || 32
      # sleep 0, 1, 2, 4, ... seconds up to the MAXIMUM_RETRIES.
      # Cap the pause time at 32 seconds.
      sleep(sec) if sec != 0
    end

    def in_nested_transaction?
      # open_transactions was added in 2.2's connection pooling changes.
      connection.open_transactions != 0
    end

    # Should we try to log innodb status -- if we don't have permission to,
    # we actually break in-flight transactions, silently (!)

  end
end

ActiveRecord::Base.send(:include, DeadlockRetry) if defined?(ActiveRecord)
