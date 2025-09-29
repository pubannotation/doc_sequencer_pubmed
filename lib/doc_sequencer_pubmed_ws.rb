#!/usr/bin/env ruby
require 'sinatra/base'
require_relative 'doc_sequencer_pubmed/doc_sequencer_pubmed'
require_relative 'doc_sequencer_pubmed/doc_sequencer_pmc'
require_relative 'doc_sequencer_pubmed/doc_sequencer_first_author'
require_relative 'doc_sequencer_pubmed/doc_sequencer_gray_anatomy'
require_relative 'failure_cache'
require_relative 'throttled_queue'
require 'json'
require 'redis'
require_relative 'logging_config'

class DocSequencerPubMedWS < Sinatra::Base

	# Initialize logger
	@@logger = LoggingConfig.setup_logger

	# Validate critical dependencies before starting
	def self.validate_dependencies
		errors = []

		# Check NCBI API Key
		if ENV['NCBI_API_KEY'].nil? || ENV['NCBI_API_KEY'].strip.empty?
			errors << "NCBI_API_KEY environment variable is required for PubMed/PMC access"
		end

		# Check Redis connectivity
		begin
			redis_url = ENV['REDIS_URL'] || 'redis://localhost:6379'
			test_redis = Redis.new(url: redis_url)
			unless test_redis.ping == 'PONG'
				errors << "Redis server is not responding (URL: #{redis_url})"
			end
			test_redis.quit
		rescue => e
			errors << "Cannot connect to Redis server (URL: #{redis_url || 'redis://localhost:6379'}): #{e.message}"
		end

		unless errors.empty?
			@@logger.fatal("Startup validation failed:")
			errors.each { |error| @@logger.fatal("  - #{error}") }
			@@logger.fatal("Service cannot start. Please check your configuration.")
			exit 1
		end

		@@logger.info("Dependency validation passed - Redis and NCBI_API_KEY are available")
	end

	# Run dependency validation
	validate_dependencies

	# Initialize document sequencers
	@@pubmed = DocSequencerPubMed.new
	@@pmc = DocSequencerPMC.new
	@@firstauthor = DocSequencerFirstAuthor.new
	@@grayanatomy = DocSequencerGrayAnatomy.new

	# Initialize cache and queue
	@@failure_cache = FailureCache.new
	@@throttled_queue = ThrottledQueue.new(
		throttle_delay: ENV.fetch('THROTTLE_DELAY', '2.0').to_f
	)

	configure do
		set :show_exceptions, :after_handler
	end

	# Request logging middleware
	before do
		@@logger.info("#{request.request_method} #{request.path_info} from #{request.ip}")
		@@logger.debug("Request params: #{params}")
		@@logger.debug("Request headers: #{request.env.select { |k, v| k.start_with?('HTTP_') }}")
		@request_start_time = Time.now
	end

	after do
		duration = Time.now - @request_start_time
		@@logger.info("Response: #{response.status} (#{(duration * 1000).round(2)}ms)")
	end

	# Graceful shutdown
	at_exit do
		@@throttled_queue.stop if @@throttled_queue
	end

	get '/' do
		raise ArgumentError, "The parameter, sourcedb, is not passed." if params['sourcedb'].nil?
		raise ArgumentError, "The parameter, sourceid, is not passed." if params['sourceid'].nil?

		sourcedb = params['sourcedb'].strip
		sourceid = params['sourceid'].strip
		language = params['language']

		@@logger.info("Processing single document request: sourcedb=#{sourcedb}, sourceid=#{sourceid}, language=#{language}")

		# Process single document request (delegates to batch processing)
		process_document_request(sourcedb, [sourceid], language)
	end

	post '/' do
		raise ArgumentError, "The parameter, sourcedb, is not passed." if params['sourcedb'].nil?
		sourceids = if request.content_type && request.content_type.downcase =~ /application\/json/
			body = request.body.read
			begin
				JSON.parse body, :symbolize_names => true unless body.empty?
			rescue => e
				@@logger.error("Failed to parse JSON payload: #{e.message}")
				raise ArgumentError, 'Could not parse the payload as a JSON content'
			end
		end

		raise ArgumentError, "No sourceid is supplied." if sourceids.nil? || sourceids.empty?

		sourcedb = params['sourcedb'].strip
		language = params['language']

		@@logger.info("Processing batch document request: sourcedb=#{sourcedb}, #{sourceids.size} documents, language=#{language}")
		@@logger.debug("Batch sourceids: #{sourceids}")

		# Process batch document request
		process_document_request(sourcedb, sourceids, language)
	end

	# Health check endpoint
	get '/health' do
		@@logger.debug("Health check requested")
		health_status = {
			cache: @@failure_cache.health_check,
			queue: {
				running: @@throttled_queue.running?,
				size: @@throttled_queue.size
			}
		}

		status = health_status[:cache] ? 200 : 503
		@@logger.info("Health check result: #{status} - cache: #{health_status[:cache]}, queue_running: #{health_status[:queue][:running]}")

		headers 'Content-Type' => 'application/json'
		status status
		body health_status.to_json
	end

	# Cache statistics endpoint
	get '/stats' do
		@@logger.debug("Statistics requested")

		begin
			stats = {}

			# Get cache stats with timeout protection
			begin
				stats[:cache] = @@failure_cache.stats
			rescue => e
				@@logger.error("Error getting cache stats: #{e.message}")
				stats[:cache] = { error: e.message }
			end

			# Get queue stats with timeout protection
			begin
				stats[:queue] = @@throttled_queue.stats
			rescue => e
				@@logger.error("Error getting queue stats: #{e.message}")
				stats[:queue] = { error: e.message }
			end

			@@logger.debug("Returning stats successfully")
			headers 'Content-Type' => 'application/json'
			body stats.to_json

		rescue => e
			@@logger.error("Fatal error in stats endpoint: #{e.message}")
			status 500
			headers 'Content-Type' => 'application/json'
			body({ error: e.message }.to_json)
		end
	end

	private

	def process_document_request(sourcedb, sourceids, language)
		validate_sourcedb(sourcedb)

		# Check cache for known failures
		@@logger.debug("Checking cache for batch failures: sourcedb=#{sourcedb}, #{sourceids.size} IDs")
		cache_result = @@failure_cache.check_batch_failures(sourcedb, sourceids, language)
		cached_failures = cache_result[:cached_failures]
		uncached_ids = cache_result[:uncached_ids]

		@@logger.info("Cache check complete: #{cached_failures.compact.size} cached failures, #{uncached_ids.size} uncached IDs")

		# Initialize results
		docs = []
		messages = []

		# Add cached failure messages
		cached_failures.each_with_index do |failure, index|
			next unless failure

			messages << {
				sourcedb: failure[:sourcedb],
				sourceid: failure[:sourceid],
				body: failure[:error_message]
			}
		end

		# Process uncached IDs if any
		if uncached_ids.any?
			@@logger.info("Fetching #{uncached_ids.size} uncached documents from #{sourcedb}")
			fresh_docs, fresh_messages, new_failures = fetch_uncached_documents(
				sourcedb, uncached_ids, language
			)

			docs.concat(fresh_docs) if fresh_docs
			messages.concat(fresh_messages) if fresh_messages

			# Cache new failures
			if new_failures.any?
				@@logger.info("Caching #{new_failures.size} new failures")
				@@failure_cache.cache_batch_failures(sourcedb, language, new_failures)
			end
		else
			@@logger.info("No uncached IDs to process")
		end

		# Return response
		result = {}
		result[:docs] = docs unless docs.empty?
		result[:messages] = messages unless messages.empty?

		# Determine appropriate HTTP status code
		http_status = determine_response_status(sourceids.size, docs.size, messages)
		@@logger.info("Request complete: #{docs.size} documents returned, #{messages.size} messages, status: #{http_status}")

		headers 'Content-Type' => 'application/json'
		status http_status
		body result.to_json
	end

	def fetch_uncached_documents(sourcedb, sourceids, language)
		# This method handles the actual upstream fetching with throttling
		@@logger.debug("Fetching uncached documents synchronously: #{sourcedb}, #{sourceids.size} IDs")

		begin
			sequencer_docs, sequencer_messages = call_upstream_sequencer(
				sourcedb, sourceids, language
			)

			docs = []
			messages = []
			new_failures = []

			# Process results and identify failures
			if sequencer_docs && !sequencer_docs.empty?
				docs.concat(sequencer_docs)
				@@logger.debug("Retrieved #{sequencer_docs.size} documents from upstream")
			end

			if sequencer_messages && !sequencer_messages.empty?
				@@logger.debug("Got #{sequencer_messages.size} messages from upstream")

				# Normalize sourceids in messages for consistent API responses
				normalized_messages = sequencer_messages.map do |msg|
					# Normalize sourceid for consistency (remove PMC prefix if present)
					normalized_id = msg[:sourceid].to_s.delete_prefix("PMC")

					msg.merge(sourceid: normalized_id)
				end

				messages.concat(normalized_messages)

				# Convert messages to cache entries for failed documents
				normalized_messages.each do |msg|
					new_failures << {
						sourceid: msg[:sourceid],
						error_type: determine_error_type(msg[:body]),
						error_message: msg[:body]
					}
				end
			end

			# Handle missing documents (requested but not returned)
			returned_ids = sequencer_docs ? sequencer_docs.map { |doc| doc[:sourceid] } : []

			# Get IDs that already have error messages from the sequencer
			message_ids = sequencer_messages ? sequencer_messages.map { |msg|
				# Normalize ID format (remove PMC prefix if present)
				msg[:sourceid].to_s.delete_prefix("PMC")
			} : []

			# Only add generic messages for IDs that have no specific error messages
			missing_ids = sourceids - returned_ids - message_ids

			if missing_ids.any?
				@@logger.debug("Found #{missing_ids.size} documents with no specific error messages")
				missing_ids.each do |missing_id|
					new_failures << {
						sourceid: missing_id,
						error_type: 'not_found',
						error_message: 'Document not found or unavailable'
					}

					messages << {
						sourcedb: sourcedb,
						sourceid: missing_id,
						body: 'Document not found or unavailable'
					}
				end
			end

			[docs, messages, new_failures]

		rescue => e
			@@logger.error("Error fetching documents: #{e.message}")
			@@logger.debug("Backtrace: #{e.backtrace.first(5).join("\n")}")

			# Handle errors in fetching
			docs = []
			messages = []
			new_failures = []

			sourceids.each do |id|
				new_failures << {
					sourceid: id,
					error_type: 'server_error',
					error_message: "Server error: #{e.message}"
				}

				messages << {
					sourcedb: sourcedb,
					sourceid: id,
					body: "Server error: #{e.message}"
				}
			end

			[docs, messages, new_failures]
		end
	end

	def call_upstream_sequencer(sourcedb, sourceids, language)
		@@logger.debug("Calling upstream sequencer: #{sourcedb} for #{sourceids.size} IDs")

		# Use throttled queue for synchronous processing with proper throttling
		result = nil
		completed = false

		@@throttled_queue.enqueue(
			DocumentFetchJob.new(sourcedb, sourceids, language,
				proc do |job|
					@@logger.debug("Processing throttled upstream call")
					start_time = Time.now

					begin
						result = case job.sourcedb.downcase
						when 'pubmed'
							docs = @@pubmed.get_docs(job.sourceids, job.language)
							[docs, @@pubmed.messages]
						when 'pmc'
							docs = @@pmc.get_docs(job.sourceids)
							[docs, @@pmc.messages]
						when 'firstauthor'
							docs = @@firstauthor.get_docs(job.sourceids)
							[docs, @@firstauthor.messages]
						when 'grayanatomy'
							docs = @@grayanatomy.get_docs(job.sourceids)
							[docs, @@grayanatomy.messages]
						else
							@@logger.error("Unknown sourcedb requested: #{job.sourcedb}")
							raise ArgumentError, "Unknown sourcedb: #{job.sourcedb}"
						end

						duration = Time.now - start_time
						docs, messages = result
						@@logger.info("Upstream call to #{job.sourcedb} completed in #{(duration * 1000).round(2)}ms: #{docs ? docs.size : 0} docs, #{messages ? messages.size : 0} messages")

					rescue => e
						@@logger.error("Error in throttled upstream call: #{e.message}")
						result = [nil, []]
						raise e
					ensure
						completed = true
					end
				end
			)
		)

		# Wait for completion
		sleep(0.01) until completed

		result || [nil, []]
	end

	def validate_sourcedb(sourcedb)
		valid_sourcedbs = %w[pubmed pmc firstauthor grayanatomy]
		unless valid_sourcedbs.include?(sourcedb.downcase)
			raise ArgumentError, "Unknown sourcedb: #{sourcedb}. Valid options: #{valid_sourcedbs.join(', ')}"
		end
	end

	def determine_error_type(error_message)
		case error_message.downcase
		when /unavailable|withdrawn|removed/
			'unavailable'
		when /restricted|access denied|forbidden|open access/
			'restricted'
		when /not found|does not exist/
			'not_found'
		when /rate limit|too many requests/
			'rate_limited'
		when /network|connection|timeout/
			'network_error'
		else
			'server_error'
		end
	end

	def determine_response_status(total_requested, docs_returned, messages)
		# If we got all documents successfully, return 200
		return 200 if docs_returned == total_requested

		# If no documents were returned, determine status based on error types
		if docs_returned == 0
			# Single error type for single document - return specific status
			if messages.size == 1
				return error_type_to_http_status(messages.first[:body])
			end

			# Multiple errors or batch request with no successes
			# Determine the most appropriate status based on error types
			error_types = messages.map { |msg| determine_error_type(msg[:body]) }.uniq

			if error_types.include?('restricted')
				return 403 # Forbidden - access restriction is primary issue
			elsif error_types.include?('not_found')
				return 404 # Not Found
			elsif error_types.include?('rate_limited')
				return 429 # Too Many Requests
			elsif error_types.include?('unavailable')
				return 410 # Gone - permanently unavailable
			else
				return 503 # Service Unavailable - server/network errors
			end
		end

		# Mixed results (some success, some failure) - use Multi-Status
		207
	end

	def error_type_to_http_status(error_message)
		case determine_error_type(error_message)
		when 'restricted'
			403 # Forbidden
		when 'not_found'
			404 # Not Found
		when 'unavailable'
			410 # Gone
		when 'rate_limited'
			429 # Too Many Requests
		when 'network_error', 'server_error'
			503 # Service Unavailable
		else
			500 # Internal Server Error
		end
	end

	not_found do
		@@logger.warn("404 Not Found: #{request.request_method} #{request.path_info} from #{request.ip}")

		headers 'Content-Type' => 'application/json'
		status 404 # Not Found
		{
			messages: ["Endpoint not found: #{request.request_method} #{request.path_info}"],
			available_endpoints: ["GET /", "POST /", "GET /health", "GET /stats"]
		}.to_json
	end

	error ArgumentError do
		error_message = env['sinatra.error'].message
		@@logger.warn("Bad request: #{error_message} from #{request.ip}")

		headers 'Content-Type' => 'application/json'
		status 400 # Bad Request
		{messages: [error_message]}.to_json
	end

	error QueueFullError do
		error_message = env['sinatra.error'].message
		@@logger.warn("Rate limit exceeded: #{error_message} from #{request.ip}")

		retry_delay = 5  # seconds
		headers 'Content-Type' => 'application/json'
		headers 'Retry-After' => retry_delay.to_s
		status 429 # Too Many Requests
		{
			messages: [error_message],
			retry_after_seconds: retry_delay,
			queue_stats: @@throttled_queue.stats
		}.to_json
	end

	error do
		error_message = env['sinatra.error'].message
		@@logger.error("Internal server error: #{error_message}")
		@@logger.error("Backtrace: #{env['sinatra.error'].backtrace.first(5).join("\n")}")

		headers 'Content-Type' => 'application/json'
		status 500 # Internal Server Error
		{messages: [error_message]}.to_json
	end

end
