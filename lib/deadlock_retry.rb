require 'active_support/core_ext/module/attribute_accessors'

module DeadlockRetry
  MAXIMUM_RETRIES_ON_DEADLOCK = 3

  def transaction(requires_new: nil, isolation: nil, joinable: true, &block)
    retry_count = 0

    begin
      super(requires_new: requires_new, isolation: isolation, joinable: joinable, &block)
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
      if in_nested_transaction?
        logger.info { "Deadlock detected in a nested transaction, not retrying. [#{e.class}]" }
        raise
      end

      if retry_count >= MAXIMUM_RETRIES_ON_DEADLOCK
        logger.info { "Deadlock detected and maximum retries exceeded (maximum: #{MAXIMUM_RETRIES_ON_DEADLOCK}), not retrying. [#{e.class}]" }
        raise
      end

      retry_count += 1
      pause_seconds = exponential_pause_seconds(retry_count)
      logger.info { "Deadlock detected on retry #{retry_count}, retrying transaction in #{pause_seconds} seconds. [#{e.class}]" }
      sleep_pause(pause_seconds)
      retry
    end
  end

  private

  WAIT_TIMES = [0, 1, 2, 4, 8, 16, 32]

  def exponential_pause_seconds(count)
    # sleep 0, 1, 2, 4, ... seconds up to the MAXIMUM_RETRIES.
    # Cap the pause time at 32 seconds.
    WAIT_TIMES[count-1] || 32
  end

  def sleep_pause(seconds)
    sleep(seconds) if seconds != 0
  end

  def in_nested_transaction?
    # open_transactions was added in 2.2's connection pooling changes.
    connection.open_transactions != 0
  end

end

ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(DeadlockRetry)