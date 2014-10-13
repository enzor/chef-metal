require 'chef_metal/convergence_strategy'
require 'pathname'
require 'cheffish'

module ChefMetal
  class ConvergenceStrategy
    class PrecreateChefObjects < ConvergenceStrategy
      def initialize(convergence_options, config)
        super
      end

      def chef_server
        @chef_server ||= convergence_options[:chef_server] || Cheffish.default_chef_server(config)
      end

      def setup_convergence(action_handler, machine)
        # Create keys on machine
        public_key = create_keys(action_handler, machine)
        # Create node and client on chef server
        create_chef_objects(action_handler, machine, public_key)

        # If the chef server lives on localhost, tunnel the port through to the guest
        # (we need to know what got tunneled!)
        chef_server_url = chef_server[:chef_server_url]
        chef_server_url = machine.make_url_available_to_remote(chef_server_url)

        # Support for multiple ohai hints, required on some platforms
        create_ohai_files(action_handler, machine)

        # Create client.rb and client.pem on machine
        content = client_rb_content(chef_server_url, machine.node['name'])
        machine.write_file(action_handler, convergence_options[:client_rb_path], content, :ensure_dir => true)
      end

      def converge(action_handler, machine)
        machine.make_url_available_to_remote(chef_server[:chef_server_url])
      end

      def cleanup_convergence(action_handler, machine_spec)
        _self = self
        ChefMetal.inline_resource(action_handler) do
          chef_node machine_spec.name do
            chef_server _self.chef_server
            action :delete
          end
          chef_client machine_spec.name do
            chef_server _self.chef_server
            action :delete
          end
        end
      end

      protected

      def create_keys(action_handler, machine)
        server_private_key = machine.read_file(convergence_options[:client_pem_path])
        if server_private_key
          begin
            server_private_key, format = Cheffish::KeyFormatter.decode(server_private_key)
          rescue
            server_private_key = nil
          end
        end

        if server_private_key
          if source_key && server_private_key.to_pem != source_key.to_pem
            # If the server private key does not match our source key, overwrite it
            server_private_key = source_key
            if convergence_options[:allow_overwrite_keys]
              machine.write_file(action_handler, convergence_options[:client_pem_path], server_private_key.to_pem, :ensure_dir => true)
            else
              raise "Private key on machine #{machine.name} does not match desired input key."
            end
          end

        else

          # If the server does not already have keys, create them and upload
          _convergence_options = convergence_options
          ChefMetal.inline_resource(action_handler) do
            private_key 'in_memory' do
              path :none
              if _convergence_options[:private_key_options]
                _convergence_options[:private_key_options].each_pair do |key,value|
                  send(key, value)
                end
              end
              after { |resource, private_key| server_private_key = private_key }
            end
          end

          machine.write_file(action_handler, convergence_options[:client_pem_path], server_private_key.to_pem, :ensure_dir => true)
        end

        server_private_key.public_key
      end

      def is_localhost(host)
        host == '127.0.0.1' || host == 'localhost' || host == '[::1]'
      end

      def source_key
        if convergence_options[:source_key].is_a?(String)
          key, format = Cheffish::KeyFormatter.decode(convergence_options[:source_key], convergence_options[:source_key_pass_phrase])
          key
        elsif convergence_options[:source_key]
          convergence_options[:source_key]
        elsif convergence_options[:source_key_path]
          key, format = Cheffish::KeyFormatter.decode(IO.read(convergence_options[:source_key_path]), convergence_options[:source_key_pass_phrase], convergence_options[:source_key_path])
          key
        else
          nil
        end
      end

      # Create the ohai file(s)
      def create_ohai_files(action_handler, machine)
        if convergence_options[:ohai_hints]
          convergence_options[:ohai_hints].each_pair do |hint, data|
            # The location of the ohai hint
            ohai_hint = "/etc/chef/ohai/hints/#{hint}.json"
            machine.write_file(action_handler, ohai_hint, data.to_json, :ensure_dir => true)
          end
        end
      end

      def create_chef_objects(action_handler, machine, public_key)
        _convergence_options = convergence_options
        _chef_server = chef_server
        # Save the node and create the client keys and client.
        ChefMetal.inline_resource(action_handler) do
          # Create client
          chef_client machine.name do
            chef_server _chef_server
            source_key public_key
            output_key_path _convergence_options[:public_key_path]
            output_key_format _convergence_options[:public_key_format]
            admin _convergence_options[:admin]
            validator _convergence_options[:validator]
          end

          # Create node
          # TODO strip automatic attributes first so we don't race with "current state"
          chef_node machine.name do
            chef_server _chef_server
            raw_json machine.node
          end
        end

        # If using enterprise/hosted chef, fix acls
        if chef_server[:chef_server_url] =~ /\/+organizations\/.+/
          grant_client_node_permissions(action_handler, chef_server, machine.name, ["read", "update"])
        end
      end

      # Grant the client permissions to the node
      # This procedure assumes that the client name and node name are the same
      def grant_client_node_permissions(action_handler, chef_server, node_name, perms)
        api = Cheffish.chef_server_api(chef_server)
        node_perms = api.get("/nodes/#{node_name}/_acl")
        perms.each do |p|
          if !node_perms[p]['actors'].include?(node_name)
            action_handler.perform_action "Add #{node_name} to client #{p} ACLs" do
              node_perms[p]['actors'] << node_name
              api.put("/nodes/#{node_name}/_acl/#{p}", p => node_perms[p])
            end
          end
        end
      end

      def client_rb_content(chef_server_url, node_name)
        <<EOM
chef_server_url #{chef_server_url.inspect}
node_name #{node_name.inspect}
client_key #{convergence_options[:client_pem_path].inspect}
ssl_verify_mode :verify_peer
EOM
      end
    end
  end
end
