require 'gooddata'
require 'prettyprint'
require 'optparse'
require "json"
require_relative('lib/core/metadata')

#
#
# Simple example
# 126102 Hard Example with custom metric
#
# Notes
# Twilio Flex Insights Solution uses GoodData platform for
# GoodData workspaces contain dashboards, reports, definition, attributes, etc.
# - A dashboard contains reports
# - Reports has one or many reportDefinition (saved definition)
# - reportDefinition contains metrics, attributes, and elementValues (for filters)
# - metrics contain other metrics, facts, attributes, and elementValues (for filters)
#
# GoodData Workspaces objects (reports, metrics, definitions) have two types of identifiers
# Internal Identifier, numeric, which is usually something like /gdc/md/w9wwwltvaq63ipwy5etdzlb2nda59jtl/obj/5308 or simply 5308
# External identifiers:
#   - For model objects is something like attributes.conversation.ivr_path.
#   - For objects generated in the UI (reports, metrics, dashboards) something like this b08a2c8ca8f4. It is randomly generated for each object. There is a minimal chance of collisions
#  - Twilio ensures that across any Flex Insights workspace, in the out of box solution, two objects with the same external identifier have the same definition
#
# GoodData Workspaces objects (reports, metrics, definitions) have two types of identifiers
# Internal Identifier, or object uri, is a numeric identifier, which is usually dispalyed like /gdc/md/w9wwwltvaq63ipwy5etdzlb2nda59jtl/obj/5308 or simply 5308
#   - The internal identifier is local to each workspace, and we can't externally influence.
#   - For each object created in a workspace makes this number increase
#   - All the GoodData APIs request must use the internal Identifier (there are a few exceptions)
# External identifiers:
#   - Two types:
#      - For the LDM objects (attributes, facts, etc) is something like attributes.conversation.ivr_path.
#      - For objects created via UI (reports, metrics, dashboards) something like this b08a2c8ca8f4. It is randomly generated for each object. There is a minimal chance of collisions
#   - Twilio ensures that across any Flex Insights workspace, in the out of box solution, two objects with the same external identifier have the same definition
# There are APIs for translating back and forth between internal and external identifiers

def get_elements_from_object(obj_string, all_objects, client)

  all_elements = get_uris(obj_string, false).select { |element| element =~ /element/ }

  # Refactor code -> Move Out
  element_to_map = []
  all_elements.map do |element|
    attribute = element.scan(%r{([^\[\]]*)\/elements\?id=(\d+)})[0][0]
    obj = all_objects.find { |obj| obj['uri'] == attribute }

    if obj['category'] == 'attribute'
      element_link = obj['content']['displayForms'][0]['links']['elements']
    else
      element_link = obj['content']['links']['elements']
    end

    title = find_element_value(element, element_link,  client)
    element_to_map <<  { 'category'=> "element", 'uri'=> element, 'attribute'=> obj['identifier'], 'value'=> title}
  end
  return element_to_map
end

def get_objects_from_object_v2( obj, opts)

  case obj['category']
  when "projectDashboard"
    all_objects = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project],  "metric,report,reportDefinition,fact,attribute,attributeDisplayForm", 1 , false )

    all_report = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project], "report", 1 , true )

    all_report.pmap do |report|
      get_objects_from_object_v2( report, opts)
    end

    obj['full_json']['projectDashboard']['meta'].delete('uri')
    obj['full_json']['projectDashboard']['meta'].delete('locked')

    final_obj = copy_obj_to_target_workspace(obj, all_objects, {client: opts[:client], target_project: opts[:project_target],  })


  when "report"

    all_report_definitions = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project], "reportDefinition", 1 , true )
    report_definition = all_report_definitions.sort_by { |obj| -obj['obj_id'].to_i }[0]

    get_objects_from_object_v2( report_definition, opts)

    #Remove any other report definition and setup the new one
    obj['full_json']['report']['meta'].delete('uri')
    obj['full_json']['report']['meta'].delete('locked')
    obj['full_json']['report']['meta']['unlisted'] = 0
    obj['full_json']['report']['content']['domains'] = []
    # Last Definition Only
    obj['full_json']['report']['content']['definitions'] = [ obj['full_json']['report']['content']['definitions'][-1] ]

    final_obj = copy_obj_to_target_workspace(obj, [report_definition ], {client: opts[:client], target_project: opts[:project_target],  })


  when "reportDefinition"

    # Get All the dependencies
    all_objects = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project],  "metric,fact,attribute,attributeDisplayForm", 1 , false )
    # Unfortunately we still need to filter out the elements
    all_objects.concat( get_elements_from_object(obj['content'].to_s, all_objects,  opts[:client] ))

    # Get the metrics on the nearest edge. This must be recursive, since we have to recreate the metrics per order
    direct_metrics  = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project],  "metric", 1 , true)

    direct_metrics.pmap do |metric|
      get_objects_from_object_v2( metric, opts)
    end

    # Delete Links, not needed
    obj['full_json']['reportDefinition'].delete('links')
    # Delete URI (obj_id) so a new one is created
    obj['full_json']['reportDefinition']['meta'].delete('uri')
    obj['full_json']['reportDefinition']['meta'].delete('locked')
    final_obj = copy_obj_to_target_workspace(obj, all_objects, {client: opts[:client], target_project: opts[:project_target],  })


  when "metric"

    all_objects = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project],  "metric,fact,reportDefinition,attribute,attributeDisplayForm", 0 , false )

    all_objects.concat( get_elements_from_object(obj['content']['expression'], all_objects,  opts[:client] ))

    direct_metrics  = get_object_dependencies(obj['obj_id'], opts[:client], opts[:project],  "metric", 1 , true)

    dependent_metrics = direct_metrics.pmap do |metric|
      get_objects_from_object_v2( metric, opts)
    end

    # Minor tweaks on the content. Needs a though
    obj['full_json'][obj['category']]['content']['folders'] = []
    obj['full_json'][obj['category']]['links'] = {}
    obj['full_json'][obj['category']]['meta'].delete('uri')
    obj['full_json'][obj['category']]['meta'].delete('locked')

    final_obj = copy_obj_to_target_workspace(obj, all_objects, {client: opts[:client], target_project: opts[:project_target],  })
  end

  return obj
