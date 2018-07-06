require 'dotenv/load'
require 'furik'
require 'slack'
require 'pry'
require 'tracker_api'

Slack.configure do |config|
  config.token = ENV['SLACK_API_TOKEN']
end

slack_client = Slack::Web::Client.new

date = Date.today

client = TrackerApi::Client.new(token: ENV['TOKEN'])
project = client.project(ENV['PROJECT_ID'])
stories =
  project.stories(filter: "owner:#{ENV['OWNER']} updated_after:#{DateTime.now.yesterday.iso8601}").concat(
    project.stories(filter: "owner:#{ENV['OWNER']} state:started,finished,delivered")
  )
stories.uniq! { |s| s['id'] }

STATE_MESSAGE_MAP = {
  started: ':skier: Started at',
  finished: ':confetti_ball: Finished at',
  delivered: ':rocket: Delivered at',
  accepted: ':ok_woman: Accepted at'
}

def describe(s)
  fields = []
  states = %w(started finished delivered accepted)

  if s.current_state.in?(states)
    transitions = s.transitions

    fields.concat(states.map { |state|
      occurred_at = transitions.select { |tr| tr.state == state }.sort_by(&:occurred_at).first&.occurred_at

      if occurred_at
        {
          title: STATE_MESSAGE_MAP[state.to_sym],
          value: occurred_at.in_time_zone('Tokyo').strftime('%Y/%m/%d %H:%M:%S'),
          short: true
        }
      else
        nil
      end
    }.compact)
  end

  if s.tasks.any?
    puts 'tasks --'
    tasks = s.tasks
    task_values = tasks.sort_by(&:position).map { |task| [task.description, task.complete] }.map do |task|
      "#{task.last ? ':ballot_box_with_check:' : ':black_medium_square:'} #{task.first}"
    end
    fields << {
      title: ':heavy_check_mark: Tasks',
      value: task_values.join("\n")
    }
  end

  pulls_body = s.client.get("/stories/#{s.id}", params: {fields: 'pull_requests'}).body
  if pulls_body && (pulls = pulls_body['pull_requests']).any?
    puts 'pull requests'
    pull_values = pulls.map do |pull|
      "#{pull['repo']}/#{pull['number']}"
    end
    fields << {
      title: ':merge: PRs',
      value: pull_values.join("\n")
    }
  end

  fields
end

attachments = stories.map { |story|
  story_type =
    case story.story_type
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

  color =
    case story.current_state
    when 'finished'
      '#223F62'
    when 'started'
      '#F3F3D3'
    when 'unstarted'
      '#E0E2E5'
    when 'accepted'
      '#639019'
    when 'delivered'
      '#F19225'
    else
      ''
    end
  {
    title: "#{story_type} #{story.name} (#{story.estimate.to_i} p)",
    color: color,
    fields: describe(story)
  }
}

github_attachments = []

Furik.events_with_grouping(gh: true, ghe: nil, from: date, to: date) do |repo, events|
  fields = []

  events.sort_by(&:type).reverse.each_with_object({keys: []}) do |event, memo|

    payload_type = event.type.
      gsub('Event', '').
      gsub(/.*Comment/, 'Comment').
      gsub('Issues', 'Issue').
      underscore
    payload = event.payload.send(:"#{payload_type}")
    type = payload_type.dup
    action = event.payload.action # closed, created
    action_type =
      case action
      when 'opened'
        ':new:'
      when 'closed'
        ':clap:'
      else
        ''
      end

    title =
      case event.type
      when 'IssueCommentEvent'
        "#{payload.body.plain.cut} (#{event.payload.issue.title.cut(50)})"
      when 'CommitCommentEvent'
        payload.body.plain.cut
      when 'IssuesEvent'
        type = "#{event.payload.action}_#{type}"
        payload.title.plain.cut
      when 'PullRequestReviewCommentEvent'
        type = 'comment'
        if event.payload.pull_request.respond_to?(:title)
          "#{payload.body.plain.cut} (#{event.payload.pull_request.title.cut(50)})"
        else
          payload.body.plain.cut
        end
      else
        payload.title.plain
      end

    link = payload.html_url
    key = "#{type}-#{link}"

    next if memo[:keys].include?(key)
    memo[:keys] << key

    if type == 'pull_request'
      fields << {
        title: ":merge: #{action_type} #{title}",
        value: link,
      }
    else
      fields << {
        title: ":speech_balloon: #{title}",
        value: link,
      }
    end
  end

  github_attachments << {
    title: ":repo: #{repo}",
    fields: fields
  }
end

slack_client.chat_postMessage(
  channel: '#dany-daily-log',
  text: "*日報 #{Date.today.strftime('%Y/%m/%d')}*"
)

slack_client.chat_postMessage(
  channel: '#dany-daily-log',
  text: ":pivotal: *Today's Activity*",
  attachments: attachments
)

slack_client.chat_postMessage(
  channel: '#dany-daily-log',
  text: ":github: *Today's Activity*",
  attachments: github_attachments
)
