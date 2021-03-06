# **Moonshine::Scout** is a Moonshine plugin for installing and configuring
# a server to check into [Scout](scoutapp).

#### Prerequisites

# * A [Scout](scoutapp) account
# * The agent key for your server. This key will be provided at the time you add your server to Scout, and is also available under the Server Admin section of the site.
#
# [scoutapp]: http://scoutapp.com
module Moonshine
  module Scout

    #### Recipe
    #
    # We define the `:scout` recipe which can take inline options.
    #
    def scout(options = {})

      # For convenience, we normalize the user scout will be running under.If nothing else, this will default to daemon.
      user = options[:user] || configuration[:user] || 'daemon'
      agent_key = options[:agent_key] || configuration[:scout][:agent_key]
      realtime = options[:realtime] || configuration[:scout][:realtime] || false
      scoutd = options[:scoutd] || configuration[:scout][:scoutd] || false

      # The only required option is :agent_key. We won't fail the deploy over it though, so just return instead.
      unless agent_key
        puts "To use the Scout agent, specify your key in config/moonshine.yml:"
        puts ":scout:"
        puts "  :agent_key: YOUR-SCOUT-KEY"
        return
      end

      if realtime
        scout_realtime(options, version)
      elsif scoutd
        scoutd(options, user, agent_key)
      else
        scout_gem(options, user, agent_key)
      end
    end

    def scout_realtime(options, realtime)
      # First, install the scout gem.
      gem 'scout', :ensure => (options[:version] || :latest)

      # If Scout Realtime is wanted, install gem.
      gem 'scout_realtime', :ensure => (realtime[:version] || :latest) if realtime
    end

    def scout_gem(options, user, agent_key)
      # First, install the scout gem.
      gem 'scout', :ensure => (options[:version] || :latest)

      # Then, we need it to run regularly through cron.
      # This can be configured with:
      #
      # * `:interval`: defaults to every minute
      cron 'scout_checkin',
        :command  => "/usr/bin/scout #{agent_key}",
        :minute   => "*/#{options[:interval]||1}",
        :user     => user

      # Scout allows you to create your own [private plugins](https://scoutapp.com/info/creating_a_plugin#private_plugins). This requires some additional setup.
      #
      # The user checking into scout needs to have a ~/.scout/scout_rsa.pub file present to be able to use private plugins.
      #
      # moonshine_scout manages this by checking app/manifests/scout_rsa.pub, and setting it up on the server if it's around
      scout_rsa_pub = local_template(Pathname.new('scout_rsa.pub'))
      if scout_rsa_pub.exist?
        file "/home/#{user}/.scout",
          :alias => '.scout',
          :ensure => :directory,
          :owner => user

        file "/home/#{user}/.scout/scout_rsa.pub",
          :ensure => :present,
          :content => template(scout_rsa_pub),
          :require => file('.scout'),
          :owner => user
      end


      # At this point, we have enough installed to be able to check into scout. However, some plugins require additional gems and packages be installed
      # The Apache Status plugin calls apache2ctl status, which
      # requires lynx
      package 'lynx', :ensure => :installed, :before => package('scout')
      # This can leave tempfiles around in /tmp though, so we setup a
      # cronjob to clear it out
      cron 'cleanup_lynx_tempfiles',
        :command  => "find /tmp/ -name 'lynx*' -type d -delete",
        :hour     => '0',
        :minute   => '0'

      # Some cool plugins need the sysstat package, which installs things like iostat, mpstat, and other friends:
      #
      #  * [Device Input/Output (iostat)](https://scoutapp.com/plugin_urls/161-device-inputoutput-iostat)
      #  * [Processor statistics (mpstat)](https://scoutapp.com/plugin_urls/331-processor-statistics-mpstat)
      package 'sysstat', :ensure => :installed, :before => package('scout')

      # The moonshine user needs to be part of the adm group for a few plugins. Usually, it's for accessing logs:
      #
      # * [MySQL Slow Queries](https://scoutapp.com/plugin_urls/21-mysql-slow-queries)
      # * [Apache Log Analyzer](https://scoutapp.com/plugin_urls/201-apache-log-analyzer)
      # needed for MySQL Slow Queries to work
      # add user to adm group, to be able to acces
      # FIXME this seems to run EVERY time, regarless of the unless
      exec "usermod -a -G adm #{configuration[:user]}",
        :unless => "groups #{configuration[:user]} | egrep '\\badm\\b'", # this could probably be more succintly and strongly specfied
        :before => package('scout')

      # [Ruby on Rails Monitoring](https://scoutapp.com/plugin_urls/181-ruby-on-rails-monitoring) depends on a few gems to be installed
      gem 'elif', :before => package('scout')
      gem 'request-log-analyzer', :ensure => :latest, :before => package('scout')

      # Lastly, we need to make sure the old scout_agent service isn't running.
      file '/etc/init.d/scout_agent',
        :content => template(File.join(File.dirname(__FILE__), 'scout', 'templates', 'scout_agent.init.erb'), binding),
        :mode    => '744'

      service 'scout_agent',
        :enable  => false,
        :ensure  => :stopped,
        :require => file('/etc/init.d/scout_agent')
    end

    def scoutd(options, user, agent_key)
      if ubuntu_trusty?
        package 'software-properties-common',
          :alias => 'python-software-properties',
          :ensure => :installed
      else
        package 'python-software-properties',
          :ensure => :installed
      end

      exec 'add scout apt key',
        :command => 'wget -q -O - https://archive.scoutapp.com/scout-archive.key | sudo apt-key -',
        :unless => "sudo apt-key list | grep 'Scout Packages (archive.scoutapp.com) <support@scoutapp.com>'",
        :require => package('python-software-properties')

      repo_path = "deb http://archive.scoutapp.com ubuntu main"

      file '/etc/apt/sources.list.d/scout.list',
        :content => repo_path,
        :require => exec('add scout apt key')

      exec 'scout apt-get update',
        :command => 'sudo apt-get update',
        :require => file('/etc/apt/sources.list.d/scout.list')

      exec 'install scoutd',
        :command => "env SCOUT_KEY=#{agent_key} apt-get -y install scoutd",
        :unless => "dpkg -l | grep 'ii  scoutd'",
        :require => [file('/etc/apt/sources.list.d/scout.list'), exec('scout apt-get update')]

      gem 'scout', :ensure => :purged

      cron 'scout_checkin',
        :command  => "/usr/bin/scout #{agent_key}",
        :ensure   => :absent,
        :user     => user

      exec 'copy scout config directory',
        :command => "sudo cp -r /home/#{configuration[:user]}/.scout/* /var/lib/scoutd/ && sudo chown -R scoutd:scoutd /var/lib/scoutd",
        :subscribe => exec('install scoutd'),
        :require => exec('install scoutd'),
        :refreshonly => true

      file '/etc/scout/scoutd.yml',
        :content => template(File.join(File.dirname(__FILE__), 'scout', 'templates', 'scoutd.yml.erb'), binding),
        :owner => 'scoutd',
        :group => 'scoutd',
        :mode => '640',
        :require => exec('install scoutd'),
        :notify => service('scout')

      exec 'scoutd add sudoers includedir',
        :command => [
          "cp /etc/sudoers /tmp/sudoers",
          "echo '#includedir /etc/sudoers.d' >> /tmp/sudoers",
          "visudo -c -f /tmp/sudoers",
          "cp /tmp/sudoers /etc/sudoers",
          "rm -f /tmp/sudoers"
        ].join(' && '),
        :unless => "grep '#includedir /etc/sudoers.d' /etc/sudoers"

      file '/etc/sudoers.d/scoutd',
        :content => template(File.join(File.dirname(__FILE__), 'scout', 'templates', 'scoutd.sudoers.erb'), binding),
        :owner => 'root',
        :group => 'root',
        :mode => '440',
        :require => [exec('install scoutd'), exec('scoutd add sudoers includedir')]

      service 'scout',
        :ensure => :running,
        :require => exec('install scoutd'),
        :enable => true
    end
  end
end
