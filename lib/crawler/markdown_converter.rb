#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

require 'concurrent/atomic/atomic_fixnum'
require 'json'
require 'net/http'
require 'securerandom'
require 'uri'

module Crawler
  # Converts crawled HTML pages and binary documents (PDF, DOCX, XLSX, PPTX) to Markdown
  # through the shared convert-markdown service. See docs/features/MARKDOWN_CONVERSION.md.
  class MarkdownConverter # rubocop:disable Metrics/ClassLength
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
    # Consecutive failures that open the circuit breaker, and how long it stays open before re-probing
    CIRCUIT_BREAKER_THRESHOLD = 20
    CIRCUIT_BREAKER_COOLDOWN = 60

    attr_reader :config, :settings

    delegate :system_logger, to: :config

    def initialize(config)
      @config = config
      @settings = config.markdown_conversion
      @converted = Concurrent::AtomicFixnum.new(0)
      @failed = Concurrent::AtomicFixnum.new(0)
      @consecutive_failures = Concurrent::AtomicFixnum.new(0)
      @circuit_open = false
      @circuit_retry_at = 0.0
      @circuit_mutex = Mutex.new
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

    # Returns :converted | :skipped | :failed and never raises.
    # On success sets crawl_result.markdown (limited to config.max_body_size bytes).
    # While the circuit breaker is open no HTTP call is made at all: the result is :failed, so
    # on_failure decides as usual (text -> plain-text body, skip -> document not ingested).
    def convert!(crawl_result)
      return :skipped unless convertible?(crawl_result)
      return fail_fast_on_open_circuit if circuit_open?

      markdown = with_one_retry(crawl_result) { run_conversion(crawl_result) }
      crawl_result.markdown = Crawler::ContentEngine::Utils.limit_bytesize(markdown, config.max_body_size)
      @converted.increment
      @consecutive_failures.value = 0
      :converted
    rescue StandardError => e
      system_logger.warn("Markdown conversion failed for #{crawl_result.url}: #{e.message}")
      record_conversion_failure
    end

    # GET /api/v1/health with a short timeout; called at crawl start and when re-probing the circuit
    # breaker. Retried once after RETRY_DELAY so a single blip does not abort a whole crawl.
    def healthy?
      return true if health_check_ok?

      sleep(RETRY_DELAY)
      health_check_ok?
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

    private

    def health_check_ok?
      uri = URI.parse("#{settings[:base_url]}#{HEALTH_PATH}")
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = config.user_agent
      response = http_client(uri, open_timeout: HEALTH_TIMEOUT, read_timeout: HEALTH_TIMEOUT).request(request)
      response.code.to_i == 200
    rescue StandardError => e
      system_logger.warn("Markdown converter health check failed (#{settings[:base_url]}): #{e.class}: #{e.message}")
      false
    end

    # Counted like any other failure, but without the per-document warning: the breaker already said it once.
    def fail_fast_on_open_circuit
      @failed.increment
      :failed
    end

    def record_conversion_failure
      @failed.increment
      open_circuit! if @consecutive_failures.increment >= CIRCUIT_BREAKER_THRESHOLD
      :failed
    end

    # A converter outage would otherwise cost every document its full retry and timeout budget. After
    # CIRCUIT_BREAKER_THRESHOLD consecutive failures conversions are short-circuited for
    # CIRCUIT_BREAKER_COOLDOWN seconds, then a single thread re-probes /health.
    def circuit_open?
      return false unless @circuit_open
      return true if monotonic_now < @circuit_retry_at

      # try_lock: only one thread probes, the others keep short-circuiting instead of queueing behind it
      with_circuit_lock(default: true) { probe_circuit }
    end

    def with_circuit_lock(default:)
      return default unless @circuit_mutex.try_lock

      begin
        yield
      ensure
        @circuit_mutex.unlock
      end
    end

    # Returns whether the breaker is still open. Called with the circuit mutex held.
    def probe_circuit
      return false unless @circuit_open
      return true if monotonic_now < @circuit_retry_at
      return close_circuit! if healthy?

      @circuit_retry_at = monotonic_now + CIRCUIT_BREAKER_COOLDOWN
      true
    end

    def close_circuit!
      @circuit_open = false
      @consecutive_failures.value = 0
      system_logger.info('Markdown converter is healthy again, circuit breaker closed')
      false
    end

    def open_circuit!
      with_circuit_lock(default: nil) { open_circuit_now! }
    end

    def open_circuit_now!
      return if @circuit_open

      @circuit_retry_at = monotonic_now + CIRCUIT_BREAKER_COOLDOWN
      @circuit_open = true
      system_logger.error(
        "Markdown converter circuit breaker opened after #{@consecutive_failures.value} consecutive failures; " \
        "skipping conversions for #{CIRCUIT_BREAKER_COOLDOWN}s"
      )
    end

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

    def with_one_retry(crawl_result)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue RetryableError => e
        raise e if attempts > 1

        system_logger.debug(
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
      uri = status_uri(job)
      interval = settings[:poll_interval].to_f
      loop do
        check_deadline!(job, deadline)
        sleep(interval)
        job = poll_status(uri)
        return job if finished?(job)

        interval = [interval * POLL_BACKOFF, MAX_POLL_INTERVAL].min
      end
    end

    # status_url is server-controlled, so it must not be able to move the poll to another service:
    # only an absolute path is accepted and the parsed URI has to stay on the configured host.
    # "@evil.host/x" would otherwise parse as host evil.host with base_url as the userinfo.
    def status_uri(job)
      status_url = job['status_url'].to_s
      if status_url.blank?
        raise ConversionError, "converter returned status #{job['status'].inspect} without a status_url"
      end

      unless status_url.start_with?('/')
        raise ConversionError, "converter returned a non-absolute status_url: #{status_url.inspect}"
      end

      URI.parse("#{settings[:base_url]}#{status_url}").tap { |uri| validate_status_host!(uri, status_url) }
    end

    def validate_status_host!(uri, status_url)
      return if uri.userinfo.nil? && uri.host == URI.parse(settings[:base_url]).host

      raise ConversionError, "converter returned an off-host status_url: #{status_url.inspect}"
    end

    # The deadline runs from the start of the submit and is never retried
    def check_deadline!(job, deadline)
      return if monotonic_now < deadline

      raise ConversionError, "timed out after #{settings[:timeout]}s waiting for job #{job['job_id']}"
    end

    def poll_status(uri)
      parse_job(perform(uri, Net::HTTP::Get.new(uri.request_uri)), polling: true)
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
  end
end
