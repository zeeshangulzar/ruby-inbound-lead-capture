module Inbound
  # Orchestrates the full processing pipeline for a single verified inbound
  # email. Kept lean: each step is a small collaborator.
  class ProcessIncomingEmail
    def initialize(payload)
      @payload = payload
    end

    def call
      normalized = PayloadNormalizer.new(@payload).call
      lead       = find_or_create_lead(normalized)

      return if lead.status == Lead::STATUS_FINALIZED
      return if lead.status == Lead::STATUS_RED_FLAGGED

      qualification = LeadQualifier.new(lead: lead, incoming_body: normalized.body_text).call

      merged_data = lead.extracted_data.merge(qualification.extracted_data.compact)
      lead.update!(extracted_data: merged_data)

      if qualification.hostile?
        finalize_as_red_flag(lead, reasoning: qualification.reasoning)
        return
      end

      if lead.ready_for_final_verdict?
        VerdictRouter.new(lead: lead).call
      else
        MelissaMailer.new(lead: lead, ai_content: qualification).send_follow_up
        lead.increment!(:ai_reply_count)
      end
    end

    private

    def find_or_create_lead(normalized)
      Lead.find_or_create_by!(thread_id: normalized.thread_id) do |lead|
        lead.sender_email = normalized.sender_email
        lead.sender_name  = normalized.sender_name
        lead.last_subject = normalized.subject
      end.tap do |lead|
        lead.update!(last_subject: normalized.subject) if normalized.subject.present?
      end
    end

    def finalize_as_red_flag(lead, reasoning:)
      lead.update!(
        status:  Lead::STATUS_RED_FLAGGED,
        verdict: {
          "tier"              => Lead::TIER_RED_FLAG,
          "score"             => 0,
          "data_completeness" => data_completeness(lead),
          "reasoning"         => reasoning,
          "next_steps"        => []
        }
      )
    end

    def data_completeness(lead)
      case lead.missing_required_fields.size
      when 0    then "full"
      when 1..2 then "partial"
      else           "minimal"
      end
    end
  end
end
