# capistrano-mon

a capistrano recipe to setup [Mon](https://mon.wiki.kernel.org/).

## Installation

Add this line to your application's Gemfile:

    gem 'capistrano-mon'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install capistrano-mon

## Usage

This recipe will setup Mon during `deploy:setup` task.

To enable this recipe, add following in your `config/deploy.rb`.

    # in "config/deploy.rb"
    require "capistrano-mon"
    set(:mon_services) {{
      "ping" => {
        :description => "Responses to ping",
        :interval => "5m",
        :monitor => "fping.monitor",
        :period => "wd {Mon-Fri} hr {7am-10pm}",
        :alert => "mail.alert root@localhost",
        :alertevery => "1h",
      }
    }

Following options are available to configure your Mon.

 * `:mon_path` - The base path of Mon configurations. Use `/etc/mon` by default.
 * `:mon_services` - The key-value map of `service` definitions of Mon.
 * `:mon_dependencies` - The packages of Mon.
 * `:mon_plugins_path` - The installation path for custom plugins.
 * `:mon_plugins` - The information of custom plugins.
 * `:mon_configure_files` - The configuration files of Mon.
 * `:mon_service_name` - The name of Mon service. Use `mon` by default.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## Author

- YAMASHITA Yuu (https://github.com/yyuu)
- Geisha Tokyo Entertainment Inc. (http://www.geishatokyo.com/)

## License

MIT
