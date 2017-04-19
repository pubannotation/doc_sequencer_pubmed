#!/usr/bin/env ruby
#require 'bundler/setup'
require 'sinatra/base'
require 'doc_sequencer_pubmed'
require 'doc_sequencer_pmc'
require 'json'

class DocSequencerPubMedWS < Sinatra::Base

	pubmed = DocSequencerPubMed.new
	pmc = DocSequencerPMC.new

	configure do
		set :show_exceptions, :after_handler
	end

	get '/' do
		raise ArgumentError, "The parameter, sourcedb, is not passed." if params['sourcedb'].nil?
		raise ArgumentError, "The parameter, sourceid, is not passed." if params['sourceid'].nil?

		sourcedb = params['sourcedb'].strip
		sourceid = params['sourceid'].strip

		divs, messages =
			if (sourcedb.downcase == 'pubmed')
				[pubmed.get_doc(sourceid), pubmed.messages]
			elsif (sourcedb.downcase == 'pmc')
				[pmc.get_doc(sourceid), pmc.messages]
			else
				raise ArgumentError, "Unknown sourcedb: #{sourcedb}."
			end

		result = {}
		result[:docs] = divs unless divs.nil? || divs.empty?
		result[:messages] = messages unless messages.nil? || messages.empty?

		headers \
			'Content-Type' => 'application/json'
		body result.to_json
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

		divs, messages =
			if (sourcedb.downcase == 'pubmed')
				[pubmed.get_docs(sourceids), pubmed.messages]
			elsif (sourcedb.downcase == 'pmc')
				[pmc.get_docs(sourceids), pmc.messages]
			else
				raise ArgumentError, "Unknown sourcedb: #{sourcedb}."
			end

		result = {}
		result[:docs] = divs unless divs.nil? || divs.empty?
		result[:messages] = messages unless messages.nil? || messages.empty?

		headers \
			'Content-Type' => 'application/json'
		body result.to_json
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
