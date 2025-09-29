#!/usr/bin/env ruby
require 'thread'
require_relative 'logging_config'

# Custom exception for when queue is full
class QueueFullError < StandardError; end

class ThrottledQueue

  DEFAULT_THROTTLE_DELAY = 0.2  # seconds between upstream requests
  DEFAULT_MAX_QUEUE_SIZE = 100  # maximum queue size

  def initialize(throttle_delay: DEFAULT_THROTTLE_DELAY, max_queue_size: nil)
    @throttle_delay = throttle_delay
    @max_queue_size = max_queue_size || ENV.fetch('QUEUE_MAX_SIZE', DEFAULT_MAX_QUEUE_SIZE.to_s).to_i

    # Use SizedQueue for bounded capacity
    @queue = SizedQueue.new(@max_queue_size)

    @last_request_time = nil
    @processor_thread = nil
    @running = false
    @mutex = Mutex.new
    @logger = LoggingConfig.get_logger
    @logger.info("ThrottledQueue initialized with #{throttle_delay}s delay, max size: #{@max_queue_size}")
  end

  def enqueue(job, timeout: 1.0)
    begin
      # Use push with timeout to avoid blocking indefinitely
      @queue.push(job, timeout)
      @logger.debug("Job enqueued: #{job}. Queue size: #{@queue.size}")
      ensure_processor_running
    rescue ThreadError => e
      if e.message.include?("queue full")
        @logger.warn("Queue is full (size: #{@max_queue_size}), rejecting job: #{job}")
        raise QueueFullError.new("Queue is full (#{@max_queue_size} items). Server is overloaded, please try again later.")
      else
        @logger.error("Unexpected error enqueueing job: #{e.message}")
        raise e
      end
    end
  end

  def size
    @queue.size
  end

  def running?
    @running
  end

  def stop
    @logger.info("Stopping ThrottledQueue")
    @mutex.synchronize do
      @running = false
      @queue.push(:stop) # Signal to stop processing
    end

    @processor_thread&.join(5) # Wait up to 5 seconds
    @processor_thread = nil
    @logger.info("ThrottledQueue stopped")
  end

  def stats
    {
      queue_size: @queue.size,
      max_queue_size: @max_queue_size,
      queue_utilization: (@queue.size.to_f / @max_queue_size * 100).round(1),
      running: @running,
      throttle_delay: @throttle_delay,
      last_request_time: @last_request_time
    }
  end

  private

  def ensure_processor_running
    @mutex.synchronize do
      return if @running

      @running = true
      @logger.debug("Starting queue processor thread")
      @processor_thread = Thread.new { process_queue }
    end
  end

  def process_queue
    while @running
      begin
        job = @queue.pop

        # Check for stop signal
        break if job == :stop

        @logger.debug("Processing job: #{job}")

        # Throttle if needed
        throttle_if_needed

        # Process the job
        start_time = Time.now
        if job.respond_to?(:call)
          job.call
        elsif job.is_a?(Hash) && job[:block]
          job[:block].call
        end

        # Update last request time
        @last_request_time = Time.now
        duration = Time.now - start_time
        @logger.debug("Job completed in #{(duration * 1000).round(2)}ms")

      rescue => e
        # Log error but continue processing
        @logger.error("Error processing queued job: #{e.message}")
        @logger.debug("Backtrace: #{e.backtrace.join("\n")}")
      end
    end

  rescue => e
    @logger.fatal("Fatal error in queue processor: #{e.message}")
    @logger.debug("Backtrace: #{e.backtrace.join("\n")}")
  ensure
    @mutex.synchronize { @running = false }
    @logger.debug("Queue processor thread terminated")
  end

  def throttle_if_needed
    return unless @last_request_time

    elapsed = Time.now - @last_request_time
    if elapsed < @throttle_delay
      sleep_time = @throttle_delay - elapsed
      @logger.debug("Throttling: sleeping for #{sleep_time.round(2)}s")
      sleep(sleep_time)
    end
  end
end

# Job wrapper for queued document fetching
class DocumentFetchJob
  attr_reader :sourcedb, :sourceids, :language, :response_callback

  def initialize(sourcedb, sourceids, language, response_callback)
    @sourcedb = sourcedb
    @sourceids = sourceids
    @language = language
    @response_callback = response_callback
  end

  def call
    # This will be called by the throttled queue processor
    # The actual document fetching logic will be implemented in the web service
    @response_callback.call(self) if @response_callback
  end

  def to_s
    "DocumentFetchJob(#{@sourcedb}, #{@sourceids.size} IDs)"
  end
end