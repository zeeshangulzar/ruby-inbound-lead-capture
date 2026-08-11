module Inbound
  # Orchestrates the full processing pipeline for a single inbound message that
  # has already been fetched off the API and normalized. Kept lean: each step is
  # a small collaborator.
  class ProcessIncomingEmail
    def initialize(normalized)
      @normalized = normalized
    end

    def call
      lead = find_or_create_lead

      # Redelivery of a message we already handled: do nothing, rather than
      # call the AI again and send the prospect a second reply. Idempotency is
      # also enforced at the DB via unique indexes on inbound_events, but this
      # guard keeps the fast path cheap.
      if lead.already_processed?(@normalized.message_id)
        Rails.logger.info("[ProcessIncomingEmail] duplicate delivery of #{@normalized.message_id} — skipped")
        return :duplicate
      end

      lead.update!(
        inbox_id:        @normalized.inbox_id,
        last_message_id: @normalized.message_id,
        last_subject:    @normalized.subject.presence || lead.last_subject
      )

      return :already_finalized if lead.status == Lead::STATUS_FINALIZED
      return :already_red_flagged if lead.status == Lead::STATUS_RED_FLAGGED

      qualification = LeadQualifier.new(lead: lead, incoming_body: @normalized.body_text).call

      merged_data = lead.extracted_data.merge(qualification.extracted_data.compact)
      lead.update!(extracted_data: merged_data)

      if qualification.hostile?
        finalize_as_red_flag(lead, reasoning: qualification.reasoning)
        return :red_flagged
      end

      if qualification.fallback?
        record_ai_unavailable(lead, reasoning: qualification.reasoning)

        # The cap still applies: it exists to stop an exchange running away, and
        # an unreachable AI is no reason to keep answering. Only successful
        # deliveries advance the counter — a failed send does not consume a
        # reply slot.
        unless lead.reply_cap_reached?
          attempt_follow_up(lead, qualification)
        end
        return :ai_unavailable
      end

      if lead.ready_for_final_verdict?
        VerdictRouter.new(lead: lead, prior_reasoning: qualification.reasoning).call
        :final_verdict
      else
        attempt_follow_up(lead, qualification)
        :followed_up
      end
    end

    private

    def attempt_follow_up(lead, qualification)
      lead.update!(last_reply_status: Lead::REPLY_STATUS_PENDING, last_reply_error: nil)

      result = MelissaMailer.new(lead: lead).send_follow_up(reply_paragraphs: qualification.reply_paragraphs)

      if result.sent?
        lead.update!(last_reply_status: Lead::REPLY_STATUS_SENT, last_reply_error: nil)
        lead.increment!(:ai_reply_count)
      else
        lead.update!(last_reply_status: Lead::REPLY_STATUS_FAILED, last_reply_error: result.error)
      end
    end

    def find_or_create_lead
      Lead.find_or_create_by!(thread_id: @normalized.thread_id) do |lead|
        lead.sender_email = @normalized.sender_email
        lead.sender_name  = @normalized.sender_name
        lead.last_subject = @normalized.subject
        lead.inbox_id     = @normalized.inbox_id
      end
    end

    def finalize_as_red_flag(lead, reasoning:)
      lead.update!(
        status:  Lead::STATUS_RED_FLAGGED,
        verdict: verdict_for(lead, tier: Lead::TIER_RED_FLAG, reasoning: reasoning)
      )
    end

    # The AI being unavailable must not lose the lead: status stays
    # in_conversation, and a later round can qualify it properly once the AI is
    # reachable again. The verdict is set to a cold tier so it surfaces in the
    # UI as a lead we couldn't process yet.
    def record_ai_unavailable(lead, reasoning:)
      lead.update!(verdict: verdict_for(lead, tier: Lead::TIER_COLD, reasoning: reasoning))
    end

    def verdict_for(lead, tier:, reasoning:)
      {
        "tier"              => tier,
        "score"             => 0,
        "extracted_data"    => lead.extracted_data,
        "data_completeness" => lead.data_completeness,
        "reasoning"         => reasoning,
        "inconsistencies"   => [],
        "next_steps"        => []
      }
    end
  end
end
