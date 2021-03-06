# !/usr/bin/env ruby
#
# Command to add and remove entire RightScale server arrays to or from ELBs.
# Intended for red/black deploys.  For instance:
# - Use node_manager.rb to clone a new server array with upgraded packages
# - Use this script to add the entire new array to an an existing ELB
# - Use this script to remove the old instances in the old array from the ELB
# - After testing, use node_manager.rb to remove the old server array

require 'optparse'

require File.join(File.expand_path(File.dirname(__FILE__)), 'defaults.rb')
require File.join(File.expand_path(File.dirname(__FILE__)), 'find_server_array')
require File.join(File.expand_path(File.dirname(__FILE__)), 'get_logger')
require File.join(File.expand_path(File.dirname(__FILE__)), 'get_right_client')
require File.join(File.expand_path(File.dirname(__FILE__)), 'node_manager')

# Global logger
$log = get_logger()

# Parse command line arguments.  Some defaults come from node_manager.rb
def elb_parse_arguments()
  options = {
    :add => false,
    :remove => false,
    :env => $DEFAULT_ENV,
    :server_array => nil,
    :elb => nil,
    :oauth2_api_url => $DEFAULT_OAUTH2_API_URL,
    :refresh_token => nil,
    :api_version => $DEFAULT_API_VERSION,
    :api_url => $DEFAULT_API_URL,
    :dryrun => false
  }

  parser = OptionParser.new do|opts|
    opts.banner = "Usage: elb_manager.rb [options]"

    opts.on('-r', '--remove', 'Remove server array from a ELB.') do
      options[:remove] = true
    end

    opts.on('-a', '--add', 'Add server array to a ELB.') do
      options[:add] = true
    end

    opts.on('-e', '--env ENV', 'Deployment environment.') do |env|
      options[:env] = env;
    end

    opts.on('-s', '--server_array SERVER_ARRAY_NAME',
            'Server array name to add or remove from ELB.') do |server_array|
      options[:server_array] = server_array
    end

    opts.on('-l', '--elb ELB_NAME',
            'ELB name to add or remove server array to or from.') do |elb|
      options[:elb] = elb
    end

    opts.on('-u', '--api_url API_URL', 'RightScale API URL.') do |api_url|
      options[:api_url] = api_url
    end

    opts.on('-v', '--api_version API_VERSION',
            'RightScale API Version.') do |api_version|
      options[:api_version] = api_version
    end

    opts.on('-t', '--refresh_token TOKEN',
            'The refresh token for RightScale OAuth2.') do |refresh_token|
      options[:refresh_token] = refresh_token
    end

    opts.on('-o', '--oauth2_api_url URL',
            'RightScale OAuth2 URL.') do |oauth2_api_url|
      options[:oauth2_api_url] = oauth2_api_url
    end

    opts.on('-d', '--dryrun', 'Dryrun. Do not update ELB.') do
      options[:dryrun] = true
    end
  end

  parser.parse!

  if options[:add] and options[:remove]
    abort('Add and remove are mutually exclusive.')
  end

  if not options[:add] and not options[:remove]
    abort('You must specify an action, --add or --remove.')
  end

  if not options[:server_array] or not options[:elb]
    abort('You must specify a server array and ELB to operate on.')
  end

  if not options[:refresh_token]
    abort('You must specify a refresh token.')
  end

  if options[:env] != 'staging' and options[:env] != 'prod'
    abort('env must be staging or prod.')
  end

  return options
end

# Add or remove all instances of a server array to an ELB.
# 
# * *Args*:
#   - +dryrun+ -> `boolean` to not invoke any API calls.
#   - +right_client+ -> instance of RightClient as expected by find_server_array
#   - +elb_name+ -> string for the name of the ELB
#   - +server_array_name+ -> string for the server array name
#   - +env+ -> string for environment (defaults.rb). Can be one of
#     - staging
#     - prod
#   - +action+ -> string for rightscale action (defaults.rb). Can be one of
#     - add
#     - remove
#
def update_elb(dryrun, right_client, elb_name, server_array_name, env, action)
  if action == 'add'
    msg   = 'Adding %s to %s'
  elsif action == 'remove'
    msg  = 'Removing %s from %s'
  else
    abort('Action must be add or remove.')
  end

  if dryrun
    $log.info('Dry run mode. Not operating on the ELB.')
  else
    $log.debug("Grabbing #{action} and #{env}")
    right_script = $RIGHT_SCRIPT[action][env]
    $log.debug("right_script is #{right_script}")

    $log.info('Looking for server_array %s.' % server_array_name)
    server_array = find_server_array(right_client, server_array_name)

    if not server_array
      abort("FAILED.  Could not find #{server_array_name}")
    end

    $log.info(msg % [server_array_name, elb_name])

    return server_array.multi_run_executable(
             :right_script_href => right_script,
             :inputs => {'ELB_NAME' => "text:%s" % elb_name})
  end
end

# Poll the given set of tasks for completion
def wait_for_elb_tasks(tasks)
  iterations = 0
  while true
    completed_task_count = 0
    for task in tasks
      $log.debug('Checking task "%s"' % task)
      if check_elb_task(task)
        completed_task_count += 1
      end
    end

    break if completed_task_count == tasks.length
    $log.info("Waiting for ELB tasks to complete...")

    iterations += 1
    if iterations >= $RS_TIMEOUT
      abort('Timeout waiting on RightScale task! (%s seconds)' % $RS_TIMEOUT)
    end
    sleep 1
  end
end

# Check if an ELB task has completed
#
# * *Args*:
#   - +task+ -> a Task object that has a summary.
#
# * *Returns*:
#   - +boolean+ -> true = completed, false = incomplete
#
# * *Raises*:
#   - +abort+ -> if a task has explicitly failed.
def check_elb_task(task)
  if task.show.summary.include? 'completed'
    return true
  elsif task.show.summary.include? 'failed'
    abort('FAILED.  RightScript task failed!')
  else
    return false
  end
end

def check_rs_timeout(iterations)
  if iterations >= $RS_TIMEOUT
    abort('Timeout waiting on RightScale task! (%s seconds)' % $RS_TIMEOUT)
  end
  sleep 1
end

# Main function.
#
def elb_main()
  args = elb_parse_arguments()
  right_client = get_right_client(args[:oauth2_api_url],
                                  args[:refresh_token],
                                  args[:api_version],
                                  args[:api_url])
  if args[:add]
    action = 'add'
  elsif args[:remove]
    action = 'remove'
  end

  task = update_elb(args[:dryrun], right_client, args[:elb],
                    args[:server_array], args[:env], action)

  iterations = 0
  while true
    $log.info('Waiting for task to complete (%s).' % task.show.summary)
    if check_elb_task(task)
      $log.info('Task completed.')
      break
    end

    iterations += 1
    check_rs_timeout(iterations)
  end
end

#
# Program entry.
#
if __FILE__ == $0
  elb_main()
end
