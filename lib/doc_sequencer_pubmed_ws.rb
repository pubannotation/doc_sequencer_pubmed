#!/usr/bin/env ruby
#require 'bundler/setup'
require 'sinatra/base'
require 'doc_sequencer_pubmed'
require 'doc_sequencer_pmc'
require 'doc_sequencer_first_author'
require 'doc_sequencer_gray_anatomy'
require 'failure_cache'
require 'throttled_queue'
require 'json'

class DocSequencerPubMedWS < Sinatra::Base

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
				raise ArgumentError, 'Could not parse the payload as a JSON content'
			end
		end

		raise ArgumentError, "No sourceid is supplied." if sourceids.nil? || sourceids.empty?

		sourcedb = params['sourcedb'].strip
		language = params['language']

		# Process batch document request
		process_document_request(sourcedb, sourceids, language)
	end

	# Health check endpoint
	get '/health' do
		health_status = {
			cache: @@failure_cache.health_check,
			queue: {
				running: @@throttled_queue.running?,
				size: @@throttled_queue.size
			}
		}

		status = health_status[:cache] ? 200 : 503
		headers 'Content-Type' => 'application/json'
		status status
		body health_status.to_json
	end

	# Cache statistics endpoint
	get '/stats' do
		stats = {
			cache: @@failure_cache.stats,
			queue: @@throttled_queue.stats
		}

		headers 'Content-Type' => 'application/json'
		body stats.to_json
	end

	private

	def process_document_request(sourcedb, sourceids, language)
		validate_sourcedb(sourcedb)

		# Check cache for known failures
		cache_result = @@failure_cache.check_batch_failures(sourcedb, sourceids, language)
		cached_failures = cache_result[:cached_failures]
		uncached_ids = cache_result[:uncached_ids]

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
			fresh_docs, fresh_messages, new_failures = fetch_uncached_documents(
				sourcedb, uncached_ids, language
			)

			docs.concat(fresh_docs) if fresh_docs
			messages.concat(fresh_messages) if fresh_messages

			# Cache new failures
			if new_failures.any?
				@@failure_cache.cache_batch_failures(sourcedb, language, new_failures)
			end
		end

		# Return response
		result = {}
		result[:docs] = docs unless docs.empty?
		result[:messages] = messages unless messages.empty?

		headers 'Content-Type' => 'application/json'
		body result.to_json
	end

	def fetch_uncached_documents(sourcedb, sourceids, language)
		# This method handles the actual upstream fetching with throttling
		docs = []
		messages = []
		new_failures = []

		# Queue the request for throttled processing
		@@throttled_queue.enqueue(
			DocumentFetchJob.new(sourcedb, sourceids, language,
				proc do |job|
					# This block will be called by the throttled queue processor
					begin
						sequencer_docs, sequencer_messages = call_upstream_sequencer(
							job.sourcedb, job.sourceids, job.language
						)

						# Process results and identify failures
						if sequencer_docs && !sequencer_docs.empty?
							docs.concat(sequencer_docs)
						end

						if sequencer_messages && !sequencer_messages.empty?
							messages.concat(sequencer_messages)

							# Convert messages to cache entries for failed documents
							sequencer_messages.each do |msg|
								new_failures << {
									sourceid: msg[:sourceid],
									error_type: determine_error_type(msg[:body]),
									error_message: msg[:body]
								}
							end
						end

						# Handle missing documents (requested but not returned)
						returned_ids = sequencer_docs ? sequencer_docs.map { |doc| doc[:sourceid] } : []
						missing_ids = job.sourceids - returned_ids

						missing_ids.each do |missing_id|
							new_failures << {
								sourceid: missing_id,
								error_type: 'not_found',
								error_message: 'Document not found or unavailable'
							}

							messages << {
								sourcedb: job.sourcedb,
								sourceid: missing_id,
								body: 'Document not found or unavailable'
							}
						end

					rescue => e
						# Handle errors in fetching
						job.sourceids.each do |id|
							new_failures << {
								sourceid: id,
								error_type: 'server_error',
								error_message: "Server error: #{e.message}"
							}

							messages << {
								sourcedb: job.sourcedb,
								sourceid: id,
								body: "Server error: #{e.message}"
							}
						end
					end
				end
			)
		)

		# Wait for the throttled processing to complete
		# Note: In a real async implementation, this would return immediately
		# and use callbacks or polling, but for simplicity we'll wait here
		sleep(0.1) while @@throttled_queue.size > 0

		[docs, messages, new_failures]
	end

	def call_upstream_sequencer(sourcedb, sourceids, language)
		case sourcedb.downcase
		when 'pubmed'
			docs = @@pubmed.get_docs(sourceids, language)
			[docs, @@pubmed.messages]
		when 'pmc'
			docs = @@pmc.get_docs(sourceids)
			[docs, @@pmc.messages]
		when 'firstauthor'
			docs = @@firstauthor.get_docs(sourceids)
			[docs, @@firstauthor.messages]
		when 'grayanatomy'
			docs = @@grayanatomy.get_docs(sourceids)
			[docs, @@grayanatomy.messages]
		else
			raise ArgumentError, "Unknown sourcedb: #{sourcedb}"
		end
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
		when /restricted|access denied|forbidden/
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

	error ArgumentError do
		headers \
			'Content-Type' => 'application/json'
		status 400 # Bad Request
		{messages: [env['sinatra.error']]}.to_json
	end

	# error RuntimeError do
	error do
		headers \
			'Content-Type' => 'application/json'
		status 500 # Internal Server Error
		{messages: [env['sinatra.error']]}.to_json
	end

end
