#     $ rails new searchapp --skip --skip-bundle --template https://raw.github.com/elasticsearch/elasticsearch-rails/master/elasticsearch-rails/lib/rails/templates/03-complex.rb

# (See: 01-basic.rb, 02-pretty.rb)

append_to_file 'README.rdoc', <<-README

== [3] Expert

The `expert` template changes to a complex database schema with model relationships: article belongs
to a category, has many authors and comments.

* The Elasticsearch integration is refactored into the `Searchable` concern
* A complex mapping for the index is defined
* A custom serialization is defined in `Article#as_indexed_json`
* The `search` method is amended with facets and suggestions
* A [Sidekiq](http://sidekiq.org) worker for handling index updates in background is added
* A custom `SearchController` with associated view is added
* A Rails initializer is added to customize the Elasticsearch client configuration
* Seed script and example data from New York Times is added

README

git add:    "README.rdoc"
git commit: "-m '[03] Updated the application README'"

# ----- Add gems into Gemfile ---------------------------------------------------------------------

puts
say_status  "Rubygems", "Adding Rubygems into Gemfile...\n", :yellow
puts        '-'*80, ''; sleep 0.25

gem "oj"

run "bundle install"

git add:    "Gemfile*"
git commit: "-m 'Added Ruby gems'"

# ----- Customize the Rails console ---------------------------------------------------------------

puts
say_status  "Rails", "Customizing `rails console`...\n", :yellow
puts        '-'*80, ''; sleep 0.25


gem "pry", group: 'development'

environment nil, env: 'development' do
  %q{
  console do
    config.console = Pry
    Pry.config.history.file = Rails.root.join('tmp/console_history.rb').to_s
    Pry.config.prompt = [ proc { |obj, nest_level, _| "(#{obj})> " },
                          proc { |obj, nest_level, _| ' '*obj.to_s.size + '  '*(nest_level+1)  + '| ' } ]
  end
  }
end

git add:    "Gemfile*"
git add:    "config/"
git commit: "-m 'Added Pry as the console for development'"

# ----- Disable asset logging in development ------------------------------------------------------

puts
say_status  "Application", "Disabling asset logging in development...\n", :yellow
puts        '-'*80, ''; sleep 0.25

environment 'config.assets.logger = false', env: 'development'
gem 'quiet_assets',  group: "development"

git add:    "Gemfile*"
git add:    "config/"
git commit: "-m 'Disabled asset logging in development'"

# ----- Define and generate schema ----------------------------------------------------------------

puts
say_status  "Models", "Adding complex schema...\n", :yellow
puts        '-'*80, ''

generate :scaffold, "Category title"
generate :scaffold, "Author first_name last_name"
generate :scaffold, "Authorship article:references author:references"

generate :model,     "Comment body:text user:string user_location:string stars:integer pick:boolean article:references"
generate :migration, "CreateArticlesCategories article:references category:references"

rake "db:drop"
rake "db:migrate"

insert_into_file "app/models/category.rb", :before => "end" do
  <<-CODE
  has_and_belongs_to_many :articles
  CODE
end

insert_into_file "app/models/author.rb", :before => "end" do
  <<-CODE
  has_many :authorships

  def full_name
    [first_name, last_name].join(' ')
  end
  CODE
end

gsub_file "app/models/authorship.rb", %r{belongs_to :article$}, <<-CODE
belongs_to :article, touch: true
CODE

# TODO Comment belongs_to :article, touch: true

insert_into_file "app/models/article.rb", after: "ActiveRecord::Base" do
  <<-CODE

  has_and_belongs_to_many :categories, after_add:    [ lambda { |a,c| Indexer.perform_async(:update,  a.class.to_s, a.id) } ],
                                       after_remove: [ lambda { |a,c| Indexer.perform_async(:update,  a.class.to_s, a.id) } ]
  has_many                :authorships
  has_many                :authors, through: :authorships
  has_many                :comments
  CODE
end

git add:    "."
git commit: "-m 'Generated Category, Author and Comment resources'"

# ----- Add the `abstract` column -----------------------------------------------------------------

puts
say_status  "Model", "Adding the `abstract` column to Article...\n", :yellow
puts        '-'*80, ''

generate :migration, "AddColumnsToArticle abstract:text url:string shares:integer"
rake "db:migrate"

git add:    "db/"
git commit: "-m 'Added additional columns to Article'"

# ----- Move the model integration into a concern -------------------------------------------------

puts
say_status  "Model", "Refactoring the model integration...\n", :yellow
puts        '-'*80, ''; sleep 0.25

remove_file 'app/models/article.rb'
create_file 'app/models/article.rb', <<-CODE
class Article < ActiveRecord::Base
  include Searchable
end
CODE

# TODO: Get from Github
# get "http://...", "app/models/concerns/searchable.rb"

copy_file File.expand_path('../searchable.rb', __FILE__), 'app/models/concerns/searchable.rb'

insert_into_file "app/models/article.rb", after: "ActiveRecord::Base" do
  <<-CODE

  has_and_belongs_to_many :categories, after_add:    [ lambda { |a,c| Indexer.perform_async(:update,  a.class.to_s, a.id) } ],
                                       after_remove: [ lambda { |a,c| Indexer.perform_async(:update,  a.class.to_s, a.id) } ]
  has_many                :authorships
  has_many                :authors, through: :authorships
  has_many                :comments

  CODE
end

git add:    "app/models/"
git commit: "-m 'Refactored the Elasticsearch integration into a concern\n\nSee:\n\n* http://37signals.com/svn/posts/3372-put-chubby-models-on-a-diet-with-concerns\n* http://joshsymonds.com/blog/2012/10/25/rails-concerns-v-searchable-with-elasticsearch/'"

# ----- Add Sidekiq indexer -----------------------------------------------------------------------

puts
say_status  "Application", "Adding Sidekiq worker for updating the index...\n", :yellow
puts        '-'*80, ''; sleep 0.25

gem "sidekiq"

run "bundle install"

# TODO: Get from Github
# get "http://...", "app/workers/indexer.rb"

copy_file File.expand_path('../indexer.rb', __FILE__), 'app/workers/indexer.rb'

git add:    "Gemfile* app/workers/"
git commit: "-m 'Added a Sidekiq indexer\n\nRun:\n\n    $ bundle exec sidekiq --queue elasticsearch --verbose\n\nSee http://sidekiq.org'"

# ----- Add SearchController -----------------------------------------------------------------------

puts
say_status  "Controllers", "Adding SearchController...\n", :yellow
puts        '-'*80, ''; sleep 0.25

create_file 'app/controllers/search_controller.rb' do
  <<-CODE.gsub(/^  /, '')
  class SearchController < ApplicationController
    respond_to :json, :html

    def index
      options = {
        category:       params[:c],
        author:         params[:a],
        published_week: params[:w],
        published_day:  params[:d],
        sort:           params[:s],
        comments:       params[:comments]
      }
      @articles = Article.search(params[:q], options).page(params[:page]).results

      respond_with @articles
    end

  end

  CODE
end

route "get '/search', to: 'search#index', as: 'search'"
gsub_file 'config/routes.rb', %r{root to: 'articles#index'$}, "root to: 'search#index'"

# TODO: Get from Github
# get "http://...", "app/views/search/index.html.erb"

copy_file File.expand_path('../index.html.erb', __FILE__), 'app/views/search/index.html.erb'

# TODO: Get from Github
# get "http://...", "app/assets/stylesheets/search.css"

copy_file File.expand_path('../search.css', __FILE__), 'app/assets/stylesheets/search.css'


git add:    "app/controllers/ config/routes.rb"
git add:    "app/views/search/ app/assets/stylesheets/search.css"
git commit: "-m 'Added SearchController#index'"

# ----- Add initializer ---------------------------------------------------------------------------

puts
say_status  "Application", "Adding Elasticsearch configuration in an initializer...\n", :yellow
puts        '-'*80, ''; sleep 0.5

create_file 'config/initializers/elasticsearch.rb', <<-CODE
# Connect to specific Elasticsearch cluster
ELASTICSEARCH_URL = ENV['ELASTICSEARCH_URL'] || 'http://localhost:9200'

Elasticsearch::Model.client = Elasticsearch::Client.new host: ELASTICSEARCH_URL

# Print Curl-formatted traces in development
#
if Rails.env.development?
  tracer = ActiveSupport::Logger.new(STDERR)
  tracer.level =  Logger::DEBUG
end

Elasticsearch::Model.client.transport.tracer = tracer
CODE

git add:    "config/initializers"
git commit: "-m 'Added Rails initializer with Elasticsearch configuration'"

# ----- Insert and index data ---------------------------------------------------------------------

puts
say_status  "Database", "Re-creating the database with data and importing into Elasticsearch...", :yellow
puts        '-'*80, ''; sleep 0.25

# TODO: Get from Github
copy_file File.expand_path('../articles.yml.gz', __FILE__), 'db/articles.yml.gz'

# TODO: Get from Github
remove_file 'db/seeds.rb'
copy_file File.expand_path('../seeds.rb', __FILE__), 'db/seeds.rb'

rake "db:reset"

git add:    "db/seeds.rb db/articles.yml.gz"
git commit: "-m 'Added a seed script and source data'"

# ----- Print Git log -----------------------------------------------------------------------------

puts
say_status  "Git", "Details about the application:", :yellow
puts        '-'*80, ''

git tag: "expert"
git log: "--reverse --oneline HEAD...pretty"

# ----- Start the application ---------------------------------------------------------------------

require 'net/http'
if (begin; Net::HTTP.get(URI('http://localhost:3000')); rescue Errno::ECONNREFUSED; false; rescue Exception; true; end)
  puts        "\n"
  say_status  "ERROR", "Some other application is running on port 3000!\n", :red
  puts        '-'*80

  port = ask("Please provide free port:", :bold)
else
  port = '3000'
end

puts  "", "="*80
say_status  "DONE", "\e[1mStarting the application. Open http://localhost:#{port}\e[0m", :yellow
puts  "="*80, ""

run  "rails server --port=#{port}"
