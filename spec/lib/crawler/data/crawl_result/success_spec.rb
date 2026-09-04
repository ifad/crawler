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
