require "capistrano-mon/version"
require "capistrano/configuration/actions/file_transfer_ext"
require "capistrano/configuration/resources/file_resources"
require "erb"
require "find"
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
          # after 'deploy:finalize_update', 'mon:update'

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
          #   application => {:repository => repository, :plugins => "config/plugins" },
          # }}
          #
          _cset(:mon_plugins_repository_cache) { File.expand_path("./tmp/mon-cache") }
          task(:update_plugins, :roles => :app, :except => { :no_release => true }) {
            plugins = mon_plugins.map { |key, val|
              if /^(ftp|http)s?:\/\// =~ key
                [ File.basename(val || URI.parse(key).path), {:uri => key, :wget => true} ]
              else
                [ key, val ]
              end
            }
            tmpdir = run_locally("mktemp -d /tmp/capistrano-mon.XXXXXXXXXX").chomp
            begin
              fetch_plugins(tmpdir, plugins)
              distribute_plugins(tmpdir, mon_plugins_path)
            ensure
#             run_locally("rm -rf #{tmpdir.dump}") rescue nil
            end
          }

          def fetch_plugins(destination, plugins, options={})
            plugins.each do |name, options|
              if options[:wget]
                fetch_plugins_wget(destination, name, options)
              else
                fetch_plugins_repository(destination, name, options)
              end
            end
          end

          def fetch_plugins_wget(destination, name, options={})
            uri = options.delete(:uri)
            file = mon_plugin_path(name, :path => destination)
            execute = []
            execute << "mkdir -p #{File.dirname(file).dump}"
            execute << "wget --no-verbose -O #{file.dump} #{uri.dump}"
            execute << "chmod a+x #{file.dump}"
            run_locally(execute.join(" && "))
          end

          def fetch_plugins_repository(destination, name, options={})
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

            plugins = [ options.fetch(:plugins, "/") ].flatten.compact
            execute = plugins.map { |c|
              repository_cache_subdir = File.join(repository_cache, c)
              exclusions = options.fetch(:plugins_exclude, []).map { |e| "--exclude=\"#{e}\"" }.join(" ")
              "rsync -lrpt #{exclusions} #{repository_cache_subdir}/ #{destination}"
            }
            run_locally(execute.join(" && "))
          end

          def distribute_plugins(destination, remote_destination)
            Find.find(destination) do |plugin_file|
              if File.file?(plugin_file)
                safe_upload(plugin_file, mon_plugin_path(plugin_file, :path => remote_destination),
                            :install => :if_modified, :mode => "a+x", :sudo => true)
              end
            end
          end

          def mon_plugin_path(name, options={})
            path = options.fetch(:path, ".")
            basename = File.basename(name)
            case basename
            when /\.alert$/   then File.join(path, "alert.d", basename)
            when /\.monitor$/ then File.join(path, "mon.d", basename)
            when /\.state$/   then File.join(path, "state.d", basename)
            else
              abort("Unknown plugin type: #{name}")
            end
          end

          task(:install_service, :roles => :app, :except => { :no_release => true }) {
            # TODO: setup (sysvinit|daemontools|upstart|runit|systemd) service of mon
          }

          _cset(:mon_template_path, File.join(File.dirname(__FILE__), 'capistrano-mon', 'templates'))
          _cset(:mon_configure_files, %w(/etc/default/mon mon.cf))
          task(:configure, :roles => :app, :except => { :no_release => true }) {
            mon_configure_files.each do |f|
              safe_put(template(f, :path => mon_template_path), (File.expand_path(f) == f ? f : File.join(mon_path, f)),
                       :sudo => true, :place => :if_modified)
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
