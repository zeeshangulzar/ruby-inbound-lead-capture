require "nokogiri"

# Fetches the lead's website through the SSRF-hardened fetcher, parses <title>,
# meta description, and the first ~2000 chars of body text, and returns a
# snapshot. The legitimacy verdict is intentionally NOT computed here — that
# belongs to FinalVerdict, which sees the snapshot alongside the extracted lead
# data and the earlier qualification reasoning.
class WebsiteAnalyzer
  Snapshot = Struct.new(
    :url, :title, :description, :body, :fetch_error, :fetched?,
    keyword_init: true
  )

  BODY_TEXT_LIMIT = 2_000

  def initialize(url)
    @url = url.to_s
  end

  def call
    return blank_url_snapshot if @url.blank?

    normalized = normalized_url
    response   = fetch(normalized)

    return fetch_error_snapshot(normalized, "HTTP #{response.status}") unless response.success?

    parse(normalized, response.body)
  rescue Inbound::SafeHttpFetcher::Error => e
    fetch_error_snapshot(safe_display_url, "#{e.class.name.split('::').last}: #{e.message}")
  rescue StandardError => e
    Rails.logger.error("[WebsiteAnalyzer] failed for #{@url}: #{e.class} — #{e.message}")
    fetch_error_snapshot(safe_display_url, "#{e.class}: #{e.message}")
  end

  private

  # A bare domain ("acme.co") parses to a URI with no host, so default the
  # scheme rather than red-flagging a legitimate lead. Anything with a scheme
  # is passed through untouched — the fetcher rejects non-HTTP schemes.
  def normalized_url
    return @url if @url.match?(%r{\A[a-z][a-z0-9+.-]*://}i)

    "https://#{@url}"
  end

  def safe_display_url
    normalized_url
  rescue StandardError
    @url
  end

  def fetch(url)
    Inbound::SafeHttpFetcher.new(url).call
  end

  def parse(url, html)
    doc = Nokogiri::HTML(html)
    Snapshot.new(
      url:         url,
      title:       doc.at_css("title")&.text.to_s.strip,
      description: doc.at_css('meta[name="description"]')&.[]("content").to_s.strip,
      body:        doc.at_css("body")&.text.to_s.gsub(/\s+/, " ").strip.slice(0, BODY_TEXT_LIMIT),
      fetch_error: nil,
      fetched?:    true
    )
  end

  def blank_url_snapshot
    Snapshot.new(url: nil, title: "", description: "", body: "", fetch_error: "No website supplied.", fetched?: false)
  end

  def fetch_error_snapshot(url, detail)
    Snapshot.new(url: url, title: "", description: "", body: "", fetch_error: detail, fetched?: false)
  end
end
