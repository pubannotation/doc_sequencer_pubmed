#!/usr/bin/env ruby
require 'net/http/persistent'
require 'xml'
require 'pp'

class DocSequencerPubMed
  attr_reader :messages

  MAX_NUM_ID = 100

  def initialize
    base_url = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/'
    @esearch_url = base_url + 'esearch.fcgi?db=pubmed&usehistory=y'
    @efetch_url = base_url + 'efetch.fcgi?db=pubmed&retmode=xml'
    @http = Net::HTTP::Persistent.new
  end

  def get_doc(id)
    docs = get_docs([id])
  end

  def get_docs(ids)
    ids.map!{|id| id.to_s}
    ids.each{|id| raise ArgumentError, "'#{id}' is not a valid ID of PubMed" unless id =~ /^(PubMed|PMID)?[:-]?([1-9][0-9]*)$/}
    raise ArgumentError, "Too many ids: #{ids.length} > #{MAX_NUM_ID}" if ids.length > MAX_NUM_ID
    ids.map!{|id| id.sub(/(PubMed|PMID)[:-]?/, '')}

    @messages = []

    xml_docs = retrieve_docs(ids)
    docs = extract_docs(xml_docs)

    if docs.length < ids.length
      return_ids = docs.map{|doc| doc[:sourceid]}
      missing_ids = ids - return_ids
      @messages << "Could not get #{missing_ids.length} #{missing_ids.length > 1 ? 'docs' : 'doc'}: #{missing_ids.join(', ')}"
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


  def extract_docs(xml_docs)
    return [] if xml_docs.nil?
    parser = XML::Parser.string(xml_docs, :encoding => XML::Encoding::UTF_8)
    parsed = parser.parse

    articles = parsed.find('/PubmedArticleSet/PubmedArticle')
    articles = parsed.find('/PubmedArticleSet/PubmedBookArticle') if articles.empty?

    articles.map do |article|
      begin
        pmid = begin
          pmid_nodes = article.find('.//MedlineCitation/PMID')
          pmid_nodes = article.find('.//BookDocument/PMID') if pmid_nodes.empty?
          raise RuntimeError, "Encountered an article with no PMID" if pmid_nodes.size < 1
          id = pmid_nodes.first.content.strip
          raise RuntimeError, "Encountered an article with multiple PMIDs: #{id}" if pmid_nodes.size > 1
          id
        end

        title = begin
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

        abstract = begin
          abstractText_nodes = article.find('.//Abstract/AbstractText')

          a = abstractText_nodes
              .map{|node| node['Label'].nil? ? node.content.strip : node['Label'] + ': ' + node.content.strip}
              .join("\n")

          otherAbstractText_nodes = article.find('.//OtherAbstract[@language="eng"]/AbstractText')

          o = otherAbstractText_nodes
              .map{|node| node['Label'].nil? ? node.content.strip : node['Label'] + ': ' + node.content.strip}
              .join("\n")

          a += "\n" + o unless o.empty?
        end

        body  = ''
        body += title if title
        body += "\n" + abstract.strip if abstract

        source_url = 'https://www.ncbi.nlm.nih.gov/pubmed/' + pmid

        {section:'TIAB', text:body, sourcedb:'PubMed', sourceid:pmid, source_url:source_url}
      rescue => e
        puts e.message
        @messages << e.message
        nil
      end
    end.compact
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

  accessor = DocSequencerPubMed.new
  # docs = accessor.get_docs(["24401455", "23790332"])
  # docs = accessor.get_docs(["24401455381719472", "23790332"])
  # docs = accessor.get_docs(["2440145501023"])
  # docs = accessor.get_doc("2440145501023")

  # docs = accessor.get_doc("28841741")
  # docs = accessor.get_doc("28840900")
  # docs = accessor.get_doc("28840673")
  # docs = accessor.get_doc("28840672")
  # docs = accessor.get_doc("28840671")
  # docs = accessor.get_doc("28837307") # book
  # docs = accessor.get_docs([28804172, 28804171, 28804170, 28804169, 28804168, 28804167])

  pp docs
  puts "---"
  pp accessor.messages


  # ARGV.each do |id|

  #   begin
  #     doc = DocSequencerPubMed.new(id)
  #   rescue
  #     warn $!
  #     exit
  #   end

  #   p doc.source_url
  #   puts '======'
  #   p doc.divs
  # end
end
