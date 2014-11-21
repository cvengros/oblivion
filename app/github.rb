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