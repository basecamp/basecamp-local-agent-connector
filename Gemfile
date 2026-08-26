source "https://rubygems.org"

git_source(:bc) { |repo| "https://github.com/basecamp/#{repo}" }

gemspec

group :development, :test do
  gem "minitest"
  gem "minitest-mock"
  gem "rake"
  gem "rubocop", require: false
  gem "rubocop-37signals", bc: "house-style", require: false
end
