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

 * `:mon_path` - "/etc/mon"
 * `:mon_lib_path` - "/var/lib/mon"
 * `:mon_log_path` - "/var/log/mon"
 * `:mon_dependencies` - `%w(mon)`
 * `:mon_plugins_path` - "/usr/local/lib/mon"
 * `:mon_plugins` - `{}`
 * `:mon_configure_files` - `%w(/etc/default/mon mon.cf))`
 * `:mon_service_name` - `"mon"`

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
