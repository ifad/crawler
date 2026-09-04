#
# Copyright Elasticsearch B.V. and/or licensed to Elasticsearch B.V. under one
# or more contributor license agreements. Licensed under the Elastic License 2.0;
# you may not use this file except in compliance with the Elastic License 2.0.
#

# frozen_string_literal: true

require 'yaml'

RSpec.describe(Crawler::API::Config) do
  describe '#initialize' do
    let(:domain1) do
      {
        url: 'https://domain1.com',
        seed_urls: %w[https://domain1.com/forum https://domain1.com/wiki],
        sitemap_urls: %w[https://domain1.com/sitemap/foo.xml]
      }
    end
    let(:domain2) { { url: 'http://domain2.com' } }
    let(:domains) { [domain1, domain2] }

    let(:expected_allowlist) { %W[#{domain1[:url]}:443 #{domain2[:url]}:80] }
    let(:expected_seed_urls) { ["#{domain2[:url]}/"] + domain1[:seed_urls] }

    let(:output_dir) { '/tmp/crawler/example.com/123' }

    it 'should fail when provided with unknown options' do
      expect do
        Crawler::API::Config.new(fubar: 42)
      end.to raise_error(ArgumentError, /Unexpected configuration options.*fubar/)
    end

    it 'can define a crawl with console output' do
      config = Crawler::API::Config.new(
        domains:,
        output_sink: :console
      )

      expect(config.domain_allowlist.map(&:to_s)).to match_array(expected_allowlist)
      expect(config.seed_urls.map(&:to_s).to_a).to match_array(expected_seed_urls)
      expect(config.output_sink).to eq(:console)
      expect(config.output_dir).to eq('./crawled_docs')
    end

    it 'can define a crawl with file output' do
      config = Crawler::API::Config.new(
        domains:,
        output_sink: :file,
        output_dir:
      )

      expect(config.domain_allowlist.map(&:to_s)).to match_array(expected_allowlist)
      expect(config.seed_urls.map(&:to_s).to_a).to match_array(expected_seed_urls)
      expect(config.output_sink).to eq(:file)
      expect(config.output_dir).to eq(output_dir)
    end

    it 'should use the console sink by default' do
      config = Crawler::API::Config.new(
        domains:
      )

      expect(config.domain_allowlist.map(&:to_s)).to match_array(expected_allowlist)
      expect(config.seed_urls.map(&:to_s).to_a).to match_array(expected_seed_urls)
      expect(config.output_sink).to eq(:elasticsearch)
      expect(config.output_dir).to eq('./crawled_docs')
    end

    context 'when a domain has an internationalized domain name' do
      let(:domain2) do
        {
          url: 'https://ポケモン.com',
          seed_urls: %w[https://ポケモン.com/問い合わせ]
        }
      end

      let(:normalized_domain) { 'https://xn--rckteqa2e.com' }
      let(:normalized_seed_url) { 'https://xn--rckteqa2e.com/%E5%95%8F%E3%81%84%E5%90%88%E3%82%8F%E3%81%9B' }

      let(:expected_allowlist) { %W[#{domain1[:url]}:443 #{normalized_domain}:443] }
      let(:expected_seed_urls) { domain1[:seed_urls] + [normalized_seed_url] }

      it 'should normalize the URL and any seed URLs' do
        config = Crawler::API::Config.new(domains:)

        expect(config.domain_allowlist.map(&:to_s)).to match_array(expected_allowlist)
        expect(config.seed_urls.map(&:to_s).to_a).to match_array(expected_seed_urls)
      end
    end

    context 'when a domain is missing a main URL' do
      let(:domain2) { { foo: 'bar' } }

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Each domain requires a url')
      end
    end

    context 'when a domain URL is invalid' do
      let(:domain2) { { url: 'huh?' } }

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Domain "huh?" does not have a URL scheme')
      end
    end

    context 'when a domain URL has a path' do
      let(:domain2) { { url: 'http://domain2.com/baa' } }

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Domain "http://domain2.com/baa" cannot have a path')
      end
    end

    context 'when a domain URL is not an HTTP(S) site' do
      let(:domain2) { { url: 'file://location/to/file.txt' } }

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Domain "file://location/to/file.txt" is not an HTTP(S) site')
      end
    end

    context 'when domains is empty' do
      let(:domains) { [] }

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Needs at least one domain')
      end
    end

    context 'when sink lock configuration is provided' do
      let(:config_with_sink_lock) do
        {
          domains: [{ url: 'http://example.com' }],
          sink_lock_retry_interval: 10,
          sink_lock_max_retries: 50
        }
      end

      it 'should load the provided sink lock values' do
        config = Crawler::API::Config.new(config_with_sink_lock)
        expect(config.sink_lock_retry_interval).to eq(10)
        expect(config.sink_lock_max_retries).to eq(50)
      end
    end

    context 'when crawl rules exist' do
      let(:domain2) do
        {
          url: 'http://domain2.com',
          crawl_rules: [
            { policy: 'deny', pattern: '/blog', type: 'begins' }
          ]
        }
      end

      it 'should create a crawl rule for the domain' do
        config = Crawler::API::Config.new(domains:)

        crawl_rules_d1 = config.crawl_rules['http://domain1.com']
        expect(crawl_rules_d1).to be_nil

        crawl_rules_d2 = config.crawl_rules['http://domain2.com']
        expect(crawl_rules_d2.size).to eq(1)
        expect(crawl_rules_d2.first.policy).to eq(:deny)
      end
    end

    context 'when crawl rules is not an array' do
      let(:domain2) do
        {
          url: 'http://domain2.com',
          crawl_rules: { policy: 'deny', pattern: '/blog', type: 'begins' }
        }
      end

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Crawl rules for http://domain2.com is not an array')
      end
    end

    context 'when exclude tags exist' do
      let(:domain2) do
        {
          url: 'https://domain2.com',
          exclude_tags: %w[header footer]
        }
      end

      it 'should create an exclusion tag mapping for the domain' do
        config = Crawler::API::Config.new(domains:)

        exclude_tags_d1 = config.exclude_tags['https://domain1.com']
        expect(exclude_tags_d1).to eq([])

        exclude_tags_d2 = config.exclude_tags['https://domain2.com']
        expect(exclude_tags_d2).to eq(domain2[:exclude_tags])
      end
    end

    context 'when exclude tags is not an array' do
      let(:domain2) do
        {
          url: 'https://domain2.com',
          exclude_tags: 'header'
        }
      end

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Exclude tags for https://domain2.com is not an array')
      end
    end

    context 'when exclude tags contains invalid tags' do
      let(:domain2) do
        {
          url: 'https://domain2.com',
          exclude_tags: %w[header footer foo bar]
        }
      end

      it 'should raise an argument error' do
        expect do
          Crawler::API::Config.new(
            domains:
          )
        end.to raise_error(ArgumentError, 'Invalid HTML5 tags: foo, bar')
      end
    end

    context 'when configuring SSL CA certificates' do
      def expect_x509_certificates(certs)
        expect(certs).to all(be_a(Java::JavaSecurityCert::X509Certificate))
      end

      let(:base_params) { { domains: [{ url: 'https://example.com' }] } }

      let(:valid_ca_cert_path) { 'spec/fixtures/ssl/ca.crt' }
      let(:invalid_ca_cert_path) { 'spec/fixtures/ssl/invalid.crt' }

      let(:expired_cert_path) { 'spec/fixtures/ssl/expired/example.crt' }
      let(:self_signed_cert_path) { 'spec/fixtures/ssl/self-signed/example.crt' }

      let(:non_existent_cert_path) { '/path/to/non_existent/cert.pem' }
      let(:unreadable_cert_path) { 'spec/fixtures/ssl/unreadable.crt' }

      let(:valid_ca_cert_content) { File.read(valid_ca_cert_path) }
      let(:invalid_ca_cert_content) { File.read(invalid_ca_cert_path) }

      let(:yaml_config_path) { 'spec/fixtures/ssl/config_with_cert.yml' }

      it 'defaults to an empty array when no certificates are provided' do
        config = Crawler::API::Config.new(base_params)
        expect(config.ssl_ca_certificates).to eq([])
      end

      it 'accepts an explicitly provided empty array' do
        config = Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: []))
        expect(config.ssl_ca_certificates).to eq([])
      end

      it 'raises ArgumentError if ssl_ca_certificates option is not an array' do
        expect do
          Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: 'not-an-array'))
        end.to raise_error(ArgumentError, 'ssl_ca_certificates must be a list of certificates or paths to certificates')
      end

      it 'raises ArgumentError if an element within the array is not a string' do
        expect do
          Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [123]))
        end.to raise_error(
          ArgumentError,
          'each entry of ssl_ca_certificates must be a certificate or a path to a certificate'
        )
      end

      context 'with certificate content strings' do
        it 'parses a valid certificate string' do
          config = Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [valid_ca_cert_content]))
          expect(config.ssl_ca_certificates.size).to eq(1)
          expect_x509_certificates(config.ssl_ca_certificates)
        end

        it 'raises ArgumentError for an invalid certificate string' do
          expect do
            Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [invalid_ca_cert_content]))
          end.to raise_error(ArgumentError, /Error while parsing an SSL certificate/)
        end
      end

      context 'with certificate file paths' do
        it 'loads a certificate from a valid file path' do
          config = Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [valid_ca_cert_path]))
          expect(config.ssl_ca_certificates.size).to eq(1)
          expect_x509_certificates(config.ssl_ca_certificates)
        end

        it 'loads a certificate from an expired certificate file path' do
          config = Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [expired_cert_path]))
          expect(config.ssl_ca_certificates.size).to eq(1)
          expect_x509_certificates(config.ssl_ca_certificates)
        end

        it 'loads a certificate from a self-signed certificate file path' do
          config = Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [self_signed_cert_path]))
          expect(config.ssl_ca_certificates.size).to eq(1)
          expect_x509_certificates(config.ssl_ca_certificates)
        end

        it 'raises ArgumentError if the file does not exist' do
          expect do
            Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [non_existent_cert_path]))
          end.to raise_error(ArgumentError, /Error while loading an SSL certificate .* No such file or directory/)
        end

        it 'raises ArgumentError if the file is unreadable' do
          allow(File).to receive(:read).with(unreadable_cert_path).and_raise(Errno::EACCES.new(unreadable_cert_path))
          expect do
            Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: [unreadable_cert_path]))
          end.to raise_error(ArgumentError, /Error while loading an SSL certificate .* Permission denied/)
        end

        it 'loads certificates from a YAML configuration file' do
          yaml_config = YAML.load_file(yaml_config_path)
          certificates_from_yaml = yaml_config['ssl_ca_certificates']
          config = Crawler::API::Config.new(base_params.merge(ssl_ca_certificates: certificates_from_yaml))

          expect(config.ssl_ca_certificates.size).to eq(3) # Expecting 3 certs from the YAML file
          expect_x509_certificates(config.ssl_ca_certificates)
        end
      end
    end

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

    describe '#configure_http_header_service!' do
      context 'when no auth configuration is provided' do
        let(:domains) { [{ url: 'https://example1.com' }, { url: 'https://example2.com' }] }

        it 'initializes the http_header_service without authentication headers' do
          config = Crawler::API::Config.new(domains:)
          expect(config.http_header_service.number_of_auth_headers).to eq(0)
        end
      end

      context 'when auth configuration is provided' do
        let(:domains) do
          [
            { url: 'https://example1.com', auth: { type: 'basic', username: 'user1', password: 'pass1' } },
            { url: 'https://example2.com', auth: { type: 'raw', header: 'AuthorizationHeader' } }
          ]
        end

        it 'initializes the http_header_service with the correct authentication headers' do
          config = Crawler::API::Config.new(domains:)
          expect(config.http_header_service.number_of_auth_headers).to eq(2)
        end
      end

      context 'when a domain is missing auth configuration' do
        let(:domains) do
          [
            { url: 'https://example1.com', auth: { type: 'basic', username: 'user1', password: 'pass1' } },
            { url: 'https://example2.com' }
          ]
        end

        it 'skips domains without auth configuration' do
          config = Crawler::API::Config.new(domains:)
          expect(config.http_header_service.number_of_auth_headers).to eq(1)
        end
      end
    end
  end

  describe '#to_s' do
    it 'redacts sensitive settings, including the markdown converter block' do
      config = Crawler::API::Config.new(
        domains: [{ url: 'https://example.com' }],
        output_sink: :console,
        markdown_conversion: { enabled: true, base_url: 'https://converter.example.com' }
      )

      expect(config.to_s).to include('elasticsearch=[redacted]')
      expect(config.to_s).to include('markdown_conversion=[redacted]')
      expect(config.to_s).not_to include('converter.example.com')
    end
  end
end
