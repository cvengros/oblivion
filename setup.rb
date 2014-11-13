require 'gooddata'
require 'rest-client'
require 'sequel'
require 'jdbc/dss'
Jdbc::DSS.load_driver

# co by to melo umet:
#   kdyz se to vysere v kroku x, bude to schopny navazat - progres nekam do filu
#   user friendly hlasky na nejcastejsi pripady co se muze rozesrat

def save_progress(progress)
  IO.write(PROGRESS_FILE, JSON.pretty_generate(progress))
end

def raise_arg_error(e, message='')
  raise ArgumentError, "#{e.message}\n #{message}\n #{USAGE}"
end

# Schedule Run_all.grf and set up parameters in Data Integration Console.
USAGE = 'Usage: bundle exec setup.rb'
PARAMS_FILE = 'params.json'
CREDENTIALS_FILE = 'credentials.json'
PROGRESS_FILE = 'progress.json'

credentials = JSON.parse(IO.read(ARGV[0] || CREDENTIALS_FILE))
params = JSON.parse(IO.read(ARGV[1] || PARAMS_FILE))
progress = File.exists?(PROGRESS_FILE) ? JSON.parse(IO.read(PROGRESS_FILE)) : {}

username = credentials['username']
password = credentials['password']
token = credentials['auth_token']

# connect
begin
  client = GoodData.connect(username, password, server: params['server'])
rescue ArgumentError => e
  raise_arg_error(e)
rescue RestClient::Forbidden => e
  raise_arg_error(e, "The username and password you provided are wrong.")
end

# Clone Social Media Funnel project.
puts "Cloning master project..."
if progress['new_project_id'].nil?
  begin
    # clone the project and write it to progress
    new_project = GoodData::Command::Project.clone(params['master_project_id'], client: client, auth_token: token)
    progress['new_project_id'] = new_project.pid
    require 'pry'; binding.pry
    save_progress(progress)
  rescue ArgumentError => e
    raise_arg_error(e)
  end
end
new_pid = progress['new_project_id']
puts "Done."

# Make ADS provisioning process.
# TODO
ads_instance_id = progress['ads_instance_id'] = 'b4d557ae08439f3a4b8ed247e7951a7e'
ads_jdbc_url = "jdbc:dss://secure.gooddata.com/gdc/dss/instances/#{ads_instance_id}"

# Run table conf/tables.sql in your ADS.
puts "Executing SQL setup script..."
sql_setup = params['sql_setup']
if sql_setup
  sql_repo_name = sql_setup['repo_name']
  sql_repo_owner = sql_setup['repo_owner']
  # URI join won't make it:
  sql_path = URI.escape(sql_setup['path'])
  sql_path = "/#{sql_path}" if sql_path[0] != '/'

  github_token = credentials['github_token']
  revision = sql_setup['revision']

  url = "https://api.github.com/repos/#{sql_repo_owner}/#{sql_repo_name}/contents#{sql_path}"
  url = "#{url}?ref=#{revision}" if revision
  puts "Fetching from #{url}..."

  # get the file content from github
  begin
    sql_string = RestClient.get(url, {:accept => 'application/vnd.github.v3.raw', :authorization => "token #{github_token}"})
  rescue RestClient::ResourceNotFound => e
    raise_arg_error(e, "The repo_name, repo_owner and path are wrong.")
  rescue RestClient::Unauthorized => e
    raise_arg_error(e, "The github_token is wrong.")
  end
  # execute the sql
  Sequel.connect(ads_jdbc_url, username: username, password: password) do |c|
    c.run(sql_string)
  end
end
puts "Done."

require 'pry'; binding.pry

# Set up parameters.

# Deploy CloudConnect project.
require 'pry'; binding.pry

