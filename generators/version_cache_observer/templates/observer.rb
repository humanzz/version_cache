class <%=observer_name%>Observer < ActiveRecord::Observer
  
  observe <%= observed_models.join "," %>
  
  def before_update(record)
    update_for_change(record)
  end
  
  def after_create(record)
    update_for_change(record)
  end
  
  def after_destroy(record)
    update_for_change(record)
  end
  
  private
  
  def update_for_change(record)
    return unless ActionController::Base.perform_caching
    update_version(record)
    if record.class.respond_to?(:cache_associates)
      record.class.cache_associates.each do |a|
        update_version(eval("record.#{a}"))
      end
    end
  end
  
  def update_version(obj)
    key = "#{obj.class.name}_#{obj.id}"
    version = 0 unless(version = Rails.cache.read(key))
    Rails.cache.write(key, version + 1)    
  end  
end