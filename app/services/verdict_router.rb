# Runs the final verdict flow once a lead is ready:
#   - Analyzes the website
#   - Applies the three-branch routing rules (red_flag / forwarded / qualified)
#   - Sends the appropriate reply
#   - Optionally pushes qualified leads to HubSpot
class VerdictRouter
  def initialize(lead:)
    @lead = lead
  end

  def call
    website_result = WebsiteAnalyzer.new(@lead.extracted_data["website"]).call

    if website_result.legitimate?
      route_by_thresholds(website_result)
    else
      finalize_as_red_flag(website_result)
    end
  end

  private

  def route_by_thresholds(website_result)
    if below_any_threshold?
      finalize_as_forwarded(website_result)
    else
      finalize_as_qualified(website_result)
    end
  end

  def below_any_threshold?
    employees  = numeric(@lead.extracted_data["employees"])
    budget_eur = numeric(@lead.extracted_data["budget_eur"])
    hours      = numeric(@lead.extracted_data["hours"])

    employees < min_employees || budget_eur < min_budget_eur || hours < min_hours
  end

  def finalize_as_red_flag(website_result)
    @lead.update!(
      status:  Lead::STATUS_RED_FLAGGED,
      verdict: build_verdict(
        tier:       Lead::TIER_RED_FLAG,
        score:      0,
        reasoning:  website_result.reasoning,
        next_steps: []
      )
    )
  end

  def finalize_as_forwarded(website_result)
    MelissaMailer.new(lead: @lead, ai_content: nil).send_forwarded(partner_email: partner_email)
    @lead.increment!(:ai_reply_count)

    @lead.update!(
      status:  Lead::STATUS_FINALIZED,
      verdict: build_verdict(
        tier:       Lead::TIER_FORWARDED,
        score:      50,
        reasoning:  "Below thresholds — handed off to partner (#{partner_email}). Website check: #{website_result.reasoning}",
        next_steps: ["Partner (#{partner_email}) will follow up directly."]
      )
    )
  end

  def finalize_as_qualified(website_result)
    tier, score = tier_and_score
    MelissaMailer.new(lead: @lead, ai_content: nil).send_qualified(scheduling_link: scheduling_link)
    @lead.increment!(:ai_reply_count)

    hubspot_contact_id = HubspotSync.new(lead: @lead).call
    @lead.update!(hubspot_contact_id: hubspot_contact_id) if hubspot_contact_id

    @lead.update!(
      status:  Lead::STATUS_FINALIZED,
      verdict: build_verdict(
        tier:       tier,
        score:      score,
        reasoning:  "Passed all thresholds. Website check: #{website_result.reasoning}",
        next_steps: ["Introductory call via #{scheduling_link}"]
      )
    )
  end

  def build_verdict(tier:, score:, reasoning:, next_steps:)
    {
      "tier"              => tier,
      "score"             => score,
      "extracted_data"    => @lead.extracted_data,
      "data_completeness" => @lead.data_completeness,
      "reasoning"         => reasoning,
      "next_steps"        => next_steps
    }
  end

  def tier_and_score
    employees  = numeric(@lead.extracted_data["employees"])
    budget_eur = numeric(@lead.extracted_data["budget_eur"])
    hours      = numeric(@lead.extracted_data["hours"])

    score = [
      threshold_score(employees,  min_employees,  min_employees * 5),
      threshold_score(budget_eur, min_budget_eur, min_budget_eur * 5),
      threshold_score(hours,      min_hours,      min_hours * 5)
    ].sum / 3

    tier =
      if    score >= 80 then Lead::TIER_HOT
      elsif score >= 60 then Lead::TIER_WARM
      else                    Lead::TIER_COLD
      end

    [tier, score]
  end

  def threshold_score(value, floor, ceiling)
    return 0  if value < floor
    return 100 if value >= ceiling

    (60 + ((value - floor).to_f / (ceiling - floor) * 40)).round
  end

  def numeric(value)
    Float(value)
  rescue ArgumentError, TypeError
    0.0
  end

  def min_employees
    ENV.fetch("MIN_EMPLOYEES", 20).to_i
  end

  def min_budget_eur
    ENV.fetch("MIN_BUDGET_EUR", 1000).to_i
  end

  def min_hours
    ENV.fetch("MIN_HOURS", 20).to_i
  end

  def partner_email
    ENV.fetch("PARTNER_EMAIL", "partner@example.com")
  end

  def scheduling_link
    ENV.fetch("SCHEDULING_LINK", "https://example.com/schedule")
  end
end
