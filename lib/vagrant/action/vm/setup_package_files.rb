require 'pathname'

module Vagrant
  module Action
    module VM
      # Sets up the mapping of files to copy into the package and verifies
      # that the files can be properly copied.
      class SetupPackageFiles
        def initialize(app, env)
          @app = app

          env["package.include"] ||= []
          env["package.vagrantfile"] ||= nil
        end

        def call(env)
          raise Errors::PackageRequiresDirectory if !env["package.directory"] ||
            !File.directory?(env["package.directory"])

          # Create a pathname to the directory that will store the files
          # we wish to include with the box.
          include_directory = Pathname.new(env["package.directory"]).join("include")

          files = {}
          env["package.include"].each do |file|
            source = Pathname.new(file)
            dest   = nil

            # If the source is relative then we add the file as-is to the include
            # directory. Otherwise, we copy only the file into the root of the
            # include directory. Kind of strange, but seems to match what people
            # expect based on history.
            if source.relative?
              dest = include_directory.join(source)
            else
              dest = include_directory.join(source.basename)
            end

            # Assign the mapping
            files[file] = dest
          end

          if env["package.vagrantfile"]
            # Vagrantfiles are treated special and mapped to a specific file
            files[env["package.vagrantfile"]] = include_directory.join("_Vagrantfile")
          end

          # Verify the mapping
          files.each do |from, _|
            raise Errors::PackageIncludeMissing, :file => from if !File.exist?(from)
          end

          # Save the mapping
          env["package.files"] = files

          @app.call(env)
        end
      end
    end
  end
end