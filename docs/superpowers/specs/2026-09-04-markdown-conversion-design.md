# Markdown conversion via convert-markdown.ifad.org — Design Spec

Date: 2026-09-04. Status: reviewed (architect review), approved for v1 implementation.

## Goal

Crawled HTML pages and binary documents (PDF, DOCX, XLSX, PPTX) are stored in Elasticsearch with `body` holding Markdown produced by the shared IFAD service `convert-markdown.ifad.org`, so every IFAD app gets identical conversions. Plain-text extraction stays as the fallback path.

## Non-goals (v1)

- Local HTML→Markdown inside the crawler.
- Skip-unchanged re-crawl logic (needs bulk `update` op; phase 3).
- Separate conversion thread pool (phase 3, only if the service becomes highly parallel).
- Service-side changes (affinity routing, light/heavy executors, cache) — separate track in the `convert-markdown` repo.

## convert-markdown API contract (existing, do not change)

- `POST {base_url}/api/v1/convert/upload?wait=<0..60>` — multipart field `file`, filename MUST carry a supported extension (`.pdf .docx .xlsx .pptx .html .htm`), else HTTP 422. Legacy `.doc .xls .ppt` → 422.
- Response JSON (both 200 and 202): `{job_id, status: pending|processing|done|failed, status_url: "/api/v1/jobs/<id>", source_name, markdown?, chars?, pages?, tables?, error?}`. HTTP 200 when `status` is `done` or `failed` within `wait`; 202 otherwise. **Branch on `status`, not HTTP code.**
- `GET {base_url}{status_url}` — same JSON; 404 when the job is unknown/expired.
- `GET {base_url}/api/v1/health` — 200 when ready.
- Service is single-worker with an in-process job store; conversions are serialised. Envoy default per-route timeout may be 15s.

## Crawler-side design

### Insertion point

`Coordinator#process_crawl_result` (`lib/crawler/coordinator.rb`, the `elsif crawl_task.content?` branch, currently lines ~399-402). Conversion runs on the crawl-task thread, after the rule engine and BEFORE `output_crawl_result`. Rationale: `OutputSink::Elasticsearch#write` holds `@queue_lock` across `to_doc` → `DocumentMapper#create_doc`; a slow call there serialises all conversions and other threads get `SinkLockedError` (retry 1s × 120 then dropped). Target diff:

```ruby
elsif crawl_task.content?
  crawl_task_progress(crawl_task, 'converting to markdown')
  config.markdown_converter.convert!(crawl_result)
  crawl_task_progress(crawl_task, 'ingesting the result')
  outcome = output_crawl_result(crawl_result)
  extracted_event.merge!(outcome)
end
```

When disabled, `convert!` MUST return without touching the crawl result (coordinator specs use RSpec doubles that only respond to `url, canonical_link, extract_links, meta_nofollow?, error?, html?, redirect?`).

### Config (`lib/crawler/api/config.rb`)

New top-level key `markdown_conversion` (nested hash, like `elasticsearch`). Add to `CONFIG_FIELDS` and `DEFAULTS`; unknown keys are rejected by `validate_param_names!`.

```yaml
markdown_conversion:
  enabled: false
  base_url: https://convert-markdown.ifad.org   # required when enabled; http(s) only
  wait_seconds: 10        # 0..60, sent as ?wait=
  poll_interval: 2        # seconds between polls; back off ×1.5 up to 5s
  timeout: 900            # hard per-document deadline (submit+poll), seconds
  on_failure: text        # text | skip
  ca_file:                # optional PEM path for Net::HTTP#ca_file
```

Validation in a `configure_markdown_conversion!` step (pattern: `configure_extraction_rules!`): when enabled, `base_url` present and http/https; `on_failure` ∈ {text, skip}; `wait_seconds` 0..60; when enabled and output_sink is elasticsearch, `max_body_size < elasticsearch.bulk_api.max_size_bytes` (default 1 MB) or raise ArgumentError with a clear message. Expose `config.markdown_converter` memoised (`@markdown_converter ||= ::Crawler::MarkdownConverter.new(self)`) next to `document_mapper`.

Also add `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` to the commented example MIME list in `config/crawler.yml.example` and document the new block there.

### `Crawler::MarkdownConverter` (`lib/crawler/markdown_converter.rb`, new)

Public API:

