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
end
