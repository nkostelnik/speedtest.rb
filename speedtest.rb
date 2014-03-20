#!/usr/bin/ruby -Ilib
require 'rubygems'
require 'json'
require 'speedtest/speedtest'

if __FILE__ == $PROGRAM_NAME
  x = Speedtest::SpeedTest.new(ARGV)
  puts x.run.to_json
end
