require_relative('app/step_queue')

USAGE = 'Usage: bundle exec setup.rb'
PARAMS_FILE = 'params.json'
CREDENTIALS_FILE = 'credentials.json'

# get the params and run the queue
credentials = JSON.parse(IO.read(ARGV[0] || CREDENTIALS_FILE))
params = JSON.parse(IO.read(ARGV[1] || PARAMS_FILE))
progress = File.exists?(StepQueue::PROGRESS_FILE) ? JSON.parse(IO.read(StepQueue::PROGRESS_FILE)) : {}

StepQueue.run(credentials, params, progress)




