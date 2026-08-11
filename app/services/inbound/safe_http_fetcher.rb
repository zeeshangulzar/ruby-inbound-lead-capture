require "net/http"
require "resolv"
require "ipaddr"
require "uri"

module Inbound
  # Fetches an untrusted URL with SSRF guards. Rejects non-HTTP schemes and any
  # host that resolves to loopback / private / link-local / multicast / reserved
  # ranges, revalidates the target on every redirect, and caps response size so
  # a hostile server cannot stream us into memory.
  #
  # This does not defeat DNS rebinding — that would require pinning the resolved
  # IP for the actual TCP connect — but it blocks the naive attacks a lead can
  # construct in an email: localhost URLs, RFC 1918 addresses, cloud metadata
  # endpoints, and redirect chains that land on any of them.
  class SafeHttpFetcher
    Response = Struct.new(:body, :status, :headers, :final_url, keyword_init: true) do
      def success?
        status.between?(200, 299)
      end
    end

    Error                 = Class.new(StandardError)
    BlockedError          = Class.new(Error)
    TooManyRedirectsError = Class.new(Error)
    ResponseTooLargeError = Class.new(Error)

    ALLOWED_SCHEMES = %w[http https].freeze
    MAX_REDIRECTS   = 3
    MAX_BYTES       = 1_048_576
    DEFAULT_TIMEOUT = 5
    USER_AGENT      = "ruby-inbound-lead-capture/1.0".freeze
    REDIRECT_CODES  = %w[301 302 303 307 308].freeze

    # Ranges chosen to cover IANA special-use v4 and v6 assignments — private,
    # loopback, link-local, CGNAT, benchmarking, documentation, multicast, and
    # reserved. IPv4-mapped IPv6 (::ffff:0:0/96) is included so an attacker
    # cannot bypass the v4 checks by using an IPv6-wrapped literal.
    BLOCKED_V4_RANGES = %w[
      0.0.0.0/8
      10.0.0.0/8
      100.64.0.0/10
      127.0.0.0/8
      169.254.0.0/16
      172.16.0.0/12
      192.0.0.0/24
      192.0.2.0/24
      192.168.0.0/16
      198.18.0.0/15
      198.51.100.0/24
      203.0.113.0/24
      224.0.0.0/4
      240.0.0.0/4
      255.255.255.255/32
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    BLOCKED_V6_RANGES = %w[
      ::/128
      ::1/128
      ::ffff:0:0/96
      64:ff9b::/96
      100::/64
      2001:db8::/32
      fc00::/7
      fe80::/10
      ff00::/8
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    def initialize(url, timeout: DEFAULT_TIMEOUT, max_redirects: MAX_REDIRECTS, max_bytes: MAX_BYTES)
      @start_url     = url.to_s
      @timeout       = timeout
      @max_redirects = max_redirects
      @max_bytes     = max_bytes
    end

    def call
      current_url    = @start_url
      redirects_left = @max_redirects

      loop do
        uri      = validate_url!(current_url)
        response = fetch(uri)

        if REDIRECT_CODES.include?(response.status.to_s)
          raise TooManyRedirectsError, "exceeded #{@max_redirects} redirects" if redirects_left <= 0

          location = response.headers["location"].to_s
          raise Error, "redirect with no Location header" if location.empty?

          current_url    = URI.join(current_url, location).to_s
          redirects_left -= 1
          next
        end

        return response
      end
    end

    private

    def validate_url!(url)
      uri = URI.parse(url)
      raise BlockedError, "unsupported scheme: #{uri.scheme.inspect}" unless ALLOWED_SCHEMES.include?(uri.scheme)
      raise BlockedError, "missing host" if uri.host.to_s.empty?

      validate_host!(uri.host)
      uri
    rescue URI::InvalidURIError => e
      raise BlockedError, "invalid URL: #{e.message}"
    end

    def validate_host!(host)
      addresses = resolve(host)
      raise BlockedError, "cannot resolve #{host}" if addresses.empty?

      addresses.each { |address| validate_ip!(address, host) }
    end

    # Literal IP hostnames come back from Resolv.getaddresses unchanged, so
    # `192.168.1.1` and `[::1]` both flow into the same validator.
    def resolve(host)
      Resolv.getaddresses(host)
    rescue Resolv::ResolvError, Resolv::ResolvTimeout
      []
    end

    def validate_ip!(address, host)
      ip = IPAddr.new(address)
      raise BlockedError, "#{host} resolves to blocked address #{address}" if blocked_ip?(ip)
    rescue IPAddr::InvalidAddressError
      raise BlockedError, "#{host} resolved to unparseable address #{address}"
    end

    def blocked_ip?(ip)
      ranges = ip.ipv6? ? BLOCKED_V6_RANGES : BLOCKED_V4_RANGES
      ranges.any? { |range| range.include?(ip) }
    end

    def fetch(uri)
      result = nil

      Net::HTTP.start(
        uri.host, uri.port,
        use_ssl:      uri.scheme == "https",
        open_timeout: @timeout,
        read_timeout: @timeout
      ) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = USER_AGENT
        request["Accept"]     = "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1"

        http.request(request) do |response|
          result = build_response(response, uri.to_s)
        end
      end

      result
    end

    def build_response(response, url)
      content_length = response["content-length"].to_i
      if content_length.positive? && content_length > @max_bytes
        raise ResponseTooLargeError, "declared Content-Length #{content_length} > #{@max_bytes}"
      end

      body = +""
      response.read_body do |chunk|
        body << chunk
        raise ResponseTooLargeError, "response body exceeded #{@max_bytes} bytes" if body.bytesize > @max_bytes
      end

      Response.new(
        body:      body,
        status:    response.code.to_i,
        headers:   response.each_header.to_h,
        final_url: url
      )
    end
  end
end
