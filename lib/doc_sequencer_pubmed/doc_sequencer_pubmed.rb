#!/usr/bin/env ruby
require 'net/http/persistent'
require 'xml'
require 'pp'

class DocSequencerPubMed
	attr_reader :messages

	MAX_NUM_ID = 100

	def initialize
		raise ArgumentError, "Could not find 'NCBI_API_KEY'" unless ENV.has_key? 'NCBI_API_KEY'
		base_url = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/'
		ncbi_api_key = ENV['NCBI_API_KEY']
		@esearch_url = base_url + "esearch.fcgi?db=pubmed&usehistory=y&api_key=#{ncbi_api_key}"
		@efetch_url = base_url + "efetch.fcgi?db=pubmed&retmode=xml&api_key=#{ncbi_api_key}"
		@http = Net::HTTP::Persistent.new
	end

	def get_doc(id, language = nil, debug = false)
		docs = get_docs([id], language, debug)
	end

	def get_docs(ids, language = nil, debug = false)
		ids.map!{|id| id.to_s}
		invalid_ids = ids.select{|id| id !~ /^(PubMed|PMID)?[:-]?([1-9][0-9]*)$/}
		unless invalid_ids.empty?
			message = "#{invalid_ids.length} invalid id(s) found: #{invalid_ids[0, 5].join(', ')}"
			message += if invalid_ids.length > 5
				'...'
			else
				'.'
			end
			raise ArgumentError, message
		end
		raise ArgumentError, "Too many ids: #{ids.length} > #{MAX_NUM_ID}" if ids.length > MAX_NUM_ID
		ids.map!{|id| id.sub(/(PubMed|PMID)[:-]?/, '')}

		@messages = []

		xml_docs = retrieve_docs(ids)

		if debug
			puts "-----"
			puts xml_docs
			puts "-----"
		end

		docs = extract_docs(xml_docs, language)

		docs.keep_if{|doc| ids.include? doc[:sourceid]}

		if docs.length < ids.length
			return_ids = docs.map{|doc| doc[:sourceid]}
			missing_ids = ids - return_ids
			sourcedb  = 'PubMed'
			sourcedb += '-' + language unless language.nil?
			missing_ids.each do |id|
				@messages << {sourcedb:sourcedb, sourceid:id, body:"Could not get the document from the server."}
			end
		end

		docs
	end

	private

	def retrieve_docs(ids)
		query = ids.map{|id| id + '[uid]'}.join('+OR+')
		uri = URI @esearch_url + '&term=' + query
		response = @http.request uri
		parser = XML::Parser.string(response.body, :encoding => XML::Encoding::UTF_8)
		parsed = parser.parse
		count = parsed.find_first('Count').content.to_i
		return nil unless count > 0

		web = parsed.find_first('WebEnv').content
		key = parsed.find_first('QueryKey').content

		uri = URI @efetch_url + "&query_key=#{key}" + "&WebEnv=#{web}" + "&retstart=0&retmax=1000"
		results = @http.request uri
		results.body
	end

	def extract_docs(xml_docs, language)
		return [] if xml_docs.nil?
		parser = XML::Parser.string(xml_docs, :encoding => XML::Encoding::UTF_8)
		parsed = parser.parse

		articles = parsed.find('/PubmedArticleSet/PubmedArticle')
		articles = parsed.find('/PubmedArticleSet/PubmedBookArticle') if articles.empty?

		articles.map do |article|
			pmid     = get_pmid(article)
			text = if language.nil?
				title    = get_title(article)
				abstract = get_abstract(article)
				_text  = ''
				_text += title if title
				_text += "\n" + abstract.strip if abstract
			else
				get_abstract_lang(article, language)
			end

			if text.empty?
				nil
			else
				source_url = 'https://www.ncbi.nlm.nih.gov/pubmed/' + pmid

				sourcedb  = 'PubMed'
				sourcedb += '-' + language unless language.nil?

				{section:'TIAB', text:text, sourcedb:sourcedb, sourceid:pmid, source_url:source_url}
			end
		rescue => e
			puts e.message
			@messages << {body: e.message}
			nil
		end.compact
	end

	private

	def get_pmid(article)
		pmid_nodes = article.find('.//MedlineCitation/PMID')
		pmid_nodes = article.find('.//BookDocument/PMID') if pmid_nodes.empty?
		raise RuntimeError, "Encountered an article with no PMID" if pmid_nodes.size < 1
		id = pmid_nodes.first.content.strip
		raise RuntimeError, "Encountered an article with multiple PMIDs: #{id}" if pmid_nodes.size > 1
		id
	end

	def get_title(article)
		title_nodes = article.find('.//ArticleTitle')
		vtitle_nodes = article.find('.//VernacularTitle')
		raise RuntimeError, "Encountered an article with multiple titles" if title_nodes.size > 1
		raise RuntimeError, "Encountered an article with multiple vernacular titles" if vtitle_nodes.size > 1
		t = ''
		t += title_nodes.first.content.strip if title_nodes.length == 1
		if vtitle_nodes.length == 1
			t += "\n" unless t.empty?
			t += vtitle_nodes.first.content.strip
		end
		t
	end

	def get_abstract(article)
		abstractText_nodes = article.find('.//Abstract/AbstractText')

		a = abstractText_nodes
				.map{|node| node['Label'].nil? ? node.content.strip : node['Label'] + ': ' + node.content.strip}
				.join("\n")

		otherAbstractText_nodes = article.find('.//OtherAbstract[@Language="eng"]/AbstractText')

		o = otherAbstractText_nodes
				.map{|node| node['Label'].nil? ? node.content.strip : node['Label'] + ': ' + node.content.strip}
				.join("\n")

		a += "\n" + o unless o.empty?
		a
	end

	def get_abstract_lang(article, language)
		otherAbstractText_nodes = article.find(".//OtherAbstract[@Language='#{language}']/AbstractText")

		o = otherAbstractText_nodes
				.map{|node| node['Label'].nil? ? node.content.strip : node['Label'] + ': ' + node.content.strip}
				.join("\n")

		raise ArgumentError, "The document does not have an abstract in the specified language: #{language}." if o.empty?
		o
	end

end

if __FILE__ == $0
	require 'optparse'

	language = nil
	debug = false

	optparse = OptionParser.new do |opts|
		opts.banner = "Usage: doc_sequencer_pubmed.rb [option(s)] id"

		opts.on('-l', '--language=lang', 'specifies the language') do |l|
			language = l
		end

		opts.on('-v', '--verbose', 'tells it to be verbose for debugging') do
			debug = true
		end

		opts.on('-h', '--help', 'displays this screen') do
			puts opts
			exit
		end
	end

	optparse.parse!

	accessor = DocSequencerPubMed.new

	ARGV.each do |id|
		docs = accessor.get_docs([id.strip], language, debug)
		puts "[#{id}]-----"
		pp docs.first
		puts "----------"
	rescue => e
		warn e.message
		exit
	end
end
