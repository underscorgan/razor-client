namespace :gettext do
  task :load_gettext_tasks do
    spec = Gem::Specification.find_by_name 'gettext-setup'
    load "#{spec.gem_dir}/lib/tasks/gettext.rake"
    GettextSetup.initialize(File.absolute_path('../locales', File.dirname(__FILE__)))
  end
end
