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
