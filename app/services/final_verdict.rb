require "json"

# Runs the final AI evaluation once qualification data has been collected. Sees
# the extracted lead fields, the website snapshot, and the reasoning
# LeadQualifier attached to the incoming email, and returns a structured verdict
# containing legitimacy, a numeric score, reasoning, inconsistencies, and next
# steps.
#
# The website snapshot is passed in — this service does not fetch. That
# separation lets WebsiteAnalyzer own the SSRF-hardened fetch + parse and keeps
# this class focused on prompting Claude with the merged context.
class FinalVerdict
  Result = Struct.new(
    :legitimate, :score, :reasoning, :inconsistencies, :next_steps, :fallback,
    keyword_init: true
  ) do
    alias_method :legitimate?, :legitimate
    alias_method :fallback?,   :fallback
  end

  MAX_TOKENS = 512

  SYSTEM_PROMPT = <<~PROMPT.freeze
    You evaluate a qualified inbound sales lead. You are given the fields the
    lead supplied, a snapshot of their website, and the reasoning the earlier
    qualification step captured. Judge:

    - Whether the company looks legitimate. Flag single-page brochures with no
      contact details, parked domains, and obvious scams.
    - Whether the supplied fields and the website tell a consistent story.
      Examples of inconsistencies: claimed "500 employees" but the website is a
      one-page brochure; a €50,000 budget from a company whose website looks
      like a personal blog; a technical domain (fintech, biotech) with a
      website in a completely unrelated sector.
    - A 0–100 confidence score. 80+ means a strong fit with no red flags;
      60–79 means qualified with minor concerns; 40–59 means concerning but not
      disqualifying; below 40 means the lead should not be pursued.
    - One or two concrete next steps for the sales team.

    Return ONLY JSON, no prose, matching this exact schema:
    {
      "legitimate": <boolean>,
      "score": <integer 0-100>,
      "reasoning": <string>,
      "inconsistencies": [<string>, ...],
      "next_steps": [<string>, ...]
    }
  PROMPT

  def initialize(lead:, website_snapshot:, prior_reasoning: nil)
    @lead             = lead
    @website_snapshot = website_snapshot
    @prior_reasoning  = prior_reasoning.to_s
  end

  def call
    parse(claude_raw_response)
  rescue StandardError => e
    Rails.logger.error("[FinalVerdict] Anthropic call failed: #{e.class} — #{e.message}")
    fallback_result("AI evaluation unavailable (#{e.class}).")
  end

  private

  def claude_raw_response
    client = Anthropic::Client.new(api_key: ENV.fetch("ANTHROPIC_API_KEY"))
    response = client.messages.create(
      model:      ENV.fetch("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001"),
      max_tokens: MAX_TOKENS,
      system:     SYSTEM_PROMPT,
      messages:   [{ role: "user", content: user_prompt }]
    )
    response.content.first.text
  end

  def user_prompt
    data = @lead.extracted_data.slice(*%w[company website employees budget_eur budget_currency hours])

    <<~PROMPT
      Extracted lead data:
      #{JSON.pretty_generate(data)}

      Website snapshot:
      URL:         #{@website_snapshot&.url}
      Fetched:     #{@website_snapshot&.fetched? ? 'yes' : 'no'}
      Fetch error: #{@website_snapshot&.fetch_error}
      Title:       #{@website_snapshot&.title}
      Description: #{@website_snapshot&.description}
      Body sample: #{@website_snapshot&.body}

      Earlier qualification reasoning:
      #{@prior_reasoning.presence || '(none)'}

      Return the JSON described in the system prompt.
    PROMPT
  end

  def parse(raw)
    json_slice = raw.to_s[/\{.*\}/m]
    return fallback_result("AI returned no JSON object.") if json_slice.nil?

    parsed = JSON.parse(json_slice)

    Result.new(
      legitimate:      parsed["legitimate"] == true,
      score:           clamp_score(parsed["score"]),
      reasoning:       parsed["reasoning"].to_s,
      inconsistencies: Array(parsed["inconsistencies"]).map(&:to_s),
      next_steps:      Array(parsed["next_steps"]).map(&:to_s),
      fallback:        false
    )
  rescue JSON::ParserError => e
    Rails.logger.error("[FinalVerdict] Claude returned unparseable JSON: #{e.message}")
    fallback_result("AI response unparseable.")
  end

  def clamp_score(value)
    Integer(value).clamp(0, 100)
  rescue ArgumentError, TypeError
    0
  end

  def fallback_result(reason)
    Result.new(
      legitimate:      false,
      score:           0,
      reasoning:       reason,
      inconsistencies: [],
      next_steps:      [],
      fallback:        true
    )
  end
end
