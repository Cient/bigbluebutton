#!/usr/bin/ruby
# encoding: UTF-8

# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/
#
# Copyright (c) 2012 BigBlueButton Inc. and by respective authors (see below).
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU Lesser General Public License as published by the Free
# Software Foundation; either version 3.0 of the License, or (at your option)
# any later version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more
# details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.

# Monit reduces the path, but we require tools that are often manually installed
# to /usr/local/bin. Add that to the path.
ENV['PATH'] += ':/usr/local/bin'

require '../lib/recordandplayback'
require 'rubygems'
require 'yaml'
require 'fileutils'


def archive_recorded_meeting(recording_dir)
  recorded_done_files = Dir.glob("#{recording_dir}/status/recorded/*.done")

  FileUtils.mkdir_p("#{recording_dir}/status/archived")
  recorded_done_files.each do |recorded_done|
    match = /([^\/]*).done$/.match(recorded_done)
    meeting_id = match[1]

    archived_done = "#{recording_dir}/status/archived/#{meeting_id}.done"
    next if File.exists?(archived_done)

    archived_fail = "#{recording_dir}/status/archived/#{meeting_id}.fail"
    next if File.exists?(archived_fail)

    ret = BigBlueButton.exec_ret("ruby", "archive/archive.rb", "-m", meeting_id)

    if ret == 0 && File.exists?(archived_done)
      BigBlueButton.logger.info("Successfully archived #{meeting_id}")
      FileUtils.rm(recorded_done)
    else
      BigBlueButton.logger.error("Failed to archive #{meeting_id}")
      FileUtils.touch(archived_fail)
    end
  end
end

def sanity_archived_meeting(recording_dir)
  archived_done_files = Dir.glob("#{recording_dir}/status/archived/*.done")

  FileUtils.mkdir_p("#{recording_dir}/status/sanity")
  archived_done_files.each do |archived_done|
    match = /([^\/]*).done$/.match(archived_done)
    meeting_id = match[1]

    sanity_done = "#{recording_dir}/status/sanity/#{meeting_id}.done"
    next if File.exists?(sanity_done)

    sanity_fail = "#{recording_dir}/status/sanity/#{meeting_id}.fail"
    next if File.exists?(sanity_fail)

    ret = BigBlueButton.exec_ret("ruby", "sanity/sanity.rb", "-m", meeting_id)

    if ret == 0 && File.exists?(sanity_done)
      BigBlueButton.logger.info("Successfully sanity checked #{meeting_id}")
      post_archive(meeting_id)
      FileUtils.rm(archived_done)
    else
      BigBlueButton.logger.error("Sanity check failed on #{meeting_id}")
      FileUtils.touch(sanity_fail)
    end
  end
end


def process_archived_meeting(recording_dir)
  sanity_done_files = Dir.glob("#{recording_dir}/status/sanity/*.done")

  FileUtils.mkdir_p("#{recording_dir}/status/processed")
  sanity_done_files.each do |sanity_done|
    match = /([^\/]*).done$/.match(sanity_done)
    meeting_id = match[1]

    process_succeeded = true

    # Iterate over the list of recording processing scripts to find available types
    # For now, we look for the ".rb" extension - TODO other scripting languages?
    Dir.glob("process/*.rb").sort.each do |process_script|
      match2 = /([^\/]*).rb$/.match(process_script)
      process_type = match2[1]

      processed_done = "#{recording_dir}/status/processed/#{meeting_id}-#{process_type}.done"
      next if File.exists?(processed_done)

      processed_fail = "#{recording_dir}/status/processed/#{meeting_id}-#{process_type}.fail"
      if File.exists?(processed_fail)
        process_succeeded = false
        next
      end

      # If the process directory doesn't exist, the script does nothing
      FileUtils.rm_rf("#{recording_dir}/process/#{process_type}/#{meeting_id}")

      process_start = Time.now
      ret = BigBlueButton.exec_ret("ruby", process_script, "-m", meeting_id)
      process_stop = Time.now

      process_time = ((process_stop - process_start) * 1000).to_i
      IO.write("#{recording_dir}/process/#{process_type}/#{meeting_id}/processing_time", process_time)
      if ret == 0 and File.exists?(processed_done)
        BigBlueButton.logger.info("Process format #{process_type} succeeded for #{meeting_id}")
        BigBlueButton.logger.info("Process took #{process_time}ms")
      else
        BigBlueButton.logger.info("Process format #{process_type} failed for #{meeting_id}")
        BigBlueButton.logger.info("Process took #{process_time}ms")
        FileUtils.touch(processed_fail)
        process_succeeded = false
      end
    end

    if process_succeeded
      post_process(meeting_id)
      FileUtils.rm(sanity_done)
    end
  end
