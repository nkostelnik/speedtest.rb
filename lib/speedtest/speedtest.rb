require 'mechanize'

class Mechanize::HTTP::Agent
  MAX_RESET_RETRIES = 10

  # We need to replace the core Mechanize HTTP method:
  #
  #   Mechanize::HTTP::Agent#fetch
  #
  # with a wrapper that handles the infamous "too many connection resets"
  # Mechanize bug that is described here:
  #
  #   https://github.com/sparklemotion/mechanize/issues/123
  #
  # The wrapper shuts down the persistent HTTP connection when it fails with
  # this error, and simply tries again. In practice, this only ever needs to
  # be retried once, but I am going to let it retry a few times
  # (MAX_RESET_RETRIES), just in case.
  #
  def fetch_with_retry(
    uri,
    method    = :get,
    headers   = {},
    params    = [],
    referer   = current_page,
    redirects = 0
  )
    action      = "#{method.to_s.upcase} #{uri.to_s}"
    retry_count = 0

    begin
      fetch_without_retry(uri, method, headers, params, referer, redirects)
    rescue Net::HTTP::Persistent::Error => e
      # Pass on any other type of error.
      raise unless e.message =~ /too many connection resets/

      # Pass on the error if we've tried too many times.
      if retry_count >= MAX_RESET_RETRIES
        # puts "**** WARN: Mechanize retried connection reset #{MAX_RESET_RETRIES} times and never succeeded: #{action}"
        raise
      end

      # Otherwise, shutdown the persistent HTTP connection and try again.
      # puts "**** WARN: Mechanize retrying connection reset error: #{action}"
      retry_count += 1
      self.http.shutdown
      retry
    end
  end

  # Alias so #fetch actually uses our new #fetch_with_retry to wrap the
  # old one aliased as #fetch_without_retry.
  alias_method :fetch_without_retry, :fetch
  alias_method :fetch, :fetch_with_retry
end

require 'nokogiri'

module Speedtest
	class GeoPoint
		attr_accessor :lat, :lon
		def initialize(lat, lon)
			@lat=Float(lat)
			@lon=Float(lon)
		end
		def to_s
			"[#{lat}, #{lon}]"
		end
		def distance(p2)
			Math.sqrt((p2.lon - lon)**2 + (p2.lat-lat)**2)
		end
	end

	def self.timemillis(time)
		(time.to_f*1000).to_i
	end

	class SpeedTest
		DEBUG=true

		DOWNLOAD_FILES = [
			'speedtest/random750x750.jpg',
			'speedtest/random1500x1500.jpg',
		]

		UPLOAD_SIZES = [
			19719,
			48396
		]
		DOWNLOAD_RUNS=2

		def initialize(argv)
			#noting yet
		end

		def run
			@a = Mechanize.new
			@a.open_timeout=1
			@a.read_timeout=1
			server = pickServer
			@server_root = server[:url]
			latency = server[:latency]
			log "Server #{@server_root}"
			downRate = download
			log "Download: #{pretty_speed downRate}"
			upRate = upload
			log "Upload: #{pretty_speed upRate}"
			{:server => @server_root, :latency => latency, :downRate => downRate, :upRate => upRate}
		end

		def pretty_speed(speed)
			units = [ "bps", "Kbps", "Mbps", "Gbps"]
			idx=0
			while speed > 1024 #&& idx < units.length - 1
				speed /= 1024
				idx+=1
			end
			"%.2f #{units[idx]}" % speed
		end

		def log(msg)
			if DEBUG
				puts msg
			end
		end

		def downloadthread(url)
			page = @a.get(url)
			Thread.current["downloaded"] = page.body.length
			#log "#{url} #{Thread.current["downloaded"]}"
		end

		def download
			threads=[]

			start_time=Time.new
			DOWNLOAD_FILES.each { |f|
				1.upto(DOWNLOAD_RUNS) { |i|
					threads << Thread.new(f) { |myPage|
						msec=Speedtest::timemillis(Time.new)
						log "#{@server_root}/#{myPage}?x=#{msec}&y=#{i}"
						downloadthread("#{@server_root}/#{myPage}?x=#{msec}&y=#{i}")
					}
				}
			}
			total_downloaded=0
			threads.each { |t|
				t.join
				total_downloaded += t["downloaded"]
			}
			total_time=Time.new - start_time
			log "Took #{total_time} seconds to download #{total_downloaded} bytes in #{threads.length} threads"
			total_downloaded * 8 / total_time
		end

		def uploadthread(url, myData)
			page = @a.post(url, { "content0" => myData })
			log "Uploading: #{url} #{Thread.current["uploaded"]}"
			Thread.current["uploaded"] = page.body.split('=')[1].to_i
		end

		def randomString(alphabet, size)
			(1.upto(size)).map {alphabet[rand(alphabet.length)] }.join
		end

		def upload
			runs=4
			data=[]
			UPLOAD_SIZES.each { |size|
				1.upto(runs) {
					data << randomString(('A'..'Z').to_a, size)
				}
			}

			threads=[]
			start_time=Time.new
			threads = data.map { |data|
				Thread.new(data) { |myData|
					msec=Speedtest::timemillis(Time.new)
					uploadthread("#{@server_root}//speedtest/upload.php?x=#{rand}", myData)
				}
			}
			total_uploaded=0
			threads.each { |t|
				t.join
				total_uploaded += t["uploaded"]
			}
			total_time=Time.new - start_time
			log "Took #{total_time} seconds to upload #{total_uploaded} bytes in #{threads.length} threads"
			total_uploaded * 8 / total_time
		end

		def pickServer
			page = @a.get("http://www.speedtest.net/speedtest-config.php")
			ip,lat,lon=page.body.scan(/<client ip="([^"]*)" lat="([^"]*)" lon="([^"]*)"/)[0]
			orig=GeoPoint.new(lat, lon)
			log "Your IP: #{ip}\nYour coordinates: #{orig}\n"

			page = @a.get("http://www.speedtest.net/speedtest-servers.php")
			sorted_servers=page.body.scan(/<server url="([^"]*)" lat="([^"]*)" lon="([^"]*)/).map { |x| {
				:distance => orig.distance(GeoPoint.new(x[1],x[2])),
				:url => x[0].split(/(http:\/\/.*)\/speedtest.*/)[1]
			} }.sort_by { |x| x[:distance] }

			log "### All Servers sorted by distance ###"
			log sorted_servers

			# sort the nearest 3 by download latency
			latency_sorted_servers=sorted_servers[0..2].map { |x|
				{
				:latency => ping(x[:url]),
				:url => x[:url]
				}}.sort_by { |x| x[:latency] }

			log "### Top 3 closest Servers sorted by latency ###"
			log latency_sorted_servers

			selected=latency_sorted_servers[0]
			log "Automatically selected server: #{selected[:url]} - #{selected[:latency]} ms"
			selected
		end

		def ping(server)
			times=[]
			1.upto(6) {
				start=Time.new
				msec=Speedtest::timemillis(start)
				begin
					page=@a.get("#{server}/speedtest/latency.txt?x=#{msec}")
					times << Time.new-start
				rescue Timeout::Error
					times << 999999
				end
			}
			times.sort
			times[1,4].inject(:+)*1000/4 # average in milliseconds
		end
	end
end
