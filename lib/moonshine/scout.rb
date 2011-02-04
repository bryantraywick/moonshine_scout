module Moonshine
  module Scout

    # Define options for this plugin in config/moonshine.yml or the
    # <tt>configure</tt> method in your application manifest:
    #
    #   configure(:scout => {:agent_key => 'YOUR-SCOUT-KEY'})
    #
    # Then include the plugin and call the recipe(s) you need:
    #
    #  plugin :scout
    #  recipe :scout
    def scout(options = {})

      unless options[:agent_key]
        puts "To use the Scout agent, specify your key in config/moonshine.yml:"
        puts ":scout:"
        puts "  :agent_key: YOUR-SCOUT-KEY"
        return
      end

      gem 'scout', :ensure => :latest
      cron 'scout_checkin',
        :command  => "/usr/bin/scout #{options[:agent_key]}",
        :minute   => "*/#{options[:interval]||1}",
        :user     => options[:user] || configuration[:user] || 'daemon'

      # needed for apache status plugin
      package 'lynx', :ensure => :installed, :before => package('scout')
      cron 'cleanup_lynx_tempfiles',
        :command  => "find /tmp/ -name 'lynx*' -type d -delete",
        :hour     => '0',
        :minute   => '0'

      # provides iostat, needed for disk i/o plugin
      package 'sysstat', :ensure => :installed, :before => package('scout')

      # needed for MySQL Slow Queries to work
      # add user to adm group, to be able to acces
      # FIXME this seems to run EVERY time, regarless of the unless
      exec "usermod -a -G adm #{configuration[:user]}",
        :unless => "groups #{configuration[:rails]} | egrep '\\badm\\b'", # this could probably be more succintly and strongly specfied
        :before => package('scout')

      # needed for the rails plugin
      gem 'elif', :before => package('scout')
      gem 'request-log-analyzer', :ensure => :latest, :before => package('scout')

      # disable the old scout_agent
      file '/etc/init.d/scout_agent',
        :content => template(File.join(File.dirname(__FILE__), 'scout', 'templates', 'scout_agent.init.erb'), binding),
        :mode    => '744'

      service 'scout_agent',
        :enable  => false,
        :ensure  => :stopped,
        :require => file('/etc/init.d/scout_agent')
    end

  end
end
