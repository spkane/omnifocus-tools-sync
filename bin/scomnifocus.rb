#!/usr/bin/env ruby

require 'bundler/setup'
Bundler.require(:default)

require 'appscript'
require 'yaml'
require 'json'

opts = Trollop::options do
  banner ""
  banner <<-EOS
ServerCentral Omnifocus Sync Tool

Usage:
       scofsync [options]

KNOWN ISSUES:
      * With long names you must use an equal sign ( i.e. --hostname=test-target-1 )

---
EOS
  version 'scofsync 1.0.0'
  opt :username, 'ServerCentral Username', :type => :string, :short => 'u', :required => false
  opt :password, 'ServerCentral Password', :type => :string, :short => 'p', :required => false
  opt :hostname, 'ServerCentral Portal Hostname', :type => :string, :short => 'h', :default => 'portal.servercentral.com'
  opt :context, 'OF Default Context', :type => :string, :short => 'c', :required => false
  opt :project, 'OF Default Project', :type => :string, :short => 'r', :required => false
  opt :flag, 'Flag tasks in OF', :type => :boolean, :short => 'f', :required => false
  opt :filter, 'SC Filter', :type => :string, :short => 'j', :required => false
  opt :quiet, 'Disable terminal output', :short => 'q', :default => true
end

class Hash
  #take keys of hash and transform those to a symbols
  def self.transform_keys_to_symbols(value)
    return value if not value.is_a?(Hash)
    hash = value.inject({}){|memo,(k,v)| memo[k.to_sym] = Hash.transform_keys_to_symbols(v); memo}
    return hash
  end
end

if  File.file?(ENV['HOME']+'/.scofsync.yaml')
  config = YAML.load_file(ENV['HOME']+'/.scofsync.yaml')
  config = Hash.transform_keys_to_symbols(config)
=begin
YAML CONFIG EXAMPLE
---
servercentral:
  hostname: 'portal.servercentral.com'
  username: 'jdoe'
  password: 'blahblahblah'
  context: 'ServerCentral'
  project: 'Work'
  flag: true
  filter: 'assignee = currentUser() AND status not in (Closed, Resolved) AND sprint in openSprints()'
=end
end

syms = [:username, :hostname, :context, :project, :flag, :filter]
syms.each { |x|
  unless opts[x]
    if config[:servercentral][x]
      opts[x] = config[:servercentral][x]
    else
      puts 'Please provide a ' + x.to_s + ' value on the CLI or in the config file.'
      exit 1
    end
  end
}

unless opts[:password]
  if config[:servercentral][:password]
    opts[:password] = config[:servercentral][:password]
  else
    opts[:password] = ask("password: ") {|q| q.echo = false}
  end
end

#ServerCentral Configuration
SC_BASE_URL = 'https://' + opts[:hostname]
SC_VIEW_URL = 'https://support.servercentral.com/index.php?/Tickets/Ticket/View/'
USERNAME = opts[:username]
PASSWORD = opts[:password]

QUERY = opts[:filter]
FILTER = URI::encode(QUERY)

#OmniFocus Configuration
DEFAULT_CONTEXT = opts[:context]
DEFAULT_PROJECT = opts[:project]
FLAGGED = opts[:flag]

# This method gets all issues that are assigned to your USERNAME and whos status isn't Closed or Resolved.  It returns a Hash of Hashes where the key is the ServerCentral Ticket ID.
def get_issues
  sc_issues = Hash.new
  # This is the REST URL that will be hit.  Change the filter if you want to adjust the query used here
  uri = URI(SC_BASE_URL + '/api/tickets?scope=all&status=open&search=' + FILTER)

  Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    request = Net::HTTP::Get.new(uri)
    request.basic_auth USERNAME, PASSWORD
    response = http.request request
    currentPage = nil
    totalPages = nil
    # If the response was good, then grab the data
    if response.code =~ /20[0-9]{1}/
      data = JSON.parse(response.body)
      if data["status"] != 0 then raise StandardError, "Unsuccessful API status code: " + data["status"] end
      currentPage = data["ticketData"]["thisPage"]
      totalPages = data["ticketData"]["totalPages"]
    else
      raise StandardError, "Unsuccessful HTTP response code: " + response.code
    end
    while currentPage <= totalPages
      uri = URI(SC_BASE_URL + '/api/tickets?scope=all&status=open&search=' + FILTER + '&page=' + currentPage.to_s)
      currentRequest = Net::HTTP::Get.new uri
      currentRequest.basic_auth USERNAME, PASSWORD
      currentResponse = http.request currentRequest
      # If the response was good, then grab the data
      if currentResponse.code =~ /20[0-9]{1}/
        data = JSON.parse(currentResponse.body)
        puts data
        if data["status"] != 0 then raise StandardError, "Unsuccessful API status code: " + data["status"] end
      else
        raise StandardError, "Unsuccessful HTTP response code: " + currentResponse.code
      end
      if data["status"] != 0 then raise StandardError, "Unsuccessful API status code: " + data["status"] end
      data["ticketData"]["Tickets"].each do |item|
        sc_id = item["Ticket"]["Id"]
        sc_issues[sc_id] = Hash.new
        sc_issues[sc_id]['subject'] = item["Ticket"]["Subject"]
        #sc_issues['ticket']['posts'] = item["Ticket"]["Posts"]
      end
      currentPage = currentPage + 1
    end
    return sc_issues
  end
