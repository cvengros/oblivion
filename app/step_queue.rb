require 'gooddata'
require 'rest-client'
require 'sequel'
require 'jdbc/dss'
require 'erb'

Jdbc::DSS.load_driver

require_relative 'github'

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
        if credentials['gooddata'].nil?
          raise ArgumentError, "GoodData credentials are missing"
        end
        @@client = GoodData.connect(credentials['gooddata']['username'], credentials['gooddata']['password'], server: params['server'])
      rescue ArgumentError => e
        raise_arg_error(e)
      rescue RestClient::Unauthorized => e
        raise_arg_error(e, "The username and password you provided are wrong.")
      rescue RestClient::Forbidden => e
        raise_arg_error(e, "The username and password you provided are wrong.")
      end

      @@queue.each_with_index do |step, i|
        puts "#{i + 1}. #{step.activity_caption}..."

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
          new_project = GoodData::Command::Project.clone(params['master_project_id'], client: StepQueue.client, auth_token: credentials['gooddata']['auth_token'])
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
        begin
          Sequel.connect(ads_jdbc_url, username: credentials['gooddata']['username'], password: credentials['gooddata']['password']) do |c|
            c.run(sql_string)
          end
        rescue Sequel::DatabaseConnectionError => e
          raise_arg_error(e, 'Cannot connect to ADS, check that your gooddata user has access')
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

  # Set up parameters.
  # workspace
  class GenerateWorkspaceParams < Step
    TAGET_DIR = 'etl'
    WORKSPACE = 'workspace.prm'
    ERB_FILE = 'workspace.prm.erb'
    class << self
      def progress_field
        'workspace_params'
      end
      def activity_caption
        'Generating workspace.prm'
      end
      def run(credentials, params)
        FileUtils.mkdir_p(TAGET_DIR)
        workspace_params = params['workspace']
        if workspace_params.nil?
          return nil
        end

        # render workspace from template
        erb = IO.read(File.join(File.dirname(__FILE__), ERB_FILE))
        renderer = ERB.new(erb)
        workspace_file = File.join(TAGET_DIR, WORKSPACE)

        # write the string to file
        File.open(workspace_file, 'w') do |f|
          f.write(renderer.result(binding))
        end
        workspace_file
      end

      # format a hash with params so that it can be in workspace.prm
      def workspace_format(hsh)
        hsh.collect{ |k,v| "#{k}=#{URI.encode(v)}"}.join("\n")
      end
    end
  end

  # Set up parameters.
  # s3
  class GenerateS3Params < Step
    TAGET_DIR = 's3'
    class << self
      def progress_field
        's3_params_folder'
      end
      def activity_caption
        'Generating s3 params'
      end
      def run(credentials, params)

        # init s3
        s3_workspace = params['workspace']['S3']
        bucket_name = s3_workspace['S3_BUCKET']

        s3 = AWS::S3.new(
          :access_key_id => s3_workspace['S3_ACCESSKEY'],
          :secret_access_key => credentials['process']['S3_SECRETKEY']
        )
        bucket = s3.buckets[bucket_name]

        # generate csv from each s3 item
        FileUtils.mkdir_p(TAGET_DIR)
        params['s3'].each do |name, csv_data|
          s3_params_path = params['workspace'][name][csv_data['path_key']]
          s3_folder = params['workspace']['S3']['S3_FOLDER']

          local_path = File.join(TAGET_DIR, File.basename(s3_params_path))
          CSV.open(local_path, "wb", force_quotes: true) do |csv|
            # write the header there
            csv << csv_data['header']

            # and all the values as well
            csv_data['values'].each do |row|
              csv << row
            end
          end

          # strip the slashes at the beginning / end because URI.join is crap
          s3_folder = s3_folder[0..-2] if s3_folder[-1] == '/'
          s3_params_path = s3_params_path[1..-1] if s3_params_path == '/'
          target_path = "#{s3_folder}/#{s3_params_path}"

          # upload the file from local_path to s3_params_path
          obj = bucket.objects[target_path]
          err_message = 'Paste it there as it is, no url encoding.'
          begin
            obj.write(Pathname.new(local_path))
          rescue AWS::S3::Errors::SignatureDoesNotMatch => e
            raise_arg_error(e, "The s3 credentials are wrong. Check out S3_SECRETKEY in credentials. #{err_message}")
          rescue AWS::S3::Errors::InvalidAccessKeyId => e
            raise_arg_error(e, "The s3 access key is wrong. Check out S3_ACCESSKEY in params. #{err_message}")
          rescue AWS::S3::Errors::NoSuchBucket => e
            raise_arg_error(e, "The s3 bucket is wrong. Check out S3_BUCKET in params. #{err_message}")
          rescue AWS::S3::Errors::AccessDenied => e
            raise_arg_error(e, "You don't have access to the bucket or folder you've provided. Check out params S3_BUCKET, S3_FOLDER, S3_ACCESSKEY and your s3 credentials (S3_SECRETKEY). #{err_message}")
          end
        end
        TAGET_DIR
      end
    end
  end

  # Deploy CloudConnect project.
  # bacha - URI.encode vsechny parametry, i hidden

  @@queue = [
    CloneProject,
    ProvisionADS,
    InitializeADS,
    DownloadETL,
    GenerateWorkspaceParams,
    GenerateS3Params
  ]

end