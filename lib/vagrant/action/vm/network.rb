require 'set'

require 'log4r'

require 'vagrant/util/network_ip'

module Vagrant
  module Action
    module VM
      # This action handles all `config.vm.network` configurations by
      # setting up the VM properly and enabling the networks afterword.
      class Network
        # Utilities to deal with network addresses
        include Util::NetworkIP

        def initialize(app, env)
          @logger = Log4r::Logger.new("vagrant::action::vm::network")

          @app = app
        end

        def call(env)
          @env = env

          # First we have to get the array of adapters that we need
          # to create on the virtual machine itself, as well as the
          # driver-agnostic network configurations for each.
          @logger.debug("Determining adapters and networks...")
          adapters = []
          networks = []
          env[:vm].config.vm.networks.each do |type, args|
            # Get the normalized configuration we'll use around
            config = send("#{type}_config", args)

            # Get the virtualbox adapter configuration
            adapter = send("#{type}_adapter", config)
            adapters << adapter

            # Get the network configuration
            network = send("#{type}_network_config", config)
            networks << network
          end

          if !adapters.empty?
            # Automatically assign an adapter number to any adapters
            # that aren't explicitly set.
            @logger.debug("Assigning adapter locations...")
            assign_adapter_locations(adapters)

            # Verify that our adapters are good just prior to enabling them.
            verify_adapters(adapters)

            # Create all the network interfaces
            @logger.info("Enabling adapters...")
            env[:ui].info I18n.t("vagrant.actions.vm.network.preparing")
            env[:vm].driver.enable_adapters(adapters)
          end

          # Continue the middleware chain. We're done with our VM
          # setup until after it is booted.
          @app.call(env)

          if !adapters.empty?
            # Determine the interface numbers for the guest.
            assign_interface_numbers(networks, adapters)

            # Configure all the network interfaces on the guest.
            env[:ui].info I18n.t("vagrant.actions.vm.network.configuring")
            env[:vm].guest.configure_networks(networks)
          end
        end

        # This method assigns the adapter to use for the adapter.
        # e.g. it says that the first adapter is actually on the
        # virtual machine's 2nd adapter location.
        #
        # It determines the adapter numbers by simply finding the
        # "next available" in each case.
        #
        # The adapters are modified in place by adding an ":adapter"
        # field to each.
        def assign_adapter_locations(adapters)
          available  = Set.new(1..8)

          # Determine which NICs are actually available.
          interfaces = @env[:vm].driver.read_network_interfaces
          interfaces.each do |number, nic|
            # Remove the number from the available NICs if the
            # NIC is in use.
            available.delete(number) if nic[:type] != :none
          end

          # Based on the available set, assign in order to
          # the adapters.
          available = available.to_a.sort
          @logger.debug("Available NICs: #{available.inspect}")
          adapters.each do |adapter|
            # Ignore the adapters that already have been assigned
            if !adapter[:adapter]
              # If we have no available adapters, then that is an exceptional
              # event.
              raise Errors::NetworkNoAdapters if available.empty?

              # Otherwise, assign as the adapter the next available item
              adapter[:adapter] = available.shift
            end
          end
        end

        # Verifies that the adapter configurations look good. This will
        # raise an exception in the case that any errors occur.
        def verify_adapters(adapters)
          # Verify that there are no collisions in the adapters being used.
          used = Set.new
          adapters.each do |adapter|
            raise Errors::NetworkAdapterCollision if used.include?(adapter[:adapter])
            used.add(adapter[:adapter])
          end
        end

        # Assigns the actual interface number of a network based on the
        # enabled NICs on the virtual machine.
        #
        # This interface number is used by the guest to configure the
        # NIC on the guest VM.
        #
        # The networks are modified in place by adding an ":interface"
        # field to each.
        def assign_interface_numbers(networks, adapters)
          current = 0
          adapter_to_interface = {}

          # Make a first pass to assign interface numbers by adapter location
          vm_adapters = @env[:vm].driver.read_network_interfaces
          vm_adapters.each do |number, adapter|
            if adapter[:type] != :none
              # Not used, so assign the interface number and increment
              adapter_to_interface[number] = current
              current += 1
            end
          end

          # Make a pass through the adapters to assign the :interface
          # key to each network configuration.
          adapters.each_index do |i|
            adapter = adapters[i]
            network = networks[i]

            # Figure out the interface number by simple lookup
            network[:interface] = adapter_to_interface[adapter[:adapter]]
          end
        end

        def hostonly_config(args)
          ip      = args[0]
          options = args[1] || {}

          options = {
            :ip      => ip,
            :netmask => "255.255.255.0",
            :adapter => nil,
            :mac     => nil,
            :name    => nil
          }.merge(options)

          # Verify that this hostonly network wouldn't conflict with any
          # bridged interfaces
          verify_no_bridge_collision(options)

          # Return the hostonly network configuration
          return options
        end

        def hostonly_adapter(config)
          @logger.debug("Searching for matching network: #{config[:ip]}")
          interface = find_matching_hostonly_network(config)

          if !interface
            @logger.debug("Network not found. Creating if we can.")

            # It is an error case if a specific name was given but the network
            # doesn't exist.
            if config[:name]
              raise Errors::NetworkNotFound, :name => config[:name]
            end

            # Otherwise, we create a new network and put the net network
            # in the list of available networks so other network definitions
            # can use it!
            interface = create_hostonly_network(config)
            @logger.debug("Created network: #{interface[:name]}")
          end

          return {
            :adapter     => config[:adapter],
            :type        => :hostonly,
            :hostonly    => interface[:name],
            :mac_address => config[:mac]
          }
        end

        def hostonly_network_config(config)
          return {
            :type    => :static,
            :ip      => config[:ip],
            :netmask => config[:netmask]
          }
        end

        # Creates a new hostonly network that matches the network requested
        # by the given host-only network configuration.
        def create_hostonly_network(config)
          # First we need to determine a good IP for the host machine
          # of this interface. We choose to use the network address
          # plus 1, which is usually what is expected.
          netaddr = network_address(config[:ip], config[:netmask])
          parts   = netaddr.split(".").map { |i| i.to_i }
          parts[3] += 1
          ip      = parts.join(".")

          # Create the options that are going to be used to create our
          # new network.
          options = config.dup
          options[:ip] = ip

          @env[:vm].driver.create_host_only_network(options)
        end

        # Finds a host only network that matches our configuration on VirtualBox.
        # This will return nil if a matching network does not exist.
        def find_matching_hostonly_network(config)
          this_netaddr = network_address(config[:ip], config[:netmask])

          @env[:vm].driver.read_host_only_interfaces.each do |interface|
            if config[:name] && config[:name] == interface[:name]
              return interface
            elsif this_netaddr == network_address(interface[:ip], interface[:netmask])
              return interface
            end
          end

          nil
        end

        # Verifies that a host-only network subnet would not collide with
        # a bridged networking interface.
        #
        # If the subnets overlap in any way then the host only network
        # will not work because the routing tables will force the traffic
        # onto the real interface rather than the virtualbox interface.
        def verify_no_bridge_collision(options)
          this_netaddr = network_address(options[:ip], options[:netmask])

          @env[:vm].driver.read_bridged_interfaces.each do |interface|
            that_netaddr = network_address(interface[:ip], interface[:netmask])
            raise Errors::NetworkCollision if this_netaddr == that_netaddr
          end
        end

        def bridged_config(args)
          options = args[0] || {}

          return {
            :adapter => nil,
            :mac     => nil
          }.merge(options)
        end

        def bridged_adapter(config)
          bridgedifs = @env[:vm].driver.read_bridged_interfaces

          # Output all the interfaces that are available as choices
          @env[:ui].info I18n.t("vagrant.actions.vm.bridged_networking.available",
                                :prefix => false)
          bridgedifs.each_index do |index|
            interface = bridgedifs[index]
            @env[:ui].info("#{index + 1}) #{interface[:name]}", :prefix => false)
          end

          # The range of valid choices
          valid = Range.new(1, bridgedifs.length)

          # The choice that the user has chosen as the bridging interface
          choice = nil
          while !valid.include?(choice)
            choice = @env[:ui].ask("What interface should the network bridge to? ")
            choice = choice.to_i
          end

          # Given the choice we can now define the adapter we're using
          return {
            :adapter     => config[:adapter],
            :type        => :bridged,
            :bridge      => bridgedifs[choice - 1][:name],
            :mac_address => config[:mac]
          }
        end

        def bridged_network_config(config)
          return {
            :type => :dhcp
          }
        end
      end
    end
  end
end
