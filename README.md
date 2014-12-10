oblivion
========

Agile and social B2C template provisioning.

# How to use it
Get the code

    git clone git@github.com:cvengros/oblivion.git    
    cd oblivion

## Configuration
Use the examples for initial values. Credentials are pieces of configuration with special handling - they act as hidden params in processes and aren't deployed in plaintext anywhere.

    cp params.example.json params.json
    cp credentials.example.json credentials.json

Open params.json and credentials.json in your favourite text editor and configure. 

Credentials `credentials.json`:
* `gooddata`: the etl user credentials. The token is also used for provisioning ADS, so make sure it has right to create ADS.
* `github_token`: token used for downloading ETL and sql setup from github. Read how to generate one in [the guide](https://help.github.com/articles/creating-an-access-token-for-command-line-use/).
* `process`: All keys here are used as hidden parameters for executing and scheduling the deployed process. 

Params `params.json`:
 * `master_project_id`: pid of the project to clone from, it must be accessible by your GD user. 
 * `sql_setup`: The tool executes an ADS setup script located in a GitHub repository. The params tell the tool where to download the script from. `revision` is optional, if not given the last version is taken.
 * `etl`: ETL process is taken from a GitHub repo as well. This can be a different repo from the one containing the SQL setup. `params` will be used as runtime params when scheduling and executing the deployed process.
 * `workspace`: The tool generates a workspace.prm file according to the params given here. The params are divided to sections according to data sources. After the `workspace.prm` file is generated it's uploaded with the graphs as a new process. 
    * `ADS_USER` must be the same user that is running the setup.
 * `S3`: The tool generates CSV files from these and pushes them to the given path at S3. 
    * `path_key` gives a key from where the S3 path is taken. I.E. if the `path_key` is `S3_TW_PARAM_URI`, the generated CSV file will be uploaded to `etl_params/Twitter_params.csv` because that's the value of the `S3_TW_PARAM_URI` key.
    * `header` is an array containing the header of the CSV file
    * `values` is an array of arrays - each inner array represents a line in the generated CSV file. 

We suggest storing the `params.json` file in git along with your project. `credentials.json` shouldn't leave your laptop. 

Install the dependencies. You have to be on jruby.

    bundle install

Run the tool

    bundle exec ruby setup.rb

The tool catches exceptions from APIs and translates them into more human-readable errors. The progress is saved to a file `progress.json` so that you don't have to repeat the steps that were already completed successfully. If you wish to repeat some of the steps, delete the appropriate keys from `progress.json`. If you want to start over, delete the `progress.json` file. 
