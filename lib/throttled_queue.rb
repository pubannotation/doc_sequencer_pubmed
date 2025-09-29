#!/usr/bin/env ruby
require 'thread'

class ThrottledQueue

  DEFAULT_THROTTLE_DELAY = 2.0  # seconds between upstream requests

  def initialize(throttle_delay: DEFAULT_THROTTLE_DELAY)
    @queue = Queue.new
    @throttle_delay = throttle_delay
    @last_request_time = nil
    @processor_thread = nil
    @running = false
    @mutex = Mutex.new
  end

  def enqueue(job)
    @queue.push(job)
    ensure_processor_running
  end

  def size
    @queue.size
  end

  def running?
    @running
  end

  def stop
    @mutex.synchronize do
      @running = false
      @queue.push(:stop) # Signal to stop processing
    end

    @processor_thread&.join(5) # Wait up to 5 seconds
    @processor_thread = nil
  end

  def stats
    {
      queue_size: @queue.size,
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
      @processor_thread = Thread.new { process_queue }
    end
  end

  def process_queue
    while @running
      begin
        job = @queue.pop

        # Check for stop signal
        break if job == :stop

        # Throttle if needed
        throttle_if_needed

        # Process the job
        if job.respond_to?(:call)
          job.call
        elsif job.is_a?(Hash) && job[:block]
          job[:block].call
        end

        # Update last request time
        @last_request_time = Time.now

      rescue => e
        # Log error but continue processing
        warn "Error processing queued job: #{e.message}"
        warn e.backtrace.join("\n") if ENV['DEBUG']
      end
    end

  rescue => e
    warn "Fatal error in queue processor: #{e.message}"
  ensure
    @mutex.synchronize { @running = false }
  end

  def throttle_if_needed
    return unless @last_request_time

    elapsed = Time.now - @last_request_time
    if elapsed < @throttle_delay
      sleep(@throttle_delay - elapsed)
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