- `initialize(config)`
- `enabled?` → bool
- `convertible?(crawl_result)` → bool: enabled AND (`crawl_result.html?` OR `crawl_result.content_extractable_file?` with a MIME in the map below).
- `convert!(crawl_result)` → `:converted | :skipped | :failed`. Never raises. Sets `crawl_result.markdown = String` on success, leaves it `nil` otherwise. Increments `stats[:converted]` / `stats[:failed]`.
- `stats` → `{ converted: Integer, failed: Integer }` (thread-safe: use `Concurrent::AtomicFixnum` or a Mutex).
- `healthy?` → bool (GET `/api/v1/health`, 5s timeout). Called once from `Crawler::API::Crawl#start!` when enabled; if false, raise so the crawl fails fast (a silent converter outage must not degrade the whole index to text).

MIME → extension map (strip `;charset=...` and downcase the content type first):

| MIME | ext |
|---|---|
| text/html | .html |
| application/pdf | .pdf |
| application/vnd.openxmlformats-officedocument.wordprocessingml.document | .docx |
| application/vnd.openxmlformats-officedocument.spreadsheetml.sheet | .xlsx |
| application/vnd.openxmlformats-officedocument.presentationml.presentation | .pptx |

Anything else (incl. `application/msword`, `application/vnd.ms-powerpoint`) → not convertible → `:skipped`, and the existing `_attachment` / Tika path handles it.

Upload filename: `"#{crawl_result.url_hash}#{ext}"`. Never use `ContentExtractableFile#file_name` (it is `File.basename(url)` and includes query strings / lacks extensions).

Payload:
- HTML: serialise from Jsoup, not raw bytes, so `exclude_tags` and `data-elastic-exclude/include` directives are honoured. Use `crawl_result.parsed_content_excluding_tags(config.exclude_tags)` (memoised, `lib/crawler/data/crawl_result/html.rb`), apply `Crawler::ContentEngine::Transformer.transform!` to its `body` (see `document_body` in html.rb for the existing sequence), set `doc.charset(java.nio.charset.StandardCharsets::UTF_8)` and upload `doc.outerHtml.to_java_bytes`. Do NOT mutate the memoised parsed document that link extraction uses — clone it first (`doc.clone`).
- Binary: `crawl_result.content` bytes as-is (`Success#content`).

Transport: Ruby `net/http` (NOT httpclient5 Java classes, NOT `java.net.http` — `bin/crawler` sets `https.protocols=SSLv3` JVM-wide which breaks JSSE clients; Net::HTTP goes through jruby-openssl and WebMock can stub it). Hand-built multipart body (boundary from `SecureRandom.hex`), `Content-Type: multipart/form-data; boundary=...`. `open_timeout` 10s, `read_timeout` = `wait_seconds + 20`. `use_ssl` when https; `ca_file` when configured. `User-Agent: "#{config.user_agent}"`.

Flow:
1. `POST /api/v1/convert/upload?wait=#{wait_seconds}`.
2. Parse JSON. If `status == done` → markdown. If `failed` → `:failed` (log `error`). If `pending`/`processing` → poll `GET base_url + status_url` every `poll_interval` (×1.5 backoff, cap 5s) until `done`/`failed` or the `timeout` deadline (measured from submit start) passes → `:failed`.
3. Retry ONCE (after 1s) on: connection error, `Net::OpenTimeout`/`Net::ReadTimeout`, HTTP 5xx, HTTP 404 on poll. Never retry HTTP 422, 4xx other than 404-on-poll, or `status: failed`.
4. Empty/blank markdown → `:failed`.
5. Apply `Crawler::ContentEngine::Utils.limit_bytesize(markdown, config.max_body_size)` before assigning.
6. Every failure: `system_logger.warn` with url, reason; never raise.

### `Crawler::Data::CrawlResult::Success`

Add `attr_accessor :markdown` (nil by default). Crawl results are created and consumed on one task thread; memoising here also means the `SinkLockedError` retry loop does not reconvert.

### `Crawler::DocumentMapper` (`lib/crawler/document_mapper.rb`)

