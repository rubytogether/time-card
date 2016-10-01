require 'sinatra'
require 'sequel'

require_relative 'db'

class PostAuth < Rack::Auth::Basic
  def call(env)
    return @app.call(env) if env["REQUEST_METHOD"] == "GET"
    super
  end
end
use PostAuth, 'Protected Area' do |username, password|
  username == 'admin' && Digest::SHA2.hexdigest(password) == ENV['TIME_CARD_ADMIN_PASSWORD_HASH']
end

get '/' do
  Entry.all.to_json
end

get '/report/:year-:month' do
  year = params[:year].to_i
  month = params[:month].to_i
  Worker.all.map do |worker|
    entries = worker.entries_dataset.where('EXTRACT(year FROM date)::INTEGER = ? AND EXTRACT(month FROM date)::INTEGER = ?', year, month)
    {
      worker: worker,
      minutes: entries.sum(:minutes),
      entries: entries
    }
  end.reject { |w| w[:entries].empty? }.to_json
end

post '/entries' do
  data = JSON.load(request.body)
  data['worker_id'] = Worker.find_or_create(user_name: data.delete('worker')).id
  data['date'] ||= DateTime.now
  e = Entry.create data
  redirect "/entries/#{e.id}"
end

get '/entries/:id' do
  Entry[params[:id]].to_json(include: :worker)
end

get '/workers/:id' do
  Worker[params[:id]].to_json(include: :entries)
end

put '/workers/:id' do
  Worker[params[:id]].update(params)
end

get '/workers' do
  Worker.all.to_json
end
