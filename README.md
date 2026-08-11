# ruby-inbound-lead-capture

A Ruby on Rails demo that **captures inbound sales leads via [Mailtrap Inbound](https://mailtrap.io)**, qualifies them with an **AI agent (Anthropic Claude)** over a multi-turn email conversation, and pushes qualified contacts to **HubSpot**.

A prospect emails your sales address → Mailtrap posts a signed webhook event to this app → the app fetches the message from Mailtrap's Inbound API, asks Claude ("Melissa") to extract the qualification fields, asks for anything missing on the same thread via Mailtrap's reply endpoint, analyses the prospect's website, and either replies with a scheduling link (qualified), hands the lead off to a partner (below thresholds), or silently red-flags it (suspicious).

## How it works

1. A prospect sends an email to your inbound address (e.g. `sales@yourdomain.com`).
2. Mailtrap parses the message and POSTs a webhook **envelope** to `POST /webhooks/mailtrap/inbound`. The envelope carries one or more events; each `inbound.message_received` event contains just `event_id`, `inbox_id`, and `message_id` — not the email body.
3. The webhook is verified with `HMAC-SHA256(MAILTRAP_INBOUND_SECRET, raw_body)`, compared against the `Mailtrap-Signature` header via the `mailtrap` gem's `Mailtrap::Webhooks.verify_signature` helper.
4. Each verified event is persisted to `inbound_events` (unique indexes on `event_id` and `message_id`) and enqueued for background processing. The controller returns `200` immediately — the AI + website work runs off the request thread.
5. `ProcessInboundEventJob` fetches the full message from Mailtrap's Inbound API (`GET /api/inbound/inboxes/:inbox_id/messages/:message_id`).
6. Auto-responders, bounces, and no-reply senders are filtered and skipped.
7. Claude extracts `company`, `website`, `employees`, `budget_eur`, `budget_currency`, `hours`.
8. If any required field is missing, **Melissa** replies asking for all missing fields at once. The reply text is rendered from ERB partials with default Rails escaping — the LLM only supplies plain-text paragraphs. The reply goes through Mailtrap's `POST /api/inbound/inboxes/:inbox_id/messages/:message_id/reply` endpoint, so Mailtrap sets the threading headers itself.
9. `ai_reply_count` is incremented only after a successful send. A failed reply is recorded on `last_reply_status` / `last_reply_error` and the lead is not finalized.
10. The conversation caps at **5 AI replies per thread**. After the cap, the AI proceeds with partial data and marks `data_completeness: minimal`.
11. Once all required fields are present (or the cap is reached), `WebsiteAnalyzer` fetches the website through the SSRF-hardened `Inbound::SafeHttpFetcher`, and `FinalVerdict` asks Claude for a structured verdict (legitimacy, score, inconsistencies, next steps) using the extracted lead data, the website snapshot, and the earlier qualification reasoning as context.
12. The lead is routed to one of three outcomes:
    - **red_flag** — missing website OR the final verdict judges the site suspicious → no reply, saved with `tier: red_flag`.
    - **forwarded** — below any threshold (`< 20 employees` OR `< €1000` budget OR `< 20 hours`) → reply with a partner handoff (CC `PARTNER_EMAIL`).
    - **qualified** — passes all thresholds → reply with a call-scheduling link, pushed to HubSpot as a Contact when `HUBSPOT_API_KEY` is set.

## Features

- `POST /webhooks/mailtrap/inbound` handler with `Mailtrap-Signature` HMAC verification — tampered payloads are rejected with HTTP 400.
- Envelope-driven flow — the webhook carries only `inbox_id` / `message_id`; the full message is fetched from the Inbound API on demand.
- **Background processing** — every valid event is persisted to `inbound_events` and enqueued as a job. The webhook returns 200 immediately and the AI / website work runs off the request thread with retries on transient failures.
- **Strong idempotency** — `inbound_events` has unique indexes on `event_id` and `message_id`, so a redelivered webhook (or an out-of-order duplicate arriving under a different event_id) collapses to a no-op instead of a second AI call and reply.
- Auto-responder loop prevention — filters `Auto-Submitted: auto-*`, `Precedence: bulk|list|junk`, `X-Autoreply`/`X-Autorespond`, and known no-reply senders (`mailer-daemon@`, `postmaster@`, `*-noreply@`, `no-reply@`, `bounces@`, `daemon@`).
- **Multi-turn conversation via the Inbound reply endpoint** — every follow-up is sent as a reply on the original message, so Mailtrap handles threading; no manual `In-Reply-To`/`References` headers.
- **SSRF-hardened website fetch** — `Inbound::SafeHttpFetcher` rejects non-HTTP schemes, resolves the host and blocks loopback / private / link-local / multicast / reserved IP ranges (both IPv4 and IPv6-mapped v4), revalidates on every redirect, caps hops and response size, and enforces a 5s timeout.
- **Structured final verdict** — `FinalVerdict` sees the extracted lead data, the website snapshot, and the earlier qualification reasoning, and returns a verdict with `legitimate`, `score`, `reasoning`, `inconsistencies[]`, and `next_steps[]`.
- Three-branch routing — `red_flag` / `forwarded` / `qualified` with configurable thresholds.
- **Reply-status tracking** — `ai_reply_count` and terminal statuses are only advanced after a successful send; failures are recorded on `last_reply_status` / `last_reply_error`.
- **Rails-owned reply HTML** — Claude returns plain-text paragraphs; HTML is rendered from ERB partials in `app/views/melissa/` with default escaping.
- HubSpot Contact push — env-gated on `HUBSPOT_API_KEY`, fail-open (a CRM error never blocks the reply).
- Prompt-injection defense — the system prompt instructs Claude to ignore in-body instructions.
- **Only extracted data is stored** — the raw email body is used for qualification and discarded; the `leads` table holds only structured fields, the AI verdict, and a HubSpot contact ID.
- Read-only `/leads` UI listing every captured lead with tier, score, and verdict reasoning.
- Graceful degradation — LLM down → generic acknowledgement reply (`tier: cold`); HubSpot down → lead still saved + replied, error logged.
- **CI** — GitHub Actions runs RSpec, RuboCop, and Brakeman on every push and pull request.

## Architecture

```
Prospect email ─► sales@yourdomain.com ─► Mailtrap Inbound
                                                │
                                                ▼ POST envelope (events[])
                                                  + Mailtrap-Signature header
Webhooks::Mailtrap::InboundController
        │
        ├── Inbound::SignatureVerifier            (reject on tamper)
        ├── Inbound::EventParser                  (extract inbound.message_received events)
        │
        ▼
InboundEvent.create!(event_id UNIQUE, message_id UNIQUE)
        │
        └── ProcessInboundEventJob.perform_later
                │
                ▼
        Inbound::ApiClient#fetch_message          (GET /inboxes/:inbox_id/messages/:message_id)
        Inbound::MessageNormalizer                (thread_id, sender, subject, body, headers)
        Inbound::AutoResponderFilter              (skip bounces / no-reply)
                │
                ▼
        Inbound::ProcessIncomingEmail
                │
                ├── LeadQualifier ─► Anthropic Claude
                │                    { extracted_data, reply_paragraphs, hostile? }
                │
                ├── if ready?  ─► VerdictRouter
                │                     │
                │                     ├── WebsiteAnalyzer ─► Inbound::SafeHttpFetcher + Nokogiri
                │                     ├── FinalVerdict    ─► Claude (extracted data + snapshot +
                │                     │                        earlier reasoning → structured verdict)
                │                     │
                │                     ├── red_flag   ─► save, no reply
                │                     ├── forwarded  ─► MelissaMailer (CC partner)
                │                     └── qualified  ─► MelissaMailer (scheduling link)
                │                                       └─► HubspotSync (if API key set)
                │
                └── else       ─► MelissaMailer (ask for missing fields, same thread)

MelissaMailer ─► ApplicationController.render(app/views/melissa/*.erb)
             ─► Inbound::ApiClient#reply           (POST /inboxes/:inbox_id/messages/:message_id/reply)
                                                     (Mailtrap sets In-Reply-To / References itself)
             ─► Result(status: :sent|:failed)      (caller gates ai_reply_count + finalize on :sent)
```

## Requirements

- Ruby 3.3.6
- Rails 7.2
- SQLite3
- A [Mailtrap](https://mailtrap.io) account with an Inbound inbox and an API token
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

1. Sign in to [Mailtrap](https://mailtrap.io) → **Email Testing** → **Inboxes** (or **Inbound** on paid plans) and open (or create) an inbound inbox.
2. Under the inbox's **Webhook** settings, set the URL to your public endpoint: `https://your-domain.com/webhooks/mailtrap/inbound`.
3. Copy the webhook's **signing secret** into `.env` as `MAILTRAP_INBOUND_SECRET`. Mailtrap signs each delivery with HMAC-SHA256 and sends the digest in the `Mailtrap-Signature` header.
4. Under **Settings → API Tokens**, create a token with the **Admin** scope. Put it into `.env` as `MAILTRAP_API_TOKEN`. The same token is used to fetch inbound messages and to send Melissa's replies.
5. Send a test email to the inbox address.

> **Reply-cap caveat:** Mailtrap-hosted inbound addresses are ideal for testing the receive side, but for the full multi-turn conversation to work (Melissa's replies coming back into the same thread), you need your own domain with an MX record pointing at Mailtrap — see below.

### Production setup with your own domain

1. Go to **Inbound → Add Domain** in Mailtrap and follow the DNS setup instructions (MX record).
2. Configure an inbound address (e.g. `sales@yourdomain.com`) so incoming email is forwarded to Mailtrap.
3. Update `MAILTRAP_INBOUND_SECRET` in `.env` with the webhook secret for the domain's inbound inbox.
4. Update `INBOUND_EMAIL` in `.env` to match the address you configured.

### Mailtrap Threads (how replies stay on the same conversation)

The app does **not** compose fresh outbound emails and it does **not** set `In-Reply-To` / `References` by hand. Instead, every follow-up is sent through Mailtrap's Inbound reply endpoint:

```
POST /api/inbound/inboxes/:inbox_id/messages/:message_id/reply
```

Mailtrap looks up the original message, addresses the reply to its sender, and sets the threading headers itself. That keeps the exchange grouped as one conversation both in the prospect's email client and in the Mailtrap dashboard.

For Mailtrap-hosted (test) inboxes, the reply is always sent from the inbox's own address and `from` is rejected by the API — `MELISSA_EMAIL` should be left blank. For a custom domain, set `MELISSA_EMAIL` to a sender on that domain.

### HubSpot Free setup (optional)

1. Sign up at [hubspot.com](https://hubspot.com) — the free CRM tier is enough.
2. Go to **Settings → Integrations → Private Apps** and create a new app.
3. Grant the scope: `crm.objects.contacts.write`.
4. Copy the generated token into `HUBSPOT_API_KEY` in `.env`.

Qualified leads are pushed as HubSpot Contacts. If the key is unset the sync is skipped silently; if the API call fails the lead is still saved locally and the reply is still sent (fail-open).

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `MAILTRAP_API_TOKEN` | yes | — | Mailtrap API token (Admin scope). Used for **both** fetching inbound messages and sending Melissa's replies. |
| `MAILTRAP_INBOUND_SECRET` | yes | — | Signing secret from the inbox's webhook settings. Used to verify `Mailtrap-Signature`. |
| `ANTHROPIC_API_KEY` | yes | — | Anthropic API key from [console.anthropic.com](https://console.anthropic.com). |
| `ANTHROPIC_MODEL` | no | `claude-haiku-4-5-20251001` | Model used for qualification and website analysis. |
| `INBOUND_EMAIL` | no | `sales@example.com` | The address prospects send lead email to (documentation-only; the actual routing is configured in Mailtrap). |
| `MELISSA_EMAIL` | no | *(unset)* | Sender for Melissa's replies. Leave blank for Mailtrap-hosted inboxes; set for a custom-domain inbox. |
| `PARTNER_EMAIL` | no | `partner@example.com` | Partner sales address CC'd on the `forwarded` reply. |
| `SCHEDULING_LINK` | no | `https://example.com/schedule` | URL included in the reply to qualified leads. |
| `MIN_EMPLOYEES` | no | `20` | Employees threshold for the qualified branch. |
| `MIN_BUDGET_EUR` | no | `1000` | Budget threshold (in EUR) for the qualified branch. |
| `MIN_HOURS` | no | `20` | Requested-hours threshold for the qualified branch. |
| `HUBSPOT_API_KEY` | no | *(unset)* | HubSpot Private App token. Leave blank to disable HubSpot sync. |

## Inbound Flow

1. Prospect emails `INBOUND_EMAIL` (e.g. `sales@yourdomain.com`).
2. Mailtrap parses the message and POSTs a webhook envelope to `/webhooks/mailtrap/inbound` with the `Mailtrap-Signature` header. The envelope shape is:
   ```json
   {
     "events": [
       {
         "event": "inbound.message_received",
         "event_id": "…",
         "timestamp": 1785398058498,
         "inbox_id": 695,
         "message_id": "1872125554587900000",
         "from": "Sam Prospect <sam@acme.co>"
       }
     ]
   }
   ```
3. `Webhooks::Mailtrap::InboundController` verifies the signature; tampered payloads return HTTP 400. Non-JSON returns HTTP 400. All other envelopes return HTTP 200 so Mailtrap does not retry.
4. `Inbound::EventParser` picks out `inbound.message_received` events.
5. For each event, an `InboundEvent` row is inserted with the `event_id` and `message_id`. Unique indexes on both columns make redelivery a no-op at the database. A `ProcessInboundEventJob` is enqueued and the controller returns 200.
6. The job calls `Inbound::ApiClient#fetch_message` (`GET /api/inbound/inboxes/:inbox_id/messages/:message_id`) to get the full parsed message. Transient failures are retried with polynomial backoff; on failure the `InboundEvent` is marked `failed` and the error is recorded.
7. `Inbound::MessageNormalizer` extracts `thread_id`, sender email + name, subject, body text (HTML is stripped as a fallback), and a lowercased header map.
8. `Inbound::AutoResponderFilter` skips bounces, vacation replies, and known no-reply senders — the event is marked `skipped` and no reply is sent.
9. `Inbound::ProcessIncomingEmail` looks up (or creates) a `Lead` keyed by `thread_id`.
10. `LeadQualifier` sends the incoming body + previously-extracted data to Claude with a strict system prompt (no hallucination, ask-for-all-missing-in-one-reply, prompt-injection defense). Claude returns extracted data + `reply_paragraphs` (plain text) + `hostile` / `off_topic` flags + `reasoning`.
11. Fields already present are preserved; newly-supplied fields are merged.
12. If the lead is ready (all required fields OR five AI replies sent):
    - `WebsiteAnalyzer` fetches the URL through `Inbound::SafeHttpFetcher` (SSRF-hardened) and returns a snapshot (title, description, body sample).
    - `FinalVerdict` sends the snapshot + extracted data + earlier reasoning to Claude and returns `{ legitimate, score, reasoning, inconsistencies[], next_steps[] }`.
    - `VerdictRouter` decides `red_flag` / `forwarded` / `qualified`, calls `MelissaMailer` (except on `red_flag`), and only flips the lead to `finalized` when the reply actually landed.
    - Qualified leads are pushed to HubSpot after a successful reply, when `HUBSPOT_API_KEY` is set.
13. Otherwise `MelissaMailer` sends a follow-up asking for the missing fields, on the same Mailtrap thread. `ai_reply_count` advances only on a successful send; a failed send is recorded on `last_reply_status` / `last_reply_error`.

## Melissa (AI agent) behaviour

- Signs every reply as "Melissa", 3–5 sentences, friendly-professional, plain text + simple HTML, no emojis.
- Asks for **all** missing fields in a single reply — never drip-feeds one question at a time.
- Never invents values — anything the prospect did not supply is stored as `null`.
- Off-topic or vague emails: gives a short summary of the consulting/training services and asks for the qualification fields.
- Hostile / spam / abusive emails: marked as `red_flag`, no reply sent.
- Prompt-injection attempts in the email body are ignored — the email is processed as suspicious content.
- Inconsistencies (e.g. "500 employees" but the website is a one-pager) are noted in `verdict.reasoning` and the score is lowered.
- Currency: extracts the numeric budget as-is and records `budget_currency` separately; the €1000 floor is still applied and any currency ambiguity is noted in `reasoning`.
- English-only for this demo; multilingual handling is a possible next step.

## Key Files

| File | Purpose |
|---|---|
| `app/controllers/webhooks/mailtrap/inbound_controller.rb` | Inbound webhook endpoint — signature verify, persist `InboundEvent`, enqueue job. |
| `app/controllers/leads_controller.rb` | Read-only `/leads` index and `/leads/:id` detail. |
| `app/jobs/process_inbound_event_job.rb` | Background job — fetches the message, filters auto-responders, runs the pipeline. |
| `app/services/inbound/signature_verifier.rb` | Verifies `Mailtrap-Signature` via `Mailtrap::Webhooks.verify_signature` against `MAILTRAP_INBOUND_SECRET`. |
| `app/services/inbound/event_parser.rb` | Extracts `inbound.message_received` events from the webhook envelope. |
| `app/services/inbound/api_client.rb` | Thin wrapper over the Mailtrap Inbound API — `fetch_message` and `reply`. |
| `app/services/inbound/message_normalizer.rb` | Turns a fetched message into `thread_id`, sender, subject, body, headers. |
| `app/services/inbound/auto_responder_filter.rb` | Skips `Auto-Submitted: auto-*`, `Precedence: bulk|list|junk`, no-reply senders. |
| `app/services/inbound/safe_http_fetcher.rb` | SSRF-hardened HTTP fetch — scheme allowlist, IP validation, redirect cap, size cap. |
| `app/services/inbound/process_incoming_email.rb` | Main orchestrator — finds/creates lead, calls qualifier, follow-up vs verdict. |
| `app/services/lead_qualifier.rb` | Anthropic call with strict system prompt, returns extracted fields + reply paragraphs. |
| `app/services/website_analyzer.rb` | Safe fetch + Nokogiri parse → `Snapshot(url, title, description, body)`. |
| `app/services/final_verdict.rb` | Anthropic call with extracted data + snapshot + prior reasoning → structured verdict. |
| `app/services/verdict_router.rb` | Applies threshold rules; routes to red_flag / forwarded / qualified. |
| `app/services/melissa_mailer.rb` | Renders ERB partials, sends Melissa's replies through Mailtrap's `/reply` endpoint, reports `:sent` / `:failed`. |
| `app/services/hubspot_sync.rb` | Env-gated, fail-open push of qualified leads to HubSpot Contacts. |
| `app/models/lead.rb` | `leads` table with `extracted_data` + `verdict` JSON columns and reply-status tracking. |
| `app/models/inbound_event.rb` | Idempotency ledger — unique `event_id` and `message_id`, status + last_error. |
| `app/views/melissa/*.erb` | Follow-up / qualified / forwarded reply bodies (HTML + text). |
| `app/views/leads/*.erb` | Read-only leads UI. |
| `db/migrate/*_create_leads.rb` | `leads` schema — `thread_id` unique, JSON columns for extracted data + verdict. |
| `db/migrate/*_add_inbound_message_tracking_to_leads.rb` | Adds `inbox_id` and `last_message_id` to `leads` for API fetch + reply. |
| `db/migrate/*_create_inbound_events.rb` | Idempotency table with unique indexes on `event_id` and `message_id`. |
| `db/migrate/*_add_reply_status_to_leads.rb` | Adds `last_reply_status` and `last_reply_error` for per-reply outcome tracking. |
| `.github/workflows/ci.yml` | GitHub Actions — RSpec, RuboCop, Brakeman. |
| `config/routes.rb` | Defines `/`, `/leads`, `/leads/:id`, `/webhooks/mailtrap/inbound`. |

## Mailtrap Integration

**Inbound signature verification** — the raw request body is HMAC-SHA256'd with the shared secret and compared to the `Mailtrap-Signature` header. Verification is delegated to the `mailtrap` gem's helper, which compares in constant time:

```ruby
# app/services/inbound/signature_verifier.rb
def valid?
  Mailtrap::Webhooks.verify_signature(
    payload:        @raw_body,
    signature:      @signature_header,
    signing_secret: secret
  )
end
```

The raw body must be passed through untouched: parsing and re-serialising the JSON can reorder keys and invalidate the signature.

**Message fetch** — the webhook envelope carries only `inbox_id` and `message_id`; the full message is fetched from the Inbound API:

```ruby
# app/services/inbound/api_client.rb
def fetch_message(inbox_id:, message_id:)
  request(:get, "/#{inbox_id}/messages/#{message_id}")
end
```

**Threaded reply** — replies go back through the Inbound reply endpoint. Mailtrap addresses the response to the original sender and sets the threading headers itself, so there is no need to track `In-Reply-To` / `References` by hand:

```ruby
# app/services/inbound/api_client.rb
def reply(inbox_id:, message_id:, text:, html:, cc: [], from: nil, category: nil)
  body = { text: text, html: html }
  body[:from]     = { email: from, name: "Melissa" } if from.present?
  body[:cc]       = Array(cc).map { |address| { email: address } } if Array(cc).any?
  body[:category] = category if category.present?

  request(:post, "/#{inbox_id}/messages/#{message_id}/reply", body)
end
```

## Running Tests

```bash
bundle exec rspec
```

Tests cover:

- `Lead` and `InboundEvent` models — validations, uniqueness, helpers.
- Inbound webhook — signature verification, envelope parsing, `InboundEvent` persistence and job enqueue, idempotency on redelivery / message-id collision.
- `ProcessInboundEventJob` — fetch, filter, dispatch, retry-on / discard behavior, event status transitions.
- `Inbound::` service objects — `EventParser`, `SignatureVerifier`, `MessageNormalizer`, `AutoResponderFilter`, `ApiClient`, `ProcessIncomingEmail`, `SafeHttpFetcher` (SSRF blocklist, redirect revalidation, size cap).
- Domain services — `LeadQualifier`, `WebsiteAnalyzer`, `FinalVerdict`, `VerdictRouter`, `MelissaMailer` (partial rendering + reply-status), `HubspotSync`.

## Continuous Integration

`.github/workflows/ci.yml` runs three jobs on every push and pull request:

- **RSpec** — the full test suite against Ruby 3.3.6.
- **RuboCop** — `rubocop-rails-omakase` ruleset.
- **Brakeman** — static security scan; the job fails on any warning.

Bundler is cached per-workflow. Dummy env vars are provided for `RAILS_ENV=test`.

## Limitations

- **`/leads` is unauthenticated.** Anyone who can reach the app can list every captured lead. Add HTTP basic auth (or an equivalent access control layer) before exposing the app publicly. This is left to the deployer intentionally — the app has no notion of admin users, and adding one would push the demo well past its intended scope.

## License

MIT License — see [LICENSE](LICENSE) for details.