end

# This method adds a new Task to OmniFocus based on the new_task_properties passed in
def add_task(omnifocus_document, new_task_properties)
  # If there is a passed in OF project name, get the actual project object
  if new_task_properties['project']
    proj_name = new_task_properties["project"]
    proj = omnifocus_document.flattened_tasks[proj_name]
  end

  # Check to see if there's already an OF Task with that name in the referenced Project
  # If there is, just stop.
  name   = new_task_properties["name"]
  exists = proj.tasks.get.find { |t| t.name.get == name }
  return false if exists

  # If there is a passed in OF context name, get the actual context object
  if new_task_properties['context']
    ctx_name = new_task_properties["context"]
    ctx = omnifocus_document.flattened_contexts[ctx_name]
  end

  # Do some task property filtering.  I don't know what this is for, but found it in several other scripts that didn't work...
  tprops = new_task_properties.inject({}) do |h, (k, v)|
    h[:"#{k}"] = v
    h
  end

  # Remove the project property from the new Task properties, as it won't be used like that.
  tprops.delete(:project)
  # Update the context property to be the actual context object not the context name
  tprops[:context] = ctx if new_task_properties['context']

  # You can uncomment this line and comment the one below if you want the tasks to end up in your Inbox instead of a specific Project
#  new_task = omnifocus_document.make(:new => :inbox_task, :with_properties => tprops)

  # Make a new Task in the Project
  proj.make(:new => :task, :with_properties => tprops)

  puts "task created"
  return true
end

# This method is responsible for getting your assigned ServerCentral Tickets and adding them to OmniFocus as Tasks
def add_sc_tickets_to_omnifocus ()
  # Get the open ServerCentral issues assigned to you
  results = get_issues
  if results.nil?
    puts "No results from ServerCentral"
    exit
  end

  # Get the OmniFocus app and main document via AppleScript
  omnifocus_app = Appscript.app.by_name("OmniFocus")
  omnifocus_document = omnifocus_app.default_document

  # Iterate through resulting issues.
  results.each do |ticket|
    # Create the task name by adding the ticket summary to the ServerCentral ticket key
    task_name = "#{ticket[0]}: #{ticket[1]['subject']}"
    # Create the task notes with the ServerCentral Ticket URL
    task_notes = "#{SC_VIEW_URL}#{ticket[0]}"

    # Build properties for the Task
    @props = {}
    @props['name'] = task_name
    @props['project'] = DEFAULT_PROJECT
    @props['context'] = DEFAULT_CONTEXT
    @props['note'] = task_notes
    @props['flagged'] = FLAGGED
    add_task(omnifocus_document, @props)
  end
end

def mark_resolved_sc_tickets_as_complete_in_omnifocus ()
  # get tasks from the project
  omnifocus_app = Appscript.app.by_name("OmniFocus")
  omnifocus_document = omnifocus_app.default_document
  ctx = omnifocus_document.flattened_contexts[DEFAULT_CONTEXT]
  ctx.tasks.get.find.each do |task|
    if task.note.get.include? SC_VIEW_URL
      # try to parse out ServerCentral id
      full_url = task.note.get
      sc_id = full_url.sub(SC_VIEW_URL,"")
      # check status of the ticket
      uri = URI(SC_BASE_URL + '/api/tickets/' + sc_id)

      Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        request = Net::HTTP::Get.new(uri)
        request.basic_auth USERNAME, PASSWORD
        response = http.request request

        if response.code =~ /20[0-9]{1}/
          data = JSON.parse(response.body)
          # Check to see if the ServerCentral ticket has been closed, if so mark it as complete.
          status = data["ticketData"]["Status"]
          if status == "Closed"
            # if resolved, mark it as complete in OmniFocus
            if task.completed.get != true
              task.completed.set(true)
              puts "task marked completed"
            end
          end
        else
         raise StandardError, "Unsuccessful response code " + response.code + " for issue " + sc_id
        end
      end
    end
  end
end

def app_is_running(app_name)
  `ps aux` =~ /#{app_name}/ ? true : false
end

def main ()
   if app_is_running("OmniFocus")
	  add_sc_tickets_to_omnifocus
	  mark_resolved_sc_tickets_as_complete_in_omnifocus
   end
end

main
