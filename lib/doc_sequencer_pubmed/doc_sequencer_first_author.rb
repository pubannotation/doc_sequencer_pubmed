#!/usr/bin/env ruby
require 'net/http/persistent'
require 'nokogiri'
require 'pp'

class DocSequencerFirstAuthor
  attr_reader :messages

  def initialize
    @http = Net::HTTP::Persistent.new
    @base_url = 'http://first.lifesciencedb.jp/archives/'
  end

  def get_doc (docid)
    raise ArgumentError, "'#{docid}' is not a valid ID of First Authors" unless docid =~ /^[1-9][0-9]*$/

    source_url = @base_url + docid
    html_doc = retrieve_doc(source_url)
    html_doc = modify_html(html_doc)
    # puts html_doc
    # divs = extract_divs(html_doc)
    text = extract_text(html_doc)
    {sourcedb:'FirstAuthors', sourceid:docid, source_url: source_url, text:text}
  end

  def get_docs (docids)
    docs = docids.map {|docid| get_doc(docid)}.compact
    docs.empty? ? [] : docs.reduce(:+)
  end

  private

  def modify_html(html_doc)
    html_doc.sub!(/<div class="article_thumb">\n/, "<div class=\"article_thumb\"><div class=\"preamble\">\n")
    html_doc.gsub!(/<h2/, '</div><div class="section"><h2 ')
    html_doc.gsub!(/ 2\.1 (.+)<\/a>/) {" 2.1 #{$1}</a></div>"}
  end

  def retrieve_doc (source_url)
    uri = URI source_url
    result = @http.request uri
    raise RuntimeError, "Could not get the document from the server. Below was the response of the server\n#{result.message}" unless result.code == '200'
    result.body
  end


  def extract_text (html_doc)
    return [] if html_doc.nil?

    doc = Nokogiri::HTML(html_doc)


    title   = doc.xpath('//div[@id="contentleft"]/div[contains(@class, "article")]/h1')
    raise RuntimeError, "Multiple titles." if title.length > 1
    title = title.first

    article = doc.xpath('//div[@id="contentleft"]/div[contains(@class, "article")]/div[contains(@class, "article_thumb")]')[1]

    text = get_text(article)
  end

  def get_text(article)
    text_preamble = ''
    text_sections = []

    article.traverse do |node|
      if node.name == 'div'
        if node['class'] == 'preamble'
          text_preamble = get_text_from_preamble(node)
        end

        if node['class'] == 'section'
          text_sections << get_text_from_section(node)
        end
      end

    end

    text =''
    text += text_preamble + "\n\n" + text_sections.join("\n\n")
    text
  end


  def get_text_from_preamble(node)
    authors = ''
    affiliations = ''
    email = ''
    origin = ''

    collect = ''
    node.traverse do |node|
      # authors
      if authors.empty? && node.name == 'strong'
        authors = node.to_s
      end

      if !authors.empty? && affiliations.empty?
        if node.name == 'sup'
          collect += node.to_s
        end
        if node.text? && node.content !~ /^[1-9]$/
          collect += node.to_s
        end
      end

      if affiliations.empty? && !collect.empty? && node.name == 'br'
        affiliations = collect
        collect = ''
      end

      if !affiliations.empty? && email.empty? && node.name == 'a'
        email += node.attr('href').to_s + " (#{node.content})"
      end

      if !email.empty? && origin.empty? && node.name == 'div'
        origin += node.inner_html
      end

    end

    text  = authors
    text += "\n\n" + affiliations
    text += "\n\n" + email
    text += "\n\n" + origin

    text
  end

  def get_text_from_section(node)
    node.inner_html
  end


  def extract_divs (html_doc)
    return [] if html_doc.nil?

    doc = Nokogiri::HTML(html_doc)
    divs = get_divs(doc)
  end



  def get_divs(doc)
    title = get_title(doc)
    secs  = get_secs(doc)

    if title and secs
      divs = []

      divs = secs.map.with_index do |sec, index|
        label, text = if index == 0
          ['TIAB', title + "\n" + sec[:body]]
        else
          _label = sec[:heading]
          _lebel = 'Introduction' if _label == 'はじめに'
          _lebel = 'Conclusion' if _label == 'おわりに'
          [_label, sec[:body]]
        end
        {section: label, text: text.strip}
      end

      divid = -1
      divs.map!{|div| div.merge(divid: divid += 1)}

      return divs
    else
      return nil
    end
  end

  def get_title(doc)
    titles = doc.xpath('//div[@id="contentleft"]//h1')
    if titles.length == 1
      title = titles.first.content.strip
    else
      warn "more than one titles."
      return nil
    end
  end

  def get_secs(doc)
    secs = []
    sec = {}

    body = doc.xpath('//div[@id="contentleft"]').first.traverse do |node|
      if node.element?
        if node.name == 'h2'
          secs << sec.dup if sec[:heading]

          if node.content == '文 献'
            sec[:heading] = nil
            sec[:body] = nil
          else
            sec[:heading] = node.content.strip
            sec[:body] = node.content.strip
          end
        # elsif sec[:heading] && node.name == 'p'
        elsif sec[:heading]
          sec[:body] += "\n" + node.content.strip
        end
      end
    end

    secs
  end

end

if __FILE__ == $0
  source = 'n'
  output = nil

  require 'optparse'
  optparse = OptionParser.new do |opts|
    opts.banner = "Usage: doc_sequencer_firstauthor.rb [option(s)] id"

    opts.on('-h', '--help', 'displays this screen') do
      puts opts
      exit
    end
  end

  optparse.parse!

  ARGV.each do |id|
    faseq = DocSequencerFirstAuthor.new
    fadoc = faseq.get_docs([id])
    pp fadoc
  end

end
