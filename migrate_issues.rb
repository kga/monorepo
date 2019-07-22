require 'octokit'
require 'pry'
require 'excon'
require 'colored'
require 'json'


class Hendl
  # e.g. KrauseFx/fastlane
  attr_accessor :source
  attr_accessor :destination

  attr_accessor :open_only

  # Reason on why this was necessary
  attr_accessor :reason

  # {
  #   source_login_id: destination_login_id,
  #   ...
  # }
  attr_accessor :user_mapping

  def initialize(source: nil, destination: nil, reason: nil, open_only: false)
    self.source = source
    self.destination = destination
    self.reason = reason
    self.open_only = open_only
    self.user_mapping = JSON.parse(File.read(ENV["USER_MAPPING_JSON"])) rescue {}
    self.start
  end

  def client
    @client ||= Octokit::Client.new(
      access_token: ENV["SOURCE_GITHUB_API_TOKEN"],
      api_endpoint: ENV.fetch("SOURCE_GITHUB_API_ENDPOINT", Octokit.api_endpoint),
    )
  end

  def start
    client.auto_paginate = true
    puts "Fetching issues from '#{source}'..."
    counter = 0
    client.issues(source, per_page: 1000, state: "all").each do |original|
      if self.open_only and original.state != "open"
        puts "Skipping #{original.number} as it's not an open one"
        next
      end

      next unless original.pull_request.nil? # no PRs for now

      labels = original.labels.collect { |a| a[:name] }
      if labels.include?("migrated") or labels.include?("migration_failed")
        puts "Skipping #{original.number} because it's already migrated or failed"
        next
      end

      hendl(original)
      smart_sleep
      counter += 1
    end
    puts "[SUCCESS] Migrated #{counter} issues / PRs"
  end

  def hendl(original)
    puts "Hendling #{original.number}"
    if original.pull_request.nil?
      hendl_issue(original)
    else
      # hendl_pr(original)
    end
  end

  def smart_sleep
    # via https://developer.github.com/guides/best-practices-for-integrators/#dealing-with-abuse-rate-limits
    #   at least one second between requests
    # also https://developer.github.com/v3/#rate-limiting
    #   maximum of 5000 requests an hour => 83 requests per minute
    sleep 2.5
  end

  def table(login, body)
    "<table>
      <tr>
        <td>
          <img src='https://github.com/#{login}.png' width='35'>
        </td>
        <td>
          #{body}
        </td>
      </tr>
    </table>"
  end

  # We copy over all the issues, and also mention everyone
  # so that people are automatically subscribed to notifications
  def hendl_issue(original)
    original_comments = client.issue_comments(source, original.number)
    comments = []
    original_comments.each do |original_comment|
      mapped_login_id = map_login_id(original_comment.user.login)
      table_code = table(mapped_login_id, "@#{mapped_login_id} commented")
      body = [table_code, original_comment.body]
      comments << {
        created_at: original_comment.created_at.iso8601,
        body: body.join("\n\n")
      }
    end

    actual_label = original.labels.collect { |a| a[:name] }

    mapped_login_id = map_login_id(original.user.login)

    table_link = "Imported from <a href='#{original.html_url}'>#{source}##{original.number}</a>"
    table_code = table(mapped_login_id, "Original issue by @#{mapped_login_id} - #{table_link}")
    body = [table_code, original.body]
    data = {
      issue: {
        title: original.title,
        body: body.join("\n\n"),
        created_at: original.created_at.iso8601,
        assignee: original.assignee.nil? ? nil : map_login_id(original.assignee.login),
        labels: actual_label,
        closed: original.state != "open"
      },
      comments: comments
    }
    data[:issue][:closed_at] = original.closed_at.iso8601 if original.state != "open"

    response = Excon.post("https://api.github.com/repos/#{destination}/import/issues", body: data.to_json, headers: destination_request_headers)
    response = JSON.parse(response.body)
    status_url = response['url']
    puts response

    new_issue_url = nil

    begin
      (5..35).each do |request_num|
        sleep(request_num)

        puts "Sending #{status_url}"
        async_response = Excon.get(status_url, headers: destination_request_headers) # if this crashes, make sure to have a valid token with admin permission to the actual repo
        async_response = JSON.parse(async_response.body)
        puts async_response.to_s.yellow

        new_issue_url = async_response['issue_url']
        break if new_issue_url.to_s.length > 0
        puts "unable to get new issue url for #{original.number} after #{request_num - 4} requests".yellow
      end
    rescue => ex
      puts "Something went wrong, wups"
      puts ex.to_s
      # If the error message is
      # {"message"=>"Not Found", "documentation_url"=>"https://developer.github.com/v3"}
      # that just means that fastlane-bot doesn't have admin access
    end

    if new_issue_url.to_s.length > 0
      new_issue_url.gsub!("api.github.com/repos", "github.com")

      client.update_issue(source, original.number, labels: (actual_label + ["migrated"]))

      # reason, link to the new issue
      puts "closing old issue #{original.number}"
      body = []
      body << "This issue was migrated to #{new_issue_url}. Please post all further comments there."
      body << reason unless reason.nil?
      puts new_issue_url
      client.add_comment(source, original.number, body.join("\n\n"))
      smart_sleep
      client.close_issue(source, original.number) unless original.state == "closed"
    else
      puts "unable to find new issue url, not closing or commenting".red
      client.update_issue(source, original.number, labels: (actual_label + ["migration_failed"]))
      puts "Status URL: #{status_url}"
      # This means we have to manually migrate the issue
      # if you want to try it again, just remove the migration_failed tag
    end
  end

  def source_request_headers
    request_headers(ENV["SOURCE_GITHUB_API_TOKEN"])
  end

  def destination_request_headers
    request_headers(ENV["DESTINATION_GITHUB_API_TOKEN"])
  end

  def request_headers(token)
    {
      "Accept" => "application/vnd.github.golden-comet-preview+json",
      "Authorization" => ("token " + token),
      "Content-Type" => "application/x-www-form-urlencoded",
      "User-Agent" => "fastlane bot"
    }
  end

  # We want to comment on PRs and tell the user to re-submit it
  # on the new repo, as we can't migrate them automatically
  def hendl_pr(original)
    puts "#{original.number} is a pull request"
    if original.state != "open"
      puts "#{original.number} is already closed - nothing to do here"
      return
    end

    body = ["Hello @#{original.user.login},"]
    body << reason
    body << "Sorry for the troubles, we'd appreciate if you could re-submit your Pull Request with these changes to the new repository"

    client.add_comment(source, original.number, body.join("\n\n"))
    smart_sleep
    client.close_pull_request(source, original.number)
  end

  def map_login_id(source_login_id)
    user_mapping.fetch(source_login_id, source_login_id)
  end
end

# foo/bar, baz/qux, 'blah blah blah'
source, destination, reason = *ARGV

open_only = !!ENV["OPE_ONLY"].to_i

puts "Migrating #{source} -> #{destination}"

Hendl.new(
  source: source,
  destination: destination,
  reason: reason,
  open_only: open_only,
)