end

def publish_processed_meeting(recording_dir)
  processed_done_files = Dir.glob("#{recording_dir}/status/processed/*.done")

  FileUtils.mkdir_p("#{recording_dir}/status/published")
  processed_done_files.each do |processed_done|
    match = /([^\/]*)-([^\/-]*).done$/.match(processed_done)
    meeting_id = match[1]
    process_type = match[2]

    publish_succeeded = true

    Dir.glob("publish/*.rb").sort.each do |publish_script|
      match2 = /([^\/]*).rb$/.match(publish_script)
      publish_type = match2[1]

      published_done = "#{recording_dir}/status/published/#{meeting_id}-#{publish_type}.done"
      next if File.exists?(published_done)

      published_fail = "#{recording_dir}/status/published/#{meeting_id}-#{publish_type}.fail"
      if File.exists?(published_fail)
        publish_succeeded = false
        next
      end

      # If the publish directory doesn't exist, the script does nothing
      FileUtils.rm_rf("#{recording_dir}/publish/#{publish_type}/#{meeting_id}")

      # For legacy reasons, the meeting ID passed to the publish script contains
      # the playback format name.
      ret = BigBlueButton.exec_ret("ruby", publish_script, "-m", "#{meeting_id}-#{publish_type}")

      if ret == 0 and File.exists?(published_done)
        BigBlueButton.logger.info("Publish format #{publish_type} succeeded for #{meeting_id}")
      else
        BigBlueButton.logger.info("Publish format #{publish_type} failed for #{meeting_id}")
        FileUtils.touch(published_fail)
        publish_succeeded = false
      end
    end

    if publish_succeeded
      post_publish(meeting_id)
      processed_done_files.each do |processed_done|
        FileUtils.rm(processed_done)
      end
      # Also clean up the publish and process work files
      Dir.glob("process/*.rb").sort.each do |process_script|
        match2 = /([^\/]*).rb$/.match(process_script)
        process_type = match2[1]
        FileUtils.rm_rf("#{recording_dir}/process/#{process_type}/#{meeting_id}")
      end
      Dir.glob("publish/*.rb").sort.each do |publish_script|
        match2 = /([^\/]*).rb$/.match(publish_script)
        publish_type = match2[1]
        FileUtils.rm_rf("#{recording_dir}/publish/#{publish_type}/#{meeting_id}")
      end

    end
  end
end

def post_archive(meeting_id)
  Dir.glob("post_archive/*.rb").sort.each do |post_archive_script|
    BigBlueButton.logger.info("Running post archive script #{post_archive_script}")
    ret = BigBlueButton.exec_ret("ruby", post_archive_script, "-m", meeting_id)
    if ret != 0
      BigBlueButton.logger.warn("Post archive script #{post_archive_script} failed")
    end
  end
end

def post_process(meeting_id)
  Dir.glob("post_process/*.rb").sort.each do |post_process_script|
    BigBlueButton.logger.info("Running post process script #{post_process_script}")
    ret = BigBlueButton.exec_ret("ruby", post_process_script, "-m", meeting_id)
    if ret != 0
      BigBlueButton.logger.warn("Post process script #{post_process_script} failed")
    end
  end
end

def post_publish(meeting_id)
  Dir.glob("post_publish/*.rb").sort.each do |post_publish_script|
    BigBlueButton.logger.info("Running post publish script #{post_publish_script}")
    ret = BigBlueButton.exec_ret("ruby", post_publish_script, "-m", meeting_id)
    if ret != 0
      BigBlueButton.logger.warn("Post publish script #{post_publish_script} failed")
    end
  end
end

begin
  props = YAML::load(File.open('bigbluebutton.yml'))

  log_dir = props['log_dir']
  recording_dir = props['recording_dir']

  logger = Logger.new("#{log_dir}/bbb-rap-worker.log",'daily' )
  logger.level = Logger::INFO
  BigBlueButton.logger = logger

  BigBlueButton.logger.debug("Running rap-worker...")

  archive_recorded_meeting(recording_dir)
  sanity_archived_meeting(recording_dir)
  process_archived_meeting(recording_dir)
  publish_processed_meeting(recording_dir)

  BigBlueButton.logger.debug("rap-worker done")

rescue Exception => e
  BigBlueButton.logger.error(e.message)
  e.backtrace.each do |traceline|
    BigBlueButton.logger.error(traceline)
  end
end	
