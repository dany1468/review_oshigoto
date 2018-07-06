require 'dotenv/load'
require 'active_support/all'
require 'pry'
require 'tracker_api'
require 'erb'

client = TrackerApi::Client.new(token: ENV['TOKEN'])
project = client.project(ENV['PROJECT_ID'])
stories =
  project.stories(filter: "owner:#{ENV['OWNER']} updated_after:#{7.days.ago.iso8601}").concat(
    project.stories(filter: "owner:#{ENV['OWNER']} state:started,finished,delivered")
  )
stories.uniq! { |s| s['id'] }

STATE_MESSAGE_MAP = {
  started: ':skier: Started at',
  finished: ':confetti_ball: Finished at',
  delivered: ':rocket: Delivered at',
  accepted: ':ok_woman: Accepted at'
}

class StoryRepresentor
  def initialize(story)
    @story = story
  end

  def title
    @story.name
  end

  def estimate
    @story.story_type == 'feature' ? "#{@story.estimate.to_i}pt" : '-'
  end

  def story_type_icon
    case @story.story_type
    when 'chore'
      ':gear:'
    when 'feature'
      ':star:'
    when 'bug'
      ':bug:'
    when 'release'
      ':waving_black_flag:'
    else
      ''
    end
  end

  def current_state_icon
    case @story.current_state
    when 'finished'
      ':checkered_flag:'
    when 'started'
      ':construction:'
    when 'unstarted'
      '-'
    when 'accepted'
      ':ok_woman:'
    when 'delivered'
      ':truck:'
    else
      ''
    end
  end

  def new_story_icon
    if @story.created_at > 7.days.ago
      ':new:'
    else
      ''
    end
  end

  def operating_days
    cycletime[:operating_days]
  end

  def waiting_pr_time
    cycletime[:waiting_pr_time]
  end

  def cycletime
    @cycletime = @cycletime || begin
      body = @story.client.get("/stories/#{@story.id}", params: {fields: 'cycle_time_details'}).body

      if @story.story_type.in?(%w(feature bug))
        started_time = body['cycle_time_details']['started_time']
        finished_time = body['cycle_time_details']['finished_time']
        {
          operating_days: get_duration_hrs_and_mins(started_time),
          waiting_pr_time: get_duration_hrs_and_mins(finished_time)
        }
      elsif @story.story_type == 'chore'
        started_time = body['cycle_time_details']['started_time']

        {
          operating_days: get_duration_hrs_and_mins(started_time),
        }
      else
        ''
      end
    end
  end

  def pulls
    pulls_body = @story.client.get("/stories/#{@story.id}", params: {fields: 'pull_requests'}).body

    if pulls_body && (pulls = pulls_body['pull_requests']).any?
      pulls.map { |pull|
        "#{pull['repo']}/#{pull['number']}"
      }.join('<br />')
    else
      ''
    end
  end

  def tasks
    if @story.tasks.any?
      @story.tasks.sort_by(&:position).map { |task|
        [task.description, task.complete]
      }.map { |task|
        "#{task.last ? ':ballot_box_with_check:' : ':white_large_square:'} #{task.first}"
      }.join('<br />')
    else
      ''
    end
  end

  def comments
    @story.comments.map { |c|
      "-- #{c.created_at.in_time_zone('Tokyo').strftime('%Y/%m/%d %H:%M:%S')}---<br />#{c.text.gsub("\n", '<br />')}"
    }.join('<br/>')
  end

  private

  def get_duration_hrs_and_mins(duration)
    return '-' if duration == 0

    hours = get_duration_hrs duration
    days = hours / 24
    return "#{days}d" if days > 0

    "#{hours}h"
  rescue => e
    puts e.message
    ''
  end

  def get_duration_hrs(duration)
    duration / (1000 * 60 * 60)
  end
end

attachments = stories.map {|story| StoryRepresentor.new(story) }

puts ERB.new(DATA.read).result(binding)
__END__
|||title (:new: は今週追加)|見積|対応期間|レビュー待ち|Tasks|PRs|Comments|
|:--|:--|:--|:--|:--|:--|:--|:--|:--|
<% attachments.each do |y| %>|<%= y.story_type_icon %>|<%= y.current_state_icon %>|<%= y.new_story_icon %><%= y.title %>|<%= y.estimate %>|<%= y.operating_days %>|<%= y.waiting_pr_time %>|<%= y.tasks.html_safe %>|<%= y.pulls.html_safe %>|<%= y.comments.html_safe %>|
<% end %>
