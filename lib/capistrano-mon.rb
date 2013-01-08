require "capistrano-mon/version"
require "erb"
require "tempfile"
require "tmpdir"
require "uri"

module Capistrano
  module Mon
    def self.extended(configuration)
      configuration.load {
        namespace(:mon) {
          _cset(:mon_path, "/etc/mon")
          _cset(:mon_lib_path, "/var/lib/mon")
          _cset(:mon_log_path, "/var/log/mon")
          _cset(:mon_hostgroup_name) { application }
          _cset(:mon_hostgroup, %w(localhost))
          _cset(:mon_services, {})
          #
          # Example:
          #
          # set(:mon_services) {{
          #   "ping" => {
          #     :description => "Responses to ping",
          #     :interval => "5m",
          #     :monitor => "fping.monitor",
          #     :period => "wd {Mon-Fri} hr {7am-10pm}",
          #     :alert => "mail.alert root@localhost",
          #     :alertevery => "1h",
          #   },
          #   "http" => {
          #     :description => "HTTP service",
          #     :interval => "10m",
          #     :monitor => "http.monitor",
          #     :period => "",
          #     :numalerts => 10,
          #     :alert => "mail.alert root@localhost",
          #     :upalert => "mail.alert root@localhost",
          #   },
          #   "smtp" => {
          #     :description => "SMTP service",
          #     :interval => "10m",
          #     :monitor => "smtp.monitor -t 60",
          #     :period => "",
          #     :numalerts => 10,
          #     :alert => "mail.alert root@localhost",
          #     :upalert => "mail.alert root@localhost",
          #   },
          # }}
          #

          desc("Setup mon.")
          task(:setup, :roles => :app, :except => { :no_release => true }) {
            transaction {
              install
              _update
            }
          }
          after 'deploy:setup', 'mon:setup'

          desc("Update mon configuration.")
          task(:update, :roles => :app, :except => { :no_release => true }) {
            transaction {
              _update
            }
          }
          # Do not run automatically during normal `deploy' to avoid slow down.
          # If you want to do so, add following line in your ./config/deploy.rb
          #
          # after 'deploy:update', 'mon:update'

          task(:_update, :roles => :app, :except => { :no_release => true }) {
            configure
            restart
          }

          _cset(:mon_use_plugins, true)
          task(:install, :roles => :app, :except => { :no_release => true }) {
            install_dependencies
            install_plugins if mon_use_plugins
            install_service
          }

          _cset(:mon_platform) {
            capture((<<-EOS).gsub(/\s+/, ' ')).strip
              if test -f /etc/debian_version; then
                if test -f /etc/lsb-release && grep -i -q DISTRIB_ID=Ubuntu /etc/lsb-release; then
                  echo ubuntu;
                else
                  echo debian;
                fi;
              elif test -f /etc/redhat-release; then
                echo redhat;
              else
                echo unknown;
              fi;
            EOS
          }
          _cset(:mon_dependencies, %w(mon))
          task(:install_dependencies, :roles => :app, :except => { :no_release => true }) {
            unless mon_dependencies.empty?
              case mon_platform
              when /(debian|ubuntu)/i
                run("#{sudo} apt-get install -q -y #{mon_dependencies.join(' ')}")
              when /redhat/i
                run("#{sudo} yum install -q -y #{mon_dependencies.join(' ')}")
              else
                # nop
              end
            end
          }

          task(:install_plugins, :roles => :app, :except => { :no_release => true }) {
            update_plugins
          }

          def tempfile(name)
            f = Tempfile.new(name)
            path = f.path
            f.close(true) # close and remove tempfile immediately
            path
          end

          _cset(:mon_plugins_path, "/usr/local/lib/mon")
          _cset(:mon_plugins, [])
          #
          # Example:
          #
          # ## simple definition
          # set(:mon_plugins, %w(
          #   https://example.com/foo.alert
          #   https://example.com/bar.monitor
          # ))
          #
          # ## use custom plugin name
          # set(:mon_plugins) {{
          #   "https://gist.github.com/raw/2321002/pyhttp.monitor.py" => "pyhttp.monitor",
          # }}
          #
          # ## use repository
          # set(:mon_plugins) {{
          #   application => { :scm => scm, :repository => repository, :revision => revision, :plugins => "config/plugins" },
          # }}
          #
          _cset(:mon_plugins_repository_cache) { File.expand_path('./tmp/capistrano-mon') }
          def fetch_plugins_from_repository(destination, name, options={})
            run_locally("mkdir -p #{destination.dump}")
            configuration = Capistrano::Configuration.new()
            options = {
              :source => lambda { Capistrano::Deploy::SCM.new(configuration[:scm], configuration) },
              :revision => lambda { configuration[:source].head },
              :real_revision => lambda {
                configuration[:source].local.query_revision(configuration[:revision]) { |cmd| with_env("LC_ALL", "C") { run_locally(cmd) } }
              },
            }.merge(options)
            variables.merge(options).each do |key, val|
              configuration.set(key, val)
            end
            repository_cache = File.join(mon_plugins_repository_cache, name)
            if File.exist?(repository_cache)
              run_locally(configuration[:source].sync(configuration[:real_revision], repository_cache))
            else
              run_locally(configuration[:source].checkout(configuration[:real_revision], repository_cache))
            end

            plugins = [ options.fetch(:plugins, '/') ].flatten.compact
            execute = plugins.map { |c|
              repository_cache_subdir = File.join(repository_cache, c)
              exclusions = options.fetch(:plugins_exclude, []).map { |e| "--exclude=\"#{e}\"" }.join(' ')
              "rsync -lrpt #{exclusions} #{repository_cache_subdir}/ #{destination}"
            }
            run_locally(execute.join(' && '))
          end

          def fetch_plugins_from_wget(destination, options={})
            basename = File.basename(options[:basename] || URI.parse(s).path)
            s = options[:uri]
            case basename
            when /\.monitor$/
              d = File.join(destination, "mon.d", basename)
            else
              d = File.join(destination, "%s.d" % [basename[/\.(\w+)$/, 1]], basename)
            end
            execute = []
            execute << "mkdir -p #{File.dirname(d).dump}"
            execute << "wget --no-verbose -O #{d.dump} #{s.dump}"
            execute << "chmod a+rx #{d.dump}"
            run_locally(execute.join(' && '))
          end

          def bundle_plugins(filename, destination)
            run_locally("cd #{File.dirname(destination)} && tar chzf #{filename} #{File.basename(destination)}")
          end

          def distribute_plugins(filename, remote_filename, remote_destination)
            upload(filename, remote_filename)
#           run("rm -rf #{remote_destination}")
            run("cd #{File.dirname(remote_destination)} && #{sudo} tar xzf #{remote_filename}")
          end

          task(:update_plugins, :roles => :app, :except => { :no_release => true }) {
            tmpdir = Dir.mktmpdir()
            remote_tmpdir = capture("mktemp -d").chomp
            destination = File.join(tmpdir, "mon")
            remote_destination = mon_plugins_path
            filename = File.join(tmpdir, "mon.tar.gz")
            remote_filename = File.join(remote_tmpdir, "plugins.tar.gz")
            begin
              mon_plugins.each do |name, options|
                if options.nil?
                  fetch_plugins_from_wget(destination, :uri => name)
                elsif options.is_a?(String)
                  fetch_plugins_from_wget(destination, :uri => name, :basename => options)
                else
                  fetch_plugins_from_repository(destination, name, options)
                end
              end
              bundle_plugins(filename, destination)
              run("mkdir -p #{remote_tmpdir}")
              distribute_plugins(filename, remote_filename, remote_destination)
            ensure
              run("rm -rf #{remote_tmpdir}") rescue nil
              run_locally("rm -rf #{tmpdir}") rescue nil
            end
          }

          task(:install_service, :roles => :app, :except => { :no_release => true }) {
            # TODO: setup (sysvinit|daemontools|upstart|runit|systemd) service of mon
          }

          def template(file)
            if File.file?(file)
              File.read(file)
            elsif File.file?("#{file}.erb")
              ERB.new(File.read("#{file}.erb")).result(binding)
            else
              abort("No such template: #{file} or #{file}.erb")
            end
          end

          _cset(:mon_template_path, File.join(File.dirname(__FILE__), 'capistrano-mon', 'templates'))
          _cset(:mon_configure_files, %w(/etc/default/mon mon.cf))
          task(:configure, :roles => :app, :except => { :no_release => true }) {
            srcs = mon_configure_files.map { |file| File.join(mon_template_path, file) }
            tmps = mon_configure_files.map { |file| tempfile('capistrano-mon') }
            dsts = mon_configure_files.map { |file| File.expand_path(file) == file ? file : File.join(mon_path, file) }
            begin
              srcs.zip(tmps) do |src, tmp|
                put(template(src), tmp)
              end
              execute = []
              dirs = dsts.map { |path| File.dirname(path) }.uniq
              execute << "#{sudo} mkdir -p #{dirs.map { |dir| dir.dump }.join(' ')}" unless dirs.empty?
              tmps.zip(dsts) do |tmp, dst|
                execute << "( diff -u #{dst.dump} #{tmp.dump} || #{sudo} mv -f #{tmp.dump} #{dst.dump} )"
              end
              run(execute.join(' && ')) unless execute.empty?
            ensure
              run("rm -f #{tmps.map { |t| t.dump }.join(' ')}") unless tmps.empty?
            end
          }

          _cset(:mon_service_name, 'mon')
          desc("Start mon daemon.")
          task(:start, :roles => :app, :except => { :no_release => true }) {
            run("#{sudo} service #{mon_service_name} start")
          }

          desc("Stop mon daemon.")
          task(:stop, :roles => :app, :except => { :no_release => true }) {
            run("#{sudo} service #{mon_service_name} stop")
          }

          desc("Restart mon daemon.")
          task(:restart, :roles => :app, :except => { :no_release => true }) {
            run("#{sudo} service #{mon_service_name} restart || #{sudo} service #{mon_service_name} start")
          }

          desc("Show mon daemon status.")
          task(:status, :roles => :app, :except => { :no_release => true }) {
            run("#{sudo} service #{mon_service_name} status")
          }
        }
      }
    end
  end
end

if Capistrano::Configuration.instance
  Capistrano::Configuration.instance.extend(Capistrano::Mon)
end

# vim:set ft=ruby ts=2 sw=2 :
