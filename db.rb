# frozen_string_literal: true
DB = Sequel.connect(ENV.fetch('DATABASE_URL') { 'postgres://localhost:5432/time-card' })
Sequel.extension :migration
Sequel::Model.plugin :json_serializer
Sequel::Model.plugin :validation_helpers

migration = Sequel.migration do
  up do
    create_table :workers do
      primary_key :id
      String      :user_name
    end

    create_table :entries do
      primary_key :id
      Integer     :minutes
      String      :message
      DateTime    :date
      foreign_key :worker_id, :workers
    end
  end
end
begin
  migration.apply(DB, :up)
rescue
  nil
end

class Worker < Sequel::Model
  one_to_many :entries
  def validate
    super
    validates_presence :user_name
  end
end

class Entry < Sequel::Model
  many_to_one :worker
  def validate
    super
    validates_presence :minutes
    validates_presence :message
    validates_presence :date
    validates_presence :worker
  end
end
