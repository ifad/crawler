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
