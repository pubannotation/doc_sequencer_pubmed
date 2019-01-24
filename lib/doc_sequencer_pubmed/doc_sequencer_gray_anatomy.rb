#!/usr/bin/env ruby
require 'net/http/persistent'
require 'oga'
require 'pp'

class DocSequencerGrayAnatomy
  attr_reader :messages

  def initialize
    @base_url = 'https://www.bartleby.com/107/'
    @http = Net::HTTP::Persistent.new
  end

  def get_doc(id)
    raise ArgumentError, "'#{id}' is not a valid ID" unless id =~ /^([1-9][0-9]*)$/

    html_doc = retrieve_doc(id)
    doc = extract_doc(html_doc)

    source_url = @base_url + id + '.html'
    doc.merge!({sourcedb: 'GrayAnatomy', sourceid:id, source_url: source_url})

    doc
  end

  def get_docs (docids)
    docs = docids.map {|docid| get_doc(docid)}.compact
    # docs.empty? ? [] : docs.reduce(:+)
  end

  def retrieve_doc(id)
    uri = URI @base_url + id + '.html'
    response = @http.request uri
    raise RuntimeError, "Could not get the document from the server. Below was the response of the server\n#{response.message}" unless response.code == '200'
    response.body
  end

  def extract_doc(article)
    title = get_title(article)
    body  = get_body(article)

    raise 'could not find the title' if title.nil?
    raise 'could not find the body' if body.nil?

    {section: title, text:body}
  end

  private

  def get_title(article)
    article.match(/BEGIN CHAPTERTITLE(.*)END CHAPTERTITLE/m)
    title_area = $1
    title_area.match(%r|<FONT SI
      ZE="+2"><BR><B>(.*)</B></FONT>|)
    title_area.match(%r|<B>(.*)</B>|)
    title = $1
  end


  def get_body(article)
    marker_begin_chapter = '<!-- BEGIN CHAPTER -->'
    chapter_beg_position = begin
      pos = article.index(marker_begin_chapter) + marker_begin_chapter.length
      # article.rindex('<TABLE', pos)
    end

    maraker_end_chapter = '<!-- END CHAPTER -->'
    chapter_end_position = begin
      pos = article.index(maraker_end_chapter) + maraker_end_chapter.length
#      article.rindex('</TABLE>', pos) + '</TABLE>'.length
    end

    html_chapter = article[chapter_beg_position ... chapter_end_position]

    # pre-parse cleaning
    # html_chapter.gsub!(%r|<FONT SIZE="-2"><A NAME ="\d+"><I>&nbsp;&nbsp;&nbsp;\d+</I></A></FONT>|, '')

    chapter_parsed = Oga.parse_html(html_chapter)
    chapter = chapter_parsed.children.text

    # post-parse cleaning
    # chapter.gsub!(/<!--[^>]+-->/, '')
    # chapter.gsub!(/\(See enlarged image\)/, '')
    chapter.gsub!(/[\u0097\u0096]/, ' - ')
    chapter.gsub!(/[\u00a0]+/, ' ')
    chapter.gsub!(/[\r\n]+/, "\n")
    chapter.gsub!(/\n /, "\n")
    chapter.gsub!(/ \n/, "\n")
    chapter.gsub!(/\n+/, "\n")
    chapter.gsub!(/^\n/, "")

    puts "-----r"
    puts chapter
    puts "-----x"

    chapter
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

  accessor = DocSequencerGrayAnatomy.new
  doc = accessor.get_doc("17")
  p doc[:body]


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
