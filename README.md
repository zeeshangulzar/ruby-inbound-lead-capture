# ruby-inbound-lead-capture

A Ruby on Rails demo showing how to **capture inbound sales leads via [Mailtrap Inbound](https://mailtrap.io)**, qualify them with an **AI agent (Anthropic Claude)** over a multi-turn email conversation, and push qualified contacts to **HubSpot**.

A prospect emails your sales address → Mailtrap Inbound POSTs the parsed email to a signed webhook → Claude ("Melissa") extracts the qualification fields, asks for anything missing on the same email thread, analyses the prospect's website, and either replies with a scheduling link (qualified), hands the lead off to a partner (below thresholds), or silently red-flags it (suspicious).

## How it works

1. A lead sends an email to your inbound address (`sales@example.com` by default)
2. Mailtrap Inbound POSTs the parsed payload to `POST /webhooks/mailtrap/inbound`
3. Signature is verified via `HMAC-SHA256(MAILTRAP_INBOUND_SECRET, raw_body)`
4. Auto-responders / bounces / no-reply senders are filtered out and skipped
5. Claude extracts `company`, `website`, `employees`, `budget_eur`, `hours`
6. If any required field is missing, **Melissa** replies asking for all missing fields at once — same Mailtrap thread, `In-Reply-To` / `References` / `X-Thread-Id` headers set
7. Conversation caps at **5 AI replies per thread**. After the cap, the AI proceeds with partial data and marks `data_completeness: minimal`
8. Once all four required fields are present (or the cap is hit), the lead's website is fetched (5s timeout) and sent to Claude for a legitimacy verdict
9. The lead is routed to one of three outcomes:
   - **red_flag** — missing website OR Claude judges the site suspicious → no reply, saved with `tier: red_flag`
   - **forwarded** — below any threshold (`< 20 employees` OR `< €1000` budget OR `< 20 hours`) → reply with partner handoff (CC `PARTNER_EMAIL`)
   - **qualified** — passes all thresholds → reply with call-scheduling link, pushed to HubSpot as a Contact when `HUBSPOT_API_KEY` is set

## Features

- `POST /webhooks/mailtrap/inbound` handler with `X-MT-Signature` HMAC verification — tampered payloads are rejected with HTTP 400
- Auto-responder loop prevention — filters `Auto-Submitted: auto-*`, `Precedence: bulk|list`, and known no-reply senders (`mailer-daemon@`, `postmaster@`, `*-noreply@`)
- **Multi-turn conversation via Mailtrap Threads** — Melissa extracts what the lead supplied, asks for missing fields in a single reply, and reuses the same `thread_id` for every outbound message
- **Website analysis** — fetches the supplied URL, parses `<title>`, meta description, and the first ~2000 characters of body text, then asks Claude for a legitimacy verdict
- Three-branch routing — `red_flag` / `forwarded` / `qualified` with configurable thresholds
- HubSpot Contact push — env-gated on `HUBSPOT_API_KEY`, fail-open (a CRM error never blocks the reply)
- Prompt-injection defense — the system prompt tells Claude to ignore in-body instructions
- **Only extracted data is stored** — the raw email body is used for qualification and then discarded; the `leads` table holds only structured fields, the AI verdict, and a HubSpot contact ID
- Read-only `/leads` UI listing every captured lead with tier, score, and verdict reasoning
- Graceful degradation — LLM down → generic "we'll get back to you" reply (`tier: cold`); HubSpot down → lead still saved + replied, error logged; Mailtrap send failure → logged, no crash

## Architecture

```
Prospect email ─► sales@yourdomain.com ─► Mailtrap Inbound
                                                │
                                                ▼ POST + X-MT-Signature
Webhooks::Mailtrap::InboundController
        │
        ├── Inbound::SignatureVerifier            (reject on tamper)
        ├── Inbound::AutoResponderFilter          (skip bounces / no-reply)
        ├── Inbound::PayloadNormalizer            (thread_id, sender, body)
        │
        ▼
Inbound::ProcessIncomingEmail
        │
        ├── LeadQualifier ─► Anthropic Claude
        │                    { extracted_data, reply, hostile?, off_topic? }
        │
        ├── if ready?  ─► VerdictRouter
        │                     │
        │                     ├── WebsiteAnalyzer ─► HTTParty + Nokogiri + Claude
        │                     │
        │                     ├── red_flag   ─► save, no reply
        │                     ├── forwarded  ─► MelissaMailer (CC partner)
        │                     └── qualified  ─► MelissaMailer (scheduling link)
        │                                       └─► HubspotSync (if API key set)
        │
        └── else       ─► MelissaMailer (ask for missing fields, same thread)
```

## Requirements

- Ruby 3.3.6
- Rails 7.2
- SQLite3
- A [Mailtrap](https://mailtrap.io) account with **Email Sending** and **Inbound** configured
- An [Anthropic](https://console.anthropic.com) API key
- (Optional) A [HubSpot](https://hubspot.com) account with a Private App token

## Setup

```bash
git clone https://github.com/zeeshangulzar/ruby-inbound-lead-capture
cd ruby-inbound-lead-capture

bundle install

cp .env.example .env
# Edit .env — add your Mailtrap, Anthropic, and (optionally) HubSpot credentials

rails db:create db:migrate
rails server
```

Open `http://localhost:3000` in your browser to see the `/leads` UI.

### Mailtrap Inbound setup

1. Sign in to [Mailtrap](https://mailtrap.io) → **Email Testing** → **Inboxes** (or **Inbound** on paid plans) and open (or create) an inbound address
2. Set the **webhook URL** to your public endpoint: `https://your-domain.com/webhooks/mailtrap/inbound`
3. Copy the **signing secret** into `.env` as `MAILTRAP_INBOUND_SECRET`
4. Send a test email to the inbound address

> **Reply-cap caveat:** Mailtrap-hosted inbound addresses are ideal for testing the receive side, but for the full multi-turn conversation to work (Melissa's replies coming back into the same thread), you need your own domain with an MX record pointing at Mailtrap — see below.

### Production setup with your own domain

1. Go to **Inbound → Add Domain** in Mailtrap and follow the DNS setup instructions (MX record)
2. Configure an inbound address (e.g. `sales@yourdomain.com`) so incoming email is forwarded to Mailtrap
3. Update `MAILTRAP_INBOUND_SECRET` in `.env` with the webhook secret for the domain's inbound address
4. Update `INBOUND_EMAIL` in `.env` to match the address you configured

### Mailtrap Email Sending setup (for Melissa's replies)

Every outbound reply goes through the Mailtrap Email Sending API using the same account.

1. In Mailtrap, go to **Domains** and either verify your own sending domain or use the pre-created **`demomailtrap.co`** demo domain (delivery only to your Mailtrap account email address — good for testing)
2. Go to **Settings** → **API Tokens** → **Add API Token** with the **Admin** scope on your sending domain
3. Put the token into `.env` as `MAILTRAP_API_TOKEN`
4. Set `MELISSA_EMAIL` to a sender on the verified domain (e.g. `melissa@yourdomain.com` or `melissa@demomailtrap.co`)

### Mailtrap Threads

Every outbound reply carries `In-Reply-To`, `References`, and `X-Thread-Id` headers set to the `thread_id` Mailtrap assigned to the incoming email. This is what keeps each round of the qualification conversation grouped as a single thread — both in the lead's email client and in the Mailtrap dashboard.

### HubSpot Free setup (optional)

1. Sign up at [hubspot.com](https://hubspot.com) — the free CRM tier is enough
2. Go to **Settings → Integrations → Private Apps** and create a new app
3. Grant the scope: `crm.objects.contacts.write`
4. Copy the generated token into `HUBSPOT_API_KEY` in `.env`

Qualified leads are pushed as HubSpot Contacts. If the key is unset the sync is skipped silently; if the API call fails the lead is still saved locally and the reply is still sent (fail-open).

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `MAILTRAP_INBOUND_SECRET` | yes | — | Signing secret from your Mailtrap Inbound settings — used to verify `X-MT-Signature` |
| `MAILTRAP_API_TOKEN` | yes | — | Mailtrap API token (Admin scope on the sending domain) — used for Melissa's outbound replies |
| `ANTHROPIC_API_KEY` | yes | — | Anthropic API key from [console.anthropic.com](https://console.anthropic.com) |
| `ANTHROPIC_MODEL` | no | `claude-haiku-4-5-20251001` | Model used for qualification and website analysis |
| `INBOUND_EMAIL` | no | `sales@example.com` | The address prospects send lead email to |
| `MELISSA_EMAIL` | no | `melissa@example.com` | The `from` on Melissa's replies (must be on a verified sending domain) |
| `PARTNER_EMAIL` | no | `partner@example.com` | Partner sales address CC'd on the `forwarded` reply |
| `SCHEDULING_LINK` | no | `https://example.com/schedule` | URL included in the reply to qualified leads |
| `MIN_EMPLOYEES` | no | `20` | Employees threshold for the qualified branch |
| `MIN_BUDGET_EUR` | no | `1000` | Budget threshold (in EUR) for the qualified branch |
| `MIN_HOURS` | no | `20` | Requested-hours threshold for the qualified branch |
| `HUBSPOT_API_KEY` | no | *(unset)* | HubSpot Private App token — leave blank to disable HubSpot sync |

## Inbound Flow

1. Prospect emails `INBOUND_EMAIL` (e.g. `sales@yourdomain.com`)
2. Mailtrap parses the message and POSTs the payload to `/webhooks/mailtrap/inbound` with `X-MT-Signature`
3. `Webhooks::Mailtrap::InboundController` verifies the signature; tampered payloads return HTTP 400
4. `Inbound::AutoResponderFilter` skips bounces, vacation replies, and known no-reply senders — returns HTTP 200 so Mailtrap does not retry
5. `Inbound::PayloadNormalizer` extracts `thread_id`, sender, subject, and body text (HTML is stripped as a fallback)
6. `Inbound::ProcessIncomingEmail` looks up (or creates) a `Lead` keyed by `thread_id`
7. `LeadQualifier` sends the incoming body + previously-extracted data to Claude with a strict system prompt (no hallucination, ask-for-all-missing-in-one-reply, prompt-injection defense)
8. Fields already present are preserved; newly-supplied fields are merged
9. If the lead is ready (all four required fields OR five AI replies sent):
   - `WebsiteAnalyzer` fetches the URL (5s timeout), parses the HTML with Nokogiri, and asks Claude for a legitimacy verdict
   - `VerdictRouter` decides `red_flag` / `forwarded` / `qualified` and calls `MelissaMailer` (except on `red_flag`, which is silent)
   - Qualified leads are pushed to HubSpot when `HUBSPOT_API_KEY` is set
10. Otherwise `MelissaMailer` sends a follow-up asking for the missing fields, on the same Mailtrap thread

## Melissa (AI agent) behaviour

- Signs every reply as "Melissa", 3–5 sentences, friendly-professional, plain text + simple HTML, no emojis
- Asks for **all** missing fields in a single reply — never drip-feeds one question at a time
- Never invents values — anything the prospect did not supply is stored as `null`
- Off-topic or vague emails: gives a short summary of the consulting/training services and asks for the qualification fields
- Hostile / spam / abusive emails: marked as `red_flag`, no reply sent
- Prompt-injection attempts in the email body are ignored — the email is processed as suspicious content
- Inconsistencies (e.g. "500 employees" but the website is a one-pager) are noted in `verdict.reasoning` and the score is lowered
- Currency: extracts the numeric budget as-is; the €1000 floor is still applied and any currency ambiguity is noted in `reasoning`
- English-only for this demo; multilingual handling is a possible next step

## Key Files

| File | Purpose |
|---|---|
| `app/controllers/webhooks/mailtrap/inbound_controller.rb` | Inbound webhook endpoint — signature verify, auto-responder filter, dispatch |
| `app/controllers/leads_controller.rb` | Read-only `/leads` index and `/leads/:id` detail |
| `app/services/inbound/signature_verifier.rb` | Verifies `X-MT-Signature` via HMAC-SHA256 against `MAILTRAP_INBOUND_SECRET` |
| `app/services/inbound/auto_responder_filter.rb` | Skips `Auto-Submitted: auto-*`, `Precedence: bulk|list`, no-reply senders |
| `app/services/inbound/payload_normalizer.rb` | Extracts `thread_id`, sender, subject, and body text from the payload |
| `app/services/inbound/process_incoming_email.rb` | Main orchestrator — finds/creates lead, calls qualifier, follow-up vs verdict |
| `app/services/lead_qualifier.rb` | Anthropic call with strict system prompt, returns extracted fields + reply text |
| `app/services/website_analyzer.rb` | HTTParty fetch, Nokogiri parse, Claude legitimacy verdict |
| `app/services/verdict_router.rb` | Applies threshold rules; routes to red_flag / forwarded / qualified |
| `app/services/melissa_mailer.rb` | Sends Melissa's replies via the Mailtrap Email Sending API with thread headers |
| `app/services/hubspot_sync.rb` | Env-gated, fail-open push of qualified leads to HubSpot Contacts |
| `app/models/lead.rb` | Single leads table with `extracted_data` + `verdict` JSON columns |
| `app/views/leads/index.html.erb` | Table of every captured lead with tier, score, status |
| `app/views/leads/show.html.erb` | Extracted data, verdict, and reasoning for one lead |
| `db/migrate/*_create_leads.rb` | `leads` schema — `thread_id` unique, JSON columns for extracted data + verdict |
| `config/routes.rb` | Defines `/`, `/leads`, `/leads/:id`, `/webhooks/mailtrap/inbound` |

## Mailtrap Integration

**Inbound signature verification** — the webhook body is HMAC-SHA256'd with the shared secret and compared to the `X-MT-Signature` header:

```ruby
# app/services/inbound/signature_verifier.rb
def valid?
  return false if @signature_header.empty?
  return false if secret.blank?

  ActiveSupport::SecurityUtils.secure_compare(expected_signature, @signature_header)
end

def expected_signature
  OpenSSL::HMAC.hexdigest("SHA256", secret, @raw_body)
end
```

**Outbound reply with thread headers** — every reply carries `In-Reply-To`, `References`, and `X-Thread-Id` so the exchange threads for the prospect and in the Mailtrap dashboard:

```ruby
# app/services/melissa_mailer.rb
mail = Mailtrap::Mail::Base.new(
  from:    { email: ENV.fetch("MELISSA_EMAIL"), name: "Melissa" },
  to:      [{ email: @lead.sender_email, name: @lead.sender_name.presence || @lead.sender_email }],
  cc:      cc.map { |addr| { email: addr } },
  subject: subject,
  text:    text,
  html:    html,
  headers: {
    "In-Reply-To" => @lead.thread_id,
    "References"  => @lead.thread_id,
    "X-Thread-Id" => @lead.thread_id
  },
  category: "inbound-lead"
)

Mailtrap::Client.new(api_key: ENV.fetch("MAILTRAP_API_TOKEN")).send(mail)
```

## Running Tests

```bash
bundle exec rspec
```

Tests cover:

- `Lead` model — validations, `missing_required_fields`, `ready_for_final_verdict?`, tier/score helpers
- Inbound webhook — accepts a properly signed payload, rejects tampered / missing-signature payloads with HTTP 400, silently skips auto-responder + no-reply senders

## License

MIT License — see [LICENSE](LICENSE) for details.
