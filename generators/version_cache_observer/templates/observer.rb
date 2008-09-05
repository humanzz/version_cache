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
    record.cache_associates.each {|ca| update_version(ca)}
  end
  
  def update_version(record)
    record.increment_cache_version
  end  
end
