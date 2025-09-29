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
- Redis server (running and accessible)
- NCBI API key (required for PubMed/PMC access)

### Critical Dependencies

The service performs startup validation and **will not start** if these dependencies are not properly configured:

1. **NCBI API Key**: Required for accessing PubMed and PMC APIs
   - Get your key from: https://www.ncbi.nlm.nih.gov/account/settings/
   - Must be set in `NCBI_API_KEY` environment variable

2. **Redis Server**: Required for failure caching and must be running before service startup
   - Default connection: `redis://localhost:6379`
   - Configure via `REDIS_URL` environment variable if using a different setup

If either dependency is missing or unreachable, the service will log detailed error messages and exit immediately.

### Setup
```bash
# Clone and install dependencies
git clone <repository-url>
cd doc_sequencer_pubmed
bundle install

# IMPORTANT: Start Redis first
redis-server

# Configure environment (REQUIRED)
cp .env.example .env
# Edit .env with your actual NCBI_API_KEY and Redis URL

# Start the service (will validate dependencies before starting)
bundle exec puma config.ru -p 4567
```

### Startup Validation

The service validates critical dependencies during startup:

- **NCBI_API_KEY**: Checks environment variable exists and is not empty
- **Redis Connectivity**: Tests actual connection with PING command

Example error output if dependencies are missing:
```
FATAL -- : Startup validation failed:
FATAL -- :   - NCBI_API_KEY environment variable is required for PubMed/PMC access
FATAL -- :   - Cannot connect to Redis server (URL: redis://localhost:6379): Connection refused
FATAL -- : Service cannot start. Please check your configuration.
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