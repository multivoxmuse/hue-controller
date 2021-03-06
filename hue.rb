#!/usr/bin/env ruby
# Hue Controller script. Pass arguments to get info or control a hue bridge.

ENV['RUBYLIB'] = '.:..:./hue'
$VERBOSE = true if ENV['VERBOSE'] == 'true'

require 'json'
require 'hue/lights'
require 'hue/auth'

class ArgumentError < StandardError; end

# Checking for credentials
$USERNAME = ""
$WAIT_TIME = 1
$AUTHENTICATED_OBJECT = nil

creds_path = "#{Dir.home}/.hue.creds"
config_path = "#{Dir.home}/.hue.config"
profiles_dir = "#{Dir.home}/.hue.profiles"

if File.file?(config_path)
  config = JSON.parse(File.open(config_path).read)
  ::Hue::Api.hostname = config['default']['hostname']
  ::Hue::Api.port = config['default']['port']
end

if File.file?(creds_path)
	creds = JSON.parse(File.open(creds_path).read)
	# Set username for later api use
	$USERNAME = creds['default']['username']
else
  authenticated = false
  until authenticated == true
    username = ::Hue::Auth.new(secret: 'pre-auth-token').create_user("hue-controller#ruby")
    if username.nil?
      puts("Press the link button on the hue bridge.") if $WAIT_TIME == 1
      sleep($WAIT_TIME)
      print(' ...')
      $WAIT_TIME = $WAIT_TIME * 2
    elsif username.class == String
      puts("Successfully authenticated. Your new api token is: #{username}")
      puts("Writing to config file #{creds_path}.")
      begin
        File.write(creds_path, JSON.generate(default: {username: username}))
      rescue StandardError => e
        puts("Error was: #{e}")
        puts("Write operation failed. Please manually create the file #{creds_path} and put this in it:\n")
        puts("{ \"default\" : {\n  \"username\" : \"#{username}\"\n  }\n}")
        abort('exiting.')
      end
      authenticated = true
    else
      abort('Unexpected route.')
    end
  end
end

# Check that we're connected and have an authenticated user
bridge_name = ::Hue::Auth.new(secret: $USERNAME).check_auth
puts("Successfully authenticated to bridge: #{bridge_name}") if $VERBOSE

STATES = [ 'on', 'sat', 'hue', 'bri', 'effect' ]
COMMANDS = [ 'color', 'turn', 'setstate', 'set', 'getstate', 'randomize', 'percent' ]

def hue_obj
  $AUTHENTICATED_OBJECT || ::Hue::Lights.new(secret: $USERNAME)
end

def set_state(light, state, value)
  puts "light:#{light} state to set:#{state}, state value:#{value}" if $VERBOSE
  if STATES.include?(state) && light.to_s =~ /[0-9]/
    puts("Setting light #{light} #{state} to #{value}")
    value = true if value == 'true'
    value = false if value == 'false'
    value = value.to_i if value =~ /[0-9]/
    status = hue_obj.set_state_by_lnum(light, state, value)
    puts(status)
	else
    puts("Not doing it. STATES=#{STATES}\nRegex eval? #{light =~ /[0-9]/}")
  end
end

def set_percentage(light, state, percent)
  puts("Setting light #{light} #{state} to #{percent}%")
  status = hue_obj.percent_of_max_by_lnum(light, {state => percent})
end

