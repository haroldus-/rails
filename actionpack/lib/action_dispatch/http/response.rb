require 'digest/md5'
require 'active_support/core_ext/module/delegation'

module ActionDispatch # :nodoc:
  # Represents an HTTP response generated by a controller action. One can use
  # an ActionController::Response object to retrieve the current state
  # of the response, or customize the response. An Response object can
  # either represent a "real" HTTP response (i.e. one that is meant to be sent
  # back to the web browser) or a test response (i.e. one that is generated
  # from integration tests). See CgiResponse and TestResponse, respectively.
  #
  # Response is mostly a Ruby on Rails framework implement detail, and
  # should never be used directly in controllers. Controllers should use the
  # methods defined in ActionController::Base instead. For example, if you want
  # to set the HTTP response's content MIME type, then use
  # ActionControllerBase#headers instead of Response#headers.
  #
  # Nevertheless, integration tests may want to inspect controller responses in
  # more detail, and that's when Response can be useful for application
  # developers. Integration test methods such as
  # ActionController::Integration::Session#get and
  # ActionController::Integration::Session#post return objects of type
  # TestResponse (which are of course also of type Response).
  #
  # For example, the following demo integration "test" prints the body of the
  # controller response to the console:
  #
  #  class DemoControllerTest < ActionController::IntegrationTest
  #    def test_print_root_path_to_console
  #      get('/')
  #      puts @response.body
  #    end
  #  end
  class Response < Rack::Response
    attr_accessor :request
    attr_reader :cache_control

    attr_writer :header
    alias_method :headers=, :header=

    delegate :default_charset, :to => 'ActionController::Base'

    def initialize
      super
      @cache_control = {}
      @header = Rack::Utils::HeaderHash.new
    end

    def status=(status)
      @status = status.to_i
    end

    # The response code of the request
    def response_code
      @status
    end

    # Returns a String to ensure compatibility with Net::HTTPResponse
    def code
      @status.to_s
    end

    def message
      StatusCodes::STATUS_CODES[@status]
    end
    alias_method :status_message, :message

    def body
      str = ''
      each { |part| str << part.to_s }
      str
    end

    def body=(body)
      @body = body.respond_to?(:to_str) ? [body] : body
    end

    def body_parts
      @body
    end

    def location
      headers['Location']
    end
    alias_method :redirect_url, :location

    def location=(url)
      headers['Location'] = url
    end

    # Sets the HTTP response's content MIME type. For example, in the controller
    # you could write this:
    #
    #  response.content_type = "text/plain"
    #
    # If a character set has been defined for this response (see charset=) then
    # the character set information will also be included in the content type
    # information.
    attr_accessor :charset, :content_type

    def last_modified
      if last = headers['Last-Modified']
        Time.httpdate(last)
      end
    end

    def last_modified?
      headers.include?('Last-Modified')
    end

    def last_modified=(utc_time)
      headers['Last-Modified'] = utc_time.httpdate
    end

    def etag
      headers['ETag']
    end

    def etag?
      headers.include?('ETag')
    end

    def etag=(etag)
      if etag.blank?
        headers.delete('ETag')
      else
        headers['ETag'] = %("#{Digest::MD5.hexdigest(ActiveSupport::Cache.expand_cache_key(etag))}")
      end
    end

    def sending_file?
      headers["Content-Transfer-Encoding"] == "binary"
    end

    def assign_default_content_type_and_charset!
      return if !headers["Content-Type"].blank?

      @content_type ||= Mime::HTML
      @charset      ||= default_charset

      type = @content_type.to_s.dup
      type << "; charset=#{@charset}" unless sending_file?

      headers["Content-Type"] = type
    end

    def prepare!
      assign_default_content_type_and_charset!
      handle_conditional_get!
      self["Set-Cookie"] ||= ""
    end

    def each(&callback)
      if @body.respond_to?(:call)
        @writer = lambda { |x| callback.call(x) }
        @body.call(self, self)
      else
        @body.each { |part| callback.call(part.to_s) }
      end

      @writer = callback
      @block.call(self) if @block
    end

    def write(str)
      str = str.to_s
      @writer.call str
      str
    end

    def set_cookie(key, value)
      if value.has_key?(:http_only)
        ActiveSupport::Deprecation.warn(
          "The :http_only option in ActionController::Response#set_cookie " +
          "has been renamed. Please use :httponly instead.", caller)
        value[:httponly] ||= value.delete(:http_only)
      end

      super(key, value)
    end

    # Returns the response cookies, converted to a Hash of (name => value) pairs
    #
    #   assert_equal 'AuthorOfNewPage', r.cookies['author']
    def cookies
      cookies = {}
      if header = headers['Set-Cookie']
        header = header.split("\n") if header.respond_to?(:to_str)
        header.each do |cookie|
          if pair = cookie.split(';').first
            key, value = pair.split("=").map { |v| Rack::Utils.unescape(v) }
            cookies[key] = value
          end
        end
      end
      cookies
    end

    private
      def handle_conditional_get!
        if etag? || last_modified? || !cache_control.empty?
          set_conditional_cache_control!
        elsif nonempty_ok_response?
          self.etag = body

          if request && request.etag_matches?(etag)
            self.status = 304
            self.body = []
          end

          set_conditional_cache_control!
        else
          headers["Cache-Control"] = "no-cache"
        end
      end

      def nonempty_ok_response?
        ok = !@status || @status == 200
        ok && string_body?
      end

      def string_body?
        !body_parts.respond_to?(:call) && body_parts.any? && body_parts.all? { |part| part.is_a?(String) }
      end

      def set_conditional_cache_control!
        if cache_control.empty?
          cache_control.merge!(:public => false, :max_age => 0, :must_revalidate => true)
        end

        public_cache, max_age, must_revalidate, extras =
          cache_control.values_at(:public, :max_age, :must_revalidate, :extras)

        options = []
        options << "max-age=#{max_age}" if max_age
        options << (public_cache ? "public" : "private")
        options << "must-revalidate" if must_revalidate
        options.concat(extras) if extras

        headers["Cache-Control"] = options.join(", ")
      end
  end
end
