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