- `html_fields`: `body: crawl_result.markdown || crawl_result.document_body(...)` (existing args), plus `body_format: crawl_result.markdown ? 'markdown' : 'text'`, `content_hash: Digest::SHA1.hexdigest(crawl_result.content)`.
- `binary_file_fields`: when `crawl_result.markdown` present → `body: markdown, body_format: 'markdown'`, and OMIT `_attachment`; otherwise unchanged (`_attachment` kept, `body_format: 'text'`). Always `content_hash: crawl_result.content_hash`.
- Add `body_format` and `content_hash` to `Constants::RESERVED_FIELD_NAMES` (`lib/constants.rb`) so extraction rules cannot clobber them.
- Existing spec expectations for docs without markdown must stay green except for the two added fields.

### `OutputSink::Elasticsearch` (`lib/crawler/output_sink/elasticsearch.rb`)

`pipeline_params`: when `config.markdown_conversion[:enabled]`, default `_reduce_whitespace` to `false` (the ingest pipeline does `\s+ → ' '` on `body`, destroying markdown). If the user explicitly sets `_reduce_whitespace: true` with markdown enabled, `system_logger.warn` and honour it. Keep `_extract_binary_content: true` (harmless without `_attachment`; enables the Tika fallback).

### `OutputSink::Console`

When `crawl_result.respond_to?(:markdown) && crawl_result.markdown`, print the markdown instead of refusing binary content / raw HTML. Two-line change; optional but cheap.

### Stats

`Crawler::API::Crawl#print_final_crawl_status` (or wherever ingestion stats are printed, `lib/crawler/api/crawl.rb` ~216-233): when enabled, also log `Markdown conversions: converted=N failed=N`.

### Docs

`docs/features/MARKDOWN_CONVERSION.md`: what it does, config block, fallback semantics (`text` vs `skip` and the purge interaction: with `purge_crawl_enabled: true`, a page whose conversion fails under `skip` is not re-indexed and is deleted by the purge because `last_crawled_at` is stale), throughput caveat (service serialises jobs; `threads_per_crawl` bounds in-flight conversions), replica-affinity caveat.

## Failure semantics summary

| Situation | on_failure: text | on_failure: skip |
|---|---|---|
| converter healthy, doc converts | body=markdown, body_format=markdown, no `_attachment` | same |
| unsupported MIME (legacy .doc) | body from Tika via `_attachment` (binary) / text (HTML) | same (not a failure) |
| converter error / timeout / `failed` job | HTML: body=text; binary: `_attachment` kept, body_format=text | doc not written; `sink.failure` outcome; warn |
| converter unreachable at crawl start | crawl aborts with clear error | same |

## Test strategy

- `spec/lib/crawler/markdown_converter_spec.rb` (WebMock; `spec_helper` already has `disable_net_connect!(allow_localhost: true)`): 200 inline done; 202 pending → poll → done; `failed`; 422; 5xx then retry succeeds; 5xx twice fails; `Net::ReadTimeout`; 404 on poll; overall deadline; MIME→filename incl. `; charset=utf-8` stripping; HTML payload has excluded tags removed and UTF-8 meta and original parsed doc untouched; binary payload byte-identical; disabled → no HTTP call and result untouched; multipart body shape (field `file`, filename, content-type); blank markdown → failed; `max_body_size` truncation; stats counters.
- `spec/lib/crawler/document_mapper_spec.rb`: HTML with/without markdown; binary with markdown has no `_attachment`; `body_format`, `content_hash` present.
- `spec/lib/crawler/coordinator_spec.rb`: converter invoked once before `sink.write` for content results; not for denied/redirect; disabled path leaves existing double-based specs green; `skip` policy returns failure outcome without writing.
- `spec/lib/crawler/output_sink/elasticsearch_spec.rb`: `_reduce_whitespace` default flips; explicit true warns.
- `spec/lib/crawler/api/config_spec.rb`: defaults, unknown key rejected, `base_url` required when enabled, `on_failure` enum, bulk-size validation.
- `spec/integration/markdown_conversion_spec.rb`: `FauxCrawl` site with an HTML page and a PDF, converter stubbed via WebMock at `http://converter.test`; assert file-sink docs have markdown bodies and `body_format`; second scenario with 5xx asserts text fallback.
- Tests run in Docker (no local JRuby): image `crawler-ci` built from `Dockerfile`; run `script/rspec <file>` inside a container with the repo mounted (see plan for exact command).

## Upstream hygiene

Fork `ifad/crawler`, branch `feature/markdown-conversion` off `upstream/1.0`. Keep the diff surgical: all logic in the new `markdown_converter.rb`; coordinator change is 3 lines. Conventional commits, small, one per task.