end

def copy_obj_to_target_workspace(single_obj, all_objects,
                                 opts = { client: GoodData.connection, target_project: GoodData.project })
  # Everything is mapped via identifier! It's critical to ensure it is the same
  results = []

  underlying_uris = all_objects.select{ |o| o['category'] != 'element'}.map { |o| o['identifier'] }

  mapping = map_identifiers_to_uri(underlying_uris, opts[:client], opts[:target_project])
  element_mapping = []

  #Element Mapping is special.
  all_elements = all_objects.select{ |o| o['category'] == 'element'}
  all_elements.map do |element|
    attribute = opts[:target_project].attributes(element['attribute']).primary_label
    element_mapping << {'source_element'=> element['uri'], 'target_element'=> attribute.find_value_uri(element['value'])}
  end

  target_json_string = single_obj['full_json'].to_s
  uris = get_uris( target_json_string )

  #We want to replace elements first!
  uris.sort_by! { |p| -p.length }

  uris.each do | uri |
    old_obj = all_objects.find{ |o| o['uri'] == uri}
    if uri =~ /element/
      new_uri = element_mapping.find{ |m| m['source_element'] == old_obj['uri']}['target_element']
    else
      new_uri = mapping.find{ |m| m['identifier'] == old_obj['identifier'] }['uri']
    end
    if new_uri.nil?
      raise( Exception )
    end
    target_json_string.gsub!(uri, new_uri)
  end

  target_json = eval( target_json_string )

  uri = save_object_ensuring_identifier( target_json, single_obj['identifier'],  opts[:client], opts[:target_project] )

  puts "#{single_obj['category']} with identifier #{single_obj['identifier']} and title #{single_obj['title']} been created/replaced with final uri: #{uri}"

end


Options = Struct.new(:name)

class Parser
  def self.parse(options)
    args = {:server => 'https://analytics.ytica.com'}

    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: copy_objects_old.rb --username [username] --password [password] --server [server] --obj_id [obj_id]"

      opts.on("-u", "--username USERNAME", "Username to Flex Insights Environment") do |u|
        puts u
        args[:user_name] = u
      end

      opts.on("-p", "--password PASSWORD", "password to Flex Insights Environment") do |p|
        args[:password] = p
      end

      opts.on("-s", "--server SERVER", "Server to login into Flex Insights - Defaults to analytics.ytica.com") do |s|
        args[:server] = s
      end

      opts.on("-c", "--config_file FILE", "Configuration file with source, target and objects to copy") do |c|
        args[:conf_file] = c
      end

      opts.on("-h", "--help", "Prints this help") do
        puts opts
        exit
      end
    end

    opt_parser.parse!(options)
    return args
  end
end


options = Parser.parse(ARGV)
file = File.open options[:conf_file]
data = JSON.load file

client = GoodData.connect(options[:user_name], options[:password], server: options[:server] )
project_source = client.projects( data['source_workspace'] )

data['target_workspaces'].each do |target_workspace|
  project_target = client.projects(target_workspace)

  data['dashboards_to_copy'].each do |dashboard|
    object = get_single_object_with_uri( "/gdc/md/#{data['source_workspace']}/obj/#{dashboard}", client)
    puts "Working on the dashboard #{dashboard}"
    get_objects_from_object_v2( object, { client: client, project: project_source, project_target: project_target})
    puts ""
  end

  data['reports_to_copy'].each do |report|
    object = get_single_object_with_uri( "/gdc/md/#{data['source_workspace']}/obj/#{report}", client)
    puts "Working on the report #{report}"
    get_objects_from_object_v2( object, { client: client, project: project_source, project_target: project_target})
    puts ""
  end
end