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
