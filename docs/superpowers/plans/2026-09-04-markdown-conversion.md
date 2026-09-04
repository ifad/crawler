# Markdown Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Crawled HTML pages and PDF/DOCX/XLSX/PPTX files are stored with `body` holding Markdown produced by the shared `convert-markdown.ifad.org` service, with plain-text extraction as the fallback.

**Architecture:** A new `Crawler::MarkdownConverter` (config-driven, `net/http` transport, WebMock-testable) is called from `Coordinator#process_crawl_result` on the crawl-task thread, after the rule engine and before the output sink. It sets `crawl_result.markdown`; `DocumentMapper` prefers that over text/`_attachment` and adds `body_format` + `content_hash`. The Elasticsearch sink stops collapsing whitespace when markdown is enabled, and `Crawl#start!` fails fast if the converter is unhealthy.

**Tech Stack:** JRuby 9.4, Ruby `net/http` (through jruby-openssl), Jsoup 1.23.2 (`org.jsoup`), `concurrent-ruby` (`Concurrent::AtomicFixnum`), RSpec + FactoryBot + WebMock, Faux test sites, rubocop (line length 120, `Metrics/MethodLength` 15, `Metrics/AbcSize` 20, `Metrics/CyclomaticComplexity` 8, `Metrics/ClassLength` 200).

**Spec:** `docs/superpowers/specs/2026-09-04-markdown-conversion-design.md`

## Global Constraints

