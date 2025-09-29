#!/usr/bin/env ruby
require 'redis'
require 'connection_pool'
require 'json'
require_relative 'logging_config'

class FailureCache

  FAILURE_TTL = {
    unavailable: 8 * 7 * 24 * 60 * 60,  # 8 weeks - document permanently unavailable
    restricted: 8 * 7 * 24 * 60 * 60,   # 8 weeks - document access restricted
    not_found: 4 * 7 * 24 * 60 * 60,    # 4 weeks - document not found
    server_error: 60 * 60,              # 1 hour - temporary server issues
    rate_limited: 30 * 60,              # 30 minutes - rate limit responses
    network_error: 10 * 60              # 10 minutes - network connectivity issues
  }.freeze

  def initialize(redis_url: nil, pool_size: 5)
    @redis_pool = ConnectionPool.new(size: pool_size, timeout: 5) do
      Redis.new(url: redis_url || ENV['REDIS_URL'] || 'redis://localhost:6379')
    end
    @logger = LoggingConfig.get_logger
  end

  def check_batch_failures(sourcedb, sourceids, language = nil)
    return { cached_failures: [], uncached_ids: sourceids } if sourceids.empty?

    keys = sourceids.map { |id| cache_key(sourcedb, id, language) }

    @redis_pool.with do |redis|
      cached_results = redis.mget(*keys)

      cached_failures = []
      uncached_ids = []

      cached_results.each_with_index do |result, index|
        if result.nil?
          uncached_ids << sourceids[index]
          cached_failures << nil
        else
          begin
            failure_data = JSON.parse(result, symbolize_names: true)
            cached_failures << failure_data
          rescue JSON::ParserError
            # Invalid cached data, treat as uncached
            redis.del(keys[index])
            uncached_ids << sourceids[index]
            cached_failures << nil
            @logger.warn("Invalid cache entry for #{keys[index]}, cleaning up")
          end
        end
      end

      {
        cached_failures: cached_failures,
        uncached_ids: uncached_ids
      }
    end
  end

  def is_known_failure?(sourcedb, sourceid, language = nil)
    key = cache_key(sourcedb, sourceid, language)

    @redis_pool.with do |redis|
      cached_data = redis.get(key)
      return nil unless cached_data

      begin
        JSON.parse(cached_data, symbolize_names: true)
      rescue JSON::ParserError
        redis.del(key)
        nil
      end
    end
  end

  def cache_failure(sourcedb, sourceid, language, error_type, error_message)
    key = cache_key(sourcedb, sourceid, language)
    ttl = FAILURE_TTL[error_type.to_sym] || FAILURE_TTL[:server_error]

    failure_entry = {
      sourcedb: sourcedb,
      sourceid: sourceid,
      language: language,
      error_type: error_type.to_s,
      error_message: error_message,
      cached_at: Time.now.to_i,
      expires_at: Time.now.to_i + ttl
    }

    @redis_pool.with do |redis|
      redis.setex(key, ttl, failure_entry.to_json)
    end

    failure_entry
  end

  def cache_batch_failures(sourcedb, language, failures)
    return if failures.empty?

    @redis_pool.with do |redis|
      failures.each do |failure|
        cache_failure(
          sourcedb,
          failure[:sourceid],
          language,
          failure[:error_type],
          failure[:error_message]
        )
      end
    end
  end

  def remove_failure(sourcedb, sourceid, language = nil)
    key = cache_key(sourcedb, sourceid, language)
    @redis_pool.with do |redis|
      redis.del(key)
    end
  end

  def stats
    @redis_pool.with do |redis|
      cursor = 0
      total_failures = 0
      error_type_counts = Hash.new(0)
      sourcedb_counts = Hash.new(0)
      iterations = 0
      max_iterations = 50  # Conservative limit
      start_time = Time.now
      timeout_seconds = 5  # 5 second timeout

      begin
        loop do
          iterations += 1

          # Safety checks to prevent hangs
          if iterations > max_iterations
            @logger.warn "Stats scan exceeded max iterations (#{max_iterations}), collected #{total_failures} entries so far"
            break
          end

          if Time.now - start_time > timeout_seconds
            @logger.warn "Stats scan exceeded timeout (#{timeout_seconds}s), collected #{total_failures} entries so far"
            break
          end

          # Use smaller batch size for safety
          cursor, keys = redis.scan(cursor, match: "*:*", count: 50)

          if keys.any?
            # Process keys in smaller chunks to avoid blocking
            keys.each_slice(10) do |key_batch|
              begin
                cached_data = redis.mget(*key_batch)
                cached_data.each_with_index do |data, index|
                  next unless data

                  begin
                    failure = JSON.parse(data, symbolize_names: true)

                    # Ensure failure is a hash with expected structure
                    if failure.is_a?(Hash) &&
                       failure.has_key?(:error_type) && failure[:error_type] &&
                       failure.has_key?(:sourcedb) && failure[:sourcedb]

                      total_failures += 1
                      error_type_counts[failure[:error_type]] += 1
                      sourcedb_counts[failure[:sourcedb]] += 1
                    else
                      # Clean up malformed entries
                      begin
                        redis.del(key_batch[index])
                      rescue => cleanup_error
                        # Ignore cleanup errors to avoid cascading failures
                      end
                    end
                  rescue JSON::ParserError => json_error
                    # Clean up invalid JSON entries
                    begin
                      redis.del(key_batch[index])
                    rescue => cleanup_error
                      # Ignore cleanup errors
                    end
                  rescue => parse_error
                    @logger.warn "Error parsing cached data: #{parse_error.message}"
                    # Skip this entry but continue processing
                  end
                end
              rescue => batch_error
                @logger.warn "Error processing key batch: #{batch_error.message}"
                # Continue with next batch
              end
            end
          end

          # Break on cursor completion
          break if cursor == 0 || cursor == "0"
        end

        {
          total_cached_failures: total_failures,
          by_error_type: error_type_counts.to_h,
          by_sourcedb: sourcedb_counts.to_h,
          scan_info: {
            iterations: iterations,
            duration_seconds: (Time.now - start_time).round(2),
            completed: cursor == 0 || cursor == "0"
          },
          redis_info: {
            total_keys: redis.dbsize,
            connection_status: "connected"
          }
        }

      rescue => e
        @logger.error "Error during stats collection: #{e.message}"
        {
          error: e.message,
          partial_results: {
            total_cached_failures: total_failures,
            by_error_type: error_type_counts.to_h,
            by_sourcedb: sourcedb_counts.to_h
          },
          redis_info: {
            connection_status: "error"
          }
        }
      end
    end
  end

  def health_check
    @redis_pool.with do |redis|
      redis.ping == 'PONG'
    end
  rescue => e
    false
  end

  private

  def cache_key(sourcedb, sourceid, language)
    key_parts = [sourcedb.downcase, sourceid]
    key_parts << language if language && !language.empty?
    key_parts.join(':')
  end
end