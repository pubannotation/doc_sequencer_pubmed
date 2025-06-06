#!/usr/bin/env ruby
require 'net/http/persistent'
require 'xml'
require 'json'
require 'pp'

class DocSequencerPMC
	attr_reader :messages

	MAX_NUM_ID = 100

	def initialize
		base_url = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/'
		ncbi_api_key = ENV['NCBI_API_KEY']
		@esearch_url = base_url + "esearch.fcgi?db=pmc&usehistory=y&api_key=#{ncbi_api_key}"
		@efetch_url = base_url + "efetch.fcgi?db=pmc&retmode=xml&api_key=#{ncbi_api_key}"
		@http = Net::HTTP::Persistent.new
	end

	def get_doc(id)
		docs = get_docs([id])
	end

	def get_docs(ids)
		ids.each{|id| raise ArgumentError, "'#{id}' is not a valid ID of PMC" unless id =~ /^(PMC)?([1-9][0-9]*)$/}
		raise ArgumentError, "Too many ids: #{ids.length} > #{MAX_NUM_ID}" if ids.length > MAX_NUM_ID
		ids.map!{|id| id.sub(/^PMC[:-]?/, '')}

		@messages = []

		xml_docs = retrieve_docs(ids)

		# puts '-----'
		# puts xml_docs
		# puts '-----'

		docs = extract_docs(xml_docs)

		return_ids = docs.map{|doc| doc[:sourceid]}.uniq
		if return_ids.length < ids.length
			missing_ids = ids - return_ids
			missing_ids.each do |id|
				@messages << {sourcedb:'PMC', sourceid:id, body:"Could not get the document."}
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
		doc = parser.parse

		messages = doc.find('.//OutputMessage')
		@messages += messages.collect{|m| m.content.strip}

		web = doc.find_first('WebEnv').content.strip
		key = doc.find_first('QueryKey').content.strip

		uri = URI @efetch_url + "&query_key=#{key}" + "&WebEnv=#{web}" + "&retstart=0&retmax=1000"
		results = @http.request uri
		results.body
	end

	def extract_docs(xml_docs)
		return [] if xml_docs.nil?
		parser = XML::Parser.string(xml_docs, :encoding => XML::Encoding::UTF_8)
		parsed = parser.parse

		articles = parsed.find('/pmc-articleset/article')

		docs = articles.map do |article|
			pmcid = begin
				get_id(article)
			rescue => e
				@messages << {body: "Could not get the doc of the PMCID: " + e.message}
				nil
			end
			if pmcid
				begin
					comment_node = article.find_first('.//comment()')
					raise ArgumentError, "The article, #{pmcid}, is not within Open Access Subset." if comment_node && comment_node.content =~ /The publisher of this article does not allow/

					text, divisions, styles = get_fulltext(article)
					source_url = 'https://pmc.ncbi.nlm.nih.gov/articles/' + pmcid
					sourceid = pmcid.delete_prefix("PMC")
					{sourcedb:'PMC', sourceid:sourceid, source_url: source_url, text:text, divisions: divisions, typesettings: styles}
				rescue => e
					@messages << {sourcedb:'PMC', sourceid:pmcid, body:e.message}
					nil
				end
			else
				nil
			end
		end.compact

		docs.empty? ? [] : docs
	end

	def get_id(article)
		pmcid = begin
			pmcid_nodes = article.find('.//front/article-meta/article-id[@pub-id-type="pmcid"]')
			raise RuntimeError, "Encountered an article with multiple pmcids" if pmcid_nodes.size > 1
			raise RuntimeError, "Encountered an article with no pmcid" if pmcid_nodes.size < 1
			pmcid_nodes.first.content.strip
		end
	end

	def get_fulltext(article)
		text = ''
		divisions = []
		styles = []

		# titles
		_text, _divisions, _styles = get_titles(article)
		_text.rstrip!
		text += _text
		divisions += _divisions
		styles += _styles

		text += "\n\n"

		# abstracts
		_text, _divisions, _styles = get_abstracts(article, text.length)
		_text.rstrip!

		# There are cases where there is no abstract
		unless _text.empty?
			text += _text
			divisions += _divisions
			styles += _styles

			text += "\n\n"
		end

		# body text
		_text, _divisions, _styles = get_body_text(article, text.length)

		text += _text
		divisions += _divisions
		styles += _styles

		# back text
		_text, _divisions, _styles = get_back_text(article, text.length + 2)

		unless _text.empty?
			_text.chomp!

			text += "\n\n"
			text += _text

			divisions += _divisions
			styles += _styles
		end

		# float group
		_text, _divisions, _styles = get_float_captions(article, text.length + 2)

		unless _text.empty?
			_text.chomp!

			text += "\n\n"
			text += _text

			divisions += _divisions
			styles += _styles
		end

		[text, divisions, styles]
	end

	def get_body_text(article, base_offset = 0)

		bodies = article.find('./body')
		case bodies.length
		when 0
			subarticles = article.find('./sub-article')
			if subarticles.length > 0
				get_subarticles(subarticles, base_offset)
			else
				# raise 'No body or sub-article in the article'
				['', [], []]
			end
		when 1
			_text, _divisions, _styles = get_text(bodies.first)
			_text.rstrip!

			divisions = [{span:{begin:0, end:_text.length}, label:'body'}] + _divisions

			adjust_offsets!(divisions, base_offset)
			adjust_offsets!(_styles, base_offset)

			[_text, divisions, _styles]
		else
			raise 'Multiple bodies in the article'
		end
	end

	def get_back_text(article, base_offset = 0)
		back = article.find('./back')
		case back.length
		when 0
			['', [], []]
		when 1
			_text, _divisions, _styles = get_text(back.first)
			_text.rstrip!

			divisions = [{span:{begin:0, end:_text.length}, label:'back'}] + _divisions

			adjust_offsets!(divisions, base_offset)
			adjust_offsets!(_styles, base_offset)

			[_text, divisions, _styles]
		else
			raise 'Multiple back matters in the article'
		end
	end

	def get_subarticles(articles, base_offset = 0)
		text = ''
		divisions = []
		styles = []

		return [text, divisions, styles] if articles.nil? || articles.empty?

		articles.each do |article|
			text += "\n\n" unless text.empty?

			_beg = text.length
			_text, _divisions, _styles = get_text(article, _beg)
			_text.rstrip!

			text += _text
			_end = text.length

			divisions << {span:{begin:_beg, end:_end}, label:'sub-article'}
			divisions += _divisions
			styles += _styles
		end

		adjust_offsets!(divisions, base_offset)
		adjust_offsets!(styles, base_offset)

		[text, divisions, styles]
	end

	def get_float_captions(article, base_offset = 0)
		fgroups = article.find('./floats-group')
		raise 'Multiple float groups in the article' if fgroups.length > 1
		return ['', [], []] if fgroups.length == 0
		get_text(fgroups.first, base_offset)
	end

	def get_titles(article, base_offset = 0)
		text = ''
		divisions = []
		styles = []

		titles = article.find('./front/article-meta/title-group')
		titles.each do |title|
			text += "\n" unless text.empty?

			_text, _divisions, _styles = get_text(title, text.length)
			_text.rstrip!

			text += _text
			divisions += _divisions
			styles += _styles
		end

		adjust_offsets!(divisions, base_offset)
		adjust_offsets!(styles, base_offset)

		[text, divisions, styles]
	end

	def get_abstracts(article, base_offset = 0)
		text = ''
		divisions = []
		styles = []

		abstracts = article.find('./front/article-meta/abstract')

		# There are cases where there is no abstract (PMC3370949)
		return [text, divisions, styles] if abstracts.nil? || abstracts.empty?

		abstracts.each do |abstract|
			text += "\n\n" unless text.empty?
			text += "Abstract\n" if abstract['abstract-type'] == nil

			_beg = text.length
			_text, _divisions, _styles = get_text(abstract, _beg)
			_text.rstrip!

			text += _text
			_end = text.length

			divisions << {span:{begin:_beg, end:_end}, label:'abstract'}
			divisions += _divisions
			styles += _styles
		end

		adjust_offsets!(divisions, base_offset)
		adjust_offsets!(styles, base_offset)

		[text, divisions, styles]
	end

	def get_text (node, base_offset = 0)
		# default output
		text = ''
		divisions = []
		styles = []

		return [text, divisions, styles] if node.nil?

		node.each do |e|
			# text extraction
			if e.node_type_name == 'text'
				node_text = e.content.gsub(/\n/, ' ').gsub(/ +/, ' ')
				text += node_text
				text.sub!(/\n +/, "\n")
			end

			# text layout control
			if e.node_type_name == 'element'
				case e.name
				when *['alt-text', 'contrib-group', 'object-id', 'ref-list', 'tex-math']
					# This group of elements will be skipped

				when *['app-group']
					text.rstrip!
					unless text.empty?
						text += "\n\n"
					end

					_text, _divisions, _styles = get_text(e, text.length)
					_text.rstrip!
					next if _text.empty?

					text += _text
					divisions += _divisions
					styles += _styles

				when *['sec', 'table-wrap', 'fig', 'ack', 'notes', 'app']
					text.rstrip!
					unless text.empty?
						text += "\n"
						text += "\n" if ['sec', 'ack', 'notes', 'app'].include? e.name
					end
					_beg = text.length

					_text, _divisions, _styles = get_text(e, _beg)
					_text.rstrip!
					next if _text.empty?

					text += _text
					_end = text.length

					obj = case e.name
					when *['sec', 'ack', 'notes']
						e.name
					when 'ack'
						'acknowledgement'
					when 'app'
						'appendix'
					when 'table-wrap'
						'table-wrap'
					when 'fig'
						'figure'
					else
						nil
					end

					divisions << {span:{begin:_beg, end:_end}, label:obj} unless obj.nil?
					divisions += _divisions
					styles += _styles

				when *['title', 'article-title', 'subtitle', 'alt-title', 'p', 'body', 'caption', 'table-wrap-foot', 'fn', 'table', 'tr']
					text.sub!(/\n +$/, "\n")
					text.sub!(/^ +/, "")

					_text, _divisions, _styles = get_text(e, text.length)
					_text.rstrip!
					next if _text.empty?

					_beg = text.length
					text += _text
					_end = text.length

					obj = case e.name
					when 'fn'
						'footnote'
					else
						e.name
					end

					divisions << {span:{begin:_beg, end:_end}, label:obj}
					divisions += _divisions
					styles += _styles
					text += "\n"

				when *['label', 'th', 'td']
					text.sub!(/\n +$/, "\n")
					text.sub!(/^ +/, "")

					_text, _divisions, _styles = get_text(e, text.length)
					_text.rstrip!
					next if _text.empty?

					_beg = text.length
					text += _text
					_end = text.length

					divisions << {span:{begin:_beg, end:_end}, label:e.name}
					divisions += _divisions
					styles += _styles
					text += ' '

				when *['italic', 'bold', 'sub', 'sup']
					_text, _divisions, _styles = get_text(e, text.length)
					_text.chomp!
					next if _text.empty?

					_beg = text.length
					text += _text
					_end = text.length

					style = case e.name
					when 'italic'
						'italic'
					when 'bold'
						'bold'
					when 'sub'
						'subscript'
					when 'sup'
						'superscript'
					else
						nil
					end

					styles << {span:{begin:_beg, end:_end}, style:style} unless style.nil?
					styles += _styles

					divisions += _divisions

				else
					text.sub!(/\n +$/, "\n")
					text.sub!(/^ +$/, "")

					_text, _divisions, _styles = get_text(e, text.length)
					next if _text.empty?

					text += _text
					divisions += _divisions
					styles += _styles
				end
			end

			# text = text.gsub(/ *\n */, "\n").lstrip
		end

		adjust_offsets!(divisions, base_offset)
		adjust_offsets!(styles, base_offset)

		[text, divisions, styles]
	end

	def adjust_offsets!(annotations, base_offset = 0)
		annotations.each do |annotation|
			annotation[:span][:begin] += base_offset
			annotation[:span][:end] += base_offset
		end
	end

end

if __FILE__ == $0
	require 'optparse'
	optparse = OptionParser.new do |opts|
		opts.banner = "Usage: doc_sequencer_pubmed.rb [option(s)] id"

		opts.on('-h', '--help', 'displays this screen') do
			puts opts
			exit
		end
	end

	optparse.parse!

	accessor = DocSequencerPMC.new

	ARGV.each do |id|
		begin
			docs = accessor.get_docs([id.strip])
		rescue => e
			warn e.message
			exit
		end
		# pp accessor.messages
		# puts "-----"
		# pp docs
		# puts "-----"
		# puts docs.first[:text]
		puts docs.first.to_json
	end
end