- Branch `feature/markdown-conversion` off `upstream/1.0`; conventional commits, one per task, prefixes `feat(markdown):`, `test(markdown):`, `docs(markdown):`. Do not commit anything else.
- All logic lives in the new `lib/crawler/markdown_converter.rb`; the coordinator change stays minimal (one call site plus one small helper).
- `convert!` never raises. When disabled it MUST return without calling any method on the crawl result (coordinator specs use strict RSpec doubles that only respond to `url, canonical_link, extract_links, meta_nofollow?, error?, html?, redirect?`).
- Transport is Ruby `net/http` only. NOT httpclient5 Java classes, NOT `java.net.http` (`bin/crawler` sets `https.protocols=SSLv3` JVM-wide, which breaks JSSE clients). Multipart bodies are hand-built, binary-encoded (`ASCII-8BIT`), `Content-Length` set by Net::HTTP from `body.bytesize`.
- Converter API contract (do not change): `POST {base_url}/api/v1/convert/upload?wait=<0..60>` multipart field `file` with a filename carrying `.pdf .docx .xlsx .pptx .html .htm`; JSON `{job_id, status: pending|processing|done|failed, status_url, markdown?, error?}`; branch on `status`, not HTTP code; `GET {base_url}{status_url}`; `GET {base_url}/api/v1/health`.
- Retry ONCE (after 1 s) on connection errors, `Net::OpenTimeout`/`Net::ReadTimeout`, HTTP 5xx, HTTP 404 while polling. Never retry HTTP 422, other 4xx, or `status: failed`.
- Poll `poll_interval` seconds, backoff ×1.5, cap 5 s; hard `timeout` deadline measured from submit start.
- `open_timeout` 10 s, `read_timeout` = `wait_seconds + 20`, health check 5 s, `User-Agent: config.user_agent` on every request (health check included), `use_ssl` for https, `ca_file` when configured, `Net::HTTP.new(host, port, nil)` so env `HTTP_PROXY`/`HTTPS_PROXY` are ignored.
- Every file starts with the Elastic license header comment and `# frozen_string_literal: true` (copy from any existing `lib/` file).
- Tests run in Docker (no local JRuby, ~10 s overhead per run). The image is `crawler-dev`: build `crawler-ci` from the repo `Dockerfile`, then layer `bundle config unset without && bundle install` on top of it and tag the result `crawler-dev`. **Test command** (run from the repo root; every task's Run step refers to this):

  ```bash
  docker run --rm --user root -v "$PWD:/home/app" -w /home/app -e HOME=/home/app -e IS_DOCKER=1 crawler-dev \
    -c "bundle config unset without >/dev/null; JRUBY_OPTS=--debug bundle exec rspec <files>"
  # lint: same, with `bundle exec rubocop <files>` instead of the rspec command
  ```

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/crawler/api/config.rb` (modify) | `markdown_conversion` nested config: field, nested defaults, validation, `config.markdown_converter` factory |
| `lib/crawler/markdown_converter.rb` (create) | Everything conversion-related: enablement, MIME map, filename, payload builders, multipart transport, polling, retry, health check, stats |
| `lib/crawler/data/crawl_result/success.rb` (modify) | `attr_accessor :markdown` |
| `lib/constants.rb` (modify) | reserve `body_format`, `content_hash` |
| `lib/crawler/coordinator.rb` (modify) | call converter before the sink; `on_failure: skip` outcome |
| `lib/crawler/api/crawl.rb` (modify) | health check at crawl start; conversion stats log line |
| `lib/errors.rb` (modify) | `Errors::MarkdownConverterUnavailableError` |
| `lib/crawler/document_mapper.rb` (modify) | `body`/`body_format`/`content_hash`; omit `_attachment` when markdown present |
| `lib/crawler/output_sink/elasticsearch.rb` (modify) | `_reduce_whitespace` default flips to `false` when markdown enabled; warn when explicitly `true` |
| `lib/crawler/output_sink/console.rb` (modify) | print markdown when present |
| `spec/support/faux/faux_crawl.rb` (modify) | pass `markdown_conversion:` option through to the crawl config |
| `config/crawler.yml.example`, `docs/features/MARKDOWN_CONVERSION.md`, `README.md` (modify/create) | documentation |

Specs: `spec/lib/crawler/api/config_spec.rb`, `spec/lib/crawler/data/crawl_result/success_spec.rb` (new), `spec/lib/constants_spec.rb` (new), `spec/lib/crawler/markdown_converter_spec.rb` (new), `spec/lib/crawler/coordinator_spec.rb`, `spec/lib/crawler/api/crawl_spec.rb`, `spec/lib/crawler/document_mapper_spec.rb`, `spec/lib/crawler/output_sink/elasticsearch_spec.rb`, `spec/lib/crawler/output_sink/console_spec.rb` (new), `spec/integration/markdown_conversion_spec.rb` (new).

Existing helpers you will reuse:
- Factories (`spec/factories/crawl_results.rb`): `FactoryBot.build(:html_crawl_result, url:, content:)` and `FactoryBot.build(:content_extractable_file_crawl_result, url:, content:, content_length:, content_type:)`. `FactoryBot::Syntax::Methods` is included, so `build(...)` also works.
- WebMock is enabled in `spec/spec_helper.rb` (`WebMock.disable_net_connect!(allow_localhost: true)`); use `stub_request`, `a_request`, `have_been_requested`.
- `FauxCrawl.run(site, options)` (`spec/support/faux/faux_crawl.rb`) runs a full crawl against a local Faux site using the `:mock` sink and returns a `ResultsCollection` of crawl results (`results.crawl`, `results.crawl_config`).
- `mock_response(...)` + `have_only_these_results` matchers (`spec/support/mock_response.rb`, `spec/support/crawl_response_matchers.rb`).

---

### Task 1: Config block, validation, and `config.markdown_converter` factory

**Files:**
- Modify: `lib/crawler/api/config.rb` (CONFIG_FIELDS at lines 67-68, DEFAULTS at lines 143-213, `initialize` at lines 231-257, `document_mapper` at lines 549-551)
- Create: `lib/crawler/markdown_converter.rb` (config-facing skeleton; Tasks 3-4 extend it)
- Test: `spec/lib/crawler/api/config_spec.rb`

**Interfaces:**
- Consumes: `ES::BulkQueue::DEFAULT_SIZE_THRESHOLD` (`lib/es/bulk_queue.rb:18`, 1 MB), `Addressable::URI.parse`.
- Produces:
  - `Crawler::API::Config#markdown_conversion` → `Hash` with symbol keys, always fully populated (a nil block means all defaults; any other non-hash raises): `{ enabled: Boolean, base_url: String|nil (no trailing slash), wait_seconds: Integer 0..60, poll_interval: Numeric > 0, timeout: Numeric > 0, on_failure: 'text'|'skip', ca_file: String|nil }`.
  - `Crawler::API::Config#markdown_converter` → memoised `Crawler::MarkdownConverter`.
  - `Crawler::MarkdownConverter.new(config)`; `#enabled?` → `true|false`; `#skip_on_failure?` → `true|false`; `#stats` → `{ converted: Integer, failed: Integer }`; `#settings` → the hash above; `#config`.
  - Validation raises `ArgumentError` with messages: `Unexpected markdown_conversion options: [...]`, `markdown_conversion.enabled must be true or false`, `markdown_conversion.base_url is required when markdown_conversion.enabled is true`, `markdown_conversion.base_url "..." must be an http(s) URL`, `markdown_conversion.on_failure must be one of text, skip`, `markdown_conversion.wait_seconds must be an integer between 0 and 60`, `markdown_conversion.<poll_interval|timeout> must be a positive number`, and the bulk-size message shown in Step 3.

- [ ] **Step 1: Write the failing config tests**

Append this context inside `describe '#initialize' do ... end` in `spec/lib/crawler/api/config_spec.rb`, right before the existing `describe '#configure_http_header_service!'` block (line 363):

```ruby
    context 'when configuring markdown conversion' do
      let(:base_params) { { domains: [{ url: 'https://example.com' }], output_sink: :console } }

      it 'defaults to disabled with the documented defaults' do
        config = Crawler::API::Config.new(base_params)
        expect(config.markdown_conversion).to eq(
          enabled: false,
          base_url: nil,
          wait_seconds: 10,
          poll_interval: 2,
          timeout: 900,
          on_failure: 'text',
          ca_file: nil
        )
      end

      it 'treats a nil markdown_conversion block as all defaults' do
        config = Crawler::API::Config.new(base_params.merge(markdown_conversion: nil))
        expect(config.markdown_conversion).to include(enabled: false, on_failure: 'text')
      end

      it 'rejects a non-hash markdown_conversion value' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: 'yes'))
        end.to raise_error(ArgumentError, 'markdown_conversion must be a hash')
      end

      it 'rejects an unknown top-level key' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversions: { enabled: true }))
        end.to raise_error(ArgumentError, /Unexpected configuration options.*markdown_conversions/)
      end

      it 'rejects unknown nested keys' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { enabled: false, retries: 3 }))
        end.to raise_error(ArgumentError, /Unexpected markdown_conversion options.*retries/)
      end

      it 'merges user settings over the defaults and strips a trailing slash from base_url' do
        config = Crawler::API::Config.new(
          base_params.merge(markdown_conversion: { enabled: true, base_url: 'http://converter.test/', wait_seconds: 5 })
        )
        expect(config.markdown_conversion).to eq(
          enabled: true,
          base_url: 'http://converter.test',
          wait_seconds: 5,
          poll_interval: 2,
          timeout: 900,
          on_failure: 'text',
          ca_file: nil
        )
      end

      it 'requires enabled to be a boolean' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { enabled: 'yes' }))
        end.to raise_error(ArgumentError, 'markdown_conversion.enabled must be true or false')
      end

      it 'requires base_url when enabled' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { enabled: true }))
        end.to raise_error(ArgumentError, /base_url is required when markdown_conversion.enabled is true/)
      end

      it 'requires an http(s) base_url when enabled' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { enabled: true, base_url: 'ftp://x' }))
        end.to raise_error(ArgumentError, 'markdown_conversion.base_url "ftp://x" must be an http(s) URL')
      end

      it 'rejects an unparseable base_url' do
        params = base_params.merge(markdown_conversion: { enabled: true, base_url: 'http://exa mple' })
        expect do
          Crawler::API::Config.new(params)
        end.to raise_error(ArgumentError, /markdown_conversion.base_url is not a valid URL/)
      end

      it 'does not require base_url when disabled' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { enabled: false }))
        end.not_to raise_error
      end

      it 'validates on_failure' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { on_failure: 'retry' }))
        end.to raise_error(ArgumentError, 'markdown_conversion.on_failure must be one of text, skip')
      end

      it 'accepts on_failure as a symbol and normalizes it to a string' do
        config = Crawler::API::Config.new(base_params.merge(markdown_conversion: { on_failure: :skip }))
        expect(config.markdown_conversion[:on_failure]).to eq('skip')
      end

      it 'validates the wait_seconds range' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { wait_seconds: 61 }))
        end.to raise_error(ArgumentError, 'markdown_conversion.wait_seconds must be an integer between 0 and 60')
      end

      it 'validates poll_interval and timeout are positive numbers' do
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { poll_interval: 0 }))
        end.to raise_error(ArgumentError, 'markdown_conversion.poll_interval must be a positive number')
        expect do
          Crawler::API::Config.new(base_params.merge(markdown_conversion: { timeout: '900' }))
        end.to raise_error(ArgumentError, 'markdown_conversion.timeout must be a positive number')
      end

      context 'with the elasticsearch sink' do
        let(:es_params) do
          {
            domains: [{ url: 'https://example.com' }],
            output_sink: :elasticsearch,
            output_index: 'my-index',
            elasticsearch: { host: 'http://localhost', port: 9200 },
            markdown_conversion: { enabled: true, base_url: 'http://converter.test' }
          }
        end

        it 'rejects a max_body_size that is not smaller than the bulk request size limit (default 1 MB)' do
          expect do
            Crawler::API::Config.new(es_params)
          end.to raise_error(
            ArgumentError,
            /max_body_size \(5242880\) is not smaller than elasticsearch.bulk_api.max_size_bytes \(1048576\)/
          )
        end

        it 'accepts a smaller max_body_size' do
          expect { Crawler::API::Config.new(es_params.merge(max_body_size: 500_000)) }.not_to raise_error
        end

        it 'honours a larger configured bulk_api.max_size_bytes' do
          params = es_params.merge(
            elasticsearch: { host: 'http://localhost', port: 9200, bulk_api: { max_size_bytes: 10_000_000 } }
          )
          expect { Crawler::API::Config.new(params) }.not_to raise_error
        end

        it 'does not validate the body size when markdown conversion is disabled' do
          params = es_params.merge(markdown_conversion: { enabled: false })
          expect { Crawler::API::Config.new(params) }.not_to raise_error
        end
      end

      it 'exposes a memoised markdown converter' do
        config = Crawler::API::Config.new(base_params)
        expect(config.markdown_converter).to be_a(Crawler::MarkdownConverter)
        expect(config.markdown_converter).to equal(config.markdown_converter)
        expect(config.markdown_converter.enabled?).to be(false)
        expect(config.markdown_converter.skip_on_failure?).to be(false)
        expect(config.markdown_converter.stats).to eq(converted: 0, failed: 0)
      end
    end
```

- [ ] **Step 2: Run the config spec to verify it fails**

Run (see Global Constraints test command): rspec spec/lib/crawler/api/config_spec.rb
Expected: the new examples FAIL (`Unexpected configuration options: [:markdown_conversion]` and `undefined method 'markdown_converter'`); all pre-existing examples PASS.

- [ ] **Step 3: Add the config field, nested defaults, validation, and factory**

In `lib/crawler/api/config.rb`:

(a) Add a `require_dependency` for the bulk queue and the converter next to the existing ones (after line 16):

```ruby
require_dependency(File.join(__dir__, '..', 'markdown_converter'))
require_dependency(File.join(__dir__, '..', '..', 'es', 'bulk_queue'))
```

(b) In `CONFIG_FIELDS`, right after `:elasticsearch, # Elasticsearch connection settings` (line 68), add:

```ruby
        # Markdown conversion settings (nested hash, see docs/features/MARKDOWN_CONVERSION.md)
        :markdown_conversion,
```

(c) Right after `EXTRACTION_RULES_FIELDS = %i[url_filters rules].freeze` (line 139), add:

```ruby
      MARKDOWN_CONVERSION_FIELDS = %i[enabled base_url wait_seconds poll_interval timeout on_failure ca_file].freeze
      MARKDOWN_CONVERSION_DEFAULTS = {
        enabled: false,
        base_url: nil,
        wait_seconds: 10,
        poll_interval: 2,
        timeout: 900,
        on_failure: 'text',
        ca_file: nil
      }.freeze
      MARKDOWN_ON_FAILURE_POLICIES = %w[text skip].freeze
```

(d) In `DEFAULTS`, right after `full_html_extraction_enabled: false,` (line 208), add:

```ruby
        markdown_conversion: MARKDOWN_CONVERSION_DEFAULTS,
```

(e) In `initialize`, after `configure_exclude_tags!` (line 256), add:

```ruby
        configure_markdown_conversion!
```

(f) Right after the `configure_extraction_rules!` method (ends at line 490), add:

```ruby
      # `markdown_conversion:` with no children parses as nil in YAML and means "all defaults"
      def configure_markdown_conversion!
        unless markdown_conversion.nil? || markdown_conversion.is_a?(Hash)
          raise ArgumentError, 'markdown_conversion must be a hash'
        end

        settings = MARKDOWN_CONVERSION_DEFAULTS.merge((markdown_conversion || {}).symbolize_keys)
        extra_keys = settings.keys - MARKDOWN_CONVERSION_FIELDS
        raise ArgumentError, "Unexpected markdown_conversion options: #{extra_keys.inspect}" if extra_keys.any?

        validate_markdown_enabled!(settings)
        validate_markdown_on_failure!(settings)
        validate_markdown_wait_seconds!(settings)
        validate_markdown_durations!(settings)
        if settings[:enabled]
          validate_markdown_base_url!(settings)
          validate_markdown_body_size!
        end

        @markdown_conversion = settings
      end

      def validate_markdown_enabled!(settings)
        return if [true, false].include?(settings[:enabled])

        raise ArgumentError, 'markdown_conversion.enabled must be true or false'
      end

      def validate_markdown_on_failure!(settings)
        settings[:on_failure] = settings[:on_failure].to_s
        return if MARKDOWN_ON_FAILURE_POLICIES.include?(settings[:on_failure])

        raise ArgumentError,
              "markdown_conversion.on_failure must be one of #{MARKDOWN_ON_FAILURE_POLICIES.join(', ')}"
      end

      def validate_markdown_wait_seconds!(settings)
        wait = settings[:wait_seconds]
        return if wait.is_a?(Integer) && wait.between?(0, 60)

        raise ArgumentError, 'markdown_conversion.wait_seconds must be an integer between 0 and 60'
      end

      def validate_markdown_durations!(settings)
        %i[poll_interval timeout].each do |key|
          value = settings[key]
          next if value.is_a?(Numeric) && value.positive?

          raise ArgumentError, "markdown_conversion.#{key} must be a positive number"
        end
      end

      def validate_markdown_base_url!(settings)
        base_url = settings[:base_url].to_s.strip
        if base_url.empty?
          raise ArgumentError, 'markdown_conversion.base_url is required when markdown_conversion.enabled is true'
        end

        scheme = Addressable::URI.parse(base_url).scheme
        unless %w[http https].include?(scheme)
          raise ArgumentError, "markdown_conversion.base_url #{base_url.inspect} must be an http(s) URL"
        end

        settings[:base_url] = base_url.chomp('/')
      rescue Addressable::URI::InvalidURIError => e
        raise ArgumentError, "markdown_conversion.base_url is not a valid URL (#{e.message})"
      end

      # A markdown body must fit into a single bulk request, otherwise the ES sink can never flush it
      def validate_markdown_body_size!
        return unless output_sink.to_s == 'elasticsearch'

        bulk_max = elasticsearch&.dig(:bulk_api, :max_size_bytes) || ES::BulkQueue::DEFAULT_SIZE_THRESHOLD
        return if max_body_size < bulk_max

        raise ArgumentError, <<~MSG.squish
          markdown_conversion is enabled but max_body_size (#{max_body_size}) is not smaller than
          elasticsearch.bulk_api.max_size_bytes (#{bulk_max}); a single markdown document could exceed one
          bulk request. Lower max_body_size or raise elasticsearch.bulk_api.max_size_bytes.
        MSG
      end
```

(g) Right after the `document_mapper` method (line 551), add:

```ruby
      def markdown_converter
        @markdown_converter ||= ::Crawler::MarkdownConverter.new(self)
      end
```

Create `lib/crawler/markdown_converter.rb`:

```ruby
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

require 'concurrent/atomic/atomic_fixnum'

module Crawler
  # Converts crawled HTML pages and binary documents (PDF, DOCX, XLSX, PPTX) to Markdown
  # through the shared convert-markdown service. See docs/features/MARKDOWN_CONVERSION.md.
  class MarkdownConverter
    attr_reader :config, :settings

    delegate :system_logger, to: :config

    def initialize(config)
      @config = config
      @settings = config.markdown_conversion
      @converted = Concurrent::AtomicFixnum.new(0)
      @failed = Concurrent::AtomicFixnum.new(0)
    end

    def enabled?
      settings[:enabled] == true
    end

    def skip_on_failure?
      settings[:on_failure] == 'skip'
    end

    # Thread-safe counters, printed at the end of the crawl
    def stats
      { converted: @converted.value, failed: @failed.value }
    end
  end
end
```

- [ ] **Step 4: Run the config spec to verify it passes**

Run (see Global Constraints test command): rspec spec/lib/crawler/api/config_spec.rb
Expected: all examples PASS.

- [ ] **Step 5: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/api/config.rb lib/crawler/markdown_converter.rb spec/lib/crawler/api/config_spec.rb
Expected: `no offenses detected`. If `Metrics/ClassLength` fires on `Config` (it is already `# rubocop:disable Metrics/ClassLength` on line 27, so it should not), keep that existing disable.

- [ ] **Step 6: Commit**

```bash
git add lib/crawler/api/config.rb lib/crawler/markdown_converter.rb spec/lib/crawler/api/config_spec.rb
git commit -m "feat(markdown): add markdown_conversion config block and converter factory"
```

---

### Task 2: `CrawlResult::Success#markdown` accessor and reserved field names

**Files:**
- Modify: `lib/crawler/data/crawl_result/success.rb:18`
- Modify: `lib/constants.rb:11-37`
- Test: `spec/lib/crawler/data/crawl_result/success_spec.rb` (create), `spec/lib/constants_spec.rb` (create)

**Interfaces:**
- Produces: `Crawler::Data::CrawlResult::Success#markdown` → `String|nil` (default `nil`), `#markdown=(String)`. Available on `HTML` and `ContentExtractableFile` results. `Constants::RESERVED_FIELD_NAMES` includes `'body_format'` and `'content_hash'`.

- [ ] **Step 1: Write the failing tests**

Create `spec/lib/crawler/data/crawl_result/success_spec.rb`:

```ruby
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

RSpec.describe(Crawler::Data::CrawlResult::Success) do
  describe '#markdown' do
    it 'is nil by default on HTML results' do
      expect(FactoryBot.build(:html_crawl_result).markdown).to be_nil
    end

    it 'is nil by default on content extractable file results' do
      expect(FactoryBot.build(:content_extractable_file_crawl_result).markdown).to be_nil
    end

    it 'can be assigned after a successful conversion' do
      result = FactoryBot.build(:html_crawl_result)
      result.markdown = '# Title'
      expect(result.markdown).to eq('# Title')
    end
  end
end
```

Create `spec/lib/constants_spec.rb`:

```ruby
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

RSpec.describe(Constants) do
  it 'reserves the document fields written by markdown conversion' do
    expect(Constants::RESERVED_FIELD_NAMES).to include('body_format', 'content_hash')
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run (see Global Constraints test command): rspec spec/lib/crawler/data/crawl_result/success_spec.rb spec/lib/constants_spec.rb
Expected: FAIL with `undefined method 'markdown'` and the `include` mismatch.

- [ ] **Step 3: Implement**

In `lib/crawler/data/crawl_result/success.rb`, replace line 18 (`attr_reader :content`) with:

```ruby
        attr_reader :content

        # Markdown produced by Crawler::MarkdownConverter, nil until a conversion succeeds.
        # Memoised on the result so the SinkLockedError retry loop in the coordinator does not reconvert.
        attr_accessor :markdown
```

In `lib/constants.rb`, inside `RESERVED_FIELD_NAMES`, add `body_format` after `body` and `content_hash` after it, so the list reads:

```ruby
    body_content
    body
    body_format
    content_hash
    domains
```

- [ ] **Step 4: Run the tests (plus the reserved-name rule spec, which iterates the constant)**

Run (see Global Constraints test command): rspec spec/lib/crawler/data/crawl_result/success_spec.rb spec/lib/constants_spec.rb spec/lib/crawler/data/extraction/rule_spec.rb spec/lib/crawler/data/crawl_result/html_spec.rb
Expected: all PASS.

- [ ] **Step 5: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/data/crawl_result/success.rb lib/constants.rb spec/lib/crawler/data/crawl_result/success_spec.rb spec/lib/constants_spec.rb
Expected: `no offenses detected`.

- [ ] **Step 6: Commit**

```bash
git add lib/crawler/data/crawl_result/success.rb lib/constants.rb spec/lib/crawler/data/crawl_result/success_spec.rb spec/lib/constants_spec.rb
git commit -m "feat(markdown): add Success#markdown accessor and reserve body_format/content_hash"
```

---

### Task 3: `MarkdownConverter` core — MIME map, `convertible?`, filename, payload builders

**Files:**
- Modify: `lib/crawler/markdown_converter.rb` (created in Task 1)
- Test: `spec/lib/crawler/markdown_converter_spec.rb` (create)

**Interfaces:**
- Consumes: `CrawlResult::HTML#parsed_content` / `#parsed_content_excluding_tags(Array<String>)` (`lib/crawler/data/crawl_result/html.rb:25-40`, both memoised Jsoup `Document`s), `Crawler::ContentEngine::Transformer.transform!(element)` (`lib/crawler/content_engine/transformer.rb:20`), `config.exclude_tags` (Hash of domain URL string → Array of tag names, `lib/crawler/api/config.rb:377-393`), `crawl_result.url_hash`, `crawl_result.content_type`, `Success#content`.
- Produces:
  - `MarkdownConverter::MIME_EXTENSIONS` → frozen `Hash<String, String>` (5 entries).
  - `#convertible?(crawl_result)` → `true|false`; returns `false` without touching the result when disabled.
  - `#upload_filename(crawl_result)` → `"#{url_hash}.html|.pdf|.docx|.xlsx|.pptx"`.
  - `#html_payload(crawl_result)` → `ASCII-8BIT` `String` of UTF-8 HTML bytes (exclusions applied, `<meta charset="UTF-8">` present, memoised documents untouched).
  - `#binary_payload(crawl_result)` → `ASCII-8BIT` `String`, byte-identical to `crawl_result.content`.
  - private `#normalized_content_type(crawl_result)` → e.g. `'application/pdf'` (charset stripped, downcased) — used by Task 4's multipart builder.

- [ ] **Step 1: Write the failing tests**

Create `spec/lib/crawler/markdown_converter_spec.rb`:

```ruby
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

RSpec.describe(Crawler::MarkdownConverter) do
  let(:domain) { 'http://example.com' }
  let(:base_url) { 'http://converter.test' }
  let(:exclude_tags) { nil }
  let(:markdown_settings) { { enabled: true, base_url:, wait_seconds: 10, poll_interval: 0.01, timeout: 5 } }
  let(:config) do
    Crawler::API::Config.new(
      domains: [{ url: domain, exclude_tags: }.compact],
      output_sink: :console,
      markdown_conversion: markdown_settings
    )
  end
  let(:converter) { described_class.new(config) }

  let(:html) do
    <<~HTML
      <html>
        <head><title>Hi</title></head>
        <body>
          <h1>Héllo</h1>
          <div data-elastic-exclude>secret</div>
          <footer>footer text</footer>
        </body>
      </html>
    HTML
  end
  let(:html_result) { FactoryBot.build(:html_crawl_result, url: "#{domain}/page", content: html) }
  let(:pdf_bytes) { "%PDF-1.4\n\xFF\xFE binary".b }
  let(:pdf_result) do
    FactoryBot.build(
      :content_extractable_file_crawl_result,
      url: "#{domain}/doc.pdf?v=2",
      content: pdf_bytes,
      content_type: 'application/pdf'
    )
  end

  let(:docx_type) { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
  let(:xlsx_type) { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
  let(:pptx_type) { 'application/vnd.openxmlformats-officedocument.presentationml.presentation' }

  def file_result(content_type)
    FactoryBot.build(:content_extractable_file_crawl_result, url: "#{domain}/file", content_type:)
  end

  describe '#convertible?' do
    it 'is true for HTML results' do
      expect(converter.convertible?(html_result)).to be(true)
    end

    it 'is true for supported binary MIME types' do
      expect(converter.convertible?(pdf_result)).to be(true)
      expect(converter.convertible?(file_result(docx_type))).to be(true)
      expect(converter.convertible?(file_result(xlsx_type))).to be(true)
      expect(converter.convertible?(file_result(pptx_type))).to be(true)
    end

    it 'strips charset parameters and ignores case when matching the MIME type' do
      xlsx = 'Application/vnd.openxmlformats-officedocument.spreadsheetml.sheet; charset=binary'
      expect(converter.convertible?(file_result(xlsx))).to be(true)
    end

    it 'is false for legacy office types and other MIME types' do
      expect(converter.convertible?(file_result('application/msword'))).to be(false)
      expect(converter.convertible?(file_result('application/vnd.ms-powerpoint'))).to be(false)
      expect(converter.convertible?(file_result('image/png'))).to be(false)
    end

    context 'when disabled' do
      let(:markdown_settings) { { enabled: false } }

      it 'is false and does not call anything on the crawl result' do
        strict_result = double(:crawl_result) # raises on any message
        expect(converter.convertible?(strict_result)).to be(false)
      end
    end
  end

  describe '#upload_filename' do
    it 'uses the URL hash plus the extension for the MIME type, never the URL basename' do
      expect(converter.upload_filename(pdf_result)).to eq("#{pdf_result.url_hash}.pdf")
      expect(converter.upload_filename(html_result)).to eq("#{html_result.url_hash}.html")
    end

    it 'maps every supported MIME type to its extension' do
      expect(converter.upload_filename(file_result('application/pdf; charset=utf-8'))).to end_with('.pdf')
      expect(converter.upload_filename(file_result(docx_type))).to end_with('.docx')
      expect(converter.upload_filename(file_result(xlsx_type))).to end_with('.xlsx')
      expect(converter.upload_filename(file_result(pptx_type))).to end_with('.pptx')
    end
  end

  describe '#html_payload' do
    let(:exclude_tags) { %w[footer] }

    it 'serialises the Jsoup document as UTF-8 bytes with a charset meta tag' do
      payload = converter.html_payload(html_result)
      expect(payload.encoding).to eq(Encoding::BINARY)
      expect(payload).to include('<meta charset="UTF-8">'.b)
      expect(payload).to include('Héllo'.b)
    end

    it 'removes excluded tags and data-elastic-exclude content' do
      payload = converter.html_payload(html_result)
      expect(payload).not_to include('footer text'.b)
      expect(payload).not_to include('secret'.b)
    end

    it 'leaves the memoised parsed documents untouched' do
      converter.html_payload(html_result)
      expect(html_result.parsed_content.select('footer').size).to eq(1)
      expect(html_result.parsed_content.select('[data-elastic-exclude]').size).to eq(1)
      expect(html_result.parsed_content_excluding_tags(%w[footer]).select('[data-elastic-exclude]').size).to eq(1)
    end

    context 'without exclude tags configured' do
      let(:exclude_tags) { nil }

      it 'keeps the footer but still honours data-elastic-exclude' do
        payload = converter.html_payload(html_result)
        expect(payload).to include('footer text'.b)
        expect(payload).not_to include('secret'.b)
      end
    end
  end

  describe '#binary_payload' do
    it 'returns the content bytes unchanged' do
      payload = converter.binary_payload(pdf_result)
      expect(payload).to eq(pdf_bytes)
      expect(payload.encoding).to eq(Encoding::BINARY)
    end
  end
end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run (see Global Constraints test command): rspec spec/lib/crawler/markdown_converter_spec.rb
Expected: FAIL with `undefined method 'convertible?'` (and friends).

- [ ] **Step 3: Implement the core**

Replace the whole `class MarkdownConverter ... end` body in `lib/crawler/markdown_converter.rb` with:

```ruby
  class MarkdownConverter
    # Response Content-Type (charset stripped, downcased) -> upload extension required by the converter.
    # Anything else (incl. legacy application/msword, application/vnd.ms-powerpoint) is not convertible.
    MIME_EXTENSIONS = {
      'text/html' => '.html',
      'application/pdf' => '.pdf',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => '.docx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => '.xlsx',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation' => '.pptx'
    }.freeze
    HTML_EXTENSION = '.html'

    attr_reader :config, :settings

    delegate :system_logger, to: :config

    def initialize(config)
      @config = config
      @settings = config.markdown_conversion
      @converted = Concurrent::AtomicFixnum.new(0)
      @failed = Concurrent::AtomicFixnum.new(0)
    end

    def enabled?
      settings[:enabled] == true
    end

    def skip_on_failure?
      settings[:on_failure] == 'skip'
    end

    # Thread-safe counters, printed at the end of the crawl
    def stats
      { converted: @converted.value, failed: @failed.value }
    end

    # Must not call anything on the crawl result when disabled (coordinator specs use strict doubles)
    def convertible?(crawl_result)
      return false unless enabled?
      return true if crawl_result.html?

      crawl_result.content_extractable_file? && !extension_for(crawl_result).nil?
    end

    # The converter picks its parser from the extension, so the filename is synthetic:
    # ContentExtractableFile#file_name is File.basename(url) and may carry query strings or no extension.
    def upload_filename(crawl_result)
      "#{crawl_result.url_hash}#{extension_for(crawl_result)}"
    end

    # Serialise from Jsoup (not raw bytes) so exclude_tags and data-elastic-exclude/include are honoured.
    # The memoised documents are also used for link extraction, so work on a deep clone.
    def html_payload(crawl_result)
      doc = source_document(crawl_result).clone
      Crawler::ContentEngine::Transformer.transform!(doc.body)
      doc.charset(java.nio.charset.StandardCharsets::UTF_8)
      String.from_java_bytes(doc.outerHtml.to_java_bytes)
    end

    def binary_payload(crawl_result)
      crawl_result.content.b
    end

    private

    def extension_for(crawl_result)
      return HTML_EXTENSION if crawl_result.html?

      MIME_EXTENSIONS[normalized_content_type(crawl_result)]
    end

    def normalized_content_type(crawl_result)
      crawl_result.content_type.to_s.split(';').first.to_s.strip.downcase
    end

    # Mirrors CrawlResult::HTML#get_body_tag: parsed_content_excluding_tags([]) would call Jsoup select('')
    def source_document(crawl_result)
      tags = tags_to_exclude(crawl_result)
      return crawl_result.parsed_content if tags.empty?

      crawl_result.parsed_content_excluding_tags(tags)
    end

    def tags_to_exclude(crawl_result)
      exclude_tags = config.exclude_tags || {}
      exclude_tags.fetch(crawl_result.url.site, nil) || exclude_tags.fetch(crawl_result.url.to_s, [])
    end
  end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run (see Global Constraints test command): rspec spec/lib/crawler/markdown_converter_spec.rb
Expected: all PASS. If `'<meta charset="UTF-8">'` is not found, print `payload` in the failing example: Jsoup 1.23 `Document#charset(Charset)` inserts `<meta charset="UTF-8">` into `<head>` (`ensureMetaCharsetElement`); the attribute value is `Charset#displayName`, i.e. exactly `UTF-8`.

- [ ] **Step 5: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/markdown_converter.rb spec/lib/crawler/markdown_converter_spec.rb
Expected: `no offenses detected`.

- [ ] **Step 6: Commit**

```bash
git add lib/crawler/markdown_converter.rb spec/lib/crawler/markdown_converter_spec.rb
git commit -m "feat(markdown): add MarkdownConverter MIME map, filename and payload builders"
```

---

### Task 4: `MarkdownConverter` transport — multipart POST, polling, retry, health, truncation, stats

**Files:**
- Modify: `lib/crawler/markdown_converter.rb`
- Test: `spec/lib/crawler/markdown_converter_spec.rb`

**Interfaces:**
- Consumes: Task 3 methods; `Crawler::ContentEngine::Utils.limit_bytesize(string, limit)` (`lib/crawler/content_engine/utils.rb:106`, appends `…` when truncating); `config.max_body_size`, `config.user_agent`; `Success#markdown=`.
- Produces:
  - `#convert!(crawl_result)` → `:converted | :skipped | :failed`. Never raises. On `:converted` sets `crawl_result.markdown` (truncated to `config.max_body_size` bytes) and increments `stats[:converted]`; on `:failed` leaves `markdown` nil, increments `stats[:failed]`, logs `system_logger.warn("Markdown conversion failed for #{url}: #{reason}")`. `:skipped` touches nothing.
  - `#healthy?` → `true|false` (GET `/api/v1/health`, 5 s open/read timeout, any exception → `false` + warn).
  - `#multipart_body(crawl_result)` → `[body (ASCII-8BIT String), content_type_header (String)]`.
  - Internal errors `MarkdownConverter::RetryableError` and `MarkdownConverter::ConversionError` (both `StandardError`); not part of the public contract but visible in logs.
  - Sleeping goes through `Kernel#sleep` on the converter instance (`sleep(RETRY_DELAY)`, `sleep(interval)`) so specs can stub it with `allow(converter).to receive(:sleep)`.

- [ ] **Step 1: Write the failing transport tests**

Append inside the top-level `RSpec.describe(Crawler::MarkdownConverter) do` block of `spec/lib/crawler/markdown_converter_spec.rb` (after `describe '#binary_payload'`):

```ruby
  describe '#convert!' do
    let(:upload_url) { "#{base_url}/api/v1/convert/upload?wait=10" }
    let(:status_url) { "#{base_url}/api/v1/jobs/job-1" }
    let(:json_headers) { { 'Content-Type' => 'application/json' } }

    def job_json(status, extra = {})
      { job_id: 'job-1', status:, status_url: '/api/v1/jobs/job-1', source_name: 'x' }.merge(extra).to_json
    end

    def json_response(status, extra = {})
      { status: 200, body: job_json(status, extra), headers: json_headers }
    end

    def pending_response
      { status: 202, body: job_json('pending'), headers: json_headers }
    end

    before do
      # Keep polling and retries instant; timing is asserted through the arguments passed to sleep
      allow(converter).to receive(:sleep)
      allow(config.system_logger).to receive(:warn)
    end

    it 'stores the markdown when the upload returns status done inline' do
      stub_request(:post, upload_url).to_return(json_response('done', markdown: '# Hi'))

      expect(converter.convert!(html_result)).to eq(:converted)
      expect(html_result.markdown).to eq('# Hi')
      expect(converter.stats).to eq(converted: 1, failed: 0)
      expect(converter).not_to have_received(:sleep)
    end

    it 'sends a multipart upload with the file field, hashed filename, part content type and user agent' do
      disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"#{pdf_result.url_hash}.pdf\"\r\n".b
      stub = stub_request(:post, upload_url).with do |request|
        body = request.body.b # compare bytes regardless of the encoding tag WebMock assigns
        request.headers['Content-Type'].start_with?('multipart/form-data; boundary=') &&
          request.headers['User-Agent'] == config.user_agent &&
          body.include?(disposition) &&
          body.include?("Content-Type: application/pdf\r\n\r\n".b + pdf_bytes + "\r\n".b)
      end.to_return(json_response('done', markdown: '# PDF'))

      expect(converter.convert!(pdf_result)).to eq(:converted)
      expect(stub).to have_been_requested.once
    end

    context 'with exclude tags configured' do
      let(:exclude_tags) { %w[footer] }

      it 'uploads the pre-processed UTF-8 HTML document' do
        stub = stub_request(:post, upload_url).with do |request|
          body = request.body.b
          body.include?("filename=\"#{html_result.url_hash}.html\"".b) &&
            body.include?("Content-Type: text/html; charset=utf-8\r\n\r\n".b) &&
            body.include?('<meta charset="UTF-8">'.b) &&
            body.include?('Héllo'.b) &&
            !body.include?('footer text'.b) &&
            !body.include?('secret'.b)
        end.to_return(json_response('done', markdown: '# HTML'))

        expect(converter.convert!(html_result)).to eq(:converted)
        expect(stub).to have_been_requested.once
      end
    end

    it 'polls the status URL with backoff until the job is done' do
      stub_request(:post, upload_url).to_return(pending_response)
      poll = stub_request(:get, status_url).to_return(
        json_response('processing'),
        json_response('processing'),
        json_response('done', markdown: '# Polled')
      )

      expect(converter.convert!(html_result)).to eq(:converted)
      expect(html_result.markdown).to eq('# Polled')
      expect(poll).to have_been_requested.times(3)
      expect(converter).to have_received(:sleep).with(0.01).ordered
      expect(converter).to have_received(:sleep).with(be_within(1e-9).of(0.015)).ordered
      expect(converter).to have_received(:sleep).with(be_within(1e-9).of(0.0225)).ordered
    end

    context 'with a large poll interval' do
      let(:markdown_settings) { super().merge(poll_interval: 4) }

      it 'caps the backoff at 5 seconds' do
        stub_request(:post, upload_url).to_return(pending_response)
        stub_request(:get, status_url).to_return(
          json_response('processing'),
          json_response('processing'),
          json_response('done', markdown: '# Capped')
        )

        expect(converter.convert!(html_result)).to eq(:converted)
        expect(converter).to have_received(:sleep).with(4.0).ordered
        expect(converter).to have_received(:sleep).with(5.0).ordered
        expect(converter).to have_received(:sleep).with(5.0).ordered
      end
    end

    it 'fails without retrying when the converter reports status failed' do
      stub = stub_request(:post, upload_url).to_return(json_response('failed', error: 'unsupported document'))

      expect(converter.convert!(pdf_result)).to eq(:failed)
      expect(pdf_result.markdown).to be_nil
      expect(converter.stats).to eq(converted: 0, failed: 1)
      expect(stub).to have_been_requested.once
      expect(converter).not_to have_received(:sleep)
      expect(config.system_logger).to have_received(:warn)
        .with(%r{Markdown conversion failed for http://example.com/doc.pdf\?v=2: .*unsupported document})
    end

    it 'fails without retrying on HTTP 422' do
      stub = stub_request(:post, upload_url).to_return(status: 422, body: '{"detail":"unsupported extension"}')

      expect(converter.convert!(pdf_result)).to eq(:failed)
      expect(stub).to have_been_requested.once
      expect(converter).not_to have_received(:sleep)
      expect(config.system_logger).to have_received(:warn).with(/HTTP 422 from converter/)
    end

    it 'fails without retrying on HTTP 404 from the upload endpoint' do
      stub = stub_request(:post, upload_url).to_return(status: 404, body: 'not found')

      expect(converter.convert!(pdf_result)).to eq(:failed)
      expect(stub).to have_been_requested.once
    end

    it 'retries once after 1s on HTTP 5xx and succeeds' do
      stub = stub_request(:post, upload_url).to_return(
        { status: 503, body: 'upstream unavailable' },
        json_response('done', markdown: '# Second try')
      )

      expect(converter.convert!(html_result)).to eq(:converted)
      expect(html_result.markdown).to eq('# Second try')
      expect(stub).to have_been_requested.twice
      expect(converter).to have_received(:sleep).with(1).once
    end

    it 'fails after two HTTP 5xx responses' do
      stub = stub_request(:post, upload_url).to_return(status: 503, body: 'upstream unavailable')

      expect(converter.convert!(html_result)).to eq(:failed)
      expect(html_result.markdown).to be_nil
      expect(stub).to have_been_requested.twice
      expect(config.system_logger).to have_received(:warn).with(/HTTP 503 from converter/)
    end

    it 'retries once on a connection error' do
      stub = stub_request(:post, upload_url)
      stub.to_raise(Errno::ECONNREFUSED).then.to_return(json_response('done', markdown: '# Reconnected'))

      expect(converter.convert!(html_result)).to eq(:converted)
      expect(stub).to have_been_requested.twice
      expect(converter).to have_received(:sleep).with(1).once
    end

    it 'retries once on an open timeout' do
      stub = stub_request(:post, upload_url).to_timeout.then.to_return(json_response('done', markdown: '# Late'))

      expect(converter.convert!(html_result)).to eq(:converted)
      expect(stub).to have_been_requested.twice
    end

    it 'fails after two read timeouts' do
      stub = stub_request(:post, upload_url).to_raise(Net::ReadTimeout)

      expect(converter.convert!(html_result)).to eq(:failed)
      expect(stub).to have_been_requested.twice
      expect(config.system_logger).to have_received(:warn).with(/Net::ReadTimeout/)
    end

    it 'resubmits once when polling returns HTTP 404 (job expired)' do
      upload = stub_request(:post, upload_url).to_return(
        pending_response,
        json_response('done', markdown: '# Resubmitted')
      )
      stub_request(:get, status_url).to_return(status: 404, body: '{"detail":"unknown job"}')

      expect(converter.convert!(html_result)).to eq(:converted)
      expect(html_result.markdown).to eq('# Resubmitted')
      expect(upload).to have_been_requested.twice
    end

    context 'when the job never finishes' do
      let(:markdown_settings) { super().merge(timeout: 0.2, poll_interval: 0.05) }

      before { allow(converter).to receive(:sleep).and_call_original }

      it 'gives up at the deadline without retrying' do
        upload = stub_request(:post, upload_url).to_return(pending_response)
        poll = stub_request(:get, status_url).to_return(json_response('processing'))

        expect(converter.convert!(html_result)).to eq(:failed)
        expect(upload).to have_been_requested.once
        expect(poll).to have_been_requested.at_least_once
        expect(config.system_logger).to have_received(:warn).with(/timed out after 0.2s waiting for job job-1/)
      end
    end

    it 'fails when the markdown is blank' do
      stub_request(:post, upload_url).to_return(json_response('done', markdown: " \n\t"))

      expect(converter.convert!(html_result)).to eq(:failed)
      expect(html_result.markdown).to be_nil
      expect(config.system_logger).to have_received(:warn).with(/empty markdown/)
    end

    it 'fails when the converter returns invalid JSON' do
      stub_request(:post, upload_url).to_return(status: 200, body: '<html>oops</html>')

      expect(converter.convert!(html_result)).to eq(:failed)
      expect(config.system_logger).to have_received(:warn).with(/invalid JSON from converter/)
    end

    context 'with a small max_body_size' do
      let(:config) do
        Crawler::API::Config.new(
          domains: [{ url: domain }],
          output_sink: :console,
          max_body_size: 10,
          markdown_conversion: markdown_settings
        )
      end

      it 'truncates the markdown to max_body_size bytes with an omission marker' do
        stub_request(:post, upload_url).to_return(json_response('done', markdown: 'a' * 50))

        expect(converter.convert!(html_result)).to eq(:converted)
        expect(html_result.markdown).to eq("#{'a' * 7}…")
        expect(html_result.markdown.bytesize).to eq(10)
      end
    end

    it 'skips unsupported MIME types without any HTTP call' do
      result = file_result('application/msword')

      expect(converter.convert!(result)).to eq(:skipped)
      expect(result.markdown).to be_nil
      expect(a_request(:any, /converter.test/)).not_to have_been_made
      expect(converter.stats).to eq(converted: 0, failed: 0)
    end

    context 'when disabled' do
      let(:markdown_settings) { { enabled: false } }

      it 'returns :skipped without any HTTP call or touching the result' do
        strict_result = double(:crawl_result)

        expect(converter.convert!(strict_result)).to eq(:skipped)
        expect(a_request(:any, /converter.test/)).not_to have_been_made
        expect(converter.stats).to eq(converted: 0, failed: 0)
      end
    end

    it 'counts conversions and failures across calls' do
      stub_request(:post, upload_url).to_return(
        json_response('done', markdown: '# One'),
        json_response('failed', error: 'boom')
      )

      converter.convert!(html_result)
      converter.convert!(pdf_result)
      expect(converter.stats).to eq(converted: 1, failed: 1)
    end

    context 'over https with a custom CA file' do
      let(:base_url) { 'https://converter.test' }
      let(:markdown_settings) { super().merge(ca_file: '/etc/ssl/converter-ca.pem') }

      it 'configures the HTTP client with TLS, the CA file and the documented timeouts' do
        clients = []
        allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
          original.call(*args).tap { |client| clients << client }
        end
        stub_request(:post, upload_url).to_return(json_response('done', markdown: '# TLS'))

        expect(converter.convert!(html_result)).to eq(:converted)
        expect(clients.size).to eq(1)
        expect(clients.first.use_ssl?).to be(true)
        expect(clients.first.ca_file).to eq('/etc/ssl/converter-ca.pem')
        expect(clients.first.open_timeout).to eq(10)
        expect(clients.first.read_timeout).to eq(30)
      end
    end
  end

  describe '#healthy?' do
    let(:health_url) { "#{base_url}/api/v1/health" }

    before { allow(config.system_logger).to receive(:warn) }

    it 'is true when the health endpoint returns 200 and sends the crawler user agent' do
      stub = stub_request(:get, health_url)
             .with(headers: { 'User-Agent' => config.user_agent })
             .to_return(status: 200, body: '{"status":"ok"}')
      expect(converter.healthy?).to be(true)
      expect(stub).to have_been_requested.once
    end

    it 'is false on a non-200 response' do
      stub_request(:get, health_url).to_return(status: 503)
      expect(converter.healthy?).to be(false)
    end

    it 'is false and warns when the service is unreachable' do
      stub_request(:get, health_url).to_raise(Errno::ECONNREFUSED)
      expect(converter.healthy?).to be(false)
      expect(config.system_logger).to have_received(:warn).with(/health check failed.*ECONNREFUSED/)
    end

    it 'is false on a timeout' do
      stub_request(:get, health_url).to_timeout
      expect(converter.healthy?).to be(false)
    end

    it 'uses a 5 second timeout' do
      clients = []
      allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |client| clients << client }
      end
      stub_request(:get, health_url).to_return(status: 200)

      converter.healthy?
      expect(clients.first.open_timeout).to eq(5)
      expect(clients.first.read_timeout).to eq(5)
    end
  end
```

- [ ] **Step 2: Run the spec to verify the new examples fail**

Run (see Global Constraints test command): rspec spec/lib/crawler/markdown_converter_spec.rb
Expected: `#convert!` and `#healthy?` examples FAIL with `undefined method 'convert!'` / `'healthy?'`; Task 3 examples still PASS.

- [ ] **Step 3: Implement the transport**

In `lib/crawler/markdown_converter.rb`:

(a) Add these requires after `require 'concurrent/atomic/atomic_fixnum'`:

```ruby
require 'json'
require 'net/http'
require 'securerandom'
require 'uri'
```

(b) Immediately after `HTML_EXTENSION = '.html'`, add:

```ruby
    # Raised internally for errors worth one retry (network, 5xx, expired job); never escapes convert!
    class RetryableError < StandardError; end
    # Raised internally for definitive failures (4xx, status: failed, empty markdown, deadline)
    class ConversionError < StandardError; end

    UPLOAD_PATH = '/api/v1/convert/upload'
    HEALTH_PATH = '/api/v1/health'
    FINISHED_STATUSES = %w[done failed].freeze
    OPEN_TIMEOUT = 10
    HEALTH_TIMEOUT = 5
    READ_TIMEOUT_MARGIN = 20 # read_timeout = wait_seconds + this
    RETRY_DELAY = 1
    POLL_BACKOFF = 1.5
    MAX_POLL_INTERVAL = 5
    RETRYABLE_ERRORS = [SystemCallError, SocketError, EOFError, Net::OpenTimeout, Net::ReadTimeout].freeze
```

(c) Add these public methods right after `binary_payload` (before `private`):

```ruby
    # Returns :converted | :skipped | :failed and never raises.
    # On success sets crawl_result.markdown (limited to config.max_body_size bytes).
    def convert!(crawl_result)
      return :skipped unless convertible?(crawl_result)

      markdown = with_one_retry(crawl_result) { run_conversion(crawl_result) }
      crawl_result.markdown = Crawler::ContentEngine::Utils.limit_bytesize(markdown, config.max_body_size)
      @converted.increment
      :converted
    rescue StandardError => e
      @failed.increment
      system_logger.warn("Markdown conversion failed for #{crawl_result.url}: #{e.message}")
      :failed
    end

    # GET /api/v1/health with a short timeout; called once at crawl start
    def healthy?
      uri = URI.parse("#{settings[:base_url]}#{HEALTH_PATH}")
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = config.user_agent
      response = http_client(uri, open_timeout: HEALTH_TIMEOUT, read_timeout: HEALTH_TIMEOUT).request(request)
      response.code.to_i == 200
    rescue StandardError => e
      system_logger.warn("Markdown converter health check failed (#{settings[:base_url]}): #{e.class}: #{e.message}")
      false
    end

    # Hand-built multipart/form-data body. Everything is appended as ASCII-8BIT so binary payloads
    # concatenate without Encoding::CompatibilityError; Net::HTTP sets Content-Length from body.bytesize.
    def multipart_body(crawl_result)
      boundary = SecureRandom.hex(16)
      payload = crawl_result.html? ? html_payload(crawl_result) : binary_payload(crawl_result)
      part_type = crawl_result.html? ? 'text/html; charset=utf-8' : normalized_content_type(crawl_result)
      head = [
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"#{upload_filename(crawl_result)}\"\r\n",
        "Content-Type: #{part_type}\r\n\r\n"
      ].join.b
      tail = "\r\n--#{boundary}--\r\n".b
      [head + payload + tail, "multipart/form-data; boundary=#{boundary}"]
    end
```

(d) Add these private methods at the end of the `private` section (after `tags_to_exclude`):

```ruby
    def with_one_retry(crawl_result)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue RetryableError => e
        raise e if attempts > 1

        system_logger.warn(
          "Markdown conversion for #{crawl_result.url} failed (#{e.message}), retrying once in #{RETRY_DELAY}s"
        )
        sleep(RETRY_DELAY)
        retry
      end
    end

    def run_conversion(crawl_result)
      deadline = monotonic_now + settings[:timeout]
      job = submit(crawl_result)
      job = poll_until_finished(job, deadline) unless finished?(job)
      raise ConversionError, "converter reported status 'failed': #{job['error']}" if job['status'] == 'failed'

      markdown = job['markdown'].to_s
      raise ConversionError, 'converter returned empty markdown' if markdown.strip.empty?

      markdown
    end

    def submit(crawl_result)
      uri = URI.parse("#{settings[:base_url]}#{UPLOAD_PATH}?wait=#{settings[:wait_seconds]}")
      request = Net::HTTP::Post.new(uri.request_uri)
      body, content_type = multipart_body(crawl_result)
      request['Content-Type'] = content_type
      request.body = body
      parse_job(perform(uri, request))
    end

    def poll_until_finished(job, deadline)
      if job['status_url'].blank?
        raise ConversionError, "converter returned status #{job['status'].inspect} without a status_url"
      end

      uri = URI.parse("#{settings[:base_url]}#{job['status_url']}")
      interval = settings[:poll_interval].to_f
      loop do
        if monotonic_now >= deadline
          raise ConversionError, "timed out after #{settings[:timeout]}s waiting for job #{job['job_id']}"
        end

        sleep(interval)
        job = parse_job(perform(uri, Net::HTTP::Get.new(uri.request_uri)), polling: true)
        return job if finished?(job)

        interval = [interval * POLL_BACKOFF, MAX_POLL_INTERVAL].min
      end
    end

    def perform(uri, request)
      request['User-Agent'] = config.user_agent
      http_client(uri, open_timeout: OPEN_TIMEOUT, read_timeout: settings[:wait_seconds] + READ_TIMEOUT_MARGIN)
        .request(request)
    rescue *RETRYABLE_ERRORS => e
      raise RetryableError, "#{e.class}: #{e.message}"
    end

    # p_addr = nil disables Net::HTTP's implicit HTTP_PROXY/HTTPS_PROXY env proxying; the crawler's own
    # http_proxy_* settings only apply to the Java HTTP client used for crawling, not to converter calls.
    def http_client(uri, open_timeout:, read_timeout:)
      Net::HTTP.new(uri.host, uri.port, nil).tap do |http|
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http.ca_file = settings[:ca_file] if settings[:ca_file].present?
      end
    end

    # Branch on the JSON status, not the HTTP code (200 and 202 both carry a job document)
    def parse_job(response, polling: false)
      raise_on_http_error!(response, polling)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise ConversionError, "invalid JSON from converter: #{e.message}"
    end

    def raise_on_http_error!(response, polling)
      code = response.code.to_i
      raise RetryableError, "HTTP #{code} from converter" if code >= 500
      raise RetryableError, 'HTTP 404 from converter while polling (job expired)' if polling && code == 404
      return if [200, 202].include?(code)

      raise ConversionError, "HTTP #{code} from converter: #{response.body.to_s[0, 200]}"
    end

    def finished?(job)
      FINISHED_STATUSES.include?(job['status'])
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run (see Global Constraints test command): rspec spec/lib/crawler/markdown_converter_spec.rb
Expected: all PASS. The deadline example takes ~0.2 s of real time; everything else is instant because `sleep` is stubbed.

- [ ] **Step 5: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/markdown_converter.rb spec/lib/crawler/markdown_converter_spec.rb
Expected: `no offenses detected`. If rubocop reports `Metrics/ClassLength` on `MarkdownConverter` (limit 200 code lines; the file should land around 170), change the class line to `class MarkdownConverter # rubocop:disable Metrics/ClassLength` (same pattern as `Coordinator`, `lib/crawler/coordinator.rb:19`).

- [ ] **Step 6: Commit**

```bash
git add lib/crawler/markdown_converter.rb spec/lib/crawler/markdown_converter_spec.rb
git commit -m "feat(markdown): add converter transport with polling, retry, health check and stats"
```

---

### Task 5: Coordinator hook, `on_failure: skip`, health check at crawl start, stats line

**Files:**
- Modify: `lib/crawler/coordinator.rb:400-404` (content branch of `process_crawl_result`) and add a private helper before `output_crawl_result` (line 529)
- Modify: `lib/crawler/api/crawl.rb:83-111` (`start!`) and private methods after `print_final_crawl_status` (line 238)
- Modify: `lib/errors.rb`
- Test: `spec/lib/crawler/coordinator_spec.rb` (inside `describe '#process_crawl_result'`, lines 162-444), `spec/lib/crawler/api/crawl_spec.rb`

**Interfaces:**
- Consumes: `config.markdown_converter.convert!(crawl_result)` → `:converted|:skipped|:failed`, `#skip_on_failure?`, `#enabled?`, `#healthy?`, `#stats` (Tasks 1, 4); `sink.failure(message)` → `{ outcome: :failure, message: }` (`lib/crawler/output_sink/base.rb:62`); `config.markdown_conversion[:base_url]`.
- Produces:
  - `Errors::MarkdownConverterUnavailableError < StandardError` (`lib/errors.rb`).
  - `Coordinator#convert_and_output_crawl_result(crawl_task, crawl_result)` (private) → outcome hash from the sink, or `sink.failure("Markdown conversion failed for #{url} and on_failure is 'skip'; document not ingested")`.
  - `Crawl#start!` raises/handles `Errors::MarkdownConverterUnavailableError` before `coordinator.run_crawl!`; outcome `:failure` with message `Markdown converter at <base_url> is not healthy (GET /api/v1/health did not return 200); aborting the crawl so the index is not degraded to plain text`.
  - Log line at crawl end (when enabled): `system_logger.info("Markdown conversions: converted=N failed=N")`.

- [ ] **Step 1: Write the failing coordinator tests**

In `spec/lib/crawler/coordinator_spec.rb`, add these contexts inside `describe '#process_crawl_result' do`, right before its closing `end` (after the `'when crawl result is an error'` context, line 443):

```ruby
    context 'when markdown conversion is disabled (default)' do
      it 'calls the converter but leaves the crawl result untouched and writes it to the sink' do
        # crawl_result is a strict double: any message outside the ones declared above raises
        expect(crawl_config.markdown_converter).to receive(:convert!).with(crawl_result).and_call_original
        expect(crawl.sink).to receive(:write).with(crawl_result).and_call_original
        process_crawl_result
      end
    end

    context 'when markdown conversion is enabled' do
      let(:on_failure) { 'text' }
      let(:conversion_result) { :converted }
      let(:crawl_configuration) do
        super().merge(
          output_sink: :mock,
          markdown_conversion: { enabled: true, base_url: 'http://converter.test', on_failure: }
        )
      end
      let(:converter) { crawl_config.markdown_converter }

      before do
        allow(converter).to receive(:convert!).and_return(conversion_result)
      end

      it 'converts the result exactly once before writing it to the sink' do
        expect(converter).to receive(:convert!).with(crawl_result).once.ordered.and_return(:converted)
        expect(crawl.sink).to receive(:write).with(crawl_result).ordered.and_call_original
        process_crawl_result
      end

      context 'when conversion fails and on_failure is text' do
        let(:conversion_result) { :failed }

        it 'still writes the result and reports success' do
          expect(crawl.sink).to receive(:write).with(crawl_result).and_call_original
          expect(events).to receive(:url_extracted).with(
            hash_including(url: crawl_result.url, outcome: :success, message: 'Successfully ingested crawl result')
          )
          coordinator.send(:process_crawl_result, crawl_task, crawl_result)
        end
      end

      context 'when conversion fails and on_failure is skip' do
        let(:on_failure) { 'skip' }
        let(:conversion_result) { :failed }
        let(:skip_message) do
          "Markdown conversion failed for http://example.com and on_failure is 'skip'; document not ingested"
        end

        it 'does not write the result and reports a failure outcome' do
          expect(crawl.sink).not_to receive(:write)
          expect(system_logger).to receive(:warn).with(skip_message)
          expect(events).to receive(:url_extracted).with(
            hash_including(url: crawl_result.url, type: :allowed, outcome: :failure, message: skip_message)
          )
          coordinator.send(:process_crawl_result, crawl_task, crawl_result)
        end
      end

      context 'when conversion is skipped (unsupported MIME type) and on_failure is skip' do
        let(:on_failure) { 'skip' }
        let(:conversion_result) { :skipped }

        it 'writes the result normally' do
          expect(crawl.sink).to receive(:write).with(crawl_result).and_call_original
          process_crawl_result
        end
      end

      context 'when the crawl result is a redirect' do
        let(:crawl_result) do
          double(
            :crawl_result,
            url:,
            redirect_chain: [],
            location: Crawler::Data::URL.parse('http://example.com/redirected'),
            error?: false,
            redirect?: true
          )
        end

        it 'does not call the converter' do
          allow(coordinator).to receive(:add_urls_to_backlog)
          expect(converter).not_to receive(:convert!)
          process_crawl_result
        end
      end

      context 'when the rule engine denies the result' do
        let(:rule_engine) do
          double(
            :rule_engine,
            output_crawl_result_outcome: double(
              :output_crawl_result_outcome, denied?: true, deny_reason: 'blocked', message: 'nope'
            ),
            discover_url_outcome: double(:discover_url_outcome, denied?: false)
          )
        end
        let(:crawl_result) { double(:crawl_result, url:, error?: true, redirect?: false) }

        it 'does not call the converter' do
          expect(converter).not_to receive(:convert!)
          process_crawl_result
        end
      end
    end
```

Note: the `output_sink: :mock` override matters — the top-level `crawl_configuration` leaves `output_sink` at its `:elasticsearch` default, and Task 1's bulk-size validation would reject the default 5 MB `max_body_size` when markdown is enabled.

- [ ] **Step 2: Write the failing crawl tests**

In `spec/lib/crawler/api/crawl_spec.rb`, add right after the `it 'has a output sink' do ... end` example (line 78):

```ruby
  it 'does not check converter health when markdown conversion is disabled' do
    expect(crawl_config.markdown_converter).not_to receive(:healthy?)
    subject.start!
  end

  context 'with markdown conversion enabled' do
    let(:crawl_config) do
      Crawler::API::Config.new(
        domains: [{ url: }],
        output_sink: :mock,
        results_collection: ResultsCollection.new,
        markdown_conversion: { enabled: true, base_url: 'http://converter.test' }
      )
    end
    let(:converter) { crawl_config.markdown_converter }
    let(:system_logger) { crawl_config.system_logger }

    before do
      allow(converter).to receive(:convert!).and_return(:converted)
      allow(system_logger).to receive(:info).and_call_original
      allow(system_logger).to receive(:error).and_call_original
    end

    context 'when the converter is healthy' do
      before { allow(converter).to receive(:healthy?).and_return(true) }

      it 'checks health once, runs the crawl and logs the conversion stats' do
        subject.start!

        expect(converter).to have_received(:healthy?).once
        expect(subject.outcome).to eq(:success)
        expect(system_logger).to have_received(:info).with('Markdown conversions: converted=0 failed=0')
      end
    end

    context 'when the converter is unhealthy' do
      before { allow(converter).to receive(:healthy?).and_return(false) }

      it 'aborts the crawl with a clear failure outcome before crawling anything' do
        expect(subject.coordinator).not_to receive(:run_crawl!)

        subject.start!

        expect(subject.outcome).to eq(:failure)
        expect(subject.outcome_message).to eq(
          'Markdown converter at http://converter.test is not healthy (GET /api/v1/health did not return 200); ' \
          'aborting the crawl so the index is not degraded to plain text'
        )
        expect(system_logger).to have_received(:error).with(/is not healthy/)
        expect(subject.config.event_logger.mock_events).to include(
          hash_including('event.action' => 'crawl-end', 'event.outcome' => 'failure')
        )
      end
    end
  end
```

- [ ] **Step 3: Run both specs to verify the new examples fail**

Run (see Global Constraints test command): rspec spec/lib/crawler/coordinator_spec.rb spec/lib/crawler/api/crawl_spec.rb
Expected: the `markdown conversion is enabled` coordinator examples FAIL (`convert!` never received / sink written on skip); the unhealthy crawl example FAILS (outcome `:success`); the healthy example FAILS on the missing stats log line. Pre-existing examples PASS.

- [ ] **Step 4: Implement**

(a) `lib/errors.rb` — add at the end of `class Errors` (after `ExitIfUnableToCreateIndex`):

```ruby

  # Raised at crawl start when markdown conversion is enabled but the converter's health endpoint
  # does not answer 200. The crawl aborts instead of silently degrading the whole index to plain text.
  class MarkdownConverterUnavailableError < StandardError; end
```

(b) `lib/crawler/coordinator.rb` — replace lines 400-404:

```ruby
      elsif crawl_task.content?
        crawl_task_progress(crawl_task, 'ingesting the result')
        outcome = output_crawl_result(crawl_result)
        extracted_event.merge!(outcome)
      end
```

with:

```ruby
      elsif crawl_task.content?
        outcome = convert_and_output_crawl_result(crawl_task, crawl_result)
        extracted_event.merge!(outcome)
      end
```

and add this private method right before `# Outputs the results of a single URL processing to an output module configured for the crawl` (line 528):

```ruby
    # Converts the crawl result to markdown (no-op when disabled) and then sends it to the output sink.
    # Runs on the crawl-task thread, before the sink, because the Elasticsearch sink holds its queue lock
    # while mapping documents and a slow conversion there would serialise every thread.
    def convert_and_output_crawl_result(crawl_task, crawl_result)
      crawl_task_progress(crawl_task, 'converting to markdown') if config.markdown_converter.enabled?
      conversion = config.markdown_converter.convert!(crawl_result)

      if conversion == :failed && config.markdown_converter.skip_on_failure?
        message = "Markdown conversion failed for #{crawl_result.url} and on_failure is 'skip'; document not ingested"
        system_logger.warn(message)
        return sink.failure(message)
      end

      crawl_task_progress(crawl_task, 'ingesting the result')
      output_crawl_result(crawl_result)
    end
```

(c) `lib/crawler/api/crawl.rb`:

Add after `require 'concurrent'` (line 10):

```ruby

require_dependency File.join(__dir__, '..', '..', 'errors')
```

Replace `start!` (lines 83-111) with:

```ruby
      def start! # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        events.crawl_start(
          url_queue_items: crawl_queue.length,
          seen_urls: seen_urls.count
        )
        verify_markdown_converter!
        ingestion_stats = coordinator.run_crawl!

        record_overall_outcome(coordinator.crawl_results)
      rescue Errors::MarkdownConverterUnavailableError => e
        system_logger.error(e.message)
        record_outcome(outcome: :failure, message: e.message)
      rescue StandardError => e
        log_exception(e, 'Unexpected error while running the crawl')
        record_outcome(
          outcome: :failure,
          message: 'Unexpected error while running the crawl, check system logs for details'
        )
      ensure
        # Execute hooks to either save the state or clean up after the crawl.
        # The actual cleanup and persistence implementation depends on specific UrlQueue and SeenUrls classes
        if allow_resume?
          system_logger.info('Not removing the crawl queue to allow the crawl to resume later')
          crawl_queue.save
          seen_urls.save
        else
          system_logger.info('Releasing resources used by the crawl...')
          crawl_queue.delete
          seen_urls.clear
          print_final_crawl_status
          log_markdown_conversion_stats
          print_crawl_ingestion_results(ingestion_stats) if config.output_sink.to_s == 'elasticsearch'
        end
      end
```

Add these private methods right after `print_final_crawl_status` (after line 238):

```ruby
      # Fail fast when the converter is down: a silent outage would degrade the whole index to plain text.
      # Calling config.markdown_converter here also warms the `@markdown_converter ||=` memo on the main
      # thread before the task pool starts (the memo is not thread-safe); keep that call unconditional so a
      # future `return unless enabled?` guard cannot leave the pool threads racing to build separate
      # instances and splitting the stats across them.
      def verify_markdown_converter!
        converter = config.markdown_converter
        return unless converter.enabled?
        return if converter.healthy?

        raise Errors::MarkdownConverterUnavailableError, <<~MSG.squish
          Markdown converter at #{config.markdown_conversion[:base_url]} is not healthy
          (GET /api/v1/health did not return 200); aborting the crawl so the index is not degraded to plain text
        MSG
      end

      def log_markdown_conversion_stats
        return unless config.markdown_converter.enabled?

        stats = config.markdown_converter.stats
        system_logger.info("Markdown conversions: converted=#{stats[:converted]} failed=#{stats[:failed]}")
      end
```

- [ ] **Step 5: Run both specs to verify they pass**

Run (see Global Constraints test command): rspec spec/lib/crawler/coordinator_spec.rb spec/lib/crawler/api/crawl_spec.rb
Expected: all PASS, including every pre-existing `#process_crawl_result` example that uses strict doubles.

Tester note (before merge, outside the unit suite): `bin/crawler` sets `https.protocols=SSLv3` JVM-wide, which breaks JSSE-based HTTP clients. The unit suite cannot prove Net::HTTP (jruby-openssl) is unaffected, so run one real `bin/crawler crawl <config>` with `markdown_conversion.enabled: true` against the HTTPS converter (or a one-off `config.markdown_converter.healthy?` call inside the `bin/crawler` runtime) and confirm the health check passes and at least one document lands with `body_format: markdown`.

- [ ] **Step 6: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/coordinator.rb lib/crawler/api/crawl.rb lib/errors.rb spec/lib/crawler/coordinator_spec.rb spec/lib/crawler/api/crawl_spec.rb
Expected: `no offenses detected` (`Coordinator` already disables the Metrics cops file-wide at line 16; `start!` already disables AbcSize/MethodLength).

- [ ] **Step 7: Commit**

```bash
git add lib/crawler/coordinator.rb lib/crawler/api/crawl.rb lib/errors.rb spec/lib/crawler/coordinator_spec.rb spec/lib/crawler/api/crawl_spec.rb
git commit -m "feat(markdown): convert crawl results before ingestion, fail fast on unhealthy converter"
```

---

### Task 6: DocumentMapper — markdown body, `body_format`, `content_hash`, no `_attachment` with markdown

**Files:**
- Modify: `lib/crawler/document_mapper.rb:68-87`
- Test: `spec/lib/crawler/document_mapper_spec.rb`

**Interfaces:**
- Consumes: `Success#markdown` (Task 2), `ContentExtractableFile#content_hash` (`lib/crawler/data/crawl_result/content_extractable_file.rb:29`), `Digest::SHA1`.
- Produces: HTML docs gain `body_format: 'markdown'|'text'` and `content_hash: <sha1 hex of crawl_result.content>`; `body` is the markdown when present. Binary docs gain `body_format`, `content_hash: crawl_result.content_hash`; with markdown → `body: markdown` and NO `_attachment`; without → unchanged (`_attachment` kept, `body_format: 'text'`).

- [ ] **Step 1: Update the expected results and add the failing markdown examples**

In `spec/lib/crawler/document_mapper_spec.rb`:

(a) HTML `expected_result` (lines 52-71): add two entries after `body: crawl_result.document_body,`:

```ruby
          body: crawl_result.document_body,
          body_format: 'text',
          content_hash: Digest::SHA1.hexdigest(content),
```

(b) Binary `expected_result` (lines 179-194): add after `content_type:,`:

```ruby
          content_type:,
          content_hash: crawl_result.content_hash,
          body_format: 'text',
```

(c) Add inside `context 'when crawl result is HTML' do`, right after the `'creates a doc with HTML fields'` example (line 77):

```ruby
      context 'when the crawl result carries markdown' do
        let(:markdown) { "# A website!\n\nChosen 1\n\n- Chosen 2" }
        let(:expected_result_markdown) { expected_result.merge(body: markdown, body_format: 'markdown') }

        before { crawl_result.markdown = markdown }

        it 'uses the markdown as the body and marks the format' do
          result = subject.create_doc(crawl_result)

          expect(result).to eq(expected_result_markdown)
        end
      end
```

(d) Add inside `context 'when crawl result is a binary file' do`, right after the `'creates a doc with binary file fields'` example (line 200):

```ruby
      context 'when the crawl result carries markdown' do
        let(:markdown) { '# A PDF for ants' }
        let(:expected_result_markdown) do
          expected_result.except(:_attachment).merge(body: markdown, body_format: 'markdown')
        end

        before { crawl_result.markdown = markdown }

        it 'uses the markdown as the body and omits the attachment' do
          result = subject.create_doc(crawl_result)

          expect(result).to eq(expected_result_markdown)
          expect(result).not_to have_key(:_attachment)
        end
      end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run (see Global Constraints test command): rspec spec/lib/crawler/document_mapper_spec.rb
Expected: every `create_doc` example FAILS on the missing `body_format`/`content_hash` keys.

- [ ] **Step 3: Implement**

In `lib/crawler/document_mapper.rb`, add `require 'digest'` after `# frozen_string_literal: true` (line 7, leave a blank line between), then replace `html_fields` and `binary_file_fields` (lines 68-87) with:

```ruby
    def html_fields(crawl_result) # rubocop:disable Metrics/AbcSize
      remove_empty_values(
        title: crawl_result.document_title(limit: config.max_title_size),
        body: html_body(crawl_result),
        body_format: body_format(crawl_result),
        content_hash: Digest::SHA1.hexdigest(crawl_result.content.to_s), # content may be nil (response.rb:47)
        meta_keywords: crawl_result.meta_keywords(limit: config.max_keywords_size),
        meta_description: crawl_result.meta_description(limit: config.max_description_size),
        links: crawl_result.links(limit: config.max_indexed_links_count),
        headings: crawl_result.headings(limit: config.max_headings_count),
        full_html: crawl_result.full_html(enabled: config.full_html_extraction_enabled)
      )
    end

    # With markdown present the ingest attachment processor is not needed, so `_attachment` is omitted
    def binary_file_fields(crawl_result)
      fields = {
        file_name: crawl_result.file_name,
        content_length: crawl_result.content_length,
        content_type: crawl_result.content_type,
        content_hash: crawl_result.content_hash,
        body_format: body_format(crawl_result)
      }
      if crawl_result.markdown
        fields[:body] = crawl_result.markdown
      else
        fields[:_attachment] = crawl_result.base64_encoded_content
      end
      remove_empty_values(fields)
    end

    def html_body(crawl_result)
      return crawl_result.markdown if crawl_result.markdown

      crawl_result.document_body(limit: config.max_body_size, exclude_tags: config.exclude_tags)
    end

    def body_format(crawl_result)
      crawl_result.markdown ? 'markdown' : 'text'
    end
```

- [ ] **Step 4: Run the spec to verify it passes**

Run (see Global Constraints test command): rspec spec/lib/crawler/document_mapper_spec.rb spec/lib/crawler/output_sink/file_spec.rb spec/lib/crawler/output_sink/elasticsearch_spec.rb
Expected: all PASS (the sink specs use `hash_including`, so the two new keys do not break them).

- [ ] **Step 5: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/document_mapper.rb spec/lib/crawler/document_mapper_spec.rb
Expected: `no offenses detected`.

- [ ] **Step 6: Commit**

```bash
git add lib/crawler/document_mapper.rb spec/lib/crawler/document_mapper_spec.rb
git commit -m "feat(markdown): map markdown into body with body_format and content_hash"
```

---

### Task 7: Elasticsearch sink `_reduce_whitespace` default + warning; console sink prints markdown

**Files:**
- Modify: `lib/crawler/output_sink/elasticsearch.rb:228-232` (`pipeline_params`, top of `private`)
- Modify: `lib/crawler/output_sink/console.rb:14-25`
- Test: `spec/lib/crawler/output_sink/elasticsearch_spec.rb` (inside `describe '#initialize'`, after the `'when elasticsearch.pipeline_params are changed'` context, line ~358), `spec/lib/crawler/output_sink/console_spec.rb` (create)

**Interfaces:**
- Consumes: `config.markdown_conversion[:enabled]` (Task 1), `Success#markdown` (Task 2).
- Produces: `OutputSink::Elasticsearch#pipeline_params` → `DEFAULT_PIPELINE_PARAMS` merged with user params, except `_reduce_whitespace` defaults to `false` when markdown conversion is enabled; explicit `_reduce_whitespace: true` with markdown enabled is honoured and logs one `system_logger.warn`. `OutputSink::Console#write` prints `crawl_result.markdown` when present.

- [ ] **Step 1: Write the failing tests**

In `spec/lib/crawler/output_sink/elasticsearch_spec.rb`, add right after the `'when elasticsearch.pipeline_params are changed'` context (its closing `end`, before `context 'when elasticsearch.pipeline_enabled is false'` that checks `overrides the specified default params`):

```ruby
    context 'when markdown conversion is enabled' do
      let(:pipeline_params) { {} }
      let(:config) do
        Crawler::API::Config.new(
          domains:,
          output_sink: 'elasticsearch',
          output_index: index_name,
          max_body_size: 500_000,
          elasticsearch: {
            host: 'http://localhost',
            port: 1234,
            api_key: 'key',
            pipeline_params:
          },
          markdown_conversion: { enabled: true, base_url: 'http://converter.test' }
        )
      end

      it 'defaults _reduce_whitespace to false and keeps binary extraction on' do
        expect(subject.pipeline_params).to eq(
          _reduce_whitespace: false,
          _run_ml_inference: true,
          _extract_binary_content: true
        )
        expect(system_logger).not_to have_received(:warn)
      end

      context 'when _reduce_whitespace is explicitly true' do
        let(:pipeline_params) { { _reduce_whitespace: true } }

        it 'honours the setting and warns that markdown will be mangled' do
          expect(subject.pipeline_params[:_reduce_whitespace]).to be(true)
          expect(system_logger).to have_received(:warn).with(
            'elasticsearch.pipeline_params._reduce_whitespace is true while markdown_conversion is enabled; ' \
            'the ingest pipeline will collapse whitespace and break markdown formatting in `body`'
          ).once
        end
      end
    end
```

Create `spec/lib/crawler/output_sink/console_spec.rb`:

```ruby
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

RSpec.describe(Crawler::OutputSink::Console) do
  let(:config) { Crawler::API::Config.new(domains: [{ url: 'http://example.com' }], output_sink: :console) }
  let(:sink) { described_class.new(config) }

  it 'prints the raw content of HTML results' do
    result = FactoryBot.build(:html_crawl_result, content: '<p>raw html</p>')
    expect { sink.write(result) }.to output(%r{<p>raw html</p>}).to_stdout
  end

  it 'prints a placeholder instead of binary content' do
    result = FactoryBot.build(:content_extractable_file_crawl_result)
    expect { sink.write(result) }.to output(%r{Content extractable file \(content type: application/pdf}).to_stdout
  end

  it 'prints the markdown when the result has been converted' do
    result = FactoryBot.build(:content_extractable_file_crawl_result)
    result.markdown = '# From the converter'
    expect { sink.write(result) }.to output(/# From the converter/).to_stdout
    expect { sink.write(result) }.not_to output(/Content extractable file/).to_stdout
  end

  it 'returns a success outcome' do
    result = FactoryBot.build(:html_crawl_result)
    outcome = nil
    expect { outcome = sink.write(result) }.to output.to_stdout
    expect(outcome).to eq(outcome: :success, message: 'Successfully ingested crawl result')
  end
end
```

- [ ] **Step 2: Run both specs to verify they fail**

Run (see Global Constraints test command): rspec spec/lib/crawler/output_sink/elasticsearch_spec.rb spec/lib/crawler/output_sink/console_spec.rb
Expected: the two new ES examples FAIL (`_reduce_whitespace` is `true`, no warning); the console markdown example FAILS (placeholder printed instead of markdown).

- [ ] **Step 3: Implement**

`lib/crawler/output_sink/elasticsearch.rb` — replace `pipeline_params` (lines 228-230) with:

```ruby
      def pipeline_params
        @pipeline_params ||= default_pipeline_params.merge(es_config[:pipeline_params] || {}).tap do |params|
          warn_about_whitespace_reduction(params)
        end
      end
```

and add these right after `private` (line 232):

```ruby
      def markdown_conversion_enabled?
        config.markdown_conversion[:enabled] == true
      end

      # The default ingest pipeline collapses whitespace in `body` (\s+ -> ' '), which destroys markdown
      def default_pipeline_params
        return DEFAULT_PIPELINE_PARAMS unless markdown_conversion_enabled?

        DEFAULT_PIPELINE_PARAMS.merge(_reduce_whitespace: false)
      end

      def warn_about_whitespace_reduction(params)
        return unless markdown_conversion_enabled? && params[:_reduce_whitespace] == true

        system_logger.warn(
          'elasticsearch.pipeline_params._reduce_whitespace is true while markdown_conversion is enabled; ' \
          'the ingest pipeline will collapse whitespace and break markdown formatting in `body`'
        )
      end
```

`lib/crawler/output_sink/console.rb` — replace `write` (lines 14-25) with:

```ruby
      def write(crawl_result)
        puts "# #{crawl_result.id}, #{crawl_result.url}, #{crawl_result.status_code}"

        if crawl_result.respond_to?(:markdown) && crawl_result.markdown
          puts crawl_result.markdown
        elsif crawl_result.content_extractable_file?
          puts "** [Content extractable file (content type: #{crawl_result.content_type}, " \
               "content length: #{crawl_result.content.bytesize})] **"
        else
          puts crawl_result.content
        end

        success
      end
```

- [ ] **Step 4: Run both specs to verify they pass**

Run (see Global Constraints test command): rspec spec/lib/crawler/output_sink/elasticsearch_spec.rb spec/lib/crawler/output_sink/console_spec.rb
Expected: all PASS.

- [ ] **Step 5: Lint**

Run (see Global Constraints test command): rubocop lib/crawler/output_sink/elasticsearch.rb lib/crawler/output_sink/console.rb spec/lib/crawler/output_sink/elasticsearch_spec.rb spec/lib/crawler/output_sink/console_spec.rb
Expected: `no offenses detected`.

- [ ] **Step 6: Commit**

```bash
git add lib/crawler/output_sink/elasticsearch.rb lib/crawler/output_sink/console.rb spec/lib/crawler/output_sink/elasticsearch_spec.rb spec/lib/crawler/output_sink/console_spec.rb
git commit -m "feat(markdown): keep markdown whitespace in the ES pipeline and print markdown on the console sink"
```

---

### Task 8: Integration spec — Faux site + WebMock-stubbed converter

**Files:**
- Modify: `spec/support/faux/faux_crawl.rb:46-73` (options) and `:152-176` (`configure_crawl`)
- Test: `spec/integration/markdown_conversion_spec.rb` (create)

**Interfaces:**
- Consumes: everything from Tasks 1-7; `FauxCrawl.run(site, options)` returning a `ResultsCollection` (`results.crawl_config`, `results.crawl`); `Crawler::DocumentMapper#create_doc`.
- Produces: `FauxCrawl` accepts `markdown_conversion: Hash` and forwards it verbatim into `Crawler::API::Config.new`. (No new production interfaces.)

Why the mock sink: `FauxCrawl` hard-codes `output_sink: :mock`, which collects `CrawlResult` objects. The spec's "file-sink docs" assertion is made equivalently by running each collected result through `results.crawl_config.document_mapper.create_doc` — the same mapper every real sink calls via `OutputSink::Base#to_doc`.

- [ ] **Step 1: Extend FauxCrawl to forward `markdown_conversion`**

In `spec/support/faux/faux_crawl.rb` (excluded from rubocop):

(a) Add `:markdown_conversion` to the `attr_reader` list (lines 46-48):

```ruby
  attr_reader :options, :sites, :site_containers, :timeouts, :content_extraction, :default_encoding, :crawl_id,
              :url_queue, :auth, :user_agent, :url, :seed_urls, :sitemap_urls, :domain_allowlist, :results,
              :expect_success, :markdown_conversion
```

(b) In `initialize`, after `@content_extraction = ...` (line 64), add:

```ruby
    @markdown_conversion = options[:markdown_conversion]
```

(c) In `configure_crawl`, after `config[:default_encoding] = default_encoding if default_encoding` (line 175), add:

```ruby
    config[:markdown_conversion] = markdown_conversion if markdown_conversion
```

- [ ] **Step 2: Write the failing integration spec**

Create `spec/integration/markdown_conversion_spec.rb`:

```ruby
#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

RSpec.describe 'Markdown conversion' do
  let(:converter_url) { 'http://converter.test' }
  let(:health_url) { "#{converter_url}/api/v1/health" }
  let(:upload_url) { "#{converter_url}/api/v1/convert/upload?wait=10" }
  let(:json_headers) { { 'Content-Type' => 'application/json' } }
  let(:markdown_conversion) do
    { enabled: true, base_url: converter_url, wait_seconds: 10, poll_interval: 0.01, timeout: 5 }
  end

  let(:site) do
    Faux.site do
      page '/' do
        body do
          text { '<h1>Home</h1>' }
          link_to '/pdf'
          text { '<footer>site footer</footer>' }
        end
      end

      page '/pdf' do
        headers 'Content-Type' => 'application/pdf'
      end
    end
  end

  def done_json(markdown)
    { job_id: 'job', status: 'done', status_url: '/api/v1/jobs/job', source_name: 'x', markdown: }.to_json
  end

  def run_crawl
    FauxCrawl.run(
      site,
      content_extraction: { enabled: true, mime_types: %w[application/pdf] },
      markdown_conversion:
    )
  end

  # Same mapping every real sink performs through OutputSink::Base#to_doc
  def docs_by_url(results)
    mapper = results.crawl_config.document_mapper
    results.each_with_object({}) { |result, docs| docs[result.url.to_s] = mapper.create_doc(result) }
  end

  before do
    stub_request(:get, health_url).to_return(status: 200, body: '{"status":"ok"}', headers: json_headers)
  end

  context 'when the converter is healthy' do
    before do
      stub_request(:post, upload_url)
        .with { |request| request.body.include?('.html"') }
        .to_return(status: 200, body: done_json("# Home\n\nsite footer"), headers: json_headers)
      stub_request(:post, upload_url)
        .with { |request| request.body.include?('.pdf"') }
        .to_return(status: 200, body: done_json('# PDF document'), headers: json_headers)
    end

    it 'stores markdown bodies for the HTML page and the PDF' do
      results = run_crawl

      expect(results).to have_only_these_results [
        mock_response(url: 'http://127.0.0.1:9393/', status_code: 200),
        mock_response(url: 'http://127.0.0.1:9393/pdf', status_code: 200)
      ]

      docs = docs_by_url(results)
      expect(docs['http://127.0.0.1:9393/']).to include(body: "# Home\n\nsite footer", body_format: 'markdown')
      expect(docs['http://127.0.0.1:9393/']).to have_key(:content_hash)
      expect(docs['http://127.0.0.1:9393/pdf']).to include(body: '# PDF document', body_format: 'markdown')
      expect(docs['http://127.0.0.1:9393/pdf']).not_to have_key(:_attachment)
      expect(results.crawl_config.markdown_converter.stats).to eq(converted: 2, failed: 0)
      expect(a_request(:get, health_url)).to have_been_made.once
    end
  end

  context 'when the converter keeps answering 5xx' do
    before do
      stub_request(:post, upload_url).to_return(status: 503, body: 'upstream unavailable')
    end

    it 'falls back to text extraction and keeps the binary attachment' do
      results = run_crawl

      docs = docs_by_url(results)
      expect(docs['http://127.0.0.1:9393/']).to include(body_format: 'text')
      expect(docs['http://127.0.0.1:9393/'][:body]).to include('Home')
      expect(docs['http://127.0.0.1:9393/pdf']).to include(body_format: 'text')
      expect(docs['http://127.0.0.1:9393/pdf']).to have_key(:_attachment)
      # two documents, each tried twice (initial attempt + one retry)
      expect(a_request(:post, upload_url)).to have_been_made.times(4)
      expect(results.crawl_config.markdown_converter.stats).to eq(converted: 0, failed: 2)
    end
  end

  context 'when the converter health check fails' do
    before do
      stub_request(:get, health_url).to_return(status: 503)
    end

    it 'aborts the crawl before fetching anything' do
      expect { run_crawl }.to raise_error(RuntimeError, /Test Crawl failed!.*is not healthy/)
      expect(a_request(:post, upload_url)).not_to have_been_made
    end
  end
end
```

- [ ] **Step 3: Run the integration spec**

Run (see Global Constraints test command): rspec spec/integration/markdown_conversion_spec.rb
Expected: all three examples PASS on the first run (Tasks 1-7 are complete). The 5xx scenario takes ~2 s of real retry sleeps. If the first run fails instead, treat it as a real integration bug: read the crawl system log in the rspec output, fix the production code (not the spec), and re-run.

Tester note: `WebMock::NetConnectNotAllowedError` inherits from `Exception`, not `StandardError`, so a stub mismatch (wrong query string, unexpected filename, missing health stub) is not caught by `convert!` — it kills the crawl-task pool thread and surfaces only as a `have_only_these_results` count mismatch or a missing doc. When an example fails, search the rspec output for `NetConnectNotAllowedError` first.

Then run the existing integration spec to make sure `FauxCrawl` still works without the new option:

Run (see Global Constraints test command): rspec spec/integration/content_extraction_spec.rb
Expected: PASS.

- [ ] **Step 4: Lint**

Run (see Global Constraints test command): rubocop spec/integration/markdown_conversion_spec.rb
Expected: `no offenses detected` (`spec/support/faux/**/*` is excluded in `.rubocop.yml`).

- [ ] **Step 5: Run the full suite once**

Run (see Global Constraints test command): rspec (no arguments, whole suite)
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add spec/support/faux/faux_crawl.rb spec/integration/markdown_conversion_spec.rb
git commit -m "test(markdown): add end-to-end crawl spec with a stubbed converter"
```

---

### Task 9: Configuration example and feature documentation

**Files:**
- Modify: `config/crawler.yml.example:204-213` (binary content block) and append a new block after the `elasticsearch` section (after line 267, before the sink-lock settings)
- Create: `docs/features/MARKDOWN_CONVERSION.md`
- Modify: `README.md:241` (feature list)

**Interfaces:**
- Consumes: the config shape from Task 1, failure semantics from Tasks 5-7.
- Produces: documentation only.

- [ ] **Step 1: Update `config/crawler.yml.example`**

(a) In the binary content extraction MIME list (lines 208-213), add the spreadsheet type so the list reads:

```yaml
#binary_content_extraction_mime_types:
#  - application/pdf
#  - application/msword
#  - application/vnd.openxmlformats-officedocument.wordprocessingml.document
#  - application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
#  - application/vnd.ms-powerpoint
#  - application/vnd.openxmlformats-officedocument.presentationml.presentation
```

(b) Insert this block right after the `elasticsearch:` section (after line 267 `#    max_size_bytes: 1_048_576`) and before `## The interval in seconds to wait before retrying to acquire the sink lock.`:

```yaml

## ------------------------------- Markdown Conversion -------------------------
#
## Convert crawled HTML pages and PDF/DOCX/XLSX/PPTX files to Markdown through the shared
##   convert-markdown service before indexing. `body` then holds Markdown and `body_format`
##   is set to `markdown`; documents that cannot be converted fall back to plain text
##   (`body_format: text`). See docs/features/MARKDOWN_CONVERSION.md for details.
##   Binary files still need `binary_content_extraction_enabled` and their MIME types listed above.
#markdown_conversion:
#  enabled: false
#  base_url: https://convert-markdown.ifad.org   # required when enabled; http(s) only
#  wait_seconds: 10        # 0..60, how long the service may hold the upload request before answering
#  poll_interval: 2        # seconds between status polls; backs off x1.5 up to 5s
#  timeout: 900            # hard per-document deadline (submit + polling), in seconds
#  on_failure: text        # text: index the plain-text fallback | skip: do not index the document
#  ca_file:                # optional PEM bundle used to verify the converter's TLS certificate
#
## NOTE: when enabled with the elasticsearch sink, `max_body_size` must be smaller than
##   `elasticsearch.bulk_api.max_size_bytes` (default 1_048_576), e.g. `max_body_size: 900_000`.
```

- [ ] **Step 2: Create `docs/features/MARKDOWN_CONVERSION.md`** (outer fence uses four backticks because the document itself contains ```yaml fences)

````markdown
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

At crawl start the crawler calls the health endpoint once. If it does not answer 200 the crawl aborts with
`Markdown converter at <base_url> is not healthy ...` instead of silently indexing the whole site as plain text.

## What gets indexed

| Document | Converted | Not converted (fallback) |
|---|---|---|
| HTML page | `body`: Markdown, `body_format: markdown` | `body`: extracted text, `body_format: text` |
| PDF / DOCX / XLSX / PPTX | `body`: Markdown, `body_format: markdown`, no `_attachment` | `_attachment` kept (Tika via the ingest pipeline), `body_format: text` |
| Other binary types (e.g. legacy `.doc`, `.ppt`) | never sent to the converter | unchanged behaviour |

Every document also gets `content_hash` (SHA-1 of the fetched bytes). `body_format` and `content_hash` are
reserved field names and cannot be overwritten by extraction rules.

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

The system log ends with `Markdown conversions: converted=N failed=N`.

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
- Converter calls go straight to `base_url`: they use neither the crawler's `http_proxy_*` settings nor the
  `HTTP_PROXY`/`HTTPS_PROXY` environment variables.
````

- [ ] **Step 3: Link the feature from the README**

In `README.md`, right after line 241 (`- [Binary content extraction](docs/features/BINARY_CONTENT_EXTRACTION.md) - Extract text from PDFs, DOCX files`), add:

```markdown
- [Markdown conversion](docs/features/MARKDOWN_CONVERSION.md) - Index HTML pages and office documents as Markdown through the shared convert-markdown service
```

- [ ] **Step 4: Verify the example config still loads and lint stays clean**

Run (see Global Constraints test command): rspec spec/lib/crawler/cli/ spec/lib/crawler/api/config_spec.rb
Expected: PASS (the CLI specs load YAML fixtures; the example file is comment-only so nothing changes at runtime, this just guards against a stray uncommented line).

Run (see Global Constraints test command): rubocop lib spec
Expected: `no offenses detected`.

- [ ] **Step 5: Commit**

```bash
git add config/crawler.yml.example docs/features/MARKDOWN_CONVERSION.md README.md
git commit -m "docs(markdown): document the markdown_conversion feature and config block"
```

---

## Self-review notes (already applied)

- **Spec coverage:** insertion point (Task 5), disabled-path double constraint (Tasks 3-5), config block + validation + factory (Task 1), MIME map / filename / Jsoup payload / binary payload (Task 3), net/http multipart transport, flow, retry rules, blank markdown, `limit_bytesize`, warn-never-raise, `healthy?`, stats (Task 4), `Success#markdown` + reserved names (Task 2), DocumentMapper (Task 6), ES `_reduce_whitespace` + console (Task 7), stats line + health check at start (Task 5), docs + yml example + xlsx MIME (Task 9), integration spec (Task 8). Every WebMock branch listed in the spec's test strategy has an example in Task 4.
- **Resolved ambiguities:** (1) the spec says `parsed_content_excluding_tags(config.exclude_tags)`, but that method takes an `Array` of tags while `config.exclude_tags` is a per-domain `Hash`, and `Jsoup#select('')` raises on an empty list — Task 3 mirrors `HTML#get_body_tag` (`html.rb:220-232`) instead. (2) `on_failure: skip` needs a branch the spec's 3-line diff does not show — Task 5 adds one small private helper rather than inlining it. (3) `FauxCrawl` only supports the `:mock` sink — Task 8 asserts on `DocumentMapper#create_doc` output of the collected results, which is what every real sink writes. (4) The retry deadline is measured per attempt (each attempt gets `timeout` from its own submit), so the worst case per document is `2 × timeout + 1 s`. (5) Enabling markdown with the ES sink and the default `max_body_size` (5 MB) is rejected by design (spec requires `max_body_size < bulk max_size_bytes`); every spec that enables markdown with the ES sink therefore sets `max_body_size: 500_000`, and specs that do not need ES use `output_sink: :mock`/`:console`. (6) Tech-lead review additions: `Net::HTTP.new(host, port, nil)` disables env proxying, the health check sends the `User-Agent`, a nil `markdown_conversion:` block means defaults, unparseable `base_url` raises `ArgumentError`, `content_hash` hashes `content.to_s`, and `crawl_task_progress('converting to markdown')` is only emitted when enabled.
- **Type consistency:** `convert!` returns `:converted|:skipped|:failed` (Tasks 4, 5, 8); `stats` returns `{ converted:, failed: }` (Tasks 1, 4, 5, 8); `skip_on_failure?` (Tasks 1, 5); `markdown_conversion` hash keys are identical in Tasks 1, 4, 7, 9; `Errors::MarkdownConverterUnavailableError` (Task 5 only); `raise_on_http_error!(response, polling)` is only called from `parse_job` (Task 4); DocumentMapper field names `body_format`, `content_hash` match `Constants::RESERVED_FIELD_NAMES` (Tasks 2, 6, 8, 9).
