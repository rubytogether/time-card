# frozen_string_literal: true

require 'sinatra'
require 'sequel'
require 'terminal-table'
require 'date'
require 'slack-notifier'

require_relative 'db'

use Rack::Auth::Basic, 'Protected Area' do |username, password|
  username == 'admin' && Digest::SHA2.hexdigest(password) == ENV['TIME_CARD_ADMIN_PASSWORD_HASH']
end

class Report
  def initialize(entries_by_worker, description: '')
    @entries_by_worker = entries_by_worker
    @description = description
  end

  def self.monthly(year:, month:)
    new(
      entries('EXTRACT(year FROM date)::INTEGER = ? AND EXTRACT(month FROM date)::INTEGER = ?', year, month),
      description: "#{'%04d' % year}-#{'%02d' % month}"
    )
  end

  def self.bi_weekly(year:, month:, day:)
    period_end = Date.new(2016, 1, 23)
    current_period_end = Date.new(year, month, day)
    current_period_end -= 1 until Date::DAYNAMES[current_period_end.wday] == 'Saturday'
    current_period_end += 7 unless ((current_period_end - period_end) % 14).zero?
    current_period_start = current_period_end - 13

    new(
      entries('date >= ? AND date <= ?', current_period_start, current_period_end),
      description: "#{current_period_start} to #{current_period_end}"
    )
  end

  def self.entries(*query)
    Entry
      .where(*query)
      .order_by(:worker_id, :date)
      .enum_for
      .group_by(&:worker_id)
      .values
  end

  def all
    @entries_by_worker.map do |entries|
      [entries.first.worker, entries]
    end
  end

  def to_a
    all.map do |worker, entries|
      {
        worker: worker.to_hash,
        entries: entries,
        minutes: entries.reduce(0) { |acc, elem| acc + elem.minutes }
      }
    end
  end

  def to_text
    all.reduce(+'') do |text, (worker, entries)|
      table = Terminal::Table.new headings: %w[Date Hours Description]
      table.title = "#{worker.user_name} (#{@description})"
      total_minutes = 0
      add_row = ->(date, minutes, description) { table.add_row [date&.to_date, '%dh %dm' % [minutes./(60.0), minutes.modulo(60)], description] }
      entries.each do |e|
        total_minutes += e.minutes
        add_row[e.date, e.minutes, word_wrap(e.message)]
      end
      table.add_separator
      add_row[nil, total_minutes, "$#{'%0.2f' % (total_minutes * 2.5)}"]
      text << table.to_s << "\n\n"
    end
  end

  def word_wrap(text, line_width: 80, break_sequence: "\n")
    text.split("\n").collect! do |line|
      line.length > line_width ? line.gsub(
        /(.{1,#{line_width}})(\s+|$)/,
        "\\1#{break_sequence}"
      ).strip : line
    end * break_sequence
  end
end

def notify_slack!(entry)
  return unless url = ENV['SLACK_NOTIFICATION_WEBHOOK_URL']

  notifier = Slack::Notifier.new(url, username: 'time_card')
  attachments = [
    {
      text: notifier.escape(entry.message),
      color: 'good',
      fields: [
        {
          title: 'worker',
          value: entry.worker.user_name,
          short: true
        },
        {
          title: 'date',
          value: entry.date.to_date,
          short: true
        },
        {
          title: 'time',
          value: '%dh %dm' % [entry.minutes./(60.0), entry.minutes.modulo(60)],
          short: true
        }
      ]
    }
  ]
  notifier.ping attachments: attachments
end

get '/' do
  content_type 'application/json'
  Entry.all.to_json
end

get '/report/monthly/:year-:month.?:format?' do
  year = params[:year].to_i
  month = params[:month].to_i
  report = Report.monthly(year: year, month: month)
  case params[:format]
  when 'json'
    content_type 'application/json'
    content_type :json
    report.to_a.to_json
  else
    content_type :text
    report.to_text
  end
end

get '/report/biweekly/:year-:month-:day.?:format?' do
  year, month, day = params.values_at(:year, :month, :day).map(&:to_i)
  report = Report.bi_weekly(year: year, month: month, day: day)
  case params[:format]
  when 'json'
    content_type 'application/json'
    content_type :json
    report.to_a.to_json
  else
    content_type :text
    report.to_text
  end
end

post '/entries' do
  data = JSON.parse(request.body.read)
  data['worker_id'] = Worker.find_or_create(user_name: data.delete('worker')).id
  data['date'] ||= DateTime.now
  e = Entry.create data
  notify_slack!(e)
  redirect "/entries/#{e.id}"
end

get '/entries/:id' do
  content_type 'application/json'
  Entry[params[:id]].to_json(include: :worker)
end

put '/entries/:id' do
  content_type 'application/json'
  Entry[params[:id]].update(JSON.parse(request.body.read))
end

delete '/entries/:id' do
  Entry[params[:id]].delete
end

get '/workers/:id' do
  content_type 'application/json'
  Worker[params[:id]].to_json(include: :entries)
end

put '/workers/:id' do
  content_type 'application/json'
  worker = Worker[params[:id]]
  worker.update(JSON.parse(request.body.read))
  worker.to_json
end

get '/workers' do
  content_type 'application/json'
  Worker.all.to_json
end
