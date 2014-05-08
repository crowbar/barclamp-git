#!/usr/bin/env ruby
#
# Copyright 2011-2013, Dell
# Copyright 2013-2014, SUSE LINUX Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#





require 'yaml'
require 'fileutils'

barclamps = {}
pip_requires = []
pip_options = []

begin
  puts ">>> Starting build cache for barclamps"
  # Collect git_repo from all crowbar.yml
  Dir.glob("#{ENV['CROWBAR_DIR']}/barclamps/*/crowbar.yml").each do |file|
    crowbar = YAML.load_file(file)
    next if crowbar["git_repo"].nil?
    barclamp = file.split("/")[-2]
    barclamps[barclamp] ||= []
    # add barclamp for pip caching
    unless crowbar["git_repo"].nil?
      crowbar["git_repo"].each do |repo|
        (name,url,branches) = repo.split(" ", 3)
        barclamps[barclamp] << { name => {:origin => url, :branches => branches.split(" ")} }
      end
    end
  end

  # Run on each repos and collect pips from tools/pip-requires
  barclamps.each do |barclamp, repos|
    repos = repos.collect{|i| i.first}
    repos.each do |repo_name,repo|
      puts ">>> Collect pip requires from: #{repo_name} (#{repo[:branches].empty? ? "?" : repo[:branches].join(", ")})"
      # TODO: #"barclamps/#{barclamp}/git_repos")
      repos_path = "#{ENV['CACHE_DIR']}/barclamps/#{barclamp}/git_repos"
      base_name ="#{repos_path}/#{repo_name}"
      file = "#{base_name}.tar.bz2"
      raise "cannot find #{file}" unless File.exists? file
      FileUtils.cd(repos_path) do %x(tar xf "#{repo_name}.tar.bz2") end
      raise "failed to expand #{file}" unless File.directory? "#{base_name}.git"

      FileUtils.cd("#{repos_path}/#{repo_name}.git") do
        repo[:branches] = %x(git for-each-ref --format='%(refname)' refs/heads).split("\n").map{ |x| x.split("refs/heads/").last}
      end if repo[:branches].empty?

      FileUtils.cd(repos_path) do
        system("rm -rf #{repo_name}")
        unless system("git clone #{repo_name}.git #{repo_name}")
          raise "failed to clone repo #{repo_name}"
        end
      end

      repo[:branches].each do |branch|
        puts ">>> Branch: #{branch}"
        FileUtils.cd("#{repos_path}/#{repo_name}") do
          raise "failed to checkout #{branch}" unless system "git checkout #{branch}"
          require_file = ["tools/pip-requires","requirements.txt"].select{|file| File.exist? file}.first
          next unless require_file
          File.read(require_file).split("\n").collect{|pip| pip.strip}.each do |line|
            if line.start_with?("-")
              pip_options << line
            elsif not line.start_with?("#")
              pip_requires << line
            end
          end
        end
      end
      FileUtils.cd(repos_path) do
        system("rm -rf #{repo_name}")
        system("rm -rf #{repo_name}.git")
      end
    end
  end

  pip_requires = pip_requires.select{|i| not i.strip.start_with?("#") and not i.strip.empty? }
  puts ">>> Total invoked packages: #{pip_requires.size}"
  pip_requires = pip_requires.uniq.sort
  puts ">>> Total unique packages: #{pip_requires.size}"
  puts ">>> Pip options: #{pip_options}" unless pip_options.empty?
  puts ">>> Pips to download: #{pip_requires.join(", ")}"

  pip_cache_path = "#{ENV['CACHE_DIR']}/barclamps/git/files/pip_cache"

  system("mkdir -p #{pip_cache_path}")
  pip_requires.each do |pip|
    10.times do
      puts ">>> Try download pip: #{pip}"
      if system("pip2pi #{pip_cache_path} #{pip_options} '#{pip}'")
        break
      end
      puts ">>> Retry exec pip2tgz"
    end
  end
  if File.directory?(pip_cache_path)
    raise "failed to package pip reqs" unless system("find '#{pip_cache_path}' -type f -iname 'index.html' -exec rm {} \\;")
  end
  puts ">>> Success build cache pips packages for all barclamps"
rescue => e
  puts "!!! #{e.message}"
  exit(1)
end
