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
      # call the AI again and send the prospect a second reply.
      if lead.already_processed?(@normalized.message_id)
        Rails.logger.info("[ProcessIncomingEmail] duplicate delivery of #{@normalized.message_id} — skipped")
        return
      end

      lead.update!(
        inbox_id:        @normalized.inbox_id,
        last_message_id: @normalized.message_id,
        last_subject:    @normalized.subject.presence || lead.last_subject
      )

      return if lead.status == Lead::STATUS_FINALIZED
      return if lead.status == Lead::STATUS_RED_FLAGGED

      qualification = LeadQualifier.new(lead: lead, incoming_body: @normalized.body_text).call

      merged_data = lead.extracted_data.merge(qualification.extracted_data.compact)
      lead.update!(extracted_data: merged_data)

      if qualification.hostile?
        finalize_as_red_flag(lead, reasoning: qualification.reasoning)
        return
      end

      # The AI was unreachable, so there is nothing to qualify on and no point
      # running the website check. Send the generic acknowledgement and record
      # the lead as cold.
      if qualification.fallback?
        record_ai_unavailable(lead, reasoning: qualification.reasoning)

        # The cap still applies: it exists to stop an exchange running away, and
        # an unreachable AI is no reason to keep answering.
        unless lead.reply_cap_reached?
          MelissaMailer.new(lead: lead, ai_content: qualification).send_follow_up
          lead.increment!(:ai_reply_count)
        end
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

    # The AI being unavailable must not lose the lead: the prospect still gets a
    # generic acknowledgement, and the lead is recorded as cold so it surfaces
    # in the UI. Status stays in_conversation, so a later round can qualify it
    # properly once the AI is reachable again.
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
        "next_steps"        => []
      }
    end
  end
end
