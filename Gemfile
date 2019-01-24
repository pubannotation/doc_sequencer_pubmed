source 'https://rubygems.org'
ruby '2.2.5'

gem 'sinatra'

gem 'net-http-persistent', '~> 2.9', '>= 2.9.4'
gem 'libxml-ruby'
gem 'nokogiri'
gem 'oga', '~> 2.2'

group :production do
	gem 'unicorn'
end

group :development, :test do
	gem 'puma'
end

group :test do
	gem 'rspec'
end
