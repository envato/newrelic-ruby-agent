namespace :coverage do
  desc "Collates all result sets generated by the different test runners"
  task :report do
    require 'simplecov'

    SimpleCov.collate Dir["test/multiverse/suites/*/coverage/.resultset.json"]
  end
end
