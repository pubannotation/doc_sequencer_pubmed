# doc_sequencer_pubmed

A Ruby web service for extracting text from biomedical literature databases including PubMed, PMC, FirstAuthor, and Gray's Anatomy. Features intelligent caching and throttling to handle burst traffic while respecting upstream API rate limits.

## Features

- **Text Extraction**: Supports PubMed, PMC, FirstAuthor, and Gray's Anatomy
- **Smart Caching**: Caches failed requests to prevent repeated upstream calls
- **Throttling**: Sequential processing with configurable delays between API requests
- **REST API**: Simple HTTP interface with batch request support
- **Monitoring**: Health checks and statistics endpoints

## Installation

### Prerequisites
- Ruby 3.3.7+
- Redis server
- NCBI API key

### Setup
```bash
# Clone and install dependencies
git clone <repository-url>
cd doc_sequencer_pubmed
bundle install

# Start Redis
redis-server

# Configure environment
cp .env.example .env
# Edit .env with your NCBI_API_KEY

# Start the service
bundle exec puma config.ru -p 4567
```

## API Usage

### Single Document
```bash
curl "http://localhost:4567/?sourcedb=pubmed&sourceid=12345"
```

### Batch Documents
```bash
curl -X POST "http://localhost:4567/?sourcedb=pubmed" \
  -H "Content-Type: application/json" \
  -d '["12345", "67890", "11111"]'
```

### Monitoring
```bash
curl "http://localhost:4567/health"  # Health check
curl "http://localhost:4567/stats"   # Cache/queue statistics
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

All source code in this repository is subject to the terms of the MIT License unless stated otherwise. A copy of this license can be found at https://opensource.org/licenses/MIT.