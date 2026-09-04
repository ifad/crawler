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
