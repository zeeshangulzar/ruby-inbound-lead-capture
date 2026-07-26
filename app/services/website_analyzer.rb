require "httparty"
require "nokogiri"

# Fetches the lead's website (5s timeout), parses <title>, meta description,
# and the first ~2000 chars of body text, then asks Claude for a legitimacy
# verdict. Any fetch/parse error → legitimate=false, so the lead is red-flagged.
class WebsiteAnalyzer
  Result = Struct.new(:legitimate, :reasoning, :fetch_error, keyword_init: true) do
    alias_method :legitimate?, :legitimate
  end

  FETCH_TIMEOUT_SECONDS = 5
  BODY_TEXT_LIMIT       = 2_000

  def initialize(url)
    @url = url.to_s
  end

  def call
    return blank_url_result if @url.blank?

    snapshot = fetch_and_parse
    return snapshot if snapshot.is_a?(Result) # error case

    ask_claude_verdict(snapshot)
  rescue => e
    Rails.logger.error("[WebsiteAnalyzer] failed for #{@url}: #{e.class} — #{e.message}")
    Result.new(legitimate: false, reasoning: "Website analysis errored (#{e.class}).", fetch_error: true)
  end

  private

  def fetch_and_parse
    response = HTTParty.get(@url, timeout: FETCH_TIMEOUT_SECONDS, follow_redirects: true)
    return fetch_error_result(response.code) unless response.success?

    doc = Nokogiri::HTML(response.body)
    {
      title:       doc.at_css("title")&.text.to_s.strip,
      description: doc.at_css('meta[name="description"]')&.[]("content").to_s.strip,
      body:        doc.at_css("body")&.text.to_s.gsub(/\s+/, " ").strip.slice(0, BODY_TEXT_LIMIT)
    }
  rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
    fetch_error_result(e.class.name)
  end

  def ask_claude_verdict(snapshot)
    client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    response = client.messages.create(
      model:      ENV.fetch("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001"),
      max_tokens: 256,
      system:     "You judge whether a company website looks legitimate. Return only JSON: { \"legitimate\": <boolean>, \"reasoning\": <string> }.",
      messages:   [{ role: "user", content: <<~PROMPT }]
        URL:          #{@url}
        Title:        #{snapshot[:title]}
        Description:  #{snapshot[:description]}
        Body sample:  #{snapshot[:body]}

        Is this a real, operating business? Flag single-page brochures with no
        contact details, parked domains, or obvious scams as not legitimate.
      PROMPT
    )
    parsed = JSON.parse(response.content.first.text[/\{.*\}/m])
    Result.new(
      legitimate:  parsed["legitimate"] == true,
      reasoning:   parsed["reasoning"].to_s,
      fetch_error: false
    )
  rescue JSON::ParserError => e
    Rails.logger.error("[WebsiteAnalyzer] Claude returned unparseable JSON: #{e.message}")
    Result.new(legitimate: false, reasoning: "Verdict parse error.", fetch_error: false)
  end

  def blank_url_result
    Result.new(legitimate: false, reasoning: "No website supplied.", fetch_error: false)
  end

  def fetch_error_result(detail)
    Result.new(legitimate: false, reasoning: "Website fetch failed (#{detail}).", fetch_error: true)
  end
end
