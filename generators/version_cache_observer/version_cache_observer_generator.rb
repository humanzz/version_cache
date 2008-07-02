class VersionCacheObserverGenerator < Rails::Generator::NamedBase

  def manifest
    record do |m|
      # Check for class naming collisions.
      m.class_collisions class_path, "#{class_name}Observer"
      m.directory File.join('app/models', class_path)
      # Model class, unit test, and fixtures.
      m.template 'observer.rb', File.join('app/models', class_path, "#{file_name}_observer.rb"),
                  :assigns => {:observer_name => class_name, :observed_models => actions}
    end
  end
end
