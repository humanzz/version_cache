module ActiveRecord
  module Espace
    module VersionCache
      module InstanceMethods
        
        def cache_version
          key = self.class.name + "_#{self.id}"
          unless(version = Rails.cache.read(key))
            version = 0
          end
          version
        end
        
        def increment_cache_version
          key = self.class.name + "_#{self.id}"
          unless(version = Rails.cache.read(key))
            version = 0
          end
          Rails.cache.write(key, version + 1)
        end
      end
    end
  end
end

module ActionController
  module Espace
    module VersionCache
      def self.included(base)
        base.extend(ClassMethods)
      end
      
      module ClassMethods
        protected
        #model class for which we'll do version caching
        #associates model members that their versions need update as well
        # options = {:expiry => number of minutes to keep in memcache maximum, :browser_cache_enabled}
        def version_cache(model, options = {})
          return unless ActionController::Base.perform_caching
          include InstanceMethods
          default_options = {:associates => [], :action => :show}
          options = default_options.merge(options)
          self.version_cache_updater(model, {:associates => options[:associates]})
          class_eval <<-"end_eval"
          def version_cache_#{model.name}_#{options[:action]}
            unless (version = Rails.cache.read("#{model.name}_" + version_cache_model_id))
              version = 0
            end
            vckp = version_cache_key_part
            options = eval('#{options.inspect}')
            options.delete :associates 
            if vckp.blank?
              cache_response(version,options) { yield }
            else
              cache_response(version, vckp,options) { yield }
            end
          end
          around_filter :version_cache_#{model.name}_#{options[:action]}, :only => [:#{options[:action]}]
          end_eval
        end
        
        def time_cache(actions = {})
          return if(!ActionController::Base.perform_caching || actions.keys.length == 0)
          include InstanceMethods
          eval("#{actions.inspect}").each do |action, options|
            class_eval <<-"end_eval"
            def time_cache_#{action.to_s}
              time_cache_#{action.to_s}_options = eval("#{options.inspect}")
              raise "options has to be a hash" unless time_cache_#{action.to_s}_options.is_a?(Hash)
              vckp = version_cache_key_part
              if vckp.blank?
                cache_response(time_cache_#{action.to_s}_options) { yield }
              else
                cache_response(vckp, time_cache_#{action.to_s}_options) { yield }
              end
            end
            around_filter :time_cache_#{action.to_s}, :only => :#{action.to_s}
            end_eval
          end
        end
        
        def version_cache_updater(model, options = {:associates => []})
          eval "def #{model.name}.cache_associates; eval('#{options[:associates].inspect}'); end"
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
          unless ActionController::Base.perform_caching
            yield
            return
          end
          
          options = {:expiry => 0, :browser_cache_enabled => false}
          options = options.merge(keys.delete_at(keys.length - 1)) if keys.length != 0 && keys[keys.length - 1].is_a?(Hash)
          key = "#{request.host}:#{request.request_uri}:#{keys * ':'}"
          etag = Digest::MD5.hexdigest(key)
          logger.info ">>>>>cache_response options #{options.inspect}"
          logger.info ">>>>>cache_response key #{key}"
          
          # first handle HTTP, lets us avoid a memcache hit
          # and saves a huge amount of bandwidth to the client
          if request.env["HTTP_IF_NONE_MATCH"] == etag
            headers["X-Cache"] = "HTTP"
            head :not_modified
            return
          end
          
          # Next check memcache
          if data = Rails.cache.read(key)
            # render from the cached values
            headers["Content-Type"] = data[:content_type]
            headers["X-Cache"] = "HIT"
            render :text=>data[:content], :status=>data[:status]
          else
            # Finally, yield, indicate we've missed then cache the response
            headers["X-Cache"] = "MISS"
            yield
            #cache 200 OK reposnes only
            if headers["Status"].to_i == 200
              if options[:browser_cache_enabled]
                response.headers["Cache-Control"] = "public, max-age=#{options[:expiry].minutes}"
                headers["Expires"] = options[:expiry].minutes.from_now.httpdate
              else
                response.headers["ETag"] = etag
              end
              
              expiry = options[:expiry] == 0 ? 0 : (options[:expiry].minutes.from_now - Time.now).to_i
              Rails.cache.write(key, {:content=>response.body, :status=> headers["Status"].to_i, :content_type=>(response.content_type || "text/html")}, :expires_in => expiry)
            end
          end
        end 
        
      end
    end  
  end
end

ActionController::Base.send(:include, ActionController::Espace::VersionCache)
ActiveRecord::Base.send(:include, ActiveRecord::Espace::VersionCache::InstanceMethods)