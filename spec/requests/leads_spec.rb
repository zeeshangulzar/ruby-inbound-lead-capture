require "rails_helper"

RSpec.describe "Leads UI", type: :request do
  describe "GET /leads" do
    it "renders an empty state with no leads" do
      get "/leads"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No leads yet")
    end

    it "lists a captured lead with its tier and score" do
      Lead.create!(
        thread_id: thread_id, sender_email: "sam@acme.co", sender_name: "Sam Prospect",
        extracted_data: complete_extracted_data,
        verdict: { "tier" => "hot", "score" => 92, "reasoning" => "Strong fit." }
      )

      get "/leads"

      expect(response.body).to include("sam@acme.co", "Sam Prospect", "Acme", "hot", "92")
    end

    it "shows pending for a lead with no verdict yet" do
      Lead.create!(thread_id: thread_id, sender_email: "sam@acme.co")
      get "/leads"

      expect(response.body).to include("pending")
    end

    it "is also served at the root path" do
      get "/"
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /leads/:id" do
    let(:lead) do
      Lead.create!(
        thread_id: thread_id, sender_email: "sam@acme.co", sender_name: "Sam Prospect",
        extracted_data: complete_extracted_data, ai_reply_count: 2,
        verdict: {
          "tier" => "warm", "score" => 68, "data_completeness" => "full",
          "reasoning" => "Solid but modest budget.", "next_steps" => ["Introductory call"]
        }
      )
    end

    it "shows the extracted data and the verdict" do
      get "/leads/#{lead.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Acme", "warm", "68", "Solid but modest budget.", "Introductory call")
    end

    it "shows the thread id" do
      get "/leads/#{lead.id}"
      expect(response.body).to include(thread_id)
    end

    it "reports progress for a lead still in conversation" do
      pending_lead = Lead.create!(thread_id: "t-2", sender_email: "other@acme.co", ai_reply_count: 1)
      get "/leads/#{pending_lead.id}"

      expect(response.body).to include("Not yet finalized")
    end

    it "marks missing required fields" do
      partial = Lead.create!(thread_id: "t-3", sender_email: "p@acme.co",
                             extracted_data: { "employees" => 40 })
      get "/leads/#{partial.id}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("missing")
    end

    it "404s for an unknown lead" do
      get "/leads/999999"
      expect(response).to have_http_status(:not_found)
    end
  end
end
