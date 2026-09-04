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
        # `have_received(...).with(5.0)` defaults to "exactly once", so record the arguments instead
        intervals = []
        allow(converter).to receive(:sleep) { |seconds| intervals << seconds }
        stub_request(:post, upload_url).to_return(pending_response)
        stub_request(:get, status_url).to_return(
          json_response('processing'),
          json_response('processing'),
          json_response('done', markdown: '# Capped')
        )

        expect(converter.convert!(html_result)).to eq(:converted)
        expect(intervals).to eq([4.0, 5.0, 5.0])
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
      # the retry line reads "Markdown conversion for <url> failed (...)", so only the final failure matches
      expect(config.system_logger).to have_received(:warn)
        .with(/Markdown conversion failed for .*HTTP 503 from converter/)
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
      expect(config.system_logger).to have_received(:warn).with(/Markdown conversion failed for .*Net::ReadTimeout/)
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

    it 'refuses to poll a status_url that smuggles another host through the userinfo' do
      upload = stub_request(:post, upload_url)
               .to_return(status: 202, body: job_json('pending', status_url: '@evil.host/x'), headers: json_headers)

      expect(converter.convert!(html_result)).to eq(:failed)
      expect(html_result.markdown).to be_nil
      expect(upload).to have_been_requested.once
      expect(a_request(:any, %r{//evil.host})).not_to have_been_made
      expect(config.system_logger).to have_received(:warn).with(/status_url/)
    end

    it 'refuses to poll an absolute status_url pointing at another host' do
      upload = stub_request(:post, upload_url).to_return(
        status: 202,
        body: job_json('pending', status_url: 'http://evil.host/x'),
        headers: json_headers
      )

      expect(converter.convert!(html_result)).to eq(:failed)
      expect(html_result.markdown).to be_nil
      expect(upload).to have_been_requested.once
      expect(a_request(:any, %r{//evil.host})).not_to have_been_made
      expect(config.system_logger).to have_received(:warn).with(/status_url/)
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
        new_args = []
        allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
          new_args << args
          original.call(*args).tap { |client| clients << client }
        end
        stub_request(:post, upload_url).to_return(json_response('done', markdown: '# TLS'))

        expect(converter.convert!(html_result)).to eq(:converted)
        expect(clients.size).to eq(1)
        expect(new_args.first[2]).to be_nil # p_addr = nil disables Net::HTTP's env proxying
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
end
