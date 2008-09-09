module VersionCache
  module ActiveRecord
    
    def self.included(base)
      base.extend(ClassMethods)
      base.send(:include,InstanceMethods) unless base.included_modules.include?(VersionCache::ActiveRecord::InstanceMethods)
    end
    
    module ClassMethods
      def has_cache_associates(*associates);@cache_associates = associates;end
      
      def cache_associates;@cache_associates||=[];end
	  
      def cache_version_key(id);"#{self.name}_#{id}";end
    end
    
    module InstanceMethods
      
      def cache_associates
        ret = []
        self.class.cache_associates.each do |ca|
          a = self.send(ca)
          ret << a if a
        end
        ret.flatten
      end
      
      def cache_version
        unless(version = Rails.cache.read(cache_version_key))
          version = 0
        end
        version
      end
      
      def increment_cache_version
        unless(version = Rails.cache.read(cache_version_key))
          version = 0
        end
        Rails.cache.write(cache_version_key, version + 1)
      end
	  
	  def cache_version_key
		@cache_version_key ||= self.class.cache_version_key(self.id)
	  end
    end
  end
end

module VersionCache
  module ActionController
    def self.included(base)
      base.extend(ClassMethods)
    end
    
    module ClassMethods
      protected
      
      # Caches certain action (show unless specified) based on a certain object's (ActiveRecord) version
      # It caches the page in the cache store and sets the etag header for the response
      # It takes the following parameters
      # model: the object's class 
      # options: a hash which can accept any of the following
      # :action for specifying an action other than :show
      # :expiry to specify the maximum number of minutes to keep the page in the cache
      # :browser_cache => (true|false) which sets the expires and cache-control headers if an expiry
      # time is specified. It defaults to false
      def version_cache(model, options = {})
        return unless ::ActionController::Base.perform_caching
        include InstanceMethods unless self.included_modules.include?(VersionCache::ActionController::InstanceMethods)
        action = options.delete(:action) || :show
        action = action.to_sym #make sure it's a symbol
        self.instance_variable_set("@version_cache_#{model.name}_#{action}_options".to_sym,options)
        class_eval <<-"end_eval"
        def version_cache_#{model.name}_#{action}
          unless (version = Rails.cache.read(#{model.name}.cache_version_key(version_cache_model_id)))
            version = 0
          end
          vckp = version_cache_key_part
          options = self.class.instance_variable_get(:@version_cache_#{model.name}_#{action}_options)
          if vckp.blank?
            cache_response(version,options) { yield }
          else
            cache_response(version, vckp,options) { yield }
          end
        end
        around_filter :version_cache_#{model.name}_#{action}, :only => [:#{action}]
        end_eval
      end
      
      # Caches certain actions for a specified period of time
      # It caches the page in the cache store and sets the etag header for the response
      # actions is a hash of the form {:action_name => action_options_hash}
      # example: {:index => {:expiry => 10}, {:show => {:expiry => 5, :browser_cache => true}}}
      # The action_options_hash options are
      # :expiry to specify the number of minutes to keep the page in the cache
      # :browser_cache => (true|false) which sets the expires and cache-control headers if an expiry
      # time is specified. It defaults to false      
      def time_cache(actions = {})
        return if(!::ActionController::Base.perform_caching || actions.keys.length == 0)
        include InstanceMethods unless self.included_modules.include?(VersionCache::ActionController::InstanceMethods)
        actions.each do |action, options|
          self.instance_variable_set("@time_cache_#{action.to_s}_options".to_sym,options)
          class_eval <<-"end_eval"
          def time_cache_#{action.to_s}
            time_cache_#{action}_options = self.class.instance_variable_get(:@time_cache_#{action}_options)
            raise "options has to be a hash" unless time_cache_#{action}_options.is_a?(Hash)
            vckp = version_cache_key_part
            if vckp.blank?
              cache_response(time_cache_#{action}_options) { yield }
            else
              cache_response(vckp, time_cache_#{action}_options) { yield }
            end
          end
          around_filter :time_cache_#{action}, :only => [:#{action}]
          end_eval
        end
      end
    end
    
    module InstanceMethods
      
      protected
      
      def version_cache_model_id
        params[:id]
      end
      
      def version_cache_key_part
        ""
      end
      
      def cache_response(*keys)
        unless ::ActionController::Base.perform_caching
          yield
          return
        end
        
        #disable rails conditional get handling
        response.conditional_get_enabled = false
        
        options = {:expiry => 0, :browser_cache => false}
        options = options.merge(keys.delete_at(keys.length - 1)) if keys.length != 0 && keys[keys.length - 1].is_a?(Hash)
        key = "#{request.host}:#{request.request_uri}:#{keys * ':'}"
        etag = Digest::MD5.hexdigest(key)        
        
        # first handle HTTP, lets us avoid a memcache hit
        # and saves a huge amount of bandwidth to the client
        if request.env["HTTP_IF_NONE_MATCH"] == etag
          response.headers["X-Cache"] = "HTTP"
          head :not_modified
          logger.info "version_cache: 304 Not Modified"
          return
        end
        
        # Next check memcache
        if data = Rails.cache.read(key)
          # render from the cached values
          response.headers["X-Cache"] = "HIT"
          data[:headers].each {|k,v| response.headers[k] = v}
          set_cache_headers(etag, data[:browser_cache], data[:cached_on], data[:cached_for])
          render :text=>data[:body], :status=>data[:headers]["Status"]
		      logger.info "version_cache: cache hit"
        else
          # Finally, yield, indicate we've missed then cache the response
          response.headers["X-Cache"] = "MISS"
          response.conditional_get_enabled = false
          yield
          #cache 200 OK reposnes only
          if headers["Status"].to_i == 200
            expiry = options[:expiry] = options[:expiry].minutes.to_i #to seconds
            cached_on = Time.now
            set_cache_headers(etag, options[:browser_cache], cached_on, expiry)
            Rails.cache.write(key, {:body=>response.body,
                                    :headers => {"Status" => response.headers["Status"],
                                                 "Content-Type" => (response.content_type || "text/html")},
                                    :browser_cache => options[:browser_cache],
                                    :cached_on => cached_on,
                                    :cached_for => expiry},
                                    :expires_in => expiry)
          end
		      logger.info "version_cache: cache miss"
		    end
      end 
      
      def set_cache_headers(etag, browser_cache, cached_on, cached_for)
        if browser_cache && cached_for > 0
          period = (cached_on + cached_for - Time.now).to_i
          response.headers["Cache-Control"] = "public, max-age=#{period}"
          response.headers["Expires"] = period.from_now.httpdate              
        end
        response.headers["ETag"] = etag        
      end
    end
  end  
end

ActionController::Base.send(:include, VersionCache::ActionController)
ActiveRecord::Base.send(:include, VersionCache::ActiveRecord)

# A hack to enable to toggle automatic etagging on or off
class ActionController::AbstractResponse
  attr_accessor :conditional_get_enabled
  
  old_initialize = self.instance_method(:initialize)
  old_handle_conditional_get = self.instance_method(:handle_conditional_get!)
  
  define_method(:initialize) do
    old_initialize.bind(self).call
    @conditional_get_enabled = true    
  end
  
  define_method(:handle_conditional_get!) do
    old_handle_conditional_get.bind(self).call if @conditional_get_enabled    
  end
end