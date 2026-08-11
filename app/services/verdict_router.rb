# Runs the final verdict flow once a lead is ready:
#   - Fetches the website snapshot (SSRF-hardened).
#   - Runs FinalVerdict with the merged context (extracted data + snapshot +
#     earlier reasoning).
#   - Applies the three-branch routing rules (red_flag / forwarded / qualified).
#   - Sends the appropriate reply and only finalizes the lead when the reply
#     actually left the system.
#   - Optionally pushes qualified leads to HubSpot after a successful reply.
class VerdictRouter
  def initialize(lead:, prior_reasoning: nil)
    @lead            = lead
    @prior_reasoning = prior_reasoning
  end

  def call
    snapshot = WebsiteAnalyzer.new(@lead.extracted_data["website"]).call
    verdict  = FinalVerdict.new(
      lead:             @lead,
      website_snapshot: snapshot,
      prior_reasoning:  @prior_reasoning
    ).call

    if verdict.legitimate?
      route_by_thresholds(verdict)
    else
      finalize_as_red_flag(verdict)
    end
  end

  private

  def route_by_thresholds(verdict)
    if below_any_threshold?
      attempt_forwarded(verdict)
    else
      attempt_qualified(verdict)
    end
  end

  def below_any_threshold?
    employees  = numeric(@lead.extracted_data["employees"])
    budget_eur = numeric(@lead.extracted_data["budget_eur"])
    hours      = numeric(@lead.extracted_data["hours"])

    employees < min_employees || budget_eur < min_budget_eur || hours < min_hours
  end

  def finalize_as_red_flag(verdict)
    @lead.update!(
      status:  Lead::STATUS_RED_FLAGGED,
      verdict: build_verdict(
        tier:            Lead::TIER_RED_FLAG,
        score:           verdict.score,
        reasoning:       verdict.reasoning,
        inconsistencies: verdict.inconsistencies,
        next_steps:      verdict.next_steps
      )
    )
  end

  def attempt_forwarded(verdict)
    result = MelissaMailer.new(lead: @lead).send_forwarded(partner_email: partner_email)

    if result.sent?
      @lead.increment!(:ai_reply_count)
      @lead.update!(
        last_reply_status: Lead::REPLY_STATUS_SENT,
        last_reply_error:  nil,
        status:            Lead::STATUS_FINALIZED,
        verdict:           build_verdict(
          tier:            Lead::TIER_FORWARDED,
          score:           verdict.score,
          reasoning:       "Below thresholds — handed off to partner (#{partner_email}). #{verdict.reasoning}",
          inconsistencies: verdict.inconsistencies,
          next_steps:      verdict.next_steps + ["Partner (#{partner_email}) will follow up directly."]
        )
      )
    else
      record_reply_failure(result)
    end
  end

  def attempt_qualified(verdict)
    result = MelissaMailer.new(lead: @lead).send_qualified(scheduling_link: scheduling_link)

    unless result.sent?
      record_reply_failure(result)
      return
    end

    @lead.increment!(:ai_reply_count)
    @lead.update!(
      last_reply_status: Lead::REPLY_STATUS_SENT,
      last_reply_error:  nil
    )

    tier, threshold_score = tier_and_threshold_score
    combined_score = combine_scores(threshold_score, verdict.score)

    hubspot_contact_id = HubspotSync.new(lead: @lead).call
    @lead.update!(hubspot_contact_id: hubspot_contact_id) if hubspot_contact_id

    @lead.update!(
      status:  Lead::STATUS_FINALIZED,
      verdict: build_verdict(
        tier:            tier,
        score:           combined_score,
        reasoning:       "Passed all thresholds. #{verdict.reasoning}",
        inconsistencies: verdict.inconsistencies,
        next_steps:      verdict.next_steps + ["Introductory call via #{scheduling_link}"]
      )
    )
  end

  def record_reply_failure(result)
    @lead.update!(
      last_reply_status: Lead::REPLY_STATUS_FAILED,
      last_reply_error:  result.error
    )
  end

  def build_verdict(tier:, score:, reasoning:, inconsistencies:, next_steps:)
    {
      "tier"              => tier,
      "score"             => score,
      "extracted_data"    => @lead.extracted_data,
      "data_completeness" => @lead.data_completeness,
      "reasoning"         => reasoning,
      "inconsistencies"   => Array(inconsistencies).map(&:to_s),
      "next_steps"        => Array(next_steps).map(&:to_s)
    }
  end

  def tier_and_threshold_score
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

  # Combine the deterministic threshold score with Claude's confidence score so
  # a strong-fit-on-paper lead with obvious inconsistencies drops below the hot
  # tier and vice versa.
  def combine_scores(threshold_score, ai_score)
    ((threshold_score + ai_score) / 2.0).round
  end

  def threshold_score(value, floor, ceiling)
    return 0   if value < floor
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
