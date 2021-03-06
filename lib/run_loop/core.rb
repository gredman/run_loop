require 'fileutils'
require 'tmpdir'
require 'timeout'
require 'json'
require 'open3'
require 'erb'
require 'ap'

module RunLoop

  class TimeoutError < RuntimeError
  end

  class WriteFailedError < RuntimeError
  end

  module Core

    START_DELIMITER = "OUTPUT_JSON:\n"
    END_DELIMITER="\nEND_OUTPUT"

    SCRIPTS_PATH = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'scripts'))
    SCRIPTS = {
        :dismiss => 'run_dismiss_location.js',
        :run_loop_fast_uia => 'run_loop_fast_uia.js',
        :run_loop_shared_element => 'run_loop_shared_element.js',
        :run_loop_host => 'run_loop_host.js',
        :run_loop_basic => 'run_loop_basic.js'
    }

    READ_SCRIPT_PATH = File.join(SCRIPTS_PATH, 'read-cmd.sh')
    TIMEOUT_SCRIPT_PATH = File.join(SCRIPTS_PATH, 'timeout3')

    def self.scripts_path
      SCRIPTS_PATH
    end

    def self.log_run_loop_options(options, xctools)
      return unless ENV['DEBUG'] == '1'
      # Ignore :sim_control b/c it is a ruby object; printing is not useful.
      ignored_keys = [:sim_control]
      options_to_log = {}
      options.each_pair do |key, value|
        next if ignored_keys.include?(key)
        options_to_log[key] = value
      end
      # Objects that override '==' cannot be printed by awesome_print
      # https://github.com/michaeldv/awesome_print/issues/154
      # RunLoop::Version overrides '=='
      options_to_log[:xcode] = xctools.xcode_version.to_s
      options_to_log[:xcode_path] = xctools.xcode_developer_dir
      ap(options_to_log, {:sort_keys => true})
    end

    # @deprecated since 1.0.0
    # still used extensively in calabash-ios launcher
    def self.above_or_eql_version?(target_version, xcode_version)
      if target_version.is_a?(RunLoop::Version)
        target = target_version
      else
        target = RunLoop::Version.new(target_version)
      end

      if xcode_version.is_a?(RunLoop::Version)
        xcode = xcode_version
      else
        xcode = RunLoop::Version.new(xcode_version)
      end
      target >= xcode
    end

    def self.script_for_key(key)
      if SCRIPTS[key].nil?
        return nil
      end
      File.join(scripts_path, SCRIPTS[key])
    end

    def self.detect_connected_device
      begin
        Timeout::timeout(1, TimeoutError) do
          return `#{File.join(scripts_path, 'udidetect')}`.chomp
        end
      rescue TimeoutError => _
        `killall udidetect &> /dev/null`
      end
      nil
    end

    # Raise an error if the application binary is not compatible with the
    # target simulator.
    #
    # @note This method is implemented for CoreSimulator environments only;
    #  for Xcode < 6.0 this method does nothing.
    #
    # @param [Hash] launch_options These options need to contain the app bundle
    #   path and a udid that corresponds to a simulator name or simulator udid.
    #   In practical terms:  call this after merging the original launch
    #   options with those options that are discovered.
    #
    # @param [RunLoop::SimControl] sim_control A simulator control object.
    # @raise [RuntimeError] Raises an error if the `launch_options[:udid]`
    #  cannot be used to find a simulator.
    # @raise [RunLoop::IncompatibleArchitecture] Raises an error if the
    #  application binary is not compatible with the target simulator.
    def self.expect_compatible_simulator_architecture(launch_options, sim_control)
      if sim_control.xcode_version_gte_6?
        sim_identifier = launch_options[:udid]
        simulator = sim_control.simulators.find do |simulator|
          [simulator.instruments_identifier(sim_control.xctools),
           simulator.udid].include?(sim_identifier)
        end

        if simulator.nil?
          raise "Could not find simulator with identifier '#{sim_identifier}'"
        end

        lipo = RunLoop::Lipo.new(launch_options[:bundle_dir_or_bundle_id])
        lipo.expect_compatible_arch(simulator)
        if ENV['DEBUG'] == '1'
          puts "Simulator instruction set '#{simulator.instruction_set}' is compatible with #{lipo.info}"
        end
        true
      else
        if ENV['DEBUG'] == '1'
          puts "Xcode #{sim_control.xctools.xcode_version} detected; skipping simulator architecture check."
        end
        false
      end
    end

    def self.run_with_options(options)
      before = Time.now

      sim_control ||= options[:sim_control] || RunLoop::SimControl.new
      xctools ||= options[:xctools] || sim_control.xctools

      RunLoop::Instruments.new.kill_instruments(xctools)

      device_target = options[:udid] || options[:device_target] || detect_connected_device || 'simulator'
      if device_target && device_target.to_s.downcase == 'device'
        device_target = detect_connected_device
      end

      log_file = options[:log_path]
      timeout = options[:timeout] || 30

      results_dir = options[:results_dir] || Dir.mktmpdir('run_loop')
      results_dir_trace = File.join(results_dir, 'trace')
      FileUtils.mkdir_p(results_dir_trace)

      dependencies = options[:dependencies] || []
      dependencies << File.join(scripts_path, 'calabash_script_uia.js')
      dependencies.each do |dep|
        FileUtils.cp(dep, results_dir)
      end

      script = File.join(results_dir, '_run_loop.js')


      code = File.read(options[:script])
      code = code.gsub(/\$PATH/, results_dir)
      code = code.gsub(/\$READ_SCRIPT_PATH/, READ_SCRIPT_PATH)
      code = code.gsub(/\$TIMEOUT_SCRIPT_PATH/, TIMEOUT_SCRIPT_PATH)
      code = code.gsub(/\$MODE/, 'FLUSH') unless options[:no_flush]

      repl_path = File.join(results_dir, 'repl-cmd.pipe')
      FileUtils.rm_f(repl_path)

      uia_strategy = options[:uia_strategy]
      if uia_strategy == :host
        create_uia_pipe(repl_path)
      end

      cal_script = File.join(SCRIPTS_PATH, 'calabash_script_uia.js')
      File.open(script, 'w') do |file|
        if include_calabash_script?(options)
          file.puts IO.read(cal_script)
        end
        file.puts code
      end

      # Compute udid and bundle_dir / bundle_id from options and target depending on Xcode version
      udid, bundle_dir_or_bundle_id = udid_and_bundle_for_launcher(device_target, options, xctools)

      args = options.fetch(:args, [])

      inject_dylib = self.dylib_path_from_options options
      # WIP This is brute-force call against all lldb processes.
      self.ensure_lldb_not_running if inject_dylib

      log_file ||= File.join(results_dir, 'run_loop.out')

      after = Time.now
      if ENV['DEBUG'] == '1'
        puts "Preparation took #{after-before} seconds"
      end

      discovered_options =
            {
                  :udid => udid,
                  :results_dir_trace => results_dir_trace,
                  :bundle_dir_or_bundle_id => bundle_dir_or_bundle_id,
                  :results_dir => results_dir,
                  :script => script,
                  :log_file => log_file,
                  :args => args
            }
      merged_options = options.merge(discovered_options)

      if self.simulator_target?(merged_options, sim_control)
        # @todo only enable accessibility on the targeted simulator
        sim_control.enable_accessibility_on_sims({:verbose => false})
        self.expect_compatible_simulator_architecture(merged_options, sim_control)
      end

      self.log_run_loop_options(merged_options, xctools)

      cmd = instruments_command(merged_options, xctools)

      log_header("Starting on #{device_target} App: #{bundle_dir_or_bundle_id}")
      cmd_str = cmd.join(' ')

      log(cmd_str) if ENV['DEBUG'] == '1'

      if !jruby? && RUBY_VERSION && RUBY_VERSION.start_with?('1.8')
        pid = fork do
          exec(cmd_str)
        end
      else
        pid = spawn(cmd_str)
      end

      Process.detach(pid)

      File.open(File.join(results_dir, 'run_loop.pid'), 'w') do |f|
        f.write pid
      end

      run_loop = {:pid => pid,
                  :index => 1,
                  :uia_strategy => uia_strategy,
                  :udid => udid,
                  :app => bundle_dir_or_bundle_id,
                  :repl_path => repl_path,
                  :log_file => log_file,
                  :results_dir => results_dir}

      uia_timeout = options[:uia_timeout] || (ENV['UIA_TIMEOUT'] && ENV['UIA_TIMEOUT'].to_f) || 10

      raw_lldb_output = nil
      before = Time.now
      begin

        if options[:validate_channel]
          options[:validate_channel].call(run_loop, 0, uia_timeout)
        else
          cmd = "UIALogger.logMessage('Listening for run loop commands')"
          File.open(repl_path, 'w') { |file| file.puts "0:#{cmd}" }
          Timeout::timeout(timeout, TimeoutError) do
            read_response(run_loop, 0, uia_timeout)
          end
        end

        # inject_dylib will be nil or a path to a dylib
        if inject_dylib
          lldb_template_file = File.join(scripts_path, 'calabash.lldb.erb')
          lldb_template = ::ERB.new(File.read(lldb_template_file))
          lldb_template.filename = lldb_template_file

          # Special!
          # These are required by the ERB in calabash.lldb.erb
          # noinspection RubyUnusedLocalVariable
          cf_bundle_executable = find_cf_bundle_executable(bundle_dir_or_bundle_id)
          # noinspection RubyUnusedLocalVariable
          dylib_path_for_target = inject_dylib

          lldb_cmd = lldb_template.result(binding)

          tmpdir = Dir.mktmpdir('lldb_cmd')
          lldb_script = File.join(tmpdir, 'lldb')

          File.open(lldb_script, 'w') { |f| f.puts(lldb_cmd) }

          if ENV['DEBUG'] == '1'
            puts "lldb script #{lldb_script}"
            puts "=== lldb script ==="
            counter = 0
            File.open(lldb_script, 'r').readlines.each { |line|
              puts "#{counter} #{line}"
              counter = counter + 1
            }
            puts "=== lldb script ==="
          end

          # Forcing a timeout.  Do not retry here.  If lldb is hanging,
          # RunLoop::Core.run* needs to be called again.  Put another way,
          # instruments and lldb must be terminated.
          Retriable.retriable({:tries => 1, :timeout => 12, :interval => 1}) do
            raw_lldb_output = `xcrun lldb -s #{lldb_script}`
            if ENV['DEBUG'] == '1'
              puts raw_lldb_output
            end
          end
        end
      rescue TimeoutError => e
        if ENV['DEBUG'] == '1'
          puts "Failed to launch."
          puts "#{e}: #{e && e.message}"
          if raw_lldb_output
            puts "LLDB OUTPUT: #{raw_lldb_output}"
          end
        end
        raise TimeoutError, "Time out waiting for UIAutomation run-loop to Start. \n Logfile #{log_file} \n\n #{File.read(log_file)}\n"
      end

      after = Time.now()

      if ENV['DEBUG']=='1'
        puts "Launching took #{after-before} seconds"
      end

      run_loop
    end

    # @!visibility private
    # Usually we include CalabashScript to ease uia automation.
    # However in certain scenarios we don't load it since
    # it slows down the UIAutomation initialization process
    # occasionally causing privacy/security dialogs not to be automated.
    #
    # @return {boolean} true if CalabashScript should be loaded
    def self.include_calabash_script?(options)

      if (options[:include_calabash_script] == false) || options[:dismiss_immediate_dialogs]
         return false
      end
      if Core.script_for_key(:run_loop_basic) == options[:script]
        return options[:include_calabash_script]
      end
      true
    end

    # @!visibility private
    # Are we targeting a simulator?
    #
    # @note  The behavior of this method is different than the corresponding
    #   method in Calabash::Cucumber::Launcher method.  If
    #   `:device_target => {nil | ''}`, then the calabash-ios method returns
    #   _false_.  I am basing run-loop's behavior off the behavior in
    #   `self.udid_and_bundle_for_launcher`
    #
    # @see {Core::RunLoop.udid_and_bundle_for_launcher}
    def self.simulator_target?(run_options, sim_control = RunLoop::SimControl.new)
      value = run_options[:device_target]

      # match the behavior of udid_and_bundle_for_launcher
      return true if value.nil? or value == ''

      # support for 'simulator' and Xcode >= 5.1 device targets
      return true if value.downcase.include?('simulator')

      # if Xcode < 6.0, we are done
      return false if not sim_control.xcode_version_gte_6?

      # support for Xcode >= 6 simulator udids
      return true if sim_control.sim_udid? value

      # support for Xcode >= 6 'named simulators'
      sims = sim_control.simulators.each
      sims.find_index { |device| device.name == value } != nil
    end

    # Extracts the value of :inject_dylib from options Hash.
    # @param options [Hash] arguments passed to {RunLoop.run}
    # @return [String, nil] If the options contains :inject_dylibs and it is a
    #  path to a dylib that exists, return the path.  Otherwise return nil or
    #  raise an error.
    # @raise [RuntimeError] If :inject_dylib points to a path that does not exist.
    # @raise [ArgumentError] If :inject_dylib is not a String.
    def self.dylib_path_from_options(options)
      inject_dylib = options.fetch(:inject_dylib, nil)
      return nil if inject_dylib.nil?
      unless inject_dylib.is_a? String
        raise ArgumentError, "Expected :inject_dylib to be a path to a dylib, but found '#{inject_dylib}'"
      end
      dylib_path = File.expand_path(inject_dylib)
      unless File.exist?(dylib_path)
        raise "Cannot load dylib.  The file '#{dylib_path}' does not exist."
      end
      dylib_path
    end

    def self.find_cf_bundle_executable(bundle_dir_or_bundle_id)
      unless File.directory?(bundle_dir_or_bundle_id)
        raise "Injecting dylibs currently only works with simulator and app bundles"
      end
      info_plist = Dir[File.join(bundle_dir_or_bundle_id, 'Info.plist')].first
      raise "Unable to find Info.plist in #{bundle_dir_or_bundle_id}" if info_plist.nil?
      `/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "#{info_plist}"`.strip
    end

    # Returns the a default simulator to target.  This default needs to be one
    # that installed by default in the current Xcode version.
    #
    # For historical reasons, the most recent non-64b SDK should be used.
    #
    # @param [RunLoop::XCTools] xcode_tools Used to detect the current xcode
    #  version.
    def self.default_simulator(xcode_tools=RunLoop::XCTools.new)
      if xcode_tools.xcode_version_gte_62?
        'iPhone 5 (8.2 Simulator)'
      elsif xcode_tools.xcode_version_gte_61?
        'iPhone 5 (8.1 Simulator)'
      elsif xcode_tools.xcode_version_gte_6?
        'iPhone 5 (8.0 Simulator)'
      else
        'iPhone Retina (4-inch) - Simulator - iOS 7.1'
      end
    end

    def self.udid_and_bundle_for_launcher(device_target, options, xctools=RunLoop::XCTools.new)
      bundle_dir_or_bundle_id = options[:app] || ENV['BUNDLE_ID']|| ENV['APP_BUNDLE_PATH'] || ENV['APP']

      unless bundle_dir_or_bundle_id
        raise 'key :app or environment variable APP_BUNDLE_PATH, BUNDLE_ID or APP must be specified as path to app bundle (simulator) or bundle id (device)'
      end

      udid = nil

      if xctools.xcode_version_gte_51?
        if device_target.nil? || device_target.empty? || device_target == 'simulator'
          device_target = self.default_simulator(xctools)
        end
        udid = device_target

        unless /simulator/i.match(device_target)
          bundle_dir_or_bundle_id = options[:bundle_id] if options[:bundle_id]
        end
      else
        if device_target == 'simulator'

          unless File.exist?(bundle_dir_or_bundle_id)
            raise "Unable to find app in directory #{bundle_dir_or_bundle_id} when trying to launch simulator"
          end


          device = options[:device] || :iphone
          device = device && device.to_sym

          plistbuddy='/usr/libexec/PlistBuddy'
          plistfile="#{bundle_dir_or_bundle_id}/Info.plist"
          if device == :iphone
            uidevicefamily=1
          else
            uidevicefamily=2
          end
          system("#{plistbuddy} -c 'Delete :UIDeviceFamily' '#{plistfile}'")
          system("#{plistbuddy} -c 'Add :UIDeviceFamily array' '#{plistfile}'")
          system("#{plistbuddy} -c 'Add :UIDeviceFamily:0 integer #{uidevicefamily}' '#{plistfile}'")
        else
          udid = device_target
          bundle_dir_or_bundle_id = options[:bundle_id] if options[:bundle_id]
        end
      end
      return udid, bundle_dir_or_bundle_id
    end

    # @deprecated 1.0.0 replaced with Xctools#version
    def self.xcode_version(xctools=RunLoop::XCTools.new)
      xctools.xcode_version.to_s
    end

    def self.create_uia_pipe(repl_path)
      begin
        Timeout::timeout(5, TimeoutError) do
          loop do
            begin
              FileUtils.rm_f(repl_path)
              return repl_path if system(%Q[mkfifo "#{repl_path}"])
            rescue Errno::EINTR => e
              #retry
              sleep(0.1)
            end
          end
        end
      rescue TimeoutError => _
        raise TimeoutError, 'Unable to create pipe (mkfifo failed)'
      end
    end

    def self.jruby?
      RUBY_PLATFORM == 'java'
    end

    def self.write_request(run_loop, cmd, logger=nil)
      repl_path = run_loop[:repl_path]
      index = run_loop[:index]
      cmd_str = "#{index}:#{escape_host_command(cmd)}"
      should_log = (ENV['DEBUG'] == '1')
      RunLoop.log_info(logger, cmd_str) if should_log
      write_succeeded = false
      2.times do |i|
        RunLoop.log_info(logger, "Trying write of command #{cmd_str} at index #{index}") if should_log
        File.open(repl_path, 'w') { |f| f.puts(cmd_str) }
        write_succeeded = validate_index_written(run_loop, index, logger)
        break if write_succeeded
      end
      unless write_succeeded
        RunLoop.log_info(logger, 'Failing...Raising RunLoop::WriteFailedError') if should_log
        raise RunLoop::WriteFailedError.new("Trying write of command #{cmd_str} at index #{index}")
      end
      run_loop[:index] = index + 1

      index
    end

    def self.validate_index_written(run_loop, index, logger)
      begin
        Timeout::timeout(10, TimeoutError) do
          Core.read_response(run_loop, index, 10, 'last_index')
        end
        RunLoop.log_info(logger, "validate index written for index #{index} ok")
        return true
      rescue TimeoutError => _
        RunLoop.log_info(logger, "validate index written for index #{index} failed. Retrying.")
        return false
      end
    end

    def self.escape_host_command(cmd)
      backquote = "\\"
      cmd.gsub(backquote,backquote*4)
    end

    def self.read_response(run_loop, expected_index, empty_file_timeout=10, search_for_property='index')

      log_file = run_loop[:log_file]
      initial_offset = run_loop[:initial_offset] || 0
      offset = initial_offset

      result = nil
      loop do
        unless File.exist?(log_file) && File.size?(log_file)
          sleep(0.2)
          next
        end


        size = File.size(log_file)

        output = File.read(log_file, size-offset, offset)

        if /AXError: Could not auto-register for pid status change/.match(output)
          if /kAXErrorServerNotFound/.match(output)
            $stderr.puts "\n\n****** Accessibility is not enabled on device/simulator, please enable it *** \n\n"
            $stderr.flush
          end
          raise TimeoutError.new('AXError: Could not auto-register for pid status change')
        end
        if /Automation Instrument ran into an exception/.match(output)
          raise TimeoutError.new('Exception while running script')
        end
        index_if_found = output.index(START_DELIMITER)
        if ENV['DEBUG_READ']=='1'
          puts output.gsub('*', '')
          puts "Size #{size}"
          puts "offset #{offset}"
          puts "index_of #{START_DELIMITER}: #{index_if_found}"
        end

        if index_if_found

          offset = offset + index_if_found
          rest = output[index_if_found+START_DELIMITER.size..output.length]
          index_of_json = rest.index("}#{END_DELIMITER}")

          if index_of_json.nil?
            #Wait for rest of json
            sleep(0.1)
            next
          end

          json = rest[0..index_of_json]


          if ENV['DEBUG_READ']=='1'
            puts "Index #{index_if_found}, Size: #{size} Offset #{offset}"

            puts ("parse #{json}")
          end

          offset = offset + json.size
          parsed_result = JSON.parse(json)
          if ENV['DEBUG_READ']=='1'
            p parsed_result
          end
          json_index_if_present = parsed_result[search_for_property]
          if json_index_if_present && json_index_if_present == expected_index
            result = parsed_result
            break
          end
        else
          sleep(0.1)
        end
      end

      run_loop[:initial_offset] = offset

      result

    end

    # @deprecated 1.0.5
    def self.pids_for_run_loop(run_loop, &block)
      RunLoop::Instruments.new.instruments_pids(&block)
    end

    def self.instruments_command_prefix(udid, results_dir_trace)
      instruments_path = 'xcrun instruments'
      if udid
        instruments_path = "#{instruments_path} -w \"#{udid}\""
      end
      instruments_path << " -D \"#{results_dir_trace}\"" if results_dir_trace
      instruments_path
    end


    def self.instruments_command(options, xctools=RunLoop::XCTools.new)
      udid = options[:udid]
      results_dir_trace = options[:results_dir_trace]
      bundle_dir_or_bundle_id = options[:bundle_dir_or_bundle_id]
      results_dir = options[:results_dir]
      script = options[:script]
      log_file = options[:log_file]
      args= options[:args] || []

      instruments_prefix = instruments_command_prefix(udid, results_dir_trace)
      cmd = [
          instruments_prefix,
          '-t', "\"#{automation_template(xctools)}\"",
          "\"#{bundle_dir_or_bundle_id}\"",
          '-e', 'UIARESULTSPATH', results_dir,
          '-e', 'UIASCRIPT', script,
          args.join(' ')
      ]
      if log_file
        cmd << "&> #{log_file}"
      end
      cmd
    end

    def self.automation_template(xctools, candidate = ENV['TRACE_TEMPLATE'])
      unless candidate && File.exist?(candidate)
        candidate = default_tracetemplate xctools
      end
      candidate
    end

    def self.default_tracetemplate(xctools=RunLoop::XCTools.new)
      templates = xctools.instruments :templates

      # xcrun instruments -s templates
      # Xcode >= 6 will return known, Apple defined tracetemplates as names
      #  e.g.  Automation, Zombies, Allocations
      #
      # Xcode < 6 will return known, Apple defined tracetemplates as paths.
      #
      # Xcode 6 Beta versions also return paths, but revert to 'normal'
      # behavior when GM is released.
      res = templates.select { |name| name == 'Automation' }.first
      return res if res

      res = templates.select do |path|
        path =~ /\/Automation.tracetemplate/ and path =~ /Xcode/
      end.first.tr("\"", '').strip
      return res if res

      msgs = ['Expected instruments to report an Automation tracetemplate.',
              'Please report this as bug:  https://github.com/calabash/run_loop/issues',
              "In the bug report, include the output of:\n",
              '$ xcrun xcodebuild -version',
              "$ xcrun instruments -s templates\n"]
      raise msgs.join("\n")
    end

    def self.log(message)
      if ENV['DEBUG']=='1'
        puts "#{Time.now } #{message}"
        $stdout.flush
      end
    end

    def self.log_header(message)
      if ENV['DEBUG']=='1'
        puts "\n\e[#{35}m### #{message} ###\e[0m"
        $stdout.flush
      end
    end

    # @deprecated 1.0.5
    def self.ensure_instruments_not_running!
      RunLoop::Instruments.new.kill_instruments
    end

    def self.instruments_running?
      RunLoop::Instruments.new.instruments_running?
    end

    # @deprecated 1.0.5
    def self.instruments_pids
      RunLoop::Instruments.new.instruments_pids
    end

    # @todo This is a WIP
    # @todo Needs rspec test
    def self.ensure_lldb_not_running
      descripts = `xcrun ps x -o pid,command | grep "lldb" | grep -v grep`.strip.split("\n")
      descripts.each do |process_desc|
        pid = process_desc.split(' ').first
        Open3.popen3("xcrun kill -9 #{pid} && xcrun wait #{pid}") do |_, stdout, stderr, _|
          out = stdout.read.strip
          err = stderr.read.strip
          next if out.to_s.empty? and err.to_s.empty?
          # there lots of 'ownership' problems trying to kill the lldb process
          #puts "kill process '#{pid}' => stdout: '#{out}' | stderr: '#{err}'"
        end
      end
    end
  end

  def self.default_script_for_uia_strategy(uia_strategy)
    case uia_strategy
      when :preferences
        Core.script_for_key(:run_loop_fast_uia)
      when :host
        Core.script_for_key(:run_loop_host)
      when :shared_element
        Core.script_for_key(:run_loop_shared_element)
      else
        Core.script_for_key(:run_loop_basic)
    end
  end

  def self.run(options={})

    if RunLoop::Instruments.new.instruments_app_running?
      msg =
            [
                  "Please quit the Instruments.app.",
                  "If Instruments.app is open, the instruments command line",
                  "tool cannot take control of your application."
            ]
      raise msg.join("\n")
    end

    uia_strategy = options[:uia_strategy]
    if options[:script]
      script = validate_script(options[:script])
    else
      if uia_strategy
        script = default_script_for_uia_strategy(uia_strategy)
      else
        if options[:calabash_lite]
          uia_strategy = :host
          script = Core.script_for_key(:run_loop_host)
        else
          uia_strategy = :preferences
          script = default_script_for_uia_strategy(uia_strategy)
        end
      end
    end
    # At this point, 'script' has been chosen, but uia_strategy might not
    unless uia_strategy
      desired_script = options[:script]
      if desired_script.is_a?(String) #custom path to script
        uia_strategy = :host
      elsif desired_script == :run_loop_host
        uia_strategy = :host
      elsif desired_script == :run_loop_fast_uia
        uia_strategy = :preferences
      elsif desired_script == :run_loop_shared_element
        uia_strategy = :shared_element
      else
        raise "Inconsistent state: desired script #{desired_script} has not uia_strategy"
      end
    end
    # At this point script and uia_strategy selected

    options[:script] = script
    options[:uia_strategy] = uia_strategy

    Core.run_with_options(options)
  end

  def self.send_command(run_loop, cmd, options={timeout: 60}, num_retries=0, last_error=nil)
    if num_retries > 3
      if last_error
        raise last_error
      else
        raise "Max retries exceeded #{num_retries} > 3. No error recorded."
      end
    end

    if options.is_a?(Numeric)
      options = {timeout: options}
    end

    if not cmd.is_a?(String)
      raise "Illegal command #{cmd} (must be a string)"
    end

    if not options.is_a?(Hash)
      raise "Illegal options #{options} (must be a Hash (or number for compatibility))"
    end

    timeout = options[:timeout] || 60
    logger = options[:logger]
    interrupt_retry_timeout = options[:interrupt_retry_timeout] || 25

    expected_index = run_loop[:index]
    result = nil
    begin
      expected_index = Core.write_request(run_loop, cmd, logger)
    rescue RunLoop::WriteFailedError, Errno::EINTR => write_error
      # Attempt recover from interrupt by attempting to read result (assuming write went OK)
      # or retry if attempted read result fails
      run_loop[:index] = expected_index # restore expected index in case it changed
      log_info(logger, "Core.write_request failed: #{write_error}. Attempting recovery...")
      log_info(logger, "Attempting read in case the request was received... Please wait (#{interrupt_retry_timeout})...")
      begin
        Timeout::timeout(interrupt_retry_timeout, TimeoutError) do
          result = Core.read_response(run_loop, expected_index)
        end
        # Update run_loop expected index since we succeeded in reading the index
        run_loop[:index] = expected_index + 1
        log_info(logger, "Did read response for interrupted request of index #{expected_index}... Proceeding.")
        return result
      rescue TimeoutError => _
        log_info(logger, "Read did not result in a response for index #{expected_index}... Retrying send_command...")
        return send_command(run_loop, cmd, options, num_retries+1, write_error)
      end
    end


    begin
      Timeout::timeout(timeout, TimeoutError) do
        result = Core.read_response(run_loop, expected_index)
      end
    rescue TimeoutError => _
      raise TimeoutError, "Time out waiting for UIAutomation run-loop for command #{cmd}. Waiting for index:#{expected_index}"
    end

    result
  end

  def self.stop(run_loop, out=Dir.pwd)
    return if run_loop.nil?
    results_dir = run_loop[:results_dir]
    dest = out

    RunLoop::Instruments.new.kill_instruments

    FileUtils.mkdir_p(dest)
    if results_dir
      pngs = Dir.glob(File.join(results_dir, 'Run 1', '*.png'))
    else
      pngs = []
    end
    FileUtils.cp(pngs, dest) if pngs and pngs.length > 0
  end


  def self.validate_script(script)
    if script.is_a?(String)
      unless File.exist?(script)
        raise "Unable to find file: #{script}"
      end
    elsif script.is_a?(Symbol)
      script = Core.script_for_key(script)
      unless script
        raise "Unknown script for symbol: #{script}. Options: #{Core::SCRIPTS.keys.join(', ')}"
      end
    else
      raise "Script must be a symbol or path: #{script}"
    end
    script
  end

  def self.log_info(logger, message)
    msg = "#{Time.now}: #{message}"
    if logger && logger.respond_to?(:info)
      logger.info(msg)
    else
      puts msg if ENV['DEBUG'] == '1'
    end
  end
end
