#!/usr/bin/env ruby

require 'optparse'
require_relative '../lib/failure_cache'

# Command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    exit
  end

  opts.on('-v', '--verbose', 'Show detailed output') do
    options[:verbose] = true
  end

  opts.on('-y', '--yes', 'Skip confirmation prompt') do
    options[:skip_confirmation] = true
  end

  opts.on('--dry-run', 'Show what would be deleted without actually deleting') do
    options[:dry_run] = true
  end

  opts.on('--stats-only', 'Only show cache statistics') do
    options[:stats_only] = true
  end
end.parse!

begin
  # Initialize failure cache
  puts "Connecting to Redis..." if options[:verbose]
  cache = FailureCache.new

  # Get current stats
  puts "Getting cache statistics..." if options[:verbose]
  stats = cache.stats

  if stats[:error]
    puts "Error connecting to Redis: #{stats[:error]}"
    exit 1
  end

  puts "\n=== Current Cache Statistics ==="
  puts "Total cached failures: #{stats[:total_cached_failures]}"
  puts "Total Redis keys: #{stats[:redis_info][:total_keys]}"

  unless stats[:by_error_type].empty?
    puts "\nBy error type:"
    stats[:by_error_type].each do |error_type, count|
      puts "  #{error_type}: #{count}"
    end
  end

  unless stats[:by_sourcedb].empty?
    puts "\nBy source database:"
    stats[:by_sourcedb].each do |sourcedb, count|
      puts "  #{sourcedb}: #{count}"
    end
  end

  if options[:stats_only]
    puts "\nStats only mode - no changes made."
    exit 0
  end

  if stats[:total_cached_failures] == 0 || stats[:total_cached_failures] == "scanning_disabled_due_to_performance"
    puts "\nNo failure cache entries found to clear."
    exit 0
  end

  # Confirmation
  unless options[:skip_confirmation] || options[:dry_run]
    print "\nAre you sure you want to clear all failure cache entries? (y/N): "
    response = gets.chomp.downcase
    unless response == 'y' || response == 'yes'
      puts "Cancelled."
      exit 0
    end
  end

  if options[:dry_run]
    puts "\n=== DRY RUN MODE ==="
    puts "Would clear all failure cache entries matching pattern '*:*'"
    puts "No actual changes will be made."
    exit 0
  end

  # Clear the cache
  puts "\nClearing failure cache..." if options[:verbose]

  cleared_count = 0
  cache.instance_eval do
    @redis_pool.with do |redis|
      cursor = 0
      loop do
        cursor, keys = redis.scan(cursor, match: "*:*", count: 100)

        if keys.any?
          redis.del(*keys)
          cleared_count += keys.size
          puts "Cleared #{keys.size} keys (total: #{cleared_count})" if options[:verbose]
        end

        break if cursor == 0 || cursor == "0"
      end
    end
  end

  puts "\n=== Cache Clear Complete ==="
  puts "Cleared #{cleared_count} failure cache entries"

  # Show final stats
  if options[:verbose]
    puts "\nFinal statistics:"
    final_stats = cache.stats
    puts "Total Redis keys remaining: #{final_stats[:redis_info][:total_keys]}"
  end

rescue => e
  puts "Error: #{e.message}"
  puts e.backtrace.join("\n") if options[:verbose]
  exit 1
end