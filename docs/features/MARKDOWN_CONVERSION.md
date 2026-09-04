# Markdown Conversion

The crawler can send every crawled HTML page and supported binary document (PDF, DOCX, XLSX, PPTX) to the shared
IFAD `convert-markdown` service and index the returned Markdown in the `body` field. Every IFAD application then
gets identical conversions, and Markdown keeps headings, lists and tables that plain-text extraction flattens.

Plain-text extraction remains the fallback: if a document cannot be converted, the crawler indexes what it
would have indexed before this feature existed.

## Using this feature

1. Make sure the converter is reachable from the crawler (`GET {base_url}/api/v1/health` must answer 200).
2. Enable the feature in the crawler configuration:

```yaml
markdown_conversion:
  enabled: true
  base_url: https://convert-markdown.ifad.org
  wait_seconds: 10
  poll_interval: 2
  timeout: 900
  on_failure: text
  # ca_file: /etc/ssl/certs/ifad-ca.pem

# Binary files are only downloaded when binary content extraction is on
binary_content_extraction_enabled: true
binary_content_extraction_mime_types:
  - application/pdf
  - application/vnd.openxmlformats-officedocument.wordprocessingml.document
  - application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  - application/vnd.openxmlformats-officedocument.presentationml.presentation

# Required with the elasticsearch sink: a markdown body must fit into one bulk request
max_body_size: 900_000
```

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Turn the feature on. |
| `base_url` | – | Converter base URL, `http` or `https`. Required when enabled. |
| `wait_seconds` | `10` | Sent as `?wait=` on upload (0..60). The service answers inline when the job finishes within this window. |
| `poll_interval` | `2` | Seconds between status polls; backs off ×1.5 per poll, capped at 5 s. |
| `timeout` | `900` | Hard per-document deadline in seconds (upload + polling). |
| `on_failure` | `text` | `text`: index the plain-text fallback. `skip`: do not index the document at all. |
| `ca_file` | – | PEM bundle to verify the converter's certificate (passed to `Net::HTTP#ca_file`). |

At crawl start the crawler calls the health endpoint once (twice if the first call fails: the check is retried
once after a second). If it still does not answer 200 the crawl aborts with
`Markdown converter at <base_url> is not healthy ...` instead of silently indexing the whole site as plain text.
This applies to both `bin/crawler crawl` and `bin/crawler urltest`, so a URL test never reports a plain-text
body while pretending the converter was consulted.

## What gets indexed

| Document | Converted | Not converted (fallback) |
|---|---|---|
| HTML page | `body`: Markdown, `body_format: markdown` | `body`: extracted text, `body_format: text` |
| PDF / DOCX / XLSX / PPTX | `body`: Markdown, `body_format: markdown`, no `_attachment` | `_attachment` kept (Tika via the ingest pipeline), `body_format: text` |
| Other binary types (e.g. legacy `.doc`, `.ppt`) | never sent to the converter | unchanged behaviour |

Every document also gets `content_hash` (SHA-1 of the fetched bytes). `body_format` and `content_hash` are
reserved field names and cannot be overwritten by extraction rules.

### What changes even when the feature is disabled

Two fields are added to every indexed document regardless of `markdown_conversion.enabled`, for HTML pages and
binary documents alike:

- `body_format` — `text` while the feature is off (and for any document that was not converted).
- `content_hash` — SHA-1 of the fetched bytes.

Both names are reserved for extraction rules in every crawl, enabled or not. This is deliberate: the fields are
written unconditionally so the shape of an index never depends on whether the converter happened to be on, and
so a later re-crawl can compare `content_hash` and skip content that has not changed. Turning the feature on
later therefore does not require a mapping change or a full re-index to make the fields appear.

HTML is uploaded after the crawler's own pre-processing, so `exclude_tags` and the
`data-elastic-exclude` / `data-elastic-include` directives are honoured in the Markdown as well.

