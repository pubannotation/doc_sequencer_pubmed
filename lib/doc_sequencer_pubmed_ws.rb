#!/usr/bin/env ruby
#require 'bundler/setup'
require 'sinatra/base'
require 'doc_sequencer_pubmed'
require 'doc_sequencer_pmc'
require 'doc_sequencer_first_author'
require 'doc_sequencer_gray_anatomy'
require 'json'

class DocSequencerPubMedWS < Sinatra::Base

	pubmed = DocSequencerPubMed.new
	pmc = DocSequencerPMC.new
	firstauthor = DocSequencerFirstAuthor.new
	grayanatomy = DocSequencerGrayAnatomy.new


	configure do
		set :show_exceptions, :after_handler
	end

	get '/' do
		raise ArgumentError, "The parameter, sourcedb, is not passed." if params['sourcedb'].nil?
		raise ArgumentError, "The parameter, sourceid, is not passed." if params['sourceid'].nil?

		sourcedb = params['sourcedb'].strip
		sourceid = params['sourceid'].strip
		language = params['language']

		divs, messages =
			if (sourcedb.downcase == 'pubmed')
				[pubmed.get_doc(sourceid, language), pubmed.messages]
			elsif (sourcedb.downcase == 'pmc')
				[pmc.get_doc(sourceid), pmc.messages]
			elsif (sourcedb.downcase == 'firstauthor')
				[firstauthor.get_doc(sourceid), firstauthor.messages]
			elsif (sourcedb.downcase == 'grayanatomy')
				[grayanatomy.get_doc(sourceid), grayanatomy.messages]
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
		language = params['language']

		divs, messages = if (sourcedb.downcase == 'pubmed')
			[pubmed.get_docs(sourceids, language), pubmed.messages]
		elsif (sourcedb.downcase == 'pmc')
			[pmc.get_docs(sourceids), pmc.messages]
		elsif (sourcedb.downcase == 'firstauthor')
			[firstauthor.get_docs(sourceids), firstauthor.messages]
		elsif (sourcedb.downcase == 'grayanatomy')
			[grayanatomy.get_docs(sourceids), grayanatomy.messages]
		else
			raise ArgumentError, "Unknown sourcedb: #{sourcedb}."
		end

		result = {docs:divs, messages: messages}

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