def run_command(light, command, params)
  command = command.downcase
  print("light: #{light} command: #{command}") if $VERBOSE
  print(" params: #{params}\n") unless params.empty? if $VERBOSE
  if command == 'turn'
    if ['on', 'off'].include?(params[0])
      value = params[0] == 'on' ? true : false
      set_state(light, 'on', value)
    end
  end

  if command == 'color'
    set_state(light, 'hue', ::Hue.color(params[0]))
  end

  # Try to set a manual attribute at your own risk
  if command == 'setstate' || command == 'set'
    hue_state = params[0]
    value = params[1]
    if STATES.include?(hue_state)
      set_state(light, hue_state, value)
    else
      abort("Only these states are allowed: #{STATES}")
    end
  end

  if command == 'percent'
    hue_state = params[0]
    percent = params[1]
    if STATES.include?(hue_state)
      set_percentage(light, hue_state, percent)
    else
      abort("Could not set percentage of invalid parameter #{hue_state}")
    end
  end

  # Try to get a specific attribute
  if command == 'getstate'
    hue_state = params[0]
    puts(hue_obj.get_states_by_lnum(light)['state'][hue_state])
  end

  # Set random values for color, saturation, brightness
  if command == 'randomize'
    states = {
      hue: rand(0..65535),
      bri: rand(30..254),
      sat: rand(30..254)
    }
    puts("Brightness: #{states[:bri]} | Hue: #{states[:hue]} | Saturation: #{states[:sat]}")
    puts(hue_obj.set_states_by_lnum(light, states))
  end
end

if ARGV[0]
  if ARGV[0] == 'all_on'
    hue_obj.all_on
  elsif ARGV[0] == 'all_off'
    hue_obj.all_off
  elsif ARGV[0] == 'all'
    # Group methods
    if ARGV[1] == 'dim'
      hue_obj.all_dim
    elsif ARGV[1] == 'off'
      hue_obj.all_off
    elsif ARGV[1] == 'on'
      hue_obj.all_on
    elsif ARGV[1] == 'bright'
      hue_obj.all_bright
    else
      groups = [0]
    end
  elsif ARGV[0] =~ /[0-9]/
    lights = [ARGV[0].to_i]
  elsif ARGV[0] == 'profile'
    if ARGV[1]
      profile_path = "#{profiles_dir}/#{ARGV[1]}"
      abort("Could not load profile #{profile_path}") unless File.file?(profile_path)
      hue_obj.set_profile(JSON.parse(open(profile_path).read))
    else
      puts(JSON.generate(hue_obj.profile))
      exit 0
    end
  else
    groups = hue_obj.room_ids(ARGV[0].downcase)
  end
end

if lights
  puts("Selected lights: #{lights}")
  lights.each do |light|
    if ARGV[1]
      if COMMANDS.include?(ARGV[1])
        command = ARGV[1]
        run_command(light, command, ARGV[2..-1])
				puts hue_obj.get_states_by_lnum(light) if $VERBOSE
      elsif ARGV[1] == 'loop'
        hue_obj.set_states_by_lnum(light, effect: 'colorloop')
      elsif ['clear', 'none', 'stop', 'null', 'nil', 'regular', 'normal'].include?(ARGV[1])
        hue_obj.set_states_by_lnum(light, effect: 'none')
      else
        puts "Invalid command #{ARGV[1]}"
        exit 1
      end
    else
      light_info = hue_obj.get_states_by_lnum(light)
      puts("Light: #{light} name: #{light_info['name']} | on? #{light_info['state']['on']}\nAll info:#{light_info}")
    end
  end
end

if groups
  puts("Selected groups: #{groups}")
  groups.each do |grp|
    if ARGV[1].nil?
      # No parameters passed, just want info
      group_info = hue_obj.get_states_by_group(grp)
      puts("Group: #{grp} | name: #{group_info['name']} | All info: #{group_info}")
    elsif ARGV[1] == 'sat'
      # Saturation
      if ARGV[2]
        new_sat = ARGV[2].to_i
      end
      hue_obj.set_states_by_group(grp, sat: new_sat)
    elsif ARGV[1] == 'loop'
      # Effect: colorloop
      hue_obj.set_states_by_group(grp, effect: 'colorloop')
    elsif ['clear', 'none', 'stop', 'null', 'nil', 'regular', 'normal'].include?(ARGV[1])
      # Effect: none
      hue_obj.set_states_by_group(grp, effect: 'none')
    elsif
      # See if parameter matches a color name. If so, just set the group to that color
      begin
        clr = ::Hue.color(ARGV[1])
      rescue ::Hue::ColorNotFoundError
        puts("Did not match any colors with #{ARGV[1]}") if $VERBOSE
        false
      end
        puts("Turning group #{grp} #{ARGV[1]}")
        hue_obj.group_color(grp, ARGV[1])
    end
  end
end