With the Elasticsearch sink, the ingest pipeline parameter `_reduce_whitespace` defaults to `false` while this
feature is enabled, because the default pipeline collapses all whitespace in `body` and would destroy the
Markdown structure. Setting it to `true` explicitly is honoured but logs a warning.

## Failure semantics

| Situation | `on_failure: text` | `on_failure: skip` |
|---|---|---|
| Converter healthy, document converts | Markdown body | Markdown body |
| Unsupported MIME type | fallback (not counted as a failure) | fallback (not counted as a failure) |
| Converter error, timeout, or `status: failed` | fallback body, `body_format: text`, warning in the system log | document not written, `url-extracted` event with `outcome: failure`, warning in the system log |
| Converter unreachable at crawl start | crawl aborts | crawl aborts |

Transient errors (connection errors, timeouts, HTTP 5xx, HTTP 404 while polling an expired job) are retried
once after one second. HTTP 422 (unsupported file), other 4xx responses and `status: failed` are not retried.
The retry itself is announced at `debug` level; only the final failure of a document is logged as a warning,
so one line per failed document reaches a normally configured log.

The system log ends with `Markdown conversions: converted=N failed=N` (also on a resumable shutdown; a crawl
that aborted on the start-up health check prints nothing, since it converted nothing).

### Circuit breaker

The converter can go down mid-crawl. Without a circuit breaker every remaining document would still pay for a
full upload, a retry and possibly the `timeout` deadline before falling back. After **20 consecutive failures**
the crawler opens a circuit breaker, logs

```
Markdown converter circuit breaker opened after 20 consecutive failures; skipping conversions for 60s
```

once, and for the next **60 seconds** `convert!` returns a failure immediately without any HTTP call. Failure
handling is unchanged in that state: with `on_failure: text` the documents get their plain-text bodies and
`body_format: text`, with `on_failure: skip` they are not indexed at all — and they are counted in the `failed`
total of the final stats line. After the cooldown the next document to be converted triggers a single health
check (one thread probes, the others keep short-circuiting): if it passes, the breaker closes with an `info`
line and normal conversion resumes; if it fails, the cooldown is re-armed for another 60 seconds. A single
successful conversion also resets the consecutive-failure counter, so isolated failures never open the breaker.
There is no configuration for this; a crawl that starts against a healthy converter degrades to plain text
rather than stalling.

### `skip` and purge crawls

With `purge_crawl_enabled: true` (the default) the purge stage deletes every document whose `last_crawled_at`
is older than the crawl start. A page whose conversion failed under `on_failure: skip` is not re-indexed, so its
`last_crawled_at` stays stale and the purge crawl deletes it from the index. Use `skip` only when a missing
document is preferable to a plain-text one.

## Throughput and deployment caveats

- The converter is single-worker with an in-process job store: conversions are serialised. Each crawl thread
  waits for its own document, so `threads_per_crawl` bounds the number of in-flight conversions; large PDFs
  block one crawl thread for the whole conversion (up to `timeout`).
- Because the job store is in-process, polling must reach the same replica that accepted the upload. Behind a
  load balancer without session affinity, polls can hit another replica and answer 404; the crawler resubmits
  once, then falls back. Run a single replica or enable affinity routing.
- The service front-end may enforce its own per-request timeout (Envoy defaults to 15 s); keep `wait_seconds`
  below it so long conversions go through the polling path instead of failing at the proxy.
- A conversion in progress ignores a crawl shutdown request: the task thread finishes (or times out) its
  current upload/poll cycle first, so a slow job can hold a task thread for up to `timeout` seconds.
- A converter that dies mid-crawl does not slow the crawl down for long: after 20 consecutive failures the
  circuit breaker (see [Circuit breaker](#circuit-breaker)) short-circuits conversions for 60 seconds at a time.
- Converter calls go straight to `base_url`: they use neither the crawler's `http_proxy_*` settings nor the
  `HTTP_PROXY`/`HTTPS_PROXY` environment variables.
