require "capistrano-mon/version"
require "erb"
require "tempfile"
require "uri"

module Capistrano
  module Mon
    def self.extended(configuration)
      configuration.load {
        namespace(:mon) {
          _cset(:mon_path, "/etc/mon")
          _cset(:mon_lib_path, "/var/lib/mon")
          _cset(:mon_log_path, "/var/log/mon")
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
          after 'deploy:update', 'mon:update'

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
          task(:update_plugins, :roles => :app, :except => { :no_release => true }) {
            srcs = mon_plugins.map { |uri, name| uri }
            tmps = mon_plugins.map { |uri, name| tempfile('capistrano-mon') }
            dsts = mon_plugins.map { |uri, name|
              basename = File.basename(name || URI.parse(uri).path)
              case basename
              when /\.alert$/
                File.join(mon_plugins_path, 'alert.d', basename)
              when /\.monitor$/
                File.join(mon_plugins_path, 'mon.d', basename)
              else
                abort("Unknown plugin type: #{basename}")
              end
            }
            begin
              execute = []
              dirs = dsts.map { |path| File.dirname(path) }.uniq
              execute << "#{sudo} mkdir -p #{dirs.join(' ')}" unless dirs.empty?
              srcs.zip(tmps, dsts) do |src, tmp, dst|
                execute << "wget --no-verbose -O #{tmp.dump} #{src.dump}"
                execute << "( diff -u #{dst.dump} #{tmp.dump} || #{sudo} mv -f #{tmp.dump} #{dst.dump} )"
                execute << "( test -x #{dst.dump} || #{sudo} chmod a+rx #{dst.dump} )"
              end
              run(execute.join(' && ')) unless execute.empty?
            ensure
              run("rm -f #{tmps.map { |t| t.dump }.join(' ')}") unless tmps.empty?
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