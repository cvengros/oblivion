require 'gooddata'
require 'rest-client'
require 'sequel'
require 'jdbc/dss'
Jdbc::DSS.load_driver

def raise_arg_error(e, message='')
  raise ArgumentError, "#{e.message}\n #{message}\n #{USAGE}"
end

class StepQueue
  PROGRESS_FILE = 'progress.json'
  class << self
    def client
      @@client
    end
    def progress
      @@progress
    end

    def run(credentials, params, progress)
      @@progress = progress
      # connect
      begin
        @@client = GoodData.connect(credentials['username'], credentials['password'], server: params['server'])
      rescue ArgumentError => e
        raise_arg_error(e)
      rescue RestClient::Unauthorized => e
        raise_arg_error(e, "The username and password you provided are wrong.")
      rescue RestClient::Forbidden => e
        raise_arg_error(e, "The username and password you provided are wrong.")
      end

      @@queue.each_with_index do |step, i|
        puts "#{i+1}. #{step.activity_caption}..."

        # if it's not done do it
        if @@progress[step.progress_field].nil?
          # save the progress
          @@progress[step.progress_field] = step.run(credentials, params)
          save_progress(@@progress)
        else
          puts "Skipped, it's already done."
        end
        puts "Done."
      end
    end

    def save_progress(progress)
      IO.write(PROGRESS_FILE, JSON.pretty_generate(progress))
    end

  end
  class Step
  end

  class CloneProject < Step
    class << self

      def progress_field
        'new_project_id'
      end
      def activity_caption
        'Cloning master project'
      end

      def run(credentials, params)
        begin
          # clone the project and write it to progress
          new_project = GoodData::Command::Project.clone(params['master_project_id'], client: StepQueue.client, auth_token: credentials['auth_token'])
          return new_project.pid
        rescue ArgumentError => e
          raise_arg_error(e)
        end
      end
    end
  end

  class ProvisionADS < Step
    class << self
      def progress_field
        'ads_instance_id'
      end
      def activity_caption
        'Provisioning ADS'
      end

      def run(credentials, params)
        # TODO
        'b4d557ae08439f3a4b8ed247e7951a7e'
      end
    end
  end

  class GitHub
    class << self
      def download_file_to_string(github_token, setup={}, raw=true, link=nil)
        if link
          url = link
        else
          sql_repo_name = setup['repo_name']
          sql_repo_owner = setup['repo_owner']

          # URI join won't make it:
          sql_path = URI.escape(setup['path'])
          sql_path = "/#{sql_path}" if sql_path[0] != '/'

          revision = setup['revision']

          url = "https://api.github.com/repos/#{sql_repo_owner}/#{sql_repo_name}/contents#{sql_path}"
          url = "#{url}?ref=#{revision}" if revision
        end
        puts "Fetching from #{url}..."

        format = raw ? 'raw' : 'json'
        # get the file content from github
        begin
          downloaded_string = RestClient.get(url, {:accept => "application/vnd.github.v3.#{format}", :authorization => "token #{github_token}"})
        rescue RestClient::ResourceNotFound => e
          raise_arg_error(e, "The url '#{url}' doesn't exist in github. Check your repo_name '#{setup['repo_name']}', repo_owner '#{setup['repo_owner']}' and/or path '#{setup['path']}'.")
        rescue RestClient::Unauthorized => e
          raise_arg_error(e, "The github_token is wrong.")
        end
        downloaded_string
      end
      def download_directory(github_token, setup, target_dir, link=nil)

        # create a dir for the contents
        # create the target dir and make sure it's absolute path
        FileUtils.mkdir_p(target_dir)
        target_dir = File.expand_path(target_dir)

        # see what is there
        json_str = download_file_to_string(github_token, setup, false, link)

        # parse it
        contents = JSON.parse(json_str)
        contents.each do |dir_item|
          # if it's a file download it and write it to file
          if dir_item['type'] == 'file'
            str = download_file_to_string(github_token, {}, true, dir_item['url'])
            target_filename = File.join(target_dir, dir_item['name'])
            IO.write(target_filename, str)
          elsif dir_item['type'] == 'dir'
            download_directory(github_token, {}, File.join(target_dir, dir_item['name']), dir_item['url'])
          else
            fail "Some weird directory item type: #{dir_item}"
          end
        end
        target_dir
      end
    end
  end

  class InitializeADS <  Step
    class << self
      def progress_field
        'ads_initialized'
      end
      def activity_caption
        'Running SQLs to initialize ADS'
      end

      def run(credentials, params)
        sql_setup = params['sql_setup']

        if sql_setup.nil?
          puts "No setup given, doing nothing"
          return nil
        end

        # download the sql
        sql_string = GitHub.download_file_to_string(credentials['github_token'], sql_setup)

        # execute it on top of ADS
        ads_jdbc_url = "jdbc:dss://secure.gooddata.com/gdc/dss/instances/#{StepQueue.progress['ads_instance_id']}"

        # execute the sql
        Sequel.connect(ads_jdbc_url, username: credentials['username'], password: credentials['password']) do |c|
          c.run(sql_string)
        end
        true
      end
    end
  end

  class DownloadETL < Step
    TAGET_DIR = 'etl'
    class << self
      def progress_field
        'etl_directory_path'
      end
      def activity_caption
        'Downloading ETL from github'
      end
      def run(credentials, params)
        FileUtils.rm_rf(TAGET_DIR)
        GitHub.download_directory(credentials['github_token'], params['etl'], TAGET_DIR)
      end
    end
  end


  # Download ETL from git
   # "type"=>"dir"
   #  "type"=>"file",
   #  "url"=>
   #   "https://api.github.com/repos/gooddata/ms_projects/contents/projects/SocialMediaFunnel/Social%20Media%20Funnel/graph/Run_all.grf?ref=master"
  # Set up parameters.
  # s3
  # workspace

  # Deploy CloudConnect project.

  @@queue = [
    CloneProject,
    ProvisionADS,
    InitializeADS,
    DownloadETL,
  ]

end