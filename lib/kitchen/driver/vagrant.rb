# -*- encoding: utf-8 -*-
#
# Author:: Fletcher Nichol (<fnichol@nichol.ca>)
#
# Copyright (C) 2012, Fletcher Nichol
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "erb"
require "fileutils"
require "rubygems/version"

require "kitchen"
require "kitchen/driver/vagrant_version"

module Kitchen

  module Driver

    # Vagrant driver for Kitchen. It communicates to Vagrant via the CLI.
    #
    # @author Fletcher Nichol <fnichol@nichol.ca>
    class Vagrant < Kitchen::Driver::Base

      include ShellOut

      kitchen_driver_api_version 2

      plugin_version Kitchen::Driver::VAGRANT_VERSION

      default_config(:box) { |driver| driver.default_box }
      required_config :box

      default_config :box_check_update, nil

      default_config(:box_url) { |driver| driver.default_box_url }

      default_config :box_version, nil

      default_config :cache_scope, :box

      default_config :cache_auto_detect, true

      default_config :customize, {}

      default_config :gui, nil

      default_config :network, []

      default_config :pre_create_command, nil

      default_config :provision, false

      default_config :provider do |_|
        ENV.fetch("VAGRANT_DEFAULT_PROVIDER", "virtualbox")
      end

      default_config :ssh, {}

      default_config :synced_folders, []

      default_config :vagrantfile_erb,
        File.join(File.dirname(__FILE__), "../../../templates/Vagrantfile.erb")
      expand_path_for :vagrantfile_erb

      default_config :vagrantfiles, []
      expand_path_for :vagrantfiles

      default_config(:vm_hostname) do |driver|
        driver.windows_os? ? nil : driver.instance.name
      end

      no_parallel_for :create, :destroy

      # Creates a Vagrant VM instance.
      #
      # @param state [Hash] mutable instance state
      # @raise [ActionFailed] if the action could not be completed
      def create(state)
        create_vagrantfile
        run_pre_create_command
        run_vagrant_up
        update_state(state)
        instance.transport.connection(state).wait_until_ready
        info("Vagrant instance #{instance.to_str} created.")
      end

      # @return [String,nil] the Vagrant box for this Instance
      def default_box
        if bento_box?(instance.platform.name)
          "opscode-#{instance.platform.name}"
        else
          instance.platform.name
        end
      end

      # @return [String,nil] the Vagrant box URL for this Instance
      def default_box_url
        return unless bento_box?(instance.platform.name)

        provider = config[:provider]
        provider = "vmware" if config[:provider] =~ /^vmware_(.+)$/

        if %w[virtualbox vmware].include?(provider)
          "https://opscode-vm-bento.s3.amazonaws.com/vagrant/#{provider}/" \
            "opscode_#{instance.platform.name}_chef-provisionerless.box"
        end
      end

      # Destroys an instance.
      #
      # @param state [Hash] mutable instance state
      # @raise [ActionFailed] if the action could not be completed
      def destroy(state)
        return if state[:hostname].nil?

        create_vagrantfile
        @vagrantfile_created = false
        instance.transport.connection(state).close
        run("vagrant destroy -f")
        FileUtils.rm_rf(vagrant_root)
        info("Vagrant instance #{instance.to_str} destroyed.")
        state.delete(:hostname)
      end

      # A lifecycle method that should be invoked when the object is about
      # ready to be used. A reference to an Instance is required as
      # configuration dependant data may be access through an Instance. This
      # also acts as a hook point where the object may wish to perform other
      # last minute checks, validations, or configuration expansions.
      #
      # @param instance [Instance] an associated instance
      # @return [self] itself, for use in chaining
      # @raise [ClientError] if instance parameter is nil
      def finalize_config!(instance)
        super
        finalize_vm_hostname!
        finalize_pre_create_command!
        finalize_synced_folders!
        self
      end

      # Performs whatever tests that may be required to ensure that this driver
      # will be able to function in the current environment. This may involve
      # checking for the presence of certain directories, software installed,
      # etc.
      #
      # @raise [UserError] if the driver will not be able to perform or if a
      #   documented dependency is missing from the system
      def verify_dependencies
        super
        if Gem::Version.new(vagrant_version) < Gem::Version.new(MIN_VER.dup)
          raise UserError, "Detected an old version of Vagrant " \
            "(#{vagrant_version})." \
            " Please upgrade to version #{MIN_VER} or higher from #{WEBSITE}."
        end
      end

      # @return [TrueClass,FalseClass] whether or not the transport's name
      #   implies a WinRM-based transport
      # @api private
      def winrm_transport?
        instance.transport.name.downcase =~ /win_?rm/
      end

      protected

      WEBSITE = "http://www.vagrantup.com/downloads.html".freeze
      MIN_VER = "1.1.0".freeze

      class << self

        # @return [true,false] whether or not the vagrant-winrm plugin is
        #   installed
        # @api private
        attr_accessor :winrm_plugin_passed

        # @return [String] the version of Vagrant installed on the workstation
        # @api private
        attr_accessor :vagrant_version
      end

      # Retuns whether or not a platform name could have a correcponding Bento
      # box produced by the Bento project.
      # (https://github.com/chef/bento).
      #
      # @return [TrueClass,FalseClass] whether or not the name could be a Bento
      #   box
      # @api private
      def bento_box?(name)
        name =~ /^(centos|debian|fedora|freebsd|opensuse|ubuntu)-/
      end

      # Renders and writes out a Vagrantfile dedicated to this instance.
      #
      # @api private
      def create_vagrantfile
        return if @vagrantfile_created

        vagrantfile = File.join(vagrant_root, "Vagrantfile")
        debug("Creating Vagrantfile for #{instance.to_str} (#{vagrantfile})")
        FileUtils.mkdir_p(vagrant_root)
        File.open(vagrantfile, "wb") { |f| f.write(render_template) }
        debug_vagrantfile(vagrantfile)
        @vagrantfile_created = true
      end

      # Logs the Vagrantfile's contents to the debug log level.
      #
      # @param vagrantfile [String] path to the Vagrantfile
      # @api private
      def debug_vagrantfile(vagrantfile)
        return unless logger.debug?

        debug("------------")
        IO.read(vagrantfile).each_line { |l| debug("#{l.chomp}") }
        debug("------------")
      end

      # Replaces any `{{vagrant_root}}` tokens in the pre create command.
      #
      # @api private
      def finalize_pre_create_command!
        return if config[:pre_create_command].nil?

        config[:pre_create_command] = config[:pre_create_command].
          gsub("{{vagrant_root}}", vagrant_root)
      end

      # Replaces an `%{instance_name}` tokens in the synced folder items.
      #
      # @api private
      def finalize_synced_folders!
        config[:synced_folders] = config[:synced_folders].
          map do |source, destination, options|
            [
              File.expand_path(
                source.gsub("%{instance_name}", instance.name),
                config[:kitchen_root]
              ),
              destination.gsub("%{instance_name}", instance.name),
              options || "nil"
            ]
          end
      end

      # Truncates the length of `:vm_hostname` to 12 characters for
      # Windows-based operating systems.
      #
      # @api private
      def finalize_vm_hostname!
        string = config[:vm_hostname]

        if windows_os? && string.is_a?(String) && string.size >= 12
          config[:vm_hostname] = "#{string[0...10]}-#{string[-1]}"
        end
      end

      # Loads any required third party Ruby libraries or runs any shell out
      # commands to prepare the plugin. This method will be called in the
      # context of the main thread of execution and so does not necessarily
      # have to be thread safe.
      #
      # @raise [ClientError] if any library loading fails or any of the
      #   dependency requirements cannot be satisfied
      # @api private
      def load_needed_dependencies!
        super
        verify_winrm_plugin if winrm_transport?
      end

      # Renders the Vagrantfile ERb template.
      #
      # @return [String] the contents for a Vagrantfile
      # @raise [ActionFailed] if the Vagrantfile template was not found
      # @api private
      def render_template
        template = File.expand_path(
          config[:vagrantfile_erb], config[:kitchen_root])

        if File.exist?(template)
          ERB.new(IO.read(template)).result(binding).gsub(%r{^\s*$\n}, "")
        else
          raise ActionFailed, "Could not find Vagrantfile template #{template}"
        end
      end

      # Convenience method to run a command locally.
      #
      # @param cmd [String] command to run locally
      # @param options [Hash] options hash
      # @see Kitchen::ShellOut.run_command
      # @api private
      def run(cmd, options = {})
        cmd = "echo #{cmd}" if config[:dry_run]
        run_command(cmd, { :cwd => vagrant_root }.merge(options))
      end

      # Delegates to Kitchen::ShellOut.run_command, overriding some default
      # options:
      #
      # * `:use_sudo` defaults to the value of `config[:use_sudo]` in the
      #   Driver object
      # * `:log_subject` defaults to a String representation of the Driver's
      #   class name
      #
      # @see Kitchen::ShellOut#run_command
      def run_command(cmd, options = {})
        merged = {
          :use_sudo => config[:use_sudo], :log_subject => name
        }.merge(options)
        super(cmd, merged)
      end

      # Runs a local command before `vagrant up` has been called.
      #
      # @api private
      def run_pre_create_command
        if config[:pre_create_command]
          run(config[:pre_create_command], :cwd => config[:kitchen_root])
        end
      end

      # Runs a local command without streaming the stdout to the logger.
      #
      # @param cmd [String] command to run locally
      # @api private
      def run_silently(cmd, options = {})
        merged = {
          :live_stream => nil, :quiet => (logger.debug? ? false : true)
        }.merge(options)
        run(cmd, merged)
      end

      # Runs the `vagrant up` command locally.
      #
      # @api private
      def run_vagrant_up
        cmd = "vagrant up"
        cmd += " --no-provision" unless config[:provision]
        cmd += " --provider #{config[:provider]}" if config[:provider]
        run(cmd)
      end

      # Updates any state after creation.
      #
      # @param state [Hash] mutable instance state
      # @api private
      def update_state(state)
        hash = winrm_transport? ? vagrant_config(:winrm) : vagrant_config(:ssh)

        state[:hostname] = hash["HostName"]
        state[:port] = hash["Port"]
        state[:username] = hash["User"]
        state[:password] = hash["Password"] if hash["Password"]
        state[:ssh_key] = hash["IdentityFile"] if hash["IdentityFile"]
        state[:proxy_command] = hash["ProxyCommand"] if hash["ProxyCommand"]
        state[:rdp_port] = hash["RDPPort"] if hash["RDPPort"]
      end

      # @return [String] full local path to the directory containing the
      #   instance's Vagrantfile
      # @api private
      def vagrant_root
        @vagrant_root ||= instance.nil? ? nil : File.join(
          config[:kitchen_root], %w[.kitchen kitchen-vagrant],
          "kitchen-#{File.basename(config[:kitchen_root])}-#{instance.name}"
        )
      end

      # @param type [Symbol] either `:ssh` or `:winrm`
      # @return [Hash] key/value pairs resulting from parsing a
      #   `vagrant ssh-config` or `vagrant winrm-config` local command
      #   invocation
      # @api private
      def vagrant_config(type)
        lines = run_silently("vagrant #{type}-config").split("\n").map do |line|
          tokens = line.strip.partition(" ")
          [tokens.first, tokens.last.gsub(/"/, "")]
        end
        Hash[lines]
      end

      # @return [String] version of Vagrant
      # @raise [UserError] if the `vagrant` command can not be found locally
      # @api private
      def vagrant_version
        self.class.vagrant_version ||= run_silently(
          "vagrant --version", :cwd => Dir.pwd).chomp.split(" ").last
      rescue Errno::ENOENT
        raise UserError, "Vagrant #{MIN_VER} or higher is not installed." \
          " Please download a package from #{WEBSITE}."
      end

      # Verify that the vagrant-winrm plugin is installed and a suitable
      #   version of Vagrant is installed
      #
      # @api private
      def verify_winrm_plugin
        if Gem::Version.new(vagrant_version) < Gem::Version.new("1.6")
          raise UserError, "Detected an old version of Vagrant " \
            "(#{vagrant_version}) that cannot support the vagrant-winrm " \
            "Vagrant plugin." \
            " Please upgrade to version 1.6 or higher from #{WEBSITE}."
        end

        if !winrm_plugin_installed?
          raise UserError, "WinRM Transport requires the vagrant-winrm " \
            "Vagrant plugin to properly communicate with this Vagrant VM. " \
            "Please install this plugin with: " \
            "`vagrant plugin install vagrant-winrm' and try again."
        end
      end

      # @return [true,false] whether or not the vagrant-winrm plugin is
      #   installed
      # @api private
      def winrm_plugin_installed?
        return true if self.class.winrm_plugin_passed

        self.class.winrm_plugin_passed = run_silently(
          "vagrant plugin list", :cwd => Dir.pwd).
          split("\n").find { |line| line =~ /^vagrant-winrm\s+/ }
      end
    end
  end
end
