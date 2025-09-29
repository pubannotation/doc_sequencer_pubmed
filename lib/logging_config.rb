#!/usr/bin/env ruby
require 'logger'

class LoggingConfig
  DEFAULT_LOG_LEVEL = 'INFO'
  DEFAULT_LOG_OUTPUT = STDOUT

  class << self
    attr_accessor :logger

    def setup_logger(
      output: ENV.fetch('LOG_OUTPUT', DEFAULT_LOG_OUTPUT),
      level: ENV.fetch('LOG_LEVEL', DEFAULT_LOG_LEVEL),
      formatter: nil
    )
      @logger = Logger.new(output == 'STDOUT' ? STDOUT : output)
      @logger.level = parse_log_level(level)
      @logger.formatter = formatter || default_formatter
      @logger
    end

    def get_logger
      @logger ||= setup_logger
    end

    private

    def parse_log_level(level)
      case level.upcase
      when 'DEBUG' then Logger::DEBUG
      when 'INFO' then Logger::INFO
      when 'WARN' then Logger::WARN
      when 'ERROR' then Logger::ERROR
      when 'FATAL' then Logger::FATAL
      else Logger::INFO
      end
    end

    def default_formatter
      proc do |severity, datetime, progname, msg|
        timestamp = datetime.strftime('%Y-%m-%d %H:%M:%S.%3N')
        "[#{timestamp}] #{severity.ljust(5)} #{progname} -- #{msg}\n"
      end
    end
  end
end