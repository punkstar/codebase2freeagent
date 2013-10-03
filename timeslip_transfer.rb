#!/usr/bin/env ruby

require 'optparse'
require 'freeagent_api'
require 'bigdecimal'
require 'csv'
require 'net/http'
require 'net/https'
require 'yaml'
require 'pp'

abort("Copy config.yml.sample to config.yml, then edit the configuration first.  Idiot.") unless File.exists? 'config.yml'

CONFIG = YAML.load_file 'config.yml'

# Double check the yaml file
abort("[error] The config.yml file doesn't have a 'freeagent' section") unless CONFIG.has_key? "freeagent"
abort("[error] The config.yml file doesn't have a 'projects' section") unless CONFIG.has_key? "projects"
abort("[error] The config.yml file doesn't have a 'users' section") unless CONFIG.has_key? "users"

projects_map = CONFIG['projects']
user_id_map  = CONFIG['users']

options = {}

optparse = OptionParser.new do |opts|
    opts.banner = "Usage: timeslip_transfer.rb --input FILE --project NAME"
  
    opts.on('--input FILE', 'Input CSV file, required.') do |f| 
        options[:input] = f 
    end
    
    opts.on('--project NAME', 'Project name, required') do |f|
        options[:project] = f
    end

    opts.on('-h', '--help', 'Display this screen') do |f| 
        puts opts
        
        puts
        puts "Available projects:"
        projects_map.each do |name, id|
            puts "\t#{name}"
        end
        
        puts
        puts "Loaded users:"
        user_id_map.each do |name, id|
          puts "\t#{name} (#{id})"
        end
        
        exit
    end 
end

optparse.parse!

begin
    raise OptionParser::MissingArgument if options[:input].nil?
    raise OptionParser::MissingArgument if options[:project].nil?
rescue
    puts 'Error: Missing required options.'
    puts optparse
    exit 1
end

begin
    raise OptionParser::MissingArgument unless File.exists? options[:input]
rescue
    puts 'Error: Input file doesn\'t exist'
    puts optparse
    exit 1
end

begin
    raise OptionParser::MissingArgument unless CONFIG['projects'].has_key? options[:project]
rescue
    puts 'Error: Couldn\'t find project in the configuration file'
    puts optparse
    puts
    puts "Available projects:"
    projects_map.each do |name, id|
        puts "\t#{name}"
    end
    exit 1
end

class ActiveResource::Connection
  # Creates new Net::HTTP instance for communication with
  # remote service and resources.
  def http
    http = Net::HTTP.new(@site.host, @site.port)
    http.use_ssl = @site.is_a?(URI::HTTPS)
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = @timeout if @timeout
    # Here's the addition that allows you to see the output
    # http.set_debug_output $stderr
    return http
  end
end

#
# Add tasks to the Freeagent gem
#
module Freeagent
  class Project
    def tasks
      Task.find :all, :from => "/projects/#{id}/tasks.xml"
    end 
  end
end

codebase_project_id = CONFIG['projects'][options[:project]]
freeagent_config = CONFIG['freeagent'].inject({}){|memo,(k,v)| memo[k.to_sym] = v; memo}
Freeagent.authenticate(freeagent_config)

project = Freeagent::Project.find codebase_project_id
project_tasks = project.tasks

row_count = 0
CSV.foreach(options[:input]) do |row|
  row_count += 1
  next if row_count == 1
  
  minutes, user, summary, date, billed, ticket, milestone = row

  billed = (billed == '1')

  unless billed
    if ticket
      task_name = "Codebase Ticket ##{ticket}"
    else
      task_name = summary
    end
    
    ticket_id = nil
    project_tasks.each do |task|
      if task.name == task_name
        ticket_id = task.id
      end
    end
    
    timeslip_params = {
      :dated_on => Date.parse(date).strftime("%FT%TZ"), # 2011-08-16T13:32:00Z
      :project_id => codebase_project_id,
      :hours => (minutes.to_i / 60.0),
      :user_id => user_id_map[user],
      :comment => summary
    }
    
    if ticket_id.nil?
      timeslip_params[:new_task] = task_name
    else
      timeslip_params[:task_id] = ticket_id
    end
    
    timeslip = Freeagent::Timeslip.new timeslip_params
    timeslip.save
    
    puts "Added #{minutes.to_i} minutes for #{task_name}"
    
    # Refresh project tasks if we just created a new one
    project_tasks = project.tasks if ticket_id.nil?
  end
end

