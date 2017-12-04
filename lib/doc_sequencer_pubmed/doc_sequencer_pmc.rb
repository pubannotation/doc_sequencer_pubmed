#!/usr/bin/env ruby
require 'net/http/persistent'
require 'xml'
require 'pp'

class DocSequencerPMC
  attr_reader :messages

  MAX_NUM_ID = 100

  def initialize
    base_url = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/'
    @esearch_url = base_url + 'esearch.fcgi?db=pmc&usehistory=y'
    @efetch_url = base_url + 'efetch.fcgi?db=pmc&retmode=xml'
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
    # puts xml_docs
    # puts "-----"

    docs = extract_docs(xml_docs)
    return_ids = docs.map{|doc| doc[:sourceid]}.uniq
    if return_ids.length < ids.length
      missing_ids = ids - return_ids
      @messages << "Could not get #{missing_ids.length} #{missing_ids.length > 1 ? 'docs' : 'doc'}: #{missing_ids.join(', ')}"
    end

    # unless @messages.empty?
    #   puts @messages.join("\n-----\n")
    #   exit
    # end

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
      begin
        pmcid = get_id(article)
        comment_node = article.find_first('.//comment()')
        raise ArgumentError, "The article, #{pmcid}, is not within Open Access Subset." if comment_node && comment_node.content =~ /The publisher of this article does not allow/
        divs = get_divs(article)
        source_url = 'https://www.ncbi.nlm.nih.gov/pmc/' + pmcid
        divs.map{|div| div.merge({sourcedb:'PMC', sourceid:pmcid, source_url: source_url})}
      rescue => e
        @messages << e.message
        nil
      end
    end.compact
    
    docs.empty? ?
      [] :
      docs.reduce(:+)
  end

  def get_id(article)
    pmcid = begin
      pmcid_nodes = article.find('.//front/article-meta/article-id[@pub-id-type="pmc"]')
      raise RuntimeError, "Encountered an article with multiple pmcids" if pmcid_nodes.size > 1
      raise RuntimeError, "Encountered an article with no pmcid" if pmcid_nodes.size < 1
      pmcid_nodes.first.content.strip
    end
  end

  def get_divs(article)
    title    = get_title(article)
    abstract = get_abstract(article)
    secs     = get_secs(article)
    fgroup   = article.find_first('.//floats-group') # floats group

    raise 'could not find a title' if title.nil?
    raise 'could not find a section' if secs.nil? || secs.empty?

    psec     = (secs and secs[0].is_a?(Array))? secs.shift : nil

    # extract captions
    caps = []

    if psec
      psec.each do |p|
        if p.name == 'fig' || p.name == 'table-wrap'
          caps << get_caption(p)
        else
          figs = p.find('.//fig')
          tbls = p.find('.//table-wrap')

          figs.each {|f| caps << get_caption(f)}
          tbls.each {|t| caps << get_caption(t)}

          figs.each {|f| f.remove!}
          tbls.each {|t| t.remove!}
        end
      end

      psec.delete_if {|p| p.name == 'fig' || p.name == 'table-wrap'}
    end

    secs.each do |sec|
      figs = sec.find('.//fig')
      tbls = sec.find('.//table-wrap')

      figs.each {|f| caps << get_caption(f)}
      tbls.each {|t| caps << get_caption(t)}

      figs.each {|f| f.remove!}
      tbls.each {|t| t.remove!}
    end

    if fgroup
      figs = fgroup.find('.//fig')
      tbls = fgroup.find('.//table-wrap')

      figs.each {|f| caps << get_caption(f)}
      tbls.each {|t| caps << get_caption(t)}

      figs.each {|f| f.remove!}
      tbls.each {|t| t.remove!}
    end

    caps.compact!

    divs = []

    divs << {section: 'TIAB', text: get_text(title) + "\n" + get_text(abstract)} if title || abstract

    if psec
      text = psec.collect {|p| get_text(p)}.join("\n")
      divs << {section: "Body", text: text}
    end

    secs.each do |sec|
      stitle  = sec.find_first('./title')
      label   = stitle.content.strip
      stitle.remove!

      ps      = sec.find('./p')
      subsecs = sec.find('./sec | ./boxed-text/sec')

      # remove dummy section
      if subsecs.length == 1
        subsubsecs = subsecs[0].find('./sec')
        subsecs = subsubsecs if subsubsecs.length > 0
      end

      if subsecs.length == 0
        divs << {section: label, text: get_text(sec)}
      else
        if ps.length > 0
          text = ps.collect{|p| get_text(p)}.join
          divs << {section: label, text: text}
        end

        subsecs.each do |subsec|
          divs << {section: label, text: get_text(subsec)}
        end
      end
    end

    divs += caps
    divs.each{|d| d[:text] = d[:text].strip.gsub(/ +/, ' ').gsub(/ \n/, "\n").gsub(/\n /, "\n").gsub(/\n+/, "\n")}
    divs.each_with_index{|d, i| d[:divid] = i}

    raise RuntimeError, "Empty document" if divs.empty?

    return divs
  end


  def get_caption(element)
    label   = begin
      l = element.find_first('./label')
      l.nil? ? 'Caption' : 'Caption-' + l.content.strip
    end
    caption = element.find_first('./caption')
    {section: label, text: get_text(caption)} if caption
  end


  def get_title(article)
    titles = article.find('.//front/article-meta/title-group/article-title')
    if titles.length == 1
      title = titles.first
      return (check_title(title))? title : nil
    else
      raise RuntimeError,"more than one titles."
    end
  end


  def get_abstract(article)
    abstracts = article.find('.//front/article-meta/abstract')

    # There are cases where there is no abstract (PMC3370949)
    return nil if abstracts.nil? || abstracts.empty?

    if abstracts.length == 1
      abstract = abstracts.first
    else
      abstracts.each do |a|
        unless a['abstract-type']
          abstract = a
          break
        end
      end
    end

    return abstract if abstract && check_abstract(abstract)
    raise RuntimeError, "something wrong in getting the abstract."
  end


  def get_secs(article)
    body = article.find_first('.//body')

    if body
      secs = Array.new
      psec = Array.new

      body.each_element do |e|
        case e.name

        # 'fig' case: PMC3417396
        # 'list' case: PMC4063857
        # 'disp-formula' : PMC4103545
        when 'p', 'list', 'fig', 'table-wrap', 'disp-formula'
          if secs.empty?
            psec << e
          else
            raise RuntimeError, "a <#{e.name}> element between <sec> elements"
          end
        when 'sec'
          secs << psec if secs.empty? && !psec.empty?

          title = e.find_first('title').content.strip.downcase
          case title
          # filtering by title
          when /contributions$/, /supplementary/, /abbreviations/, 'competing interests', 'supporting information', 'additional information', 'funding'
          else
            case e["sec-type"]
            when 'supplementary-material' # PMC4159038, PMC4159043, PMC4262357, PMC4262369
            else
              if check_sec(e)
                secs << e
              else
                raise RuntimeError, "a unexpected structure of <sec>"
              end
            end
          end
        when 'supplementary-material'
        when 'disp-quote'
        else
          raise RuntimeError, "an unexpected element out of sec: #{e.name}"
          return nil
        end
      end

      secs << psec if secs.empty? && !psec.empty?

      if secs.empty?
        return nil
      else
        return secs
      end
    else
      return nil
    end
  end


  def check_sec (sec)
    title = ''
    sec.each_element do |e|
      case e.name
      when 'title'
        title = e.content.strip
        return false unless check_title(e)
      when 'label'
      when 'disp-formula'
      when 'disp-quote' # PMC3417391
      when 'graphic'
      when 'list'
      when 'boxed-text'
      when 'p'
        return false unless check_p(e)
      when 'sec'
        return false unless check_sec(e)
      when 'fig', 'table-wrap'
        return false unless check_float(e)
      else
        raise RuntimeError, "a unexpected element in sec (#{title}): #{e.name}"
      end
    end
    true
  end


  def check_subsec (sec)
    sec.each_element do |e|
      case e.name
      when 'title'
        return false unless check_title(e)
      when 'label'
      when 'p'
        return false unless check_p(e)
      when 'fig', 'table-wrap'
        return false unless check_float(e)
      else
        raise RuntimeError, "a unexpected element in subsec: #{e.name}"
        return false
      end
    end
    return true
  end


  def check_abstract (node)
    node.each_element do |e|
      case e.name
      when 'title'
        return false unless check_title(e)
      when 'p'
        return false unless check_p(e)
      when 'sec'
        return false unless check_subsec(e)
      else
        raise RuntimeError, "a unexpected element in abstract: #{e.name}"
      end
    end
    return true
  end


  def check_title(node)
    node.each_element do |e|
      case e.name
      when 'italic', 'bold', 'sup', 'sub', 'underline', 'sc'
      when 'xref', 'named-content'
      when 'inline-formula' # TODO: check if it can be ignored.
      else
        raise RuntimeError, "a unexpected element in title: #{e.name}\n#{get_text(node)}"
      end
    end
    return true
  end


  def check_p(node)
    node.each_element do |e|
      case e.name
      when 'italic', 'bold', 'sup', 'sub', 'underline', 'sc', 'monospace'
      when 'styled-content'
      when 'xref', 'ext-link', 'uri', 'named-content', 'email'
      when 'list' # PMC4114466, TODO: list-type=order
      when 'fig', 'table-wrap', 'fig-group'
      when 'graphic' # PMC3417534
      when 'statement' # TODO: check what it is
      when 'inline-graphic', 'disp-formula', 'inline-formula' # TODO: check if it can be ignored.
      else
        raise RuntimeError, "a unexpected element in p: #{e.name}"
      end
    end
    return true
  end


  def check_float(node)
    labels   = node.find('./label')
    captions = node.find('./caption')

    # raise RuntimeError, "There are #{captions.length} captions" unless captions.length == 1
    # There are cases where label does not exist, e.g., PMC3370950

    # There are cases where caption does not exist, e.g., PMC4688367
    return true if captions.empty?

    caption = captions.first

    caption.each_element do |e|
      case e.name
      when 'title'
        return false unless check_title(e)
      when 'p'
        return false unless check_p(e)
      else
        raise RuntimeError, "a unexpected element in caption: #{e.name}"
        return false
      end
    end
    true
  end

  def get_text (node)
    return '' if node.nil?

    text = ''
    node.each do |e|
      if e.node_type_name == 'text'
        text += e.content.gsub(/\n/, ' ')
      elsif e.node_type_name == 'element'
        text += "\n" if e.name == 'sec' || e.name == 'title' || e.name == 'p'
        text += get_text(e)
        text += "\n" if e.name == 'sec' || e.name == 'title' || e.name == 'p'
      end
    end

    case node.name
    when 'article-title', 'abstract', 'sec', 'title', 'p'
      text.strip!
    end

    text
  end

  def get_text_old (node)
    text = ''
    node.each do |e|
      if e.node_type_name == 'element' && (e.name == 'sec' || e.name == 'list' || e.name == 'list-item')
        text += get_text(e)
      else
        text += e.content.strip.gsub(/\n/, ' ').gsub(/ +/, ' ')
      end
      text += "\n" if e.node_type_name == 'element' && (e.name == 'sec' || e.name == 'title' || e.name == 'p')
    end
    text
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
    pp accessor.messages
    puts "-----"
    pp docs
  end
end